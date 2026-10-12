import importlib.util
import json
import sys
from pathlib import Path

import pytest

SWARM_PY = Path(__file__).resolve().parents[1] / "swarm.py"
spec = importlib.util.spec_from_file_location("swarm_cli", SWARM_PY)
swarm_cli = importlib.util.module_from_spec(spec)
sys.modules["swarm_cli"] = swarm_cli
spec.loader.exec_module(swarm_cli)


def test_run_requires_tasks_flag():
    with pytest.raises(SystemExit):
        swarm_cli.main(["run"])


def test_run_rejects_non_codex_provider(tmp_path):
    tasks = tmp_path / "tasks.json"
    tasks.write_text(json.dumps({"tasks": [{"id": "a", "task": "x", "via": "other"}]}))
    with pytest.raises(SystemExit) as exc:
        swarm_cli.main(["run", "--tasks", str(tasks)])
    assert "unknown provider" in str(exc.value)


def test_run_passes_codex_options(tmp_path, monkeypatch, capsys):
    tasks = tmp_path / "tasks.json"
    tasks.write_text(json.dumps({"tasks": [{"id": "a", "task": "x"}]}))
    captured = {}

    class StubEngine:
        def __init__(self, workspace, task_list, **kwargs):
            captured["workspace"] = workspace
            captured["tasks"] = task_list
            captured["kwargs"] = kwargs

        def run(self):
            return 2, {"run_id": "r", "workspace": "w", "base_sha": "abc",
                       "counts": {"completed": 1, "blocked": 1,
                                  "provider_limited": 0, "provider_unavailable": 0},
                       "tasks": []}

    monkeypatch.setattr(swarm_cli, "SwarmEngine", StubEngine)
    with pytest.raises(SystemExit) as exc:
        swarm_cli.main(["run", "--workspace", str(tmp_path), "--tasks", str(tasks),
                        "--max-parallel", "2", "--max-total", "3", "--allow-dirty", "--json"])
    assert exc.value.code == 2
    assert captured["tasks"][0]["via"] == "codex"
    assert captured["kwargs"]["max_parallel"] == 2
    assert captured["kwargs"]["allow_dirty"] is True
    assert json.loads(capsys.readouterr().out)["run_id"] == "r"


def test_status_and_clean_missing_run_errors():
    for command in (["status", "missing"], ["clean", "missing"]):
        with pytest.raises(SystemExit) as exc:
            swarm_cli.main(command)
        assert "no manifest" in str(exc.value)
