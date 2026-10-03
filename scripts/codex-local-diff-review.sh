#!/usr/bin/env bash
# Compatibility entry point for the Codex Stop-hook contract.

exec "$(dirname "$0")/hooks/local-diff-review-codex.sh"
