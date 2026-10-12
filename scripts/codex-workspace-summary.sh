#!/usr/bin/env bash
# Print a compact summary of the local Codex workspace setup.

set -u

workspace="${1:-$PWD}"

echo "Workspace: $workspace"

if command -v codex >/dev/null 2>&1; then
  printf 'Codex: '
  codex --version 2>/dev/null || true
else
  echo "Codex: not found on PATH"
fi

if [ -f "$HOME/.codex/config.toml" ]; then
  echo "Config: $HOME/.codex/config.toml"
else
  echo "Config: missing $HOME/.codex/config.toml"
fi

if [ -f "$workspace/AGENTS.md" ]; then
  bytes="$(wc -c < "$workspace/AGENTS.md" | tr -d ' ')"
  echo "Workspace instructions: $workspace/AGENTS.md ($bytes bytes)"
else
  echo "Workspace instructions: missing $workspace/AGENTS.md"
fi

if [ -d "$workspace/.codex-harness" ]; then
  echo "Harness: $workspace/.codex-harness"
else
  echo "Harness: missing $workspace/.codex-harness"
fi

if [ -f "$workspace/.agents/plugins/marketplace.json" ]; then
  echo "Marketplace: $workspace/.agents/plugins/marketplace.json"
else
  echo "Marketplace: none at $workspace/.agents/plugins/marketplace.json"
fi

codex_root="${CODEX_HOME:-$HOME/.codex}"
if [ -f "$codex_root/skills/llm-jury-orchestrate/SKILL.md" ]; then
  echo "LLM-Jury orchestration: ready (Codex)"
else
  echo "LLM-Jury orchestration: not installed (optional)"
fi

if command -v codex >/dev/null 2>&1; then
  echo
  codex mcp list 2>/dev/null || true
fi
