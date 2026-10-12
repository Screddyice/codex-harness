#!/usr/bin/env bash

set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap '/bin/rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/workspace/.codex-harness"
cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 'codex test 0.0.0' ;;
  mcp) printf 'Name Status\ncmem disabled\nnebos enabled\n' ;;
  *) printf '{"type":"item.completed","item":{"text":"CODEX_HARNESS_OK"}}\n' ;;
esac
EOF
chmod +x "$tmp/bin/codex"
printf '{}' > "$tmp/hooks.json"

HOME="$tmp" CODEX_HOME="$tmp" PATH="$tmp/bin:$PATH" \
  "$root/scripts/codex-diagnostics.sh" --workspace "$tmp/workspace" > "$tmp/out"
grep -q 'Codex: codex test 0.0.0' "$tmp/out"
grep -q 'Hook commands: 0' "$tmp/out"
grep -q 'Repository state: ' "$tmp/out"

echo 'PASS Codex diagnostics'
