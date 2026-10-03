#!/usr/bin/env bash

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
hooks="$repo_root/scripts/hooks"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/runtime"
git -C "$tmp/repo" init -q -b main
git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid \
  commit --allow-empty -qm "initial"
git -C "$tmp/repo" remote add origin https://github.com/example/repo.git
git -C "$tmp/repo" switch -qc feat/test
git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid \
  commit --allow-empty -qm "change"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${MOCK_GH_MODE:-missing}" = "error" ]; then exit 1; fi' \
  'if [ "${MOCK_GH_MODE:-missing}" = "present" ]; then echo 1; else echo 0; fi' \
  > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

payload="$(printf '{\"cwd\":\"%s\"}' "$tmp/repo")"

codex_output="$(printf '%s' "$payload" | PATH="$tmp/bin:$PATH" TMPDIR="$tmp/runtime" \
  "$hooks/enforce-pr-codex.sh")"
printf '%s' "$codex_output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["continue"] is False
assert "feat/test" in result["systemMessage"]
'

codex_silent="$(printf '%s' "$payload" | PATH="$tmp/bin:$PATH" MOCK_GH_MODE=present \
  TMPDIR="$tmp/runtime" "$hooks/enforce-pr-codex.sh")"
[ -z "$codex_silent" ]

printf '%s\n' '#!/usr/bin/env bash' 'echo "defect in app.py: broken branch"' 'exit 2' \
  > "$tmp/reviewer.sh"
chmod +x "$tmp/reviewer.sh"
review_output="$(printf '{}' | CODEX_LOCAL_REVIEWER="$tmp/reviewer.sh" \
  "$hooks/local-diff-review-codex.sh")"
printf '%s' "$review_output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["continue"] is False
assert "defect in app.py" in result["systemMessage"]
'

echo "PASS shared Codex hooks"

# --- PR base resolution -----------------------------------------------------
#
# Where a branch FORKED is not always where a PR may LAND. In a repo with an
# integration branch, trunk is a deploy branch: nebos-v2's guard-main-base.yml
# accepts only dev, promote/* and hotfix/* at main. A branch cut from main still
# scores main as its fork point, so the hook aimed there and CI rejected it on
# arrival — nebos-v2 #531 and #532, and #365 before them.

base_repo() {
  # $1 = dir, $2 = branch to create, rest = extra branches to create off main
  local d="$1" br="$2"; shift 2
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" -c user.name=T -c user.email=t@e.invalid commit --allow-empty -qm init
  git -C "$d" remote add origin https://github.com/example/repo.git
  # Remote-tracking refs: the resolver scores those alone when any exist.
  git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse main)"
  local extra
  for extra in "$@"; do
    git -C "$d" update-ref "refs/remotes/origin/$extra" "$(git -C "$d" rev-parse main)"
  done
  git -C "$d" switch -qc "$br"
  git -C "$d" -c user.name=T -c user.email=t@e.invalid commit --allow-empty -qm work
}

resolved_base() {
  ( cd "$1" && . "$hooks/hook-common.sh" && hook_load_branch_context >/dev/null 2>&1 \
      && printf '%s' "$HOOK_BASE_BRANCH" )
}

# A feature branch forked from main, in a repo that has dev, must aim at dev.
base_repo "$tmp/base-dev" "fix/thing" dev
got="$(resolved_base "$tmp/base-dev")"
[ "$got" = "dev" ] || { echo "FAIL: fix/* in a dev repo resolved to '$got', expected dev"; exit 1; }

# A main-based branch must not be moved to a dev branch that cannot contain its fork point.
diverged_main_dev_repo() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  local c="git -C $d -c user.name=T -c user.email=t@e.invalid"
  $c commit --allow-empty -qm init
  git -C "$d" remote add origin https://github.com/example/repo.git
  git -C "$d" switch -qc dev
  $c commit --allow-empty -qm d1
  git -C "$d" update-ref refs/remotes/origin/dev "$(git -C "$d" rev-parse dev)"
  git -C "$d" switch main
  $c commit --allow-empty -qm m1
  git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse main)"
  git -C "$d" switch -qc fix/from-main
  $c commit --allow-empty -qm work
}

diverged_main_dev_repo "$tmp/base-diverged-dev"
got="$(resolved_base "$tmp/base-diverged-dev")"
[ "$got" = "main" ] || { echo "FAIL: main-based branch in diverged dev repo resolved to '$got', expected main"; exit 1; }

# hotfix/* is an explicit escape hatch and keeps trunk.
base_repo "$tmp/base-hotfix" "hotfix/outage" dev
got="$(resolved_base "$tmp/base-hotfix")"
[ "$got" = "main" ] || { echo "FAIL: hotfix/* resolved to '$got', expected main"; exit 1; }

# A repo with no integration branch is untouched — most repos are this.
base_repo "$tmp/base-trunk" "fix/thing"
got="$(resolved_base "$tmp/base-trunk")"
[ "$got" = "main" ] || { echo "FAIL: trunk-only repo resolved to '$got', expected main"; exit 1; }

# The repo declaring its own base beats the hook guessing at it.
base_repo "$tmp/base-declared" "fix/thing" dev staging
mkdir -p "$tmp/base-declared/.codex-harness"
printf 'staging\n' > "$tmp/base-declared/.codex-harness/pr-base"
got="$(resolved_base "$tmp/base-declared")"
[ "$got" = "staging" ] || { echo "FAIL: declared base resolved to '$got', expected staging"; exit 1; }

echo "PR base resolution: ok"

# --- Stacked branches -------------------------------------------------------
#
# The fork-point scorer only knows trunk and the integration branches, so a branch
# cut from another FEATURE branch scored dev or main, and the PR carried the
# parent's commits as its own: three of them on nebos-v2 #531, ten on the branch
# behind #508.

stacked_repo() {
  # main <- origin/feat/parent (3) <- feat/child (2), with origin/dev present so the
  # integration rule would otherwise claim this branch.
  local d="$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  local c="git -C $d -c user.name=T -c user.email=t@e.invalid"
  $c commit --allow-empty -qm init
  git -C "$d" remote add origin https://github.com/example/repo.git
  git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse main)"
  git -C "$d" update-ref refs/remotes/origin/dev "$(git -C "$d" rev-parse main)"
  git -C "$d" switch -qc feat/parent
  $c commit --allow-empty -qm p1; $c commit --allow-empty -qm p2; $c commit --allow-empty -qm p3
  git -C "$d" update-ref refs/remotes/origin/feat/parent "$(git -C "$d" rev-parse feat/parent)"
  git -C "$d" switch -qc feat/child
  $c commit --allow-empty -qm c1; $c commit --allow-empty -qm c2
}

stacked_repo "$tmp/stacked"
got="$(resolved_base "$tmp/stacked")"
[ "$got" = "feat/parent" ] || { echo "FAIL: stacked branch resolved to '$got', expected feat/parent"; exit 1; }
# And it must propose only its OWN two commits, not the parent's three.
ahead="$( cd "$tmp/stacked" && . "$hooks/hook-common.sh" && hook_load_branch_context >/dev/null 2>&1 \
    && printf '%s' "$HOOK_AHEAD" )"
[ "$ahead" = "2" ] || { echo "FAIL: stacked branch would carry $ahead commits, expected 2"; exit 1; }

# A branch forked straight off dev must NOT be dragged onto some other branch that
# happens to share history. Tightening only ever moves the base FORWARD.
plain_dev_repo() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b main
  local c="git -C $d -c user.name=T -c user.email=t@e.invalid"
  $c commit --allow-empty -qm init
  git -C "$d" remote add origin https://github.com/example/repo.git
  git -C "$d" update-ref refs/remotes/origin/main "$(git -C "$d" rev-parse main)"
  git -C "$d" switch -qc dev
  $c commit --allow-empty -qm d1
  git -C "$d" update-ref refs/remotes/origin/dev "$(git -C "$d" rev-parse dev)"
  git -C "$d" switch -qc feat/off-dev
  $c commit --allow-empty -qm f1
}

plain_dev_repo "$tmp/plain-dev"
got="$(resolved_base "$tmp/plain-dev")"
[ "$got" = "dev" ] || { echo "FAIL: branch off dev resolved to '$got', expected dev"; exit 1; }

echo "stacked-branch base resolution: ok"
