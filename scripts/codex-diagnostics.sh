#!/usr/bin/env bash

# Read-only diagnostics for a Codex installation and its configured request path.

set -uo pipefail

probe=0
workspace="${CODEX_PROJECT_DIR:-$PWD}"
while [ $# -gt 0 ]; do
  case "$1" in
    --probe) probe=1; shift ;;
    --workspace)
      [ $# -ge 2 ] || { echo "--workspace needs a path" >&2; exit 2; }
      workspace="$2"
      shift 2
      ;;
    -h|--help) sed -n 's/^# \{0,1\}//p' "$0" | sed -n '1,8p'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

printf '%s\n' 'Codex diagnostics'
if command -v codex >/dev/null 2>&1; then
  printf 'Codex: '; codex --version 2>/dev/null || true
else
  echo 'Codex: missing from PATH'
fi
printf 'Config: %s\n' "${CODEX_HOME:-$HOME/.codex}/config.toml"
printf 'Hooks: %s\n' "${CODEX_HOME:-$HOME/.codex}/hooks.json"

if [ -f "${CODEX_HOME:-$HOME/.codex}/hooks.json" ]; then
  hook_count="$(rg -c '"command"' "${CODEX_HOME:-$HOME/.codex}/hooks.json" 2>/dev/null || echo 0)"
  echo "Hook commands: $hook_count"
else
  echo 'Hook commands: hooks.json missing'
fi

if command -v codex >/dev/null 2>&1; then
  echo 'MCP status:'
  codex mcp list 2>/dev/null \
    | awk 'NR == 1 || /enabled|disabled/ {print}' \
    | sed -E 's/(Bearer|token|api[_-]?key|secret|password)[=:][^ ]*/\1=<redacted>/Ig' \
    | sed -n '1,80p'
fi

if [ -f "$workspace/AGENTS.md" ]; then
  echo "Workspace instructions: $workspace/AGENTS.md"
else
  echo "Workspace instructions: missing $workspace/AGENTS.md"
fi
if [ -d "$workspace/.codex-harness" ]; then
  echo "Repository state: $workspace/.codex-harness"
else
  echo "Repository state: missing $workspace/.codex-harness"
fi

if [ "$probe" = 1 ]; then
  command -v codex >/dev/null 2>&1 || { echo 'Probe: skipped, Codex is missing' >&2; exit 1; }
  echo 'Probe: sending a minimal request through the configured provider'
  codex exec --ephemeral --skip-git-repo-check --json \
    'Reply with exactly CODEX_HARNESS_OK.' | tail -n 20
fi
