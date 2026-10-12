#!/usr/bin/env bash
# Tests for scripts/agent-worktree.sh. The first one reproduces the 2026-09-05
# incident: a branch already checked out elsewhere, which made `worktree add`
# fail, `cd` fail, and the following git command run in the caller's directory.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SUT="$HERE/agent-worktree.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir -p "$repo"; cd "$repo"
git init -q -b main .; git config user.email a@b.c; git config user.name t
echo one > f; git add f; git -c commit.gpgsign=false commit -qm one
git branch taken

# 1. THE INCIDENT. Ask for a branch that is already checked out.
git worktree add -q "$tmp/held" taken
canary="$tmp/canary"; mkdir -p "$canary"; cd "$canary"
out=$("$SUT" "$repo" taken main -- git init -q . 2>&1); rc=$?
if [ $rc -ne 0 ] && [ ! -d "$canary/.git" ]; then
  ok "refuses a branch checked out elsewhere, and runs nothing in the caller's cwd"
else
  bad "refuses a branch checked out elsewhere" "rc=$rc, canary git dir: $([ -d "$canary/.git" ] && echo CREATED || echo none)"
fi
case "$out" in *"already checked out"*) ok "the refusal names the reason" ;;
  *) bad "the refusal names the reason" "got: $out" ;; esac

# 2. The happy path still works, and the command runs INSIDE the worktree.
cd "$canary"
# Assert on the COMMAND's own output, not the script's banner: an earlier
# version of this test matched the banner and passed while the command never ran.
got=$("$SUT" "$repo" fresh main -- sh -c 'printf RAN_IN=%s "$PWD"' 2>/dev/null | tr -d '\n' | sed 's/.*RAN_IN=//')
case "$got" in
  "") bad "command runs inside the worktree" "the command produced no output — it did not run" ;;
  "$canary"*) bad "command runs inside the worktree" "ran in the caller's cwd: $got" ;;
  */agent-wt-*) ok "command runs inside the new worktree ($got)" ;;
  *) bad "command runs inside the worktree" "unexpected: $got" ;;
esac

# 3. The worktree is cleaned up, leaving no stale registration.
left=$(git -C "$repo" worktree list | grep -c agent-wt- || true)
[ "$left" = 0 ] && ok "worktree is removed after the command" || bad "worktree is removed" "$left left"

# 4. A missing repo is rejected rather than half-run.
cd "$canary"
"$SUT" "$tmp/nope" b main -- true >/dev/null 2>&1 && bad "rejects a non-repo" "exit 0" || ok "rejects a non-repo"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
