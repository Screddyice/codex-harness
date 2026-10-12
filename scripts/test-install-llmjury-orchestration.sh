#!/usr/bin/env bash

set -eu

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
log="$tmp/calls.log"

cat > "$tmp/bin/llmjury" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$1" in
  install-codex)
    root="${CODEX_HOME:-$HOME/.codex}"
    mkdir -p "$root/skills/llm-jury-orchestrate"
    : > "$root/skills/llm-jury-orchestrate/SKILL.md"
    ;;
  *)
    echo "unexpected llmjury command: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/llmjury"

export HOME="$tmp/home"
export PATH="$tmp/bin:$PATH"
export MOCK_LOG="$log"

"$(dirname "$0")/install-llmjury-orchestration.sh" >/dev/null
grep -qx 'install-codex' "$log"
test -f "$HOME/.codex/skills/llm-jury-orchestrate/SKILL.md"

: > "$log"
"$(dirname "$0")/install-llmjury-orchestration.sh" --force >/dev/null
grep -qx 'install-codex --force' "$log"

if "$(dirname "$0")/install-llmjury-orchestration.sh" --unknown >/dev/null 2>&1; then
  echo "unknown flags should be rejected" >&2
  exit 1
fi

echo "PASS LLM-Jury orchestration installer"
