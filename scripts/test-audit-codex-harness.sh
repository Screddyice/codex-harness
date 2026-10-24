#!/usr/bin/env bash

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

codex_home="$tmp/codex"
workspace="$tmp/workspace"
mkdir -p "$codex_home" "$workspace/.codex-harness"
git -C "$workspace" init -q -b main
git -C "$workspace" -c user.name=Test -c user.email=test@example.invalid \
  commit --allow-empty -qm init
printf '{}\n' > "$workspace/.codex-harness/config.json"

# Plugin-managed hooks are the current Codex-native state. No standalone
# hooks.json is required for an audit to pass.
cat > "$codex_home/config.toml" <<'EOF'
[hooks.state]
"claude-mem@personal:hooks/codex-hooks.json:stop:0:0" = { enabled = true }
EOF

output="$(CODEX_HOME="$codex_home" "$repo_root/scripts/audit-codex-harness.sh" "$workspace")"
printf '%s\n' "$output" | grep -q 'PASS: Codex harness audit'
printf '%s\n' "$output" | grep -q 'plugin-managed Codex hooks'

# The installed standalone profile uses llm-jury, without legacy scaffold hooks.
cat > "$codex_home/hooks.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$HOME/.local/bin/llmjury\" review-hook --host codex","timeout":600}]}]}}
EOF
output="$(CODEX_HOME="$codex_home" "$repo_root/scripts/audit-codex-harness.sh" "$workspace")"
printf '%s\n' "$output" | grep -q 'PASS: Codex harness audit'

# A review for the other host (or an echoed command) is not a Codex hook.
for command in 'llmjury review-hook --host claude' 'echo llmjury review-hook --host codex'; do
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$command" > "$codex_home/hooks.json"
  if CODEX_HOME="$codex_home" "$repo_root/scripts/audit-codex-harness.sh" "$workspace" >/dev/null 2>&1; then
    echo 'FAIL: a non-Codex review command was accepted' >&2
    exit 1
  fi
done
printf '{malformed\n' > "$codex_home/hooks.json"
if CODEX_HOME="$codex_home" "$repo_root/scripts/audit-codex-harness.sh" "$workspace" >/dev/null 2>&1; then
  echo 'FAIL: malformed hooks JSON was accepted' >&2
  exit 1
fi
rm "$codex_home/hooks.json"

# Legacy Claude hook state still fails closed.
cat > "$codex_home/config.toml" <<'EOF'
[hooks.state]
"claude-harness@claude-harness:hooks/hooks.json:stop:0:0" = { enabled = true }
EOF
if CODEX_HOME="$codex_home" "$repo_root/scripts/audit-codex-harness.sh" "$workspace" >/dev/null 2>&1; then
  echo 'FAIL: stale Claude hook state was accepted' >&2
  exit 1
fi

echo 'PASS Codex harness audit'
