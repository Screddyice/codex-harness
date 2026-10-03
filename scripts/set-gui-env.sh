#!/bin/bash
# Publish selected credentials into the macOS GUI (Aqua) launchd domain at login.
#
# WHY: a Dock-launched app inherits launchd's environment, not a shell's, so an
# export in ~/.zshrc or a value in ~/projects/.env never reaches Codex Desktop.
# Its `cmem` MCP server declares `bearer_token_env_var = "CMEM_PRO_TOKEN"`, so
# without this the server loads with no token and its tools quietly do not
# appear — the failure looks like a missing feature rather than a missing
# credential.
#
# `launchctl setenv` alone is not enough: it lives only until logout or reboot.
# This runs at every login so the value is always current.
#
# The secret VALUE stays in ~/projects/.env. This script reads it there and
# hands it to launchd; it is never written into the plist, a log, or any file.
#
# It also publishes LLMJURY_OLLAMA_PARALLEL, which is derived rather than secret
# and so does not depend on the env file existing. llm-jury's memguard charges
# KV as num_ctx x this value and falls back to Ollama's default of 4 when it
# cannot see the real setting, so a GUI-launched session running the council or
# the diff reviewer overestimates and refuses work without it. It moved here on
# 2026-09-10 from router-gui-env.sh, which was deleted with the Backdoor router.
set -uo pipefail
ENV_FILE="${GUI_ENV_SOURCE:-$HOME/projects/.env}"
KEYS="${GUI_ENV_KEYS:-CMEM_PRO_TOKEN}"

# Secrets. A missing file skips this block and leaves the derived value below
# alone, rather than exiting: the two have nothing to do with each other.
if [ -r "$ENV_FILE" ]; then
  for key in $KEYS; do
    value=$(grep -m1 "^${key}=" "$ENV_FILE" | cut -d= -f2- | sed 's/^["'"'"']//; s/["'"'"']$//')
    if [ -n "$value" ]; then
      launchctl setenv "$key" "$value"
      echo "set-gui-env: published $key (${#value} chars) to the GUI domain"
    else
      echo "set-gui-env: $key not found in $ENV_FILE" >&2
    fi
  done
else
  echo "set-gui-env: no $ENV_FILE" >&2
fi

# Derived, not secret. Ollama's parallel-decode slots live in the server's own
# launchd unit, which exports them to the server process and nowhere else. Read
# the unit and republish the number under the name llm-jury looks for. An
# absent, malformed, or zero value unsets the variable instead of publishing a
# wrong one, since memguard's own conservative default beats a bad number.
OLLAMA_PLIST="${OLLAMA_PLIST:-$HOME/Library/LaunchAgents/com.screddy.ollama.plist}"
slots=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OLLAMA_NUM_PARALLEL' \
          "$OLLAMA_PLIST" 2>/dev/null)
case "$slots" in
  ''|*[!0-9]*|0)
    launchctl unsetenv LLMJURY_OLLAMA_PARALLEL
    echo "set-gui-env: no usable OLLAMA_NUM_PARALLEL in $OLLAMA_PLIST; unset LLMJURY_OLLAMA_PARALLEL" >&2
    ;;
  *)
    launchctl setenv LLMJURY_OLLAMA_PARALLEL "$slots"
    echo "set-gui-env: published LLMJURY_OLLAMA_PARALLEL=$slots to the GUI domain"
    ;;
esac
