#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
QWEN="$ROOT/scripts/qwen"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/state" "$TMP/leases"

cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  */api/version*) echo '{"version":"test"}';;
  */api/tags*) echo '{"models":[{"name":"qwen3.5:4b-64k","size":1000}]}' ;;
  */api/ps*) cat "$FIXTURE/ps.json" ;;
  *) exit 1;;
esac
SH
cat > "$BIN/ollama" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/ollama.log"
if [ "$1" = run ]; then echo "RAN"; fi
SH
cat > "$BIN/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FIXTURE/codex.argv"
SH
cat > "$BIN/sysctl" <<'SH'
#!/usr/bin/env bash
echo 1
SH
cat > "$BIN/vm_stat" <<'SH'
#!/usr/bin/env bash
cat <<'EOF'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free: 100000.
Pages speculative: 0.
Pages purgeable: 0.
File-backed pages: 100000.
EOF
SH
cat > "$BIN/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN"/*
export HOME="$TMP" FIXTURE="$TMP" PATH="$BIN:$PATH"
export OLLAMA_HOST=127.0.0.1:11434 QWEN_MODEL=qwen3.5:4b-64k
export QWEN_STATE_DIR="$TMP/state" LLMJURY_COMPUTE_LEASE_DIR="$TMP/leases"
export CMEM_PRO_TOKEN=test-token
echo '{"models":[]}' > "$TMP/ps.json"

out=$(bash "$QWEN" status)
printf '%s\n' "$out" | grep -q 'not loaded'
QWEN_FORCE=1 bash "$QWEN" codex --mcp none
grep -q -- '-m' "$TMP/codex.argv"
grep -q 'qwen3.5:4b-64k' "$TMP/codex.argv"
QWEN_FORCE=1 bash "$QWEN" raw hello
grep -q 'run qwen3.5:4b-64k hello' "$TMP/ollama.log"

if grep -Eiq 'claude|anthropic|CLAUDE_CONFIG_DIR' "$QWEN"; then
  echo "qwen wrapper contains a non-Codex runtime reference" >&2
  exit 1
fi
echo "PASS Codex-only qwen wrapper"
