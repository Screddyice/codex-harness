#!/usr/bin/env bash
# Read-only audit that the Codex harness does not carry Claude plugin wiring.
set -uo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

[ -f "$root/README.md" ] || fail "missing $root/README.md"
[ -f "$root/docs/client-boundary.md" ] || fail "missing client-boundary.md"

if find "$root" -type d \( -name .claude-plugin \) -print -quit 2>/dev/null |
   grep -q .; then
  fail "Codex harness contains a Claude plugin directory"
fi

if rg -n -i --hidden --glob '!.git/**' \
    'claude plugin marketplace|\.claude-plugin|install-claude-plugin' \
    "$root/config" "$root/examples" "$root/marketplace" >"${TMPDIR:-/tmp}/codex-harness-boundary.$$" 2>/dev/null; then
  sed 's/^/FAIL: stale Claude plugin wiring: /' "${TMPDIR:-/tmp}/codex-harness-boundary.$$" >&2
  failures=$((failures + 1))
fi
rm -f "${TMPDIR:-/tmp}/codex-harness-boundary.$$"

if [ "$failures" -eq 0 ]; then
  printf 'PASS: Codex harness client boundary (%s)\n' "$root"
  exit 0
fi
printf 'Codex harness boundary audit found %d issue(s)\n' "$failures" >&2
exit 1
