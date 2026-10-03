#!/usr/bin/env bash

# Codex Stop-hook adapter for the shared branch/PR checks.

set -uo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=hook-common.sh
. "$script_dir/hook-common.sh"

input="$(cat 2>/dev/null || true)"
hook_resolve_cwd "$input"
hook_load_branch_context || exit 0
hook_load_pr_status
[ "$HOOK_PR_STATUS" = "needs_pr" ] || exit 0

head_sha="$(git rev-parse HEAD 2>/dev/null || echo x)"
marker_key="$(printf '%s#%s#%s' "$HOOK_TOP" "$HOOK_BRANCH" "$head_sha" | tr '/ .' '___')"
marker="${TMPDIR:-/tmp}/codex-prnudge-${marker_key}"
[ -f "$marker" ] && exit 0
: > "$marker" 2>/dev/null || true

message="HARDLINE RULE: '$HOOK_BRANCH' has $HOOK_AHEAD commit(s) ahead of $HOOK_BASE but no open pull request. Run \`gh pr create --head $HOOK_BRANCH --fill\` and add --draft if the work is unfinished. RS21 repositories are exempt."
MESSAGE="$message" python3 - <<'PY'
import json
import os

print(json.dumps({
    "continue": False,
    "stopReason": "A work branch has commits but no open pull request.",
    "systemMessage": os.environ["MESSAGE"],
}))
PY
