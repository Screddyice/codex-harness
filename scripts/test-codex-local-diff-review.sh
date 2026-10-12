#!/usr/bin/env bash

set -eu

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mock="$tmp/reviewer.sh"

printf '%s\n' '#!/usr/bin/env bash' 'echo "defect in app.py: broken branch"' 'exit 2' > "$mock"
chmod +x "$mock"

output="$(printf '{"hook_event_name":"Stop"}' | \
  CODEX_LOCAL_REVIEWER="$mock" "$(dirname "$0")/hooks/local-diff-review-codex.sh")"

printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["continue"] is False
assert "defect in app.py" in d["systemMessage"]
assert d["stopReason"]
'

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$mock"
silent="$(printf '{}' | CODEX_LOCAL_REVIEWER="$mock" \
  "$(dirname "$0")/hooks/local-diff-review-codex.sh")"
[ -z "$silent" ]

echo "PASS Codex local diff review adapter"
