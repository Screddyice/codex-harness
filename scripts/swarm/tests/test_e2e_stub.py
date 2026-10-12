import os
import stat

import pytest

from conftest import git, make_tasks
from swarmlib import engine as engine_mod
from swarmlib.engine import SwarmEngine, load_tasks

CODEX_STUB = """#!/bin/bash
cd_dir=""
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cd) shift; cd_dir="$1";;
    --output-last-message) shift; out="$1";;
  esac
  shift
done
echo "stub codex output" > "$cd_dir/codex_did.txt"
printf '%s\n' '{"status":"completed","summary":"codex stub did it","checks":["true"],"blockers":[]}' > "$out"
"""


@pytest.fixture
def stub_path(tmp_path, monkeypatch):
    bin_dir = tmp_path / "stub-bin"
    bin_dir.mkdir()
    script = bin_dir / "codex"
    script.write_text(CODEX_STUB)
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", f"{bin_dir}:{os.environ['PATH']}")
    return bin_dir


def test_full_codex_lifecycle(repo, stub_path):
    tasks = load_tasks(make_tasks(("a", "codex"), ("b", "codex")), "codex")
    eng = SwarmEngine(repo, tasks, echo=lambda *_: None)
    code, report = eng.run()
    assert code == 0
    assert all(item["status"] == "completed" for item in report["tasks"])
    assert all(item["changed_files"] == ["codex_did.txt"] for item in report["tasks"])
    view = engine_mod.status(eng.run_id)
    assert all(item["git"]["branch_exists"] for item in view["tasks"])
    cleaned, refused = engine_mod.clean(eng.run_id, force=True)
    assert set(cleaned) == {"a", "b"} and refused == []


def test_codex_limit_trips_breaker(repo, stub_path):
    stub = stub_path / "codex"
    stub.write_text("#!/bin/bash\necho 'usage limit' >&2\nexit 1\n")
    tasks = load_tasks(make_tasks(("a", "codex"), ("b", "codex")), "codex")
    code, report = SwarmEngine(repo, tasks, max_parallel=1, echo=lambda *_: None).run()
    assert code == 3
    assert all(item["status"] == "provider_limited" for item in report["tasks"])
