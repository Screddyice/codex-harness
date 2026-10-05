#!/usr/bin/env bash

# Read-only audit for the Codex harness and the user-level Codex wiring.

set -uo pipefail

workspace="${1:-${CODEX_PROJECT_DIR:-$PWD}}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
harness_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
failures=0
audit_tmp="$(mktemp "${TMPDIR:-/tmp}/codex-harness-audit.XXXXXX")"
trap 'rm -f "$audit_tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

check_file() {
  [ -f "$1" ] || fail "missing $1"
}

check_file "$harness_root/README.md"
check_file "$harness_root/AGENTS.md"
check_file "$harness_root/scripts/init-codex-harness.sh"
check_file "$harness_root/scripts/hooks/auto-pr-push.sh"
check_file "$harness_root/scripts/hooks/enforce-pr-codex.sh"
check_file "$harness_root/scripts/hooks/local-diff-review.sh"
check_file "$harness_root/scripts/hooks/local-diff-review-codex.sh"

if [ -f "$codex_home/hooks.json" ]; then
  if ! rg -q 'codex-harness/scripts' "$codex_home/hooks.json"; then
    fail "$codex_home/hooks.json does not reference this harness"
  fi
  if rg -qi 'claude-code-harness|claude-harness|\.claude-harness|enforce-pr-claude' "$codex_home/hooks.json"; then
    fail "$codex_home/hooks.json contains stale Claude harness wiring"
  fi
else
  # Current Codex releases persist plugin-managed hook registrations in
  # config.toml. A missing standalone hooks.json means the harness hooks are
  # not installed; it is not an invalid installation and must not make this
  # read-only audit fail.
  if [ -f "$codex_home/config.toml" ] && rg -q '^\[hooks\.state\][[:space:]]*$' "$codex_home/config.toml"; then
    printf 'INFO: no standalone hooks.json; using plugin-managed Codex hooks\n'
  else
    printf 'INFO: no standalone hooks.json; Codex harness hooks are not installed\n'
  fi
fi

if [ -f "$codex_home/config.toml" ] && rg -q '^\[features\][[:space:]]*$' "$codex_home/config.toml"; then
  rg -q '^hooks[[:space:]]*=[[:space:]]*true' "$codex_home/config.toml" ||
    fail "$codex_home/config.toml does not enable Codex hooks"
fi

if [ -f "$codex_home/config.toml" ]; then
  if rg -qi 'claude-code-harness|claude-harness|enforce-pr-claude|CLAUDE_CONFIG_DIR' "$codex_home/config.toml"; then
    fail "$codex_home/config.toml contains stale Claude harness wiring"
  fi
  for plugin in holyclaude claude-harness; do
    awk -v name="$plugin" '
      $0 ~ "^\\[plugins\\.\"" name "@" { in_plugin=1; next }
      in_plugin && /^\[/ { in_plugin=0 }
      in_plugin && /^enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { found=1 }
      END { exit found ? 0 : 1 }
    ' "$codex_home/config.toml" && fail "legacy plugin $plugin is enabled in $codex_home/config.toml"
  done
fi

watchdog_plist="$HOME/Library/LaunchAgents/com.screddy.kernel-zone-watchdog.plist"
if [ -f "$watchdog_plist" ]; then
  if rg -q 'claude-code-harness|claude-harness' "$watchdog_plist"; then
    fail "$watchdog_plist contains stale Claude harness wiring"
  fi
  watchdog_path=$(plutil -extract ProgramArguments.0 raw -o - "$watchdog_plist" 2>/dev/null || true)
  [ -x "$watchdog_path" ] || fail "kernel-zone watchdog target is not executable: $watchdog_path"
fi

if [ -d "$workspace" ]; then
  git -C "$workspace" rev-parse --show-toplevel >/dev/null 2>&1 ||
    fail "$workspace is not a git repository"
  if [ -d "$workspace/.claude-harness" ]; then
    fail "$workspace still has Claude harness state; migrate it before using Codex state"
  fi
  if [ -d "$workspace/.codex-harness" ]; then
    [ -f "$workspace/.codex-harness/config.json" ] ||
      fail "$workspace/.codex-harness/config.json is missing"
  fi
fi

if rg -n -i --hidden --glob '!.git/**' --glob '!audit-codex-harness.sh' \
    'claude-code-harness|claude-harness|\.claude-harness|enforce-pr-claude|CLAUDE_CONFIG_DIR|ANTHROPIC_' \
    "$harness_root/scripts/qwen" "$harness_root/scripts/swarm" "$harness_root/scripts/hooks" \
    "$harness_root/scripts/init-codex-harness.sh" "$harness_root/config" "$harness_root/examples" >"$audit_tmp" 2>/dev/null; then
  sed 's/^/FAIL: stale runtime reference: /' "$audit_tmp" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
  printf 'PASS: Codex harness audit (%s)\n' "$harness_root"
  exit 0
fi
printf 'Codex harness audit found %d issue(s)\n' "$failures" >&2
exit 1
