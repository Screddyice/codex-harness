#!/usr/bin/env bash

# Base-branch selection on the auto-pr-push hook.
#
# Two defects, and they cancelled out often enough to stay hidden.
#
# 1. `gh pr create` was called with no `--base` at all, so GitHub used the repo's
#    DEFAULT branch regardless of what the hook had measured "commits ahead"
#    against. The PR base and the precondition came from different refs.
# 2. HOOK_BASE only ever looked for main/master. A repo whose integration branch
#    is anything else was measured against a ref the work does not belong on.
#
# Seen live on 2026-08-17: teamnebula-ai/nebos-v2#365 opened against `main` when
# every PR in that repo targets `dev`. Same class as the Nebby follow-up bug --
# a PR whose base is guessed rather than derived from where the work forked.
#
# The fix picks, among candidate integration refs that actually exist, the one
# HEAD forked from most recently (fewest commits ahead), and then PASSES it to
# `gh pr create` so the two can no longer disagree.
#
# AUTO_PR_PUSH_DRYRUN keeps this off the network, and it returns before `gh pr
# create`, so the hook's own log is the observable -- it now names the base it
# resolved and the --base it would pass. The hook backgrounds its work, so each
# case polls rather than assuming.

set -eu

hook="$(cd "$(dirname "$0")" && pwd)/hooks/auto-pr-push.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
logdir="$tmp/logs"
log="$logdir/auto-pr-push.log"
argv="$tmp/gh-argv"
mkdir -p "$repo" "$logdir" "$tmp/bin"

git -C "$repo" init -q -b main
git -C "$repo" config user.email t@t.t
git -C "$repo" config user.name t
git -C "$repo" remote add origin https://github.com/screddyice/repo.git
printf 'base\n' > "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -qm base
git -C "$repo" update-ref refs/remotes/origin/main HEAD

# `dev` is the integration branch and has moved on past main, exactly as
# nebos-v2's has. A branch cut from dev is therefore FEWER commits ahead of dev
# than of main, which is the signal the fix keys on.
git -C "$repo" checkout -q -b dev
printf 'dev-only\n' >> "$repo/a.txt"
git -C "$repo" commit -qam 'dev moves ahead'
git -C "$repo" update-ref refs/remotes/origin/dev HEAD

# Mocked gh. Records argv so the test can assert on --base.
cat > "$tmp/bin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$argv"
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr list") printf '0\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

run() {
  : > "$log"
  : > "$argv"
  printf '{"cwd": "%s"}' "$repo" \
    | env HARNESS_PR_OWNERS='screddyice' HARNESS_HOOK_LOG_DIR="$logdir" \
          AUTO_PR_PUSH_DRYRUN=1 "$hook" >/dev/null 2>&1
  for _ in $(seq 1 100); do
    [ -s "$log" ] && return 0
    sleep 0.1
  done
  return 0
}

fail() { echo "FAIL: $1" >&2; echo "--- log ---" >&2; cat "$log" >&2;
         echo "--- gh argv ---" >&2; cat "$argv" 2>/dev/null >&2; exit 1; }

# 1. Forked from dev -> the PR must target dev, not the repo default.
git -C "$repo" checkout -q -b feat/be-from-dev refs/remotes/origin/dev
printf 'work\n' >> "$repo/a.txt"
git -C "$repo" commit -qam work
run
grep -q 'DRYRUN' "$log" || fail "a branch with new work should be pushed/PR'd"
grep -q 'base=dev' "$log" \
  || fail "a branch cut from dev must open its PR against dev, not the repo default"
grep -q -- '--base dev' "$log" \
  || fail "the resolved base must be passed to gh pr create, not left to the repo default"
grep -q 'base=main' "$log" \
  && fail "targeting main here is the nebos-v2#365 bug"
grep -q 'ahead=1' "$log" \
  || fail "ahead must be measured against dev (1), not main (2)"

# 2. The ahead-count must be measured against the SAME ref the PR targets.
#    Against main this branch is 2 ahead (dev's commit + its own); against dev, 1.
[ "$(git -C "$repo" rev-list --count refs/remotes/origin/dev..HEAD)" = "1" ] \
  || fail "test setup: branch should be exactly 1 commit ahead of dev"
[ "$(git -C "$repo" rev-list --count refs/remotes/origin/main..HEAD)" = "2" ] \
  || fail "test setup: branch should be 2 commits ahead of main"

# 3. Forked from main in the same repo -> must still target main. The fix must
#    derive the base per branch, not pin the whole repo to one answer.
git -C "$repo" checkout -q -b feat/be-from-main refs/remotes/origin/main
printf 'other\n' > "$repo/b.txt"
git -C "$repo" add b.txt
git -C "$repo" commit -qm 'work off main'
run
grep -q -- '--base main' "$log" \
  || fail "a branch cut from main must open its PR against main"

# 4. A repo with only main still works -- the candidate list must degrade, not fail.
repo2="$tmp/repo2"; mkdir -p "$repo2"
git -C "$repo2" init -q -b main
git -C "$repo2" config user.email t@t.t
git -C "$repo2" config user.name t
git -C "$repo2" remote add origin https://github.com/screddyice/repo2.git
printf 'x\n' > "$repo2/a.txt"
git -C "$repo2" add a.txt
git -C "$repo2" commit -qm base
git -C "$repo2" update-ref refs/remotes/origin/main HEAD
git -C "$repo2" checkout -q -b feat/be-only-main
printf 'y\n' >> "$repo2/a.txt"
git -C "$repo2" commit -qam work
: > "$log"; : > "$argv"
printf '{"cwd": "%s"}' "$repo2" \
  | env HARNESS_PR_OWNERS='screddyice' HARNESS_HOOK_LOG_DIR="$logdir" \
        AUTO_PR_PUSH_DRYRUN=1 "$hook" >/dev/null 2>&1
for _ in $(seq 1 100); do [ -s "$log" ] && break; sleep 0.1; done
grep -q -- '--base main' "$log" \
  || fail "a repo with only main must still target main"

# 5. A STALE LOCAL branch must never beat its remote-tracking ref.
#    After a squash merge origin/main carries a commit the branch lacks, so it
#    scores 1 WORSE on divergence than an untouched local main. Scoring both tiers
#    together therefore picks the stale local ref, and the "base already contains
#    this tree" guard silently stops firing -- which is the llm-jury#18 duplicate-PR
#    bug. Caught by test-auto-pr-push-merged-guard case 4; pinned here too because
#    that test asserts the guard, not the ref that broke it.
git -C "$repo" checkout -q feat/be-from-main
squash_tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
squash_commit="$(git -C "$repo" commit-tree "$squash_tree" \
  -p "$(git -C "$repo" rev-parse refs/remotes/origin/main)" -m 'squash merge')"
git -C "$repo" update-ref refs/remotes/origin/main "$squash_commit"
# Local main is deliberately left at the old tip, as a real checkout would be.
[ "$(git -C "$repo" rev-parse main)" != "$(git -C "$repo" rev-parse refs/remotes/origin/main)" ] \
  || fail "test setup: local main must be stale for this to exercise anything"
run
grep -q '\[skip\].*adds nothing' "$log" \
  || fail "origin/main must outrank a stale local main, or the merged-work guard goes blind"

echo "PASS auto-pr-push base-branch selection"
