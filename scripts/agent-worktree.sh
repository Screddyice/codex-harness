#!/usr/bin/env bash
# Create a throwaway worktree and run a command inside it, or fail loudly.
#
# WHY THIS EXISTS: on 2026-09-05 an agent ran
#
#     git worktree add -q "$W" -B "$branch" "origin/$branch" || true
#     cd "$W"
#     git merge origin/main
#
# against a branch that was already checked out somewhere else. `worktree add`
# refused, `|| true` swallowed it, `cd` failed, and the shell stayed in the
# previous directory -- which was the user's MAIN CHECKOUT. The merge ran there.
# It happened to be clean and on the intended branch, so nothing was lost, but
# the next such slip lands a merge in whatever repo the shell was last in.
#
# Two failures made that possible and both are fixed here: a create that fails
# is never ignored, and the command runs via `git -C` / a subshell whose `cd` is
# checked, so it cannot fall through to the caller's directory.
set -euo pipefail

usage() { echo "usage: $0 <repo> <branch> <start-point> [command...]" >&2; exit 2; }
[ $# -ge 3 ] || usage
repo=$1 branch=$2 start=$3; shift 3
[ "${1:-}" = "--" ] && shift   # allow the conventional separator before the command

git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $repo" >&2; exit 2; }

# A branch checked out anywhere else cannot be checked out again. Say so by name
# rather than letting `worktree add` fail into a swallowed error.
existing=$(git -C "$repo" worktree list --porcelain 2>/dev/null \
           | awk -v b="refs/heads/$branch" '/^worktree /{w=$2} /^branch /{if($2==b) print w}')
if [ -n "$existing" ]; then
  echo "branch '$branch' is already checked out at: $existing" >&2
  echo "reuse that worktree or pick another branch; refusing to guess." >&2
  exit 3
fi

dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-wt-XXXXXX")
cleanup() { git -C "$repo" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"; }
trap cleanup EXIT

git -C "$repo" worktree add -q "$dir" -b "$branch" "$start"
echo "worktree: $dir  ($branch from $start)"

[ $# -gt 0 ] || { trap - EXIT; echo "left in place; remove with: git -C $repo worktree remove $dir"; exit 0; }

# The subshell's cd is checked, so a failure here can never run the command in
# the caller's directory -- the specific way the original bug did damage.
( cd "$dir" || { echo "cannot enter $dir" >&2; exit 4; }; "$@" )
