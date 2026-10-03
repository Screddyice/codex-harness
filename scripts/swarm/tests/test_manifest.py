import json
import subprocess

import pytest

from swarmlib.manifest import Manifest, RepoLock, RepoLockError, atomic_write_json, swarm_home


def test_atomic_write_creates_parents_and_valid_json(tmp_path):
    target = tmp_path / "deep" / "nested" / "file.json"
    atomic_write_json(target, {"a": 1})
    assert json.loads(target.read_text()) == {"a": 1}
    assert not target.with_name(target.name + ".tmp").exists()


def test_swarm_home_env_override(swarm_home_env):
    assert swarm_home() == swarm_home_env


def test_lock_blocks_second_acquire(repo):
    first, second = RepoLock(repo), RepoLock(repo)
    first.acquire()
    with pytest.raises(RepoLockError, match="holds the lock"):
        second.acquire()
    first.release()
    second.acquire()
    second.release()


def test_dead_pid_lock_auto_releases(repo):
    proc = subprocess.Popen(["true"])
    proc.wait()
    lock = RepoLock(repo)
    lock.path.parent.mkdir(parents=True, exist_ok=True)
    lock.path.write_text(json.dumps({"pid": proc.pid}))
    lock.acquire()  # dead pid must not block
    lock.release()


def test_corrupt_lock_auto_releases(repo):
    lock = RepoLock(repo)
    lock.path.parent.mkdir(parents=True, exist_ok=True)
    lock.path.write_text("not json")
    lock.acquire()
    lock.release()


def test_manifest_round_trip(repo):
    tasks = [{"id": "t1", "status": "pending"}]
    m = Manifest.create("run-x", repo, "abc123", tasks, {"max_total": 4})
    loaded = Manifest.load("run-x")
    assert loaded.data["base_sha"] == "abc123"
    assert loaded.task_order == ["t1"]
    loaded.tasks["t1"]["status"] = "completed"
    loaded.save()
    assert Manifest.load("run-x").tasks["t1"]["status"] == "completed"


def test_manifest_load_missing_run():
    with pytest.raises(FileNotFoundError):
        Manifest.load("no-such-run")
