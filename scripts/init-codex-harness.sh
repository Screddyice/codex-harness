#!/usr/bin/env bash
# Idempotently initialize a .codex-harness directory in a git repository.

set -u

target="${1:-${CODEX_PROJECT_DIR:-$PWD}}"

if [ -z "$target" ] || [ ! -d "$target" ]; then
  echo "Target directory does not exist: $target" >&2
  exit 1
fi

cd "$target" || exit 1

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not inside a git repository: $target" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$repo_root" ]; then
  echo "Could not resolve git repository root" >&2
  exit 1
fi

cd "$repo_root" || exit 1

harness="$repo_root/.codex-harness"

mkdir -p \
  "$harness/agents" \
  "$harness/features" \
  "$harness/impact" \
  "$harness/memory/learned" \
  "$harness/memory/episodic" \
  "$harness/memory/semantic" \
  "$harness/memory/procedural" \
  "$harness/prd" \
  "$harness/sessions"

write_if_missing() {
  local path="$1"
  local content="$2"
  if [ ! -f "$path" ]; then
    printf '%s\n' "$content" > "$path"
  fi
}

write_if_missing "$harness/config.json" '{
  "version": 1,
  "agent": "codex",
  "instructionFile": "AGENTS.md",
  "purpose": "Per-repo scaffolding for Codex context, lightweight memory, and planning artifacts",
  "createdBy": "init-codex-harness.sh"
}'

write_if_missing "$harness/session-briefing.md" '# Session Briefing

Use this file for repo-specific handoff notes that should persist outside a single Codex session.
'

write_if_missing "$harness/agents/context.json" '{
  "notes": [],
  "openQuestions": []
}'

write_if_missing "$harness/features/active.json" '[]'
write_if_missing "$harness/features/archive.json" '[]'
write_if_missing "$harness/impact/change-log.json" '[]'
write_if_missing "$harness/impact/dependency-graph.json" '{}'
write_if_missing "$harness/prd/analyst-prompts.json" '[]'
write_if_missing "$harness/sessions/.current-session-id" ''

write_if_missing "$harness/memory/learned/rules.json" '[]'
write_if_missing "$harness/memory/episodic/decisions.json" '[]'
write_if_missing "$harness/memory/semantic/entities.json" '{}'
write_if_missing "$harness/memory/semantic/architecture.json" '{}'
write_if_missing "$harness/memory/semantic/constraints.json" '[]'
write_if_missing "$harness/memory/procedural/successes.json" '[]'
write_if_missing "$harness/memory/procedural/failures.json" '[]'
write_if_missing "$harness/memory/procedural/patterns.json" '[]'

if [ ! -f "$repo_root/AGENTS.md" ]; then
  cat > "$repo_root/AGENTS.md" <<'AGENTS'
# Project AGENTS.md

## Project Context

Document the project purpose, owner, stack, and safety constraints here.

## Local Setup

```bash
# install
# test
# dev
```

## Working Rules

- Keep changes scoped to the requested behavior.
- Prefer existing project patterns.
- Do not commit secrets, generated auth caches, or local logs.
- Ask before mutating production systems or external accounts.
- Open a draft PR immediately after the first commit on a work branch, push later
  checkpoints to it, and never leave keepable branch commits without a PR.
AGENTS
fi

echo "Initialized Codex harness at $harness"
