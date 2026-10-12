#!/usr/bin/env bash
# Install the standalone CLI without overwriting scripts/qwen's memory guard.
set -euo pipefail
command -v npm >/dev/null || { echo 'Node.js 22+ and npm are required.' >&2; exit 1; }
npm install --prefix "$HOME/.local/share/qwen-code" \
  '@qwen-code/qwen-code@0.23.4' --no-audit --no-fund
"$HOME/.local/share/qwen-code/node_modules/.bin/qwen" --version
