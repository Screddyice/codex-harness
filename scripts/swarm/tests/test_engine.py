import pytest

from conftest import FakeWorker, fail, git, make_tasks, ok_edit, ok_no_handoff
from swarmlib import engine as engine_mod
from swarmlib import gitops
from swarmlib.engine import SwarmEngine, SwarmError, load_tasks
from swarmlib.manifest import Manifest, RepoLock, RepoLockError


def build(repo, data, workers, **kwargs):
    tasks = load_tasks(data, kwargs.pop("via", "codex"))
    kwargs.setdefault("echo", lambda *_: None)
    return SwarmEngine(repo, tasks, workers=workers, **kwargs)


def test_load_tasks_is_codex_only():
    with pytest.raises(SwarmError, match="unknown provider"):
        load_tasks({"tasks": [{"id": "a", "task": "x", "via": "other"}]}, "codex")
    tasks = load_tasks({"tasks": [{"id": "a", "task": "x"}]}, "codex")
    assert tasks[0]["via"] == "codex"


def test_load_tasks_rejects_invalid_input():
    with pytest.raises(SwarmError, match="tasks file must be"):
        load_tasks({}, "codex")
    with pytest.raises(SwarmError, match="duplicate"):
        load_tasks({"tasks": [{"id": "a", "task": "x"}, {"id": "a", "task": "y"}]}, "codex")


def test_preflight_and_dirty_guard(repo):
    (repo / "README.md").write_text("dirty\n")
    assert any("uncommitted" in item for item in engine_mod.preflight(repo, [], False, set()))
    assert engine_mod.preflight(repo, [], True, set()) == []


def test_run_commits_codex_worker_output(repo):
    workers = {"codex": FakeWorker("codex", default=ok_edit("codex.txt"))}
    code, report = build(repo, make_tasks(("a", "codex")), workers).run()
    assert code == 0
    task = report["tasks"][0]
    assert task["status"] == "completed"
    assert task["commit"] and task["changed_files"] == ["codex.txt"]
    assert gitops.branch_exists(repo, task["branch"])


def test_blocked_or_missing_handoff_stays_uncommitted(repo):
    blocked = build(repo, make_tasks(("a", "codex")),
                    {"codex": FakeWorker("codex", default=ok_edit("partial.txt", status="blocked"))})
    code, report = blocked.run()
    assert code == 3 and report["tasks"][0]["commit"] is None

    missing = build(repo, make_tasks(("b", "codex")),
                    {"codex": FakeWorker("codex", default=ok_no_handoff())})
    code, report = missing.run()
    assert code == 3 and "no parseable" in report["tasks"][0]["blockers"][0]


def test_limit_breaker_skips_queued_tasks(repo):
    workers = {"codex": FakeWorker("codex", default=fail(stderr="usage limit", duration=3))}
    code, report = build(repo, make_tasks(("a", "codex"), ("b", "codex")), workers,
                         max_parallel=1).run()
    assert code == 3
    assert all(item["status"] == "provider_limited" for item in report["tasks"])
    assert workers["codex"].calls == ["task-a"]


def test_concurrency_cap(repo):
    workers = {"codex": FakeWorker("codex", default=ok_edit("out.txt"), delay=0.02)}
    data = make_tasks(*[(str(i), "codex") for i in range(4)])
    code, _ = build(repo, data, workers, max_parallel=1, max_total=4).run()
    assert code == 0 and workers["codex"].max_active == 1


def test_second_run_obeys_repo_lock(repo):
    lock = RepoLock(repo)
    lock.acquire()
    try:
        with pytest.raises(RepoLockError):
            build(repo, make_tasks(("a", "codex")), {"codex": FakeWorker("codex")}).run()
    finally:
        lock.release()


def test_status_and_clean_require_fold(repo):
    workers = {"codex": FakeWorker("codex", behaviors={
        "task-a": ok_edit("a.txt"), "task-b": ok_edit("b.txt")})}
    eng = build(repo, make_tasks(("a", "codex"), ("b", "codex")), workers)
    code, report = eng.run()
    assert code == 0
    view = engine_mod.status(eng.run_id)
    assert all(item["git"]["branch_exists"] and item["git"]["ahead"] == 1 for item in view["tasks"])
    cleaned, refused = engine_mod.clean(eng.run_id)
    assert cleaned == [] and len(refused) == 2
    for task in report["tasks"]:
        git(["merge", "--squash", task["branch"]], repo)
        git(["commit", "-q", "-m", "fold"], repo)
    cleaned, refused = engine_mod.clean(eng.run_id)
    assert refused == [] and set(cleaned) == {"a", "b"}
    assert Manifest.load(eng.run_id).data["status"] == "cleaned"
