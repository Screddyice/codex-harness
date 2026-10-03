"""The swarm engine: preflight, worktree fan-out, scheduling, breaker, reconcile.

Execution model (eng review D9/D12): the main thread owns ALL state — it
creates worktrees, submits workers to a thread pool, applies every result,
runs every git command, and is the manifest's single writer. Worker threads
only shell out to their CLI and hand back a WorkerResult.

    tasks.json ─► preflight ─► per task: worktree + branch swarm/<run>/<id>
                                   │
                     ┌─────────────┴──────────────┐
                     ▼ (≤ --max-parallel/provider) ▼ (Σ ≤ --max-total)
                CodexWorker …               CodexWorker …
                     │        edit-only          │
                     └─────────────┬─────────────┘
                                   ▼
              engine commits per worktree, derives git facts,
              updates breaker, rewrites manifest atomically
"""
from __future__ import annotations

import concurrent.futures
import os
import re
import shutil
import time
import uuid
from pathlib import Path

from . import gitops
from .manifest import Manifest, RepoLock, swarm_home
from .workers import WORKER_TYPES

PROVIDERS = ("codex",)
TASK_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
CONSECUTIVE_FAST_TRIP = 2

TERMINAL = ("completed", "blocked", "provider_limited", "provider_unavailable")


class SwarmError(RuntimeError):
    pass


def load_tasks(data, default_via):
    if not isinstance(data, dict) or not isinstance(data.get("tasks"), list):
        raise SwarmError('tasks file must be {"tasks": [...]}')
    tasks, seen = [], set()
    for raw in data["tasks"]:
        if not isinstance(raw, dict):
            raise SwarmError("every task must be an object")
        tid = str(raw.get("id") or "")
        if not TASK_ID_RE.match(tid):
            raise SwarmError(f"invalid task id {tid!r} (need [A-Za-z0-9][A-Za-z0-9._-]*)")
        if tid in seen:
            raise SwarmError(f"duplicate task id {tid!r}")
        seen.add(tid)
        text = str(raw.get("task") or "").strip()
        if not text:
            raise SwarmError(f"task {tid!r} has no task text")
        via = raw.get("via") or default_via
        if via not in PROVIDERS:
            raise SwarmError(f"task {tid!r}: unknown provider {via!r} (codex only)")
        files = raw.get("files") or []
        if not isinstance(files, list) or not all(isinstance(f, str) for f in files):
            raise SwarmError(f"task {tid!r}: files must be a list of strings")
        tasks.append({
            "id": tid, "task": text, "via": via,
            "model": raw.get("model"), "effort": raw.get("effort"),
            "files": files, "status": "pending",
            "branch": None, "worktree": None, "commit": None,
            "changed_files": [], "summary": "", "checks": [], "blockers": [],
            "attempts": [],
        })
    if not tasks:
        raise SwarmError("tasks file contains no tasks")
    return tasks


def overlap_warnings(tasks):
    """Advisory file-scope overlap check (eng review D15). Warns, never blocks."""
    warnings = []
    for i, a in enumerate(tasks):
        for b in tasks[i + 1:]:
            shared = sorted(set(a["files"]) & set(b["files"]))
            if shared:
                warnings.append(
                    f"tasks {a['id']!r} and {b['id']!r} both declare files: "
                    + ", ".join(shared))
    return warnings


def preflight(workspace, tasks, allow_dirty, providers_needed, which=shutil.which):
    errors = []
    if not gitops.is_git_repo(workspace):
        errors.append(f"{workspace} is not a git repository")
        return errors
    if gitops.is_rs21(workspace):
        errors.append("rs21 repository detected — swarm refuses to run here (workspace policy)")
    dirty = gitops.dirty_tracked_files(workspace)
    if dirty and not allow_dirty:
        errors.append(
            "working tree has uncommitted tracked changes (workers branch from HEAD "
            "and will NOT see them): " + ", ".join(dirty[:20])
            + (" …" if len(dirty) > 20 else "")
            + " — commit first, or pass --allow-dirty to proceed without them")
    for provider in sorted(providers_needed):
        if which(WORKER_TYPES[provider].executable) is None:
            errors.append(f"{provider} CLI not found on PATH but tasks require it")
    return errors


class Breaker:
    """Per-provider circuit breaker (eng review 2A/D12): trips on a usage-limit
    signature (provider_limited) or on 2 consecutive fast failures
    (provider_unavailable). A single slow failure never trips."""

    def __init__(self):
        self.state = {p: {"tripped": None, "fast": 0} for p in PROVIDERS}

    def tripped(self, provider):
        return self.state[provider]["tripped"]

    def record_success(self, provider):
        self.state[provider]["fast"] = 0

    def record_failure(self, provider, result):
        entry = self.state[provider]
        if result.limit_hit:
            entry["tripped"] = "provider_limited"
        elif result.fast_failure:
            entry["fast"] += 1
            if entry["fast"] >= CONSECUTIVE_FAST_TRIP:
                entry["tripped"] = "provider_unavailable"
        else:
            entry["fast"] = 0
        return entry["tripped"]


class SwarmEngine:
    def __init__(self, workspace, tasks, max_parallel=3, max_total=4,
                 fallback=False, allow_dirty=False, timeout=1800,
                 workers=None, run_id=None, echo=print):
        self.workspace = Path(workspace).resolve()
        self.task_list = tasks
        self.max_parallel = max(1, int(max_parallel))
        self.max_total = max(1, int(max_total))
        self.fallback = fallback
        self.allow_dirty = allow_dirty
        self.timeout = timeout
        self._workers = dict(workers or {})
        self.run_id = run_id or time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
        self.breaker = Breaker()
        self.echo = echo

    # -- workers ---------------------------------------------------------
    def worker_for(self, provider):
        if provider not in self._workers:
            self._workers[provider] = WORKER_TYPES[provider](timeout=self.timeout)
        return self._workers[provider]

    def worker_available(self, provider):
        try:
            self.worker_for(provider)
            return True
        except RuntimeError:
            return False

    # -- run -------------------------------------------------------------
    def run(self):
        providers_needed = {t["via"] for t in self.task_list}
        skip_which = bool(self._workers)  # injected workers (tests) bypass PATH checks
        errors = preflight(
            self.workspace, self.task_list, self.allow_dirty, providers_needed,
            which=(lambda name: name) if skip_which else shutil.which)
        for warning in overlap_warnings(self.task_list):
            self.echo(f"warning: {warning}")
        if errors:
            raise SwarmError("; ".join(errors))
        if self.allow_dirty and gitops.dirty_tracked_files(self.workspace):
            self.echo("warning: running with a dirty tree — workers exclude all "
                      "uncommitted work (they branch from HEAD)")

        lock = RepoLock(self.workspace)
        lock.acquire()
        try:
            base_sha = gitops.head_sha(self.workspace)
            manifest = Manifest.create(
                self.run_id, self.workspace, base_sha, self.task_list,
                {"max_parallel": self.max_parallel, "max_total": self.max_total,
                 "fallback": self.fallback, "allow_dirty": self.allow_dirty,
                 "timeout": self.timeout, "pid": os.getpid()})
            self._loop(manifest, base_sha)
            manifest.data["status"] = "finished"
            manifest.save()
            return self._exit_code(manifest), self._report(manifest)
        finally:
            lock.release()

    def _loop(self, manifest, base_sha):
        pending = list(manifest.task_order)
        running = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.max_total) as pool:
            while pending or running:
                self._sweep_tripped(manifest, pending)
                self._launch_eligible(manifest, base_sha, pending, running, pool)
                if not running:
                    break  # everything left was skipped by the breaker
                done, _ = concurrent.futures.wait(
                    running, return_when=concurrent.futures.FIRST_COMPLETED)
                for future in done:
                    task = manifest.tasks[running.pop(future)]
                    self._apply_result(manifest, base_sha, task, future, pending)
                    manifest.save()

    def _launch_eligible(self, manifest, base_sha, pending, running, pool):
        def provider_running(p):
            return sum(1 for tid in running.values()
                       if manifest.tasks[tid]["via"] == p)
        for tid in list(pending):
            task = manifest.tasks[tid]
            provider = task["via"]
            if self.breaker.tripped(provider):
                continue  # handled by _sweep_tripped next cycle
            if len(running) >= self.max_total:
                break
            if provider_running(provider) >= self.max_parallel:
                continue
            if not self.worker_available(provider):
                task["status"] = "provider_unavailable"
                task["blockers"] = [f"{provider} CLI unavailable at launch"]
                pending.remove(tid)
                manifest.save()
                continue
            branch = f"swarm/{self.run_id}/{tid}" + ("-fb" if task["attempts"] else "")
            worktree = swarm_home() / "worktrees" / self.run_id / branch.rsplit("/", 1)[-1]
            gitops.worktree_add(self.workspace, worktree, branch, base_sha)
            task.update({"status": "running", "branch": branch,
                         "worktree": str(worktree), "started_at": time.time()})
            manifest.save()
            worker = self.worker_for(provider)
            future = pool.submit(worker.run_task, task["task"], worktree,
                                 task.get("model"), task.get("effort"))
            running[future] = tid
            pending.remove(tid)
            self.echo(f"[{tid}] → {provider} worker on {branch}")

    def _apply_result(self, manifest, base_sha, task, future, pending):
        provider = task["via"]
        try:
            result = future.result()
        except Exception as exc:  # worker adapters shouldn't raise; belt+braces
            task["status"] = "blocked"
            task["blockers"] = [f"worker crashed: {exc}"]
            return
        task["attempts"].append({
            "via": provider, "branch": task["branch"], "rc": result.returncode,
            "duration_s": round(result.duration, 1), "limit": result.limit_hit,
        })
        task["finished_at"] = time.time()

        if result.ok:
            self.breaker.record_success(provider)
            handoff = result.handoff
            if handoff is None:
                task["status"] = "blocked"
                task["blockers"] = ["worker returned no parseable handoff"]
                return
            task["summary"] = handoff["summary"]
            task["checks"] = handoff["checks"]
            task["blockers"] = handoff["blockers"]
            if handoff["status"] == "completed":
                first_line = task["task"].splitlines()[0][:60]
                try:
                    task["commit"] = gitops.commit_all(
                        task["worktree"], f"chore(swarm): {task['id']} - {first_line}")
                    task["changed_files"] = gitops.changed_files(task["worktree"], base_sha)
                except gitops.GitError as exc:
                    task["status"] = "blocked"
                    task["blockers"] = [f"engine commit failed: {exc}"]
                    return
                task["status"] = "completed"
                self.echo(f"[{task['id']}] completed "
                          f"({len(task['changed_files'])} files)")
            else:
                # Blocked work stays UNCOMMITTED for inspection; clean's dirty-
                # worktree guard protects it from deletion (D12).
                task["status"] = "blocked"
                self.echo(f"[{task['id']}] blocked: "
                          + "; ".join(task["blockers"][:2]))
            return

        tripped = self.breaker.record_failure(provider, result)
        if tripped:
            task["status"] = tripped
            self.echo(f"[{task['id']}] {provider} {tripped.replace('provider_', '')} "
                      f"— breaker tripped")
            self._maybe_fallback(task, pending)
        else:
            tail = (result.stderr or result.stdout).strip().splitlines()
            task["status"] = "blocked"
            task["blockers"] = [f"{provider} exited {result.returncode}"
                                + (f": {tail[-1]}" if tail else "")]
            self.echo(f"[{task['id']}] blocked ({provider} exited {result.returncode})")

    def _sweep_tripped(self, manifest, pending):
        for tid in list(pending):
            task = manifest.tasks[tid]
            tripped = self.breaker.tripped(task["via"])
            if not tripped:
                continue
            pending.remove(tid)
            task["status"] = tripped
            if not self._maybe_fallback(task, pending):
                manifest.save()

    def _maybe_fallback(self, task, pending):
        """Re-route a limited/unavailable task to the other provider in a
        FRESH worktree (eng review D12). One hop only."""
        if not self.fallback or task["attempts"] and any(
                a["via"] != task["via"] for a in task["attempts"]):
            return False
        other = next(p for p in PROVIDERS if p != task["via"])
        if self.breaker.tripped(other) or not self.worker_available(other):
            return False
        task["via"] = other
        task["status"] = "pending"
        task["branch"] = None
        task["worktree"] = None
        pending.append(task["id"])
        self.echo(f"[{task['id']}] re-routed to {other} (--fallback)")
        return True

    # -- reporting -------------------------------------------------------
    @staticmethod
    def _exit_code(manifest):
        statuses = [t["status"] for t in manifest.tasks.values()]
        completed = statuses.count("completed")
        if completed == len(statuses):
            return 0
        return 2 if completed else 3

    @staticmethod
    def _report(manifest):
        tasks = [manifest.tasks[tid] for tid in manifest.task_order]
        return {
            "run_id": manifest.run_id,
            "workspace": manifest.data["workspace"],
            "base_sha": manifest.data["base_sha"],
            "counts": {
                status: sum(1 for t in tasks if t["status"] == status)
                for status in TERMINAL},
            "tasks": tasks,
        }


# -- status / clean ------------------------------------------------------

def status(run_id):
    """Manifest + git-reality reconciliation (eng review D12): report what git
    actually shows next to what the manifest claims."""
    manifest = Manifest.load(run_id)
    workspace = manifest.data["workspace"]
    base_sha = manifest.data["base_sha"]
    view = []
    for tid in manifest.task_order:
        task = manifest.tasks[tid]
        branch = task.get("branch")
        entry = dict(task)
        entry["git"] = {
            "branch_exists": bool(branch) and gitops.branch_exists(workspace, branch),
            "worktree_exists": bool(task.get("worktree"))
                               and Path(task["worktree"]).is_dir(),
            "worktree_dirty": bool(task.get("worktree"))
                              and gitops.worktree_dirty(task["worktree"]),
            "ahead": gitops.ahead_count(workspace, branch, base_sha) if branch else 0,
        }
        view.append(entry)
    return {"run_id": run_id, "status": manifest.data["status"],
            "workspace": workspace, "base_sha": base_sha, "tasks": view}


def clean(run_id, force=False):
    """Remove a run's worktrees and scratch branches. Refuses to delete work
    that is not patch-equivalent to the session branch history, or worktrees
    with uncommitted changes, unless --force (eng review D12)."""
    manifest = Manifest.load(run_id)
    workspace = manifest.data["workspace"]
    refused, cleaned = [], []
    for tid in manifest.task_order:
        task = manifest.tasks[tid]
        if task["status"] == "cleaned":
            continue
        branch, worktree = task.get("branch"), task.get("worktree")
        exists = bool(branch) and gitops.branch_exists(workspace, branch)
        if not force:
            reasons = []
            if worktree and gitops.worktree_dirty(worktree):
                reasons.append("worktree has uncommitted changes")
            if exists and gitops.unmerged_commits(workspace, branch):
                reasons.append("branch has commits not folded into the session branch")
            if reasons:
                refused.append(f"{tid} ({branch}): " + "; ".join(reasons))
                continue
        if worktree:
            gitops.worktree_remove(workspace, worktree)
        if exists:
            gitops.branch_delete(workspace, branch)
        task["status"] = "cleaned"
        cleaned.append(tid)
    if not refused:
        manifest.data["status"] = "cleaned"
    manifest.save()
    return cleaned, refused
