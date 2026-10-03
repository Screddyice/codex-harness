#!/usr/bin/env bash

# Classification in rejected-prs.sh, with `gh` mocked.
#
# The bug this pins was silent and wrong in the expensive direction. The commit
# count was fetched with `gh api --jq --arg since ...`, but `gh api` has no
# --arg flag, so jq read "$since" as a filter and matched nothing. Every PR came
# back with zero commits since its rejection and was labelled `needs-work` —
# including eleven that had just been fixed and resubmitted.
#
# That is the exact failure the script exists to prevent: two sessions wrote the
# same fix for hyperscale#94 on 2026-08-31 because neither could see the work
# was already done. A tool that reports "needs work" for finished work does not
# fail safe; it causes the duplicate.

set -eu

script="$(cd "$(dirname "$0")" && pwd)/rejected-prs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Mocked gh. The PR under test is always screddyice/repo#7, rejected by iankiku
# at 2026-08-01. What varies per case:
#   MOCK_PENDING     — logins currently holding a live review request
#   MOCK_REVIEWS     — "<login>\t<STATE>\t<iso8601>" rows, oldest first
#   MOCK_COMMIT_DATE — committer date of the PR's newest commit
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "auth status"*) exit 0 ;;
  *"search prs"*) printf 'screddyice/repo\n'; exit 0 ;;
  *"/reviews"*) printf '%s\n' "$MOCK_REVIEWS"; exit 0 ;;
  *"/commits"*)
    # Mirrors the real jq filter: the script compares against env.SINCE.
    if [ "$MOCK_COMMIT_DATE" \> "${SINCE:-9999}" ]; then printf '1\n'; else printf '0\n'; fi
    exit 0
    ;;
esac
case "$1 $2" in
  "pr list") printf '7\t%s\tfix something\n' "${MOCK_PENDING:-}"; exit 0 ;;
esac
exit 0
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

out=""
run() {
  out="$(MOCK_REVIEWS="$1" MOCK_COMMIT_DATE="$2" MOCK_PENDING="${3:-}" \
    "$script" screddyice 2>&1)" || true
}
fail() { echo "FAIL: $1" >&2; echo "--- output ---" >&2; printf '%s\n' "$out" >&2; exit 1; }

rejected="$(printf 'iankiku\tCHANGES_REQUESTED\t2026-08-01T00:00:00Z')"

# 1. No commits since the rejection: work is genuinely outstanding.
run "$rejected" '2026-07-30T00:00:00Z' ''
printf '%s' "$out" | grep -q 'needs-work' || fail "a PR with no commits since the rejection is needs-work"

# 2. Commits landed, but nobody was asked to look again. This is the state the
#    whole sweep was about: fixed, invisible, and indistinguishable from unfixed.
run "$rejected" '2026-08-15T00:00:00Z' ''
printf '%s' "$out" | grep -q 'fixed?' \
  || fail "commits after the rejection with no live request must read as fixed?, not needs-work"

# 3. Commits landed AND the rejecter holds a live request: it is their turn.
run "$rejected" '2026-08-15T00:00:00Z' 'iankiku'
printf '%s' "$out" | grep -q 'resubmitted' \
  || fail "a re-requested rejecter means the PR is back with the reviewer"

# 4. A live request from someone who did NOT reject is not a resubmission to the
#    person waiting on it.
run "$rejected" '2026-08-15T00:00:00Z' 'maira692'
printf '%s' "$out" | grep -q 'fixed?' \
  || fail "requesting a different reviewer does not answer the standing rejection"

# 5. Rejected then approved by the same person: no longer standing. GitHub keeps
#    every review event, so only the latest state per person may count.
run "$(printf 'iankiku\tCHANGES_REQUESTED\t2026-08-01T00:00:00Z\niankiku\tAPPROVED\t2026-08-02T00:00:00Z')" \
    '2026-07-30T00:00:00Z' ''
printf '%s' "$out" | grep -q '(bot/unknown)' \
  || fail "an approval must supersede that person's earlier rejection"

echo "rejected-prs classification tests passed"
