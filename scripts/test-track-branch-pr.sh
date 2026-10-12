#!/usr/bin/env bash

set -eu

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo"
log="$tmp/log"

cat > "$tmp/bin/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
  rev-parse) printf '%s\n' "$MOCK_REPO" ;;
  symbolic-ref)
    case "$*" in
      *refs/remotes/origin/HEAD*) printf '%s\n' origin/main ;;
      *) printf '%s\n' "${MOCK_BRANCH:-feat/test}" ;;
    esac
    ;;
  remote) printf '%s\n' https://example.invalid/owner/repo.git ;;
  rev-list) printf '%s\n' 1 ;;
  push) printf 'git %s\n' "$*" >> "$MOCK_LOG" ;;
  show-ref) exit 1 ;;
  *) echo "unexpected git command: $*" >&2; exit 1 ;;
esac
SH

cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list")
    [ -n "${MOCK_EXISTING_PR:-}" ] && printf '%s\n' "$MOCK_EXISTING_PR"
    exit 0
    ;;
  "pr create")
    printf 'gh %s\n' "$*" >> "$MOCK_LOG"
    printf '%s\n' https://example.invalid/owner/repo/pull/7
    ;;
  *) echo "unexpected gh command: $*" >&2; exit 1 ;;
esac
SH

chmod +x "$tmp/bin/git" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" MOCK_REPO="$tmp/repo" MOCK_LOG="$log"

"$(dirname "$0")/track-branch-pr.sh" "$tmp/repo" >/dev/null
grep -q '^git push -u origin feat/test$' "$log"
grep -q '^gh pr create --draft --fill --base main --head feat/test$' "$log"

: > "$log"
MOCK_EXISTING_PR=$'8\tOPEN\thttps://example.invalid/owner/repo/pull/8' \
  "$(dirname "$0")/track-branch-pr.sh" "$tmp/repo" >/dev/null
grep -q '^git push -u origin feat/test$' "$log"
! grep -q 'pr create' "$log"

if MOCK_BRANCH=main "$(dirname "$0")/track-branch-pr.sh" "$tmp/repo" >/dev/null 2>&1; then
  echo "protected branch should have been rejected" >&2
  exit 1
fi

echo "PASS branch PR tracking"
