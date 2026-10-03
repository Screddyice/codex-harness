"""Git plumbing for the swarm engine.

The engine — never a worker — runs every git command (eng review D9): workers
are sandboxed and a linked worktree's refs live in the main repo's common git
dir, outside any per-worktree writable root. All facts reported in handoffs
(branch, commit, changed files) are derived here from git itself.
"""
from __future__ import annotations

import subprocess
from pathlib import Path


class GitError(RuntimeError):
    pass


def _git(args, cwd, check=True):
    completed = subprocess.run(
        ["git", "-C", str(cwd)] + list(args),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    if check and completed.returncode != 0:
        raise GitError(
            f"git {' '.join(args)} failed in {cwd}: {completed.stderr.strip()}")
    return completed


def is_git_repo(workspace):
    return _git(["rev-parse", "--is-inside-work-tree"], workspace, check=False).returncode == 0


def toplevel(workspace):
    return Path(_git(["rev-parse", "--show-toplevel"], workspace).stdout.strip())


def origin_url(workspace):
    completed = _git(["remote", "get-url", "origin"], workspace, check=False)
    return completed.stdout.strip() if completed.returncode == 0 else ""


def is_rs21(workspace):
    identity = f"{origin_url(workspace)} {toplevel(workspace).name}".lower()
    return "rs21" in identity


def head_sha(workspace):
    return _git(["rev-parse", "HEAD"], workspace).stdout.strip()


def dirty_tracked_files(workspace):
    """Tracked files with uncommitted changes. Untracked files never block a
    run — workers branch from a commit either way (eng review 1A/D12)."""
    out = _git(["status", "--porcelain"], workspace).stdout
    return [line[3:] for line in out.splitlines() if line and not line.startswith("??")]


def worktree_add(workspace, path, branch, base_sha):
    _git(["worktree", "add", "-b", branch, str(path), base_sha], workspace)


def worktree_remove(workspace, path):
    _git(["worktree", "remove", "--force", str(path)], workspace, check=False)
    _git(["worktree", "prune"], workspace, check=False)


def branch_exists(workspace, branch):
    return _git(["rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"],
                workspace, check=False).returncode == 0


def branch_delete(workspace, branch):
    _git(["branch", "-D", branch], workspace, check=False)


def commit_all(worktree, message):
    """Stage and commit everything in the worktree. Returns the commit sha,
    or None when the worker changed nothing."""
    _git(["add", "-A"], worktree)
    if not _git(["status", "--porcelain"], worktree).stdout.strip():
        return None
    _git(["commit", "-m", message], worktree)
    return head_sha(worktree)


def changed_files(worktree, base_sha):
    out = _git(["diff", "--name-only", f"{base_sha}..HEAD"], worktree).stdout
    return [line for line in out.splitlines() if line]


def ahead_count(workspace, branch, base_sha):
    completed = _git(["rev-list", "--count", f"{base_sha}..{branch}"], workspace, check=False)
    try:
        return int(completed.stdout.strip())
    except ValueError:
        return 0


def unmerged_commits(workspace, branch):
    """Commits on branch not patch-equivalent to anything in the workspace's
    current HEAD history (git cherry — survives squash merges of the engine's
    one-commit-per-task branches). Eng review D12: clean must never delete
    the only copy of unreviewed work."""
    completed = _git(["cherry", "HEAD", branch], workspace, check=False)
    if completed.returncode != 0:
        return []
    return [line[2:] for line in completed.stdout.splitlines() if line.startswith("+")]


def worktree_dirty(worktree):
    if not Path(worktree).is_dir():
        return False
    return bool(_git(["status", "--porcelain"], worktree, check=False).stdout.strip())
