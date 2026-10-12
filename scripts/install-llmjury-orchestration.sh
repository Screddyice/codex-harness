#!/usr/bin/env bash
# Install optional Codex orchestration supplied by LLM-Jury.

set -eu

force=""
if [ "${1:-}" = "--force" ]; then
  force="--force"
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--force]" >&2
  exit 2
fi

command -v llmjury >/dev/null 2>&1 || {
  echo "LLM-Jury is not installed; install llm-jury-verify first" >&2
  exit 1
}

codex_root="${CODEX_HOME:-$HOME/.codex}"
codex_skill="$codex_root/skills/llm-jury-orchestrate/SKILL.md"

if [ -n "$force" ]; then
  llmjury install-codex --force
else
  llmjury install-codex
fi

test -f "$codex_skill" || {
  echo "Codex orchestration skill was not created: $codex_skill" >&2
  exit 1
}

echo "LLM-Jury orchestration ready"
echo "  Codex: $codex_skill"
echo "Restart Codex after the first install."
