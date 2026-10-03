#!/usr/bin/env bash

# Duplicate-PR guard on the auto-pr-push hook.
#
# The hook asks `gh pr list --state open` to decide whether a branch still needs
# a PR. After a SQUASH merge the branch's PR is MERGED rather than open, so that
# count is 0 and the hook opened a *second* PR for work already on the base --
# and its push re-created the remote branch the merge had just deleted. Squash
# merges also leave the branch's commits out of the base's ancestry, so the
# "commits ahead of base" precondition stays true and cannot catch it.
#
# Seen live on 2026-07-31: Screddyice/llm-jury#18 was opened ten seconds after
# #17 squash-merged, containing the same three commits and an empty diff.
#
# Two guards now run before the push. This exercises both, plus the two cases
# that must still proceed. `gh` is mocked; AUTO_PR_PUSH_DRYRUN keeps the run off
# the network, and the hook's own log is the observable.
#
# The hook does its work in a detached background job, so each case polls for a
# log line rather than assuming it has already been written.

set -eu

hook="$(cd "$(dirname "$0")" && pwd)/hooks/auto-pr-push.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
logdir="$tmp/logs"
log="$logdir/auto-pr-push.log"
mkdir -p "$repo" "$logdir" "$tmp/bin"

git -C "$repo" init -q -b main
git -C "$repo" config user.email t@t.t
git -C "$repo" config user.name t
git -C "$repo" remote add origin https://github.com/screddyice/repo.git
printf 'base\n' > "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -qm base
# A local origin/main ref, as a real checkout would have.
git -C "$repo" update-ref refs/remotes/origin/main HEAD

git -C "$repo" checkout -qb feat/guard
printf 'work\n' > "$repo/a.txt"
git -C "$repo" commit -qam work
head_oid="$(git -C "$repo" rev-parse HEAD)"

# Mocked gh. MOCK_MERGED_OID is the head SHA of a merged PR for this branch, if
# any; empty means no merged PR exists.
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list")
    case "$*" in
      *"--state merged"*) [ -n "${MOCK_MERGED_OID:-}" ] && printf '%s\n' "$MOCK_MERGED_OID" ;;
      *) printf '0\n' ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

run() { # run <label>; echoes nothing, leaves output in $log
  : > "$log"
  printf '{"cwd": "%s"}' "$repo" \
    | env HARNESS_PR_OWNERS='screddyice' HARNESS_HOOK_LOG_DIR="$logdir" \
          AUTO_PR_PUSH_DRYRUN=1 "$hook" >/dev/null 2>&1
  # The hook backgrounds its work; wait for it to land (bounded).
  for _ in $(seq 1 100); do
    [ -s "$log" ] && return 0
    sleep 0.1
  done
  return 0
}

fail() { echo "FAIL: $1" >&2; echo "--- log ---" >&2; cat "$log" >&2; exit 1; }

# 1. No merged PR, branch adds work -> must still propose.
MOCK_MERGED_OID='' run
grep -q 'DRYRUN' "$log" || fail "a branch with new work should still be pushed/PR'd"

# 2. This exact commit is already merged -> must skip (the llm-jury#18 case).
MOCK_MERGED_OID="$head_oid" run
grep -q '\[skip\].*already merged' "$log" \
  || fail "a branch whose HEAD is already merged must not be re-proposed"
grep -q 'DRYRUN' "$log" && fail "guard fired but the hook still intended to push"

# 2b. Checkout stopped pulling before the PR merged: the merged head is a later
#     commit of this branch and HEAD is its ancestor -> must skip, not re-propose.
git -C "$repo" commit -q --allow-empty -m 'landed on the remote after this checkout stopped pulling'
later_oid="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" reset -q --hard "$head_oid"
MOCK_MERGED_OID="$later_oid" run
grep -q '\[skip\].*already merged' "$log" \
  || fail "a branch behind its merged PR head must not be re-proposed"
grep -q 'DRYRUN' "$log" && fail "behind-merged guard fired but the hook still intended to push"

# 3. Branch reused for NEW commits after its PR merged -> must proceed again.
#    Guards keyed on the merged SHA, not the branch name, so this stays possible.
printf 'more\n' >> "$repo/a.txt"
git -C "$repo" commit -qam more
MOCK_MERGED_OID="$head_oid" run
grep -q 'DRYRUN' "$log" \
  || fail "new commits after a merged PR must get a fresh PR"

# 4. Base already contains this tree -> skip without needing the network.
#    Built as a real squash merge would leave things: origin/main gains a commit
#    carrying the branch's tree, so the branch is still "ahead" (its own commits
#    are not in that ancestry) while adding nothing. Pointing origin/main at HEAD
#    instead would make it 0 ahead, and the hook would bail earlier for an
#    unrelated reason -- passing the assertion without exercising the guard.
squash_tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
squash_commit="$(git -C "$repo" commit-tree "$squash_tree" \
  -p "$(git -C "$repo" rev-parse refs/remotes/origin/main)" -m 'squash merge')"
git -C "$repo" update-ref refs/remotes/origin/main "$squash_commit"
[ "$(git -C "$repo" rev-list --count refs/remotes/origin/main..HEAD)" -gt 0 ] \
  || fail "test setup: branch must still be ahead for the guard to be reachable"
MOCK_MERGED_OID='' run
grep -q '\[skip\].*adds nothing' "$log" \
  || fail "a branch adding nothing over its base should not be proposed"

echo "PASS auto-pr-push duplicate-PR guard"
