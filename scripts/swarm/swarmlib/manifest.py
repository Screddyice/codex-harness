"""Run-state store: single-writer manifest with atomic writes + per-repo PID lock.

Only the engine's main thread writes the manifest (worker threads hand results
back over futures), so every on-disk snapshot is internally consistent. Writes
go through a temp file + os.replace so a crash at any point leaves either the
previous or the next complete state, never a torn file.
"""
from __future__ import annotations

import errno
import hashlib
import json
import os
from pathlib import Path


def swarm_home():
    return Path(os.environ.get("SWARM_HOME", "~/.codex-swarm")).expanduser()


def atomic_write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    os.replace(tmp, path)


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError as exc:
        # EPERM means the pid exists but belongs to another user — still alive.
        return exc.errno == errno.EPERM
    return True


class RepoLockError(RuntimeError):
    pass


class RepoLock:
    """One swarm run per repository. PID-stamped; dead-PID locks auto-release."""

    def __init__(self, workspace):
        digest = hashlib.sha256(str(Path(workspace).resolve()).encode()).hexdigest()[:16]
        self.path = swarm_home() / "locks" / f"{digest}.lock"
        self.acquired = False

    def acquire(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists():
            try:
                holder = json.loads(self.path.read_text(encoding="utf-8"))
                pid = int(holder.get("pid", -1))
            except (ValueError, OSError):
                pid = -1
            if pid > 0 and _pid_alive(pid):
                raise RepoLockError(
                    f"another swarm run (pid {pid}) holds the lock for this repo; "
                    f"wait for it or remove {self.path} if it is not a real run")
            self.path.unlink(missing_ok=True)
        atomic_write_json(self.path, {"pid": os.getpid()})
        self.acquired = True

    def release(self):
        if self.acquired:
            self.path.unlink(missing_ok=True)
            self.acquired = False


class Manifest:
    """The run's source of truth. Load/save whole-document; engine mutates
    task dicts in place and calls save() after every state change."""

    def __init__(self, run_id, data=None):
        self.run_id = run_id
        self.path = swarm_home() / f"{run_id}.json"
        self.data = data or {}

    @classmethod
    def create(cls, run_id, workspace, base_sha, tasks, options):
        m = cls(run_id)
        m.data = {
            "run_id": run_id,
            "workspace": str(Path(workspace).resolve()),
            "base_sha": base_sha,
            "status": "running",
            "options": options,
            "tasks": {t["id"]: t for t in tasks},
            "task_order": [t["id"] for t in tasks],
        }
        m.save()
        return m

    @classmethod
    def load(cls, run_id):
        path = swarm_home() / f"{run_id}.json"
        if not path.exists():
            raise FileNotFoundError(f"no manifest for run {run_id} at {path}")
        return cls(run_id, json.loads(path.read_text(encoding="utf-8")))

    def save(self):
        atomic_write_json(self.path, self.data)

    @property
    def tasks(self):
        return self.data["tasks"]

    @property
    def task_order(self):
        return self.data["task_order"]
