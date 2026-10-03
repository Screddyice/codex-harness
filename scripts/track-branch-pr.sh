#!/usr/bin/env bash
# Push the current work branch and ensure it has a draft pull request.

set -eu

target="${1:-$PWD}"
remote="${PR_TRACK_REMOTE:-origin}"

cd "$target"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Not inside a git repository: $target" >&2
  exit 1
}
cd "$repo_root"

branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || {
  echo "Detached HEAD cannot be tracked with a branch pull request" >&2
  exit 1
}

case "$branch" in
  main|master)
    echo "Refusing to push the protected branch: $branch" >&2
    exit 1
    ;;
esac

git remote get-url "$remote" >/dev/null 2>&1 || {
  echo "Missing git remote: $remote" >&2
  exit 1
}

command -v gh >/dev/null 2>&1 || {
  echo "GitHub CLI is required: install and authenticate gh" >&2
  exit 1
}
gh auth status >/dev/null 2>&1 || {
  echo "GitHub CLI is not authenticated; run: gh auth login" >&2
  exit 1
}

base="${PR_TRACK_BASE:-}"
if [ -z "$base" ]; then
  base_ref="$(git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)"
  base="${base_ref#"$remote"/}"
fi
if [ -z "$base" ]; then
  if git show-ref --verify --quiet "refs/remotes/$remote/main"; then
    base="main"
  elif git show-ref --verify --quiet "refs/remotes/$remote/master"; then
    base="master"
  else
    echo "Cannot determine the base branch; set PR_TRACK_BASE" >&2
    exit 1
  fi
fi

ahead="$(git rev-list --count "$remote/$base..HEAD")"
if [ "$ahead" -eq 0 ]; then
  echo "No commits on $branch beyond $remote/$base; nothing to track"
  exit 0
fi

existing="$(gh pr list --state all --head "$branch" --limit 1 \
  --json number,state,url \
  --jq 'if length == 0 then empty else .[0] | [.number, .state, .url] | @tsv end')"

if [ -n "$existing" ]; then
  number="$(printf '%s' "$existing" | cut -f1)"
  state="$(printf '%s' "$existing" | cut -f2)"
  url="$(printf '%s' "$existing" | cut -f3)"
  if [ "$state" != "OPEN" ]; then
    echo "Branch $branch already has PR #$number in state $state; create a new branch" >&2
    exit 1
  fi
  git push -u "$remote" "$branch"
  echo "Updated tracked PR #$number: $url"
  exit 0
fi

git push -u "$remote" "$branch"
url="$(gh pr create --draft --fill --base "$base" --head "$branch")"
echo "Opened draft PR: $url"
