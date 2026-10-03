#!/usr/bin/env bash

# Adapt the shared reviewer’s plain-text/exit-2 result to Codex Stop-hook JSON.

set +e
if [ -n "${CODEX_LOCAL_REVIEWER:-}" ]; then
  output="$("$CODEX_LOCAL_REVIEWER" 2>&1)"
  status=$?
else
  output="$($({ cat; } | "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/local-diff-review.sh") 2>&1)"
  status=$?
fi
set -e

[ "$status" -eq 2 ] || exit 0
python3 - "$output" <<'PY'
import json
import sys

print(json.dumps({
    "continue": False,
    "stopReason": "Local diff reviewer found a defect",
    "systemMessage": sys.argv[1],
}))
PY
