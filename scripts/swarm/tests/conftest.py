import subprocess
import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from swarmlib.workers import WorkerResult  # noqa: E402


def git(args, cwd):
    subprocess.run(["git", "-C", str(cwd)] + args, check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


@pytest.fixture
def repo(tmp_path):
    """A real git repo with one commit."""
    path = tmp_path / "repo"
    path.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(path)], check=True)
    git(["config", "user.email", "swarm@test"], path)
    git(["config", "user.name", "Swarm Test"], path)
    (path / "README.md").write_text("hello\n")
    git(["add", "-A"], path)
    git(["commit", "-q", "-m", "init"], path)
    return path


@pytest.fixture(autouse=True)
def swarm_home_env(tmp_path, monkeypatch):
    home = tmp_path / "swarm-home"
    monkeypatch.setenv("SWARM_HOME", str(home))
    return home


class FakeWorker:
    """Scripted worker: behaviors maps task text -> callable(worktree) -> WorkerResult.
    Also tracks concurrency so cap tests can assert the observed maximum."""

    def __init__(self, provider, behaviors=None, default=None, delay=0.0):
        self.provider = provider
        self.behaviors = behaviors or {}
        self.default = default
        self.delay = delay
        self._lock = threading.Lock()
        self._active = 0
        self.max_active = 0
        self.calls = []

    def run_task(self, task_text, worktree, model=None, effort=None):
        import time
        with self._lock:
            self._active += 1
            self.max_active = max(self.max_active, self._active)
            self.calls.append(task_text)
        try:
            if self.delay:
                time.sleep(self.delay)
            behavior = self.behaviors.get(task_text, self.default)
            if behavior is None:
                behavior = ok_edit("done.txt")
            return behavior(worktree)
        finally:
            with self._lock:
                self._active -= 1


def handoff(status="completed", summary="did it", checks=None, blockers=None):
    return {"status": status, "summary": summary,
            "checks": checks or ["pytest -q"], "blockers": blockers or []}


def ok_edit(filename, status="completed"):
    def behavior(worktree):
        (Path(worktree) / filename).write_text("made by worker\n")
        return WorkerResult(0, "", "", 1.0, handoff(status=status))
    return behavior


def ok_no_handoff():
    def behavior(worktree):
        return WorkerResult(0, "gibberish, no json here", "", 1.0, None)
    return behavior


def fail(rc=1, stderr="boom", duration=1.0):
    def behavior(worktree):
        return WorkerResult(rc, "", stderr, duration)
    return behavior


def make_tasks(*specs):
    """specs: (id, via) or (id, via, files)."""
    tasks = []
    for spec in specs:
        tid, via = spec[0], spec[1]
        files = spec[2] if len(spec) > 2 else []
        tasks.append({"id": tid, "task": f"task-{tid}", "via": via, "files": files})
    return {"tasks": tasks}
