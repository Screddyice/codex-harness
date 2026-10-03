from pathlib import Path

from conftest import git

from swarmlib import gitops


def test_dirty_tracked_only(repo):
    assert gitops.dirty_tracked_files(repo) == []
    (repo / "untracked.txt").write_text("new\n")
    assert gitops.dirty_tracked_files(repo) == []  # untracked never blocks
    (repo / "README.md").write_text("changed\n")
    assert gitops.dirty_tracked_files(repo) == ["README.md"]


def test_worktree_commit_and_changed_files(repo, tmp_path):
    base = gitops.head_sha(repo)
    wt = tmp_path / "wt"
    gitops.worktree_add(repo, wt, "swarm/run/t1", base)
    assert gitops.branch_exists(repo, "swarm/run/t1")
    (wt / "new.txt").write_text("worker output\n")
    sha = gitops.commit_all(wt, "chore(swarm): t1 - test")
    assert sha and sha != base
    assert gitops.changed_files(wt, base) == ["new.txt"]
    assert gitops.ahead_count(repo, "swarm/run/t1", base) == 1


def test_commit_all_nothing_to_commit(repo, tmp_path):
    base = gitops.head_sha(repo)
    wt = tmp_path / "wt"
    gitops.worktree_add(repo, wt, "swarm/run/t2", base)
    assert gitops.commit_all(wt, "empty") is None


def test_unmerged_then_squash_fold(repo, tmp_path):
    base = gitops.head_sha(repo)
    wt = tmp_path / "wt"
    gitops.worktree_add(repo, wt, "swarm/run/t3", base)
    (wt / "feature.txt").write_text("content\n")
    gitops.commit_all(wt, "chore(swarm): t3 - feature")
    assert gitops.unmerged_commits(repo, "swarm/run/t3")

    git(["merge", "--squash", "swarm/run/t3"], repo)
    git(["commit", "-q", "-m", "fold t3"], repo)
    assert gitops.unmerged_commits(repo, "swarm/run/t3") == []


def test_worktree_dirty_and_remove(repo, tmp_path):
    base = gitops.head_sha(repo)
    wt = tmp_path / "wt"
    gitops.worktree_add(repo, wt, "swarm/run/t4", base)
    assert not gitops.worktree_dirty(wt)
    (wt / "wip.txt").write_text("uncommitted\n")
    assert gitops.worktree_dirty(wt)
    gitops.worktree_remove(repo, wt)
    assert not Path(wt).exists()
    assert not gitops.worktree_dirty(wt)  # missing dir is not dirty
    gitops.branch_delete(repo, "swarm/run/t4")
    assert not gitops.branch_exists(repo, "swarm/run/t4")


def test_is_rs21(repo):
    assert not gitops.is_rs21(repo)
    git(["remote", "add", "origin", "git@github.com:teamnebula-ai/rs21-nasa-thing.git"], repo)
    assert gitops.is_rs21(repo)
