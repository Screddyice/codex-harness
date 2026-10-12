#!/usr/bin/env bash
# Install swarm: bin shim + Codex skill.
#
# Usage: scripts/swarm/install.sh [--force]

set -eu

force=""
if [ "${1:-}" = "--force" ]; then
  force="1"
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--force]" >&2
  exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
codex_root="${CODEX_HOME:-$HOME/.codex}"
bin_dir="${SWARM_BIN_DIR:-$HOME/.local/bin}"

install_file() {
  src="$1"; dest="$2"
  if [ -e "$dest" ] && [ -z "$force" ] && ! cmp -s "$src" "$dest"; then
    echo "skip (exists, differs — use --force): $dest"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  echo "installed: $dest"
}

# bin shim — same ~/.local/bin pattern as the other per-machine CLIs
mkdir -p "$bin_dir"
shim="$bin_dir/swarm"
cat > "$shim" <<EOF
#!/usr/bin/env bash
exec python3 "$here/swarm.py" "\$@"
EOF
chmod +x "$shim"
echo "installed: $shim"

install_file "$here/skills/codex/SKILL.md" "$codex_root/skills/swarm-dispatch/SKILL.md"

echo "done. try: swarm run --help"
