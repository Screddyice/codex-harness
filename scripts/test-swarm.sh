#!/usr/bin/env bash
# Run the swarm engine's pytest suite (repo convention: scripts/test-*.sh).

set -eu
cd "$(dirname "$0")/swarm"
python3 -m pytest tests/ -q "$@"
