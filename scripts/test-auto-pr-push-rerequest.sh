#!/usr/bin/env bash

# Re-request the reviewer when a fix lands on a rejected PR.
#
# GitHub does not clear CHANGES_REQUESTED when the author pushes a fix, and it
# does not re-notify the reviewer. The PR then sits in a state that looks
# identical from the outside whether the work was done or not: request spent,
# review still red, nobody told.
#
# Seen at scale on 2026-08-31. A sweep of the teamnebula-ai org turned up ELEVEN
# open PRs holding CHANGES_REQUESTED, and roughly two thirds of them had already
# been fixed in an earlier session. They were waiting on nothing but this call.
#
# The hook pushes for real here (origin is a local bare repo) because the
# re-request runs after the push; AUTO_PR_PUSH_DRYRUN returns before it. `gh` is
# mocked, and the observable is the hook's log plus a file the mock appends to
# when a re-request POST is issued.
#
# The hook works in a detached background job, so each case polls rather than
# assuming the log has already been written.

set -eu

hook="$(cd "$(dirname "$0")" && pwd)/hooks/auto-pr-push.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
bare="$tmp/origin.git"
logdir="$tmp/logs"
log="$logdir/auto-pr-push.log"
faillog="$logdir/auto-pr-push-failures.log"
posted="$tmp/requested.txt"
mkdir -p "$repo" "$logdir" "$tmp/bin"

git init -q --bare -b main "$bare"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@t.t
git -C "$repo" config user.name t
# The fetch URL keeps a real-looking slug, because the hook derives the owner
# allowlist and the gh --repo argument from it. Only the PUSH url points at the
# local bare repo. `url.<x>.insteadOf` would not work here: `git remote get-url`
# applies the rewrite, so the hook would see a filesystem path and parse no owner.
git -C "$repo" remote add origin "https://github.com/screddyice/repo.git"
git -C "$repo" remote set-url --push origin "$bare"
printf 'base\n' > "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -qm base
git -C "$repo" push -q origin main
git -C "$repo" update-ref refs/remotes/origin/main HEAD

git -C "$repo" checkout -qb feat/fix-it

# Mocked gh.
#   MOCK_REVIEWS  — newline-separated "<login> <STATE>" review events, oldest first
#   MOCK_AUTHOR   — the PR author login
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "auth status"*) exit 0 ;;
  *"requested_reviewers"*)
    # Record exactly which logins were requested.
    for a in "$@"; do
      case "$a" in reviewers\[\]=*) printf '%s\n' "${a#reviewers[]=}" >> "$MOCK_POSTED" ;; esac
    done
    exit 0
    ;;
  *"/reviews"*)
    printf '%s\n' "${MOCK_REVIEWS:-}"
    exit 0
    ;;
esac
case "$1 $2" in
  "pr list")
    case "$*" in
      *"--state merged"*) ;;                       # nothing merged
      *"number,author,headRefOid"*)
        printf '7 %s %s\n' "${MOCK_AUTHOR:-someone}" "$(git -C "$MOCK_REPO" rev-parse HEAD)" ;;
      *) printf '1\n' ;;                           # one open PR for this branch
    esac
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export MOCK_POSTED="$posted" MOCK_REPO="$repo"

run() { # run — commits a fresh change, fires the hook, waits for the log
  : > "$log"
  printf '%s\n' "$(date +%s%N)" > "$repo/a.txt"
  git -C "$repo" commit -qam work
  printf '{"cwd": "%s"}' "$repo" \
    | env HARNESS_PR_OWNERS='screddyice' HARNESS_HOOK_LOG_DIR="$logdir" "$hook" >/dev/null 2>&1
  for _ in $(seq 1 100); do
    grep -q 'PR already open' "$log" 2>/dev/null && break
    sleep 0.1
  done
  # The re-request happens after that line; give the background job a moment.
  sleep 0.4
}

rerun_same_head() { # fire the hook again WITHOUT a new commit
  : > "$log"
  printf '{"cwd": "%s"}' "$repo" \
    | env HARNESS_PR_OWNERS='screddyice' HARNESS_HOOK_LOG_DIR="$logdir" "$hook" >/dev/null 2>&1
  for _ in $(seq 1 100); do
    grep -q 'PR already open' "$log" 2>/dev/null && break
    sleep 0.1
  done
  sleep 0.4
}

fail() { echo "FAIL: $1" >&2; echo "--- log ---" >&2; cat "$log" >&2; \
         echo "--- requested ---" >&2; cat "$posted" 2>/dev/null >&2; exit 1; }

# 1. A standing rejection is re-requested when the fix lands.
: > "$posted"
export MOCK_REVIEWS='iankiku CHANGES_REQUESTED'
export MOCK_AUTHOR='screddyice'
run
grep -qx 'iankiku' "$posted" || fail "a fix pushed over CHANGES_REQUESTED must re-request the rejecter"
grep -q 're-requested review' "$log" || fail "the re-request should be logged"

# 2. Same head, hook fires again -> must not re-notify.
#    This hook runs after EVERY Bash call, so without the per-SHA stamp one
#    session would ping the reviewer dozens of times.
: > "$posted"
rerun_same_head
[ -s "$posted" ] && fail "re-requesting twice for the same head SHA re-notifies the reviewer"

# 3. A reviewer who rejected and then APPROVED is no longer standing.
#    GitHub keeps CHANGES_REQUESTED in force until the same person approves, so
#    only the LATEST state per person may count.
: > "$posted"
export MOCK_REVIEWS='iankiku CHANGES_REQUESTED
iankiku APPROVED'
run
[ -s "$posted" ] && fail "an approval supersedes that person's earlier rejection"

# 4. Nobody has requested changes -> nothing to resubmit.
: > "$posted"
export MOCK_REVIEWS='iankiku COMMENTED'
run
[ -s "$posted" ] && fail "a plain comment is not a rejection"

# 5. The author's own rejection must not re-request the author.
#    GitHub answers 422, and it would ping Shawn about his own branch.
: > "$posted"
export MOCK_REVIEWS='screddyice CHANGES_REQUESTED'
export MOCK_AUTHOR='screddyice'
run
[ -s "$posted" ] && fail "the PR author must never be re-requested on their own PR"

# 6. Two rejecters, one of whom is the author -> only the other is requested.
: > "$posted"
export MOCK_REVIEWS='screddyice CHANGES_REQUESTED
noyaabraham1 CHANGES_REQUESTED'
run
grep -qx 'noyaabraham1' "$posted" || fail "a non-author rejecter must still be re-requested"
grep -qx 'screddyice' "$posted" && fail "the author was re-requested alongside a real reviewer"

# 7. A failed re-request is loud. The silent version of this failure IS the bug:
#    a fixed PR nobody has been told about looks exactly like an unfixed one.
: > "$posted"; : > "$faillog"
export MOCK_REVIEWS='iankiku CHANGES_REQUESTED'
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "auth status"*) exit 0 ;;
  *"requested_reviewers"*) exit 1 ;;
  *"/reviews"*) printf '%s\n' "${MOCK_REVIEWS:-}"; exit 0 ;;
esac
case "$1 $2" in
  "pr list")
    case "$*" in
      *"--state merged"*) ;;
      *"number,author,headRefOid"*) printf '7 %s %s\n' "${MOCK_AUTHOR:-someone}" "$(git -C "$MOCK_REPO" rev-parse HEAD)" ;;
      *) printf '1\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$tmp/bin/gh"
run
grep -q 're-request FAILED' "$faillog" \
  || fail "a failed re-request must reach the failures log, not just the noisy one"

echo "auto-pr-push re-request tests passed"
