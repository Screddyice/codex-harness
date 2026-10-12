# shellcheck shell=bash
# Repositories the harness must never automate (no PR prompts, pushes or reviews).
#
# The names live outside this repository so private client names stay private:
#   HARNESS_EXCLUDED_REPOS       comma- or space-separated name fragments
#   HARNESS_EXCLUDED_REPOS_FILE  one fragment per line, `#` starts a comment
#                                (default ~/.config/agent-harness/excluded-repos)
# A repository is excluded when its origin URL or directory name contains any
# fragment, ignoring case. With no fragments configured, nothing is excluded.

harness_excluded_patterns() {
  local file="${HARNESS_EXCLUDED_REPOS_FILE:-$HOME/.config/agent-harness/excluded-repos}"
  printf '%s\n' "${HARNESS_EXCLUDED_REPOS:-}" | tr ', ' '\n\n'
  if [ -r "$file" ]; then
    sed -e 's/#.*//' "$file"
  fi
}

# Usage: harness_repo_excluded "<origin url> <directory name>"
harness_repo_excluded() {
  local identity pattern
  identity="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r pattern; do
    pattern="$(printf '%s' "$pattern" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ -n "$pattern" ] || continue
    case "$identity" in *"$pattern"*) return 0 ;; esac
  done <<PATTERNS
$(harness_excluded_patterns)
PATTERNS
  return 1
}
