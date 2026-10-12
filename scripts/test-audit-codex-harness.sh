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
