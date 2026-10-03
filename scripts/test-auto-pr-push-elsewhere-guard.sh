#!/usr/bin/env bash

# Cross-branch duplicate-PR guard, plus the opt-out by branch name.
#
# Push a local branch's HEAD to a DIFFERENT remote branch -- `git push origin
# HEAD:feat/real` while sitting on a throwaway integration branch -- and the
# work is under review under a name this checkout has never heard of. The
# merged-PR guard cannot see it: that asks `--head "$HOOK_BRANCH"` and the PR is
# on `feat/real`. So the hook pushed the scratch name as well and opened a
# second PR for commits already in review.
#
# Observed 2026-08-25 in Screddyice/backdoor: #51 and #52 appeared for the
# `pr47-check` and `pr44-check` branches used to test-merge #47 and #44.
#
# `gh` is mocked; AUTO_PR_PUSH_DRYRUN keeps the run off the network, and the
# hook's own log is the observable. The hook works in a detached background job,
# so each case polls for a log line rather than assuming one is there.

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
git -C "$repo" update-ref refs/remotes/origin/main HEAD

# The throwaway integration branch, standing in for pr44-check.
git -C "$repo" checkout -qb pr44-check
printf 'work\n' > "$repo/a.txt"
git -C "$repo" commit -qam work
head_oid="$(git -C "$repo" rev-parse HEAD)"

# Mocked gh.
#   MOCK_ELSEWHERE_OID  head SHA of a PR on some other branch, if any
#   MOCK_ELSEWHERE_STATE  OPEN / MERGED / CLOSED for that PR
# The hook's --state all query is answered with the jq-shaped string the real
# call produces: "#<n> <branch>", or nothing.
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list")
    case "$*" in
      *"--state all"*)
        if [ -n "${MOCK_ELSEWHERE_JUNK:-}" ]; then
          printf '%s\n' "$MOCK_ELSEWHERE_JUNK"
        elif [ -n "${MOCK_ELSEWHERE_OID:-}" ] \
           && [ "${MOCK_ELSEWHERE_STATE:-OPEN}" != "CLOSED" ]; then
          printf '#77 feat/real\n'
        fi
        ;;
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

run() { # run [extra env assignments...]
  : > "$log"
  printf '{"cwd": "%s"}' "$repo" \
    | env HARNESS_PR_OWNERS='screddyice' HARNESS_HOOK_LOG_DIR="$logdir" \
          AUTO_PR_PUSH_DRYRUN=1 "$@" "$hook" >/dev/null 2>&1
  for _ in $(seq 1 100); do
    [ -s "$log" ] && return 0
    sleep 0.1
  done
  return 0
}

fail() { echo "FAIL: $1" >&2; echo "--- log ---" >&2; cat "$log" >&2; exit 1; }

# 1. Nothing under review anywhere -> must still propose.
run MOCK_ELSEWHERE_OID=''
grep -q 'DRYRUN' "$log" || fail "a branch with unreviewed work should still be proposed"

# 2. This exact commit is open under another branch -> skip, and name it.
run MOCK_ELSEWHERE_OID="$head_oid" MOCK_ELSEWHERE_STATE=OPEN
grep -q '\[skip\].*already under review as #77 feat/real' "$log" \
  || fail "a head already under review elsewhere must not get a second PR"
grep -q 'DRYRUN' "$log" && fail "guard fired but the hook still intended to push"

# 3. Same, but that PR has MERGED. Still no second PR: the work landed.
run MOCK_ELSEWHERE_OID="$head_oid" MOCK_ELSEWHERE_STATE=MERGED
grep -q '\[skip\].*already under review' "$log" \
  || fail "a head merged under another branch must not be re-proposed"

# 4. That PR was CLOSED unmerged. Rejected work has no review surface, so this
#    branch does need its own PR.
run MOCK_ELSEWHERE_OID="$head_oid" MOCK_ELSEWHERE_STATE=CLOSED
grep -q 'DRYRUN' "$log" \
  || fail "a head whose only other PR was closed unmerged still needs one"

# 5. Branch reused for a NEW commit -> the match is stale, propose again.
#    The mock keys on presence, not equality, so drive this by clearing it the
#    way a real gh would once the SHA no longer matches any PR.
printf 'more\n' >> "$repo/a.txt"
git -C "$repo" commit -qam more
run MOCK_ELSEWHERE_OID=''
grep -q 'DRYRUN' "$log" || fail "new commits must get their own PR"

# 6. Explicit opt-out by branch name. Off unless asked for: case 1 already
#    proved this same branch is proposed without the variable.
run MOCK_ELSEWHERE_OID='' HARNESS_PR_SKIP_BRANCHES='pr*-check scratch/*'
grep -q 'DRYRUN' "$log" \
  && fail "HARNESS_PR_SKIP_BRANCHES did not exempt a matching branch"

# 7. A non-matching pattern must not exempt anything.
run MOCK_ELSEWHERE_OID='' HARNESS_PR_SKIP_BRANCHES='scratch/*'
grep -q 'DRYRUN' "$log" \
  || fail "HARNESS_PR_SKIP_BRANCHES exempted a branch it does not match"

# 8. gh answers with something that is not "#<n> <branch>". The guard SUPPRESSES
#    a PR, so an unrecognised answer must fail toward opening one rather than
#    silently withholding review. Caught for real by the two older auto-pr-push
#    tests, whose gh mocks answer an unknown `pr list` query with `0`: a
#    non-empty check treated that as a match and stopped proposing PRs for
#    every branch they exercise.
for junk in '0' 'gh: deprecation warning' '#notanumber feat/real' '#77'; do
  run MOCK_ELSEWHERE_OID='' MOCK_ELSEWHERE_JUNK="$junk"
  grep -q 'DRYRUN' "$log" \
    || fail "unrecognised gh output '$junk' suppressed a PR instead of failing safe"
done

echo "PASS auto-pr-push cross-branch duplicate guard"
