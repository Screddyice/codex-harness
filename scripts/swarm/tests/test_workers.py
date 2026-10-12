import json
import subprocess

import pytest

from swarmlib.workers import CodexWorker, WorkerResult, limit_signature, parse_handoff, scrubbed_env

GOOD = {"status": "completed", "summary": "done", "checks": ["pytest"], "blockers": []}


def test_parse_handoff_variants():
    assert parse_handoff(json.dumps(GOOD))["status"] == "completed"
    assert parse_handoff("not json") is None


@pytest.mark.parametrize("text", ["HTTP 429", "usage limit", "rate-limited", "quota exceeded"])
def test_limit_signature(text):
    assert limit_signature(text)


def test_worker_result_only_failed_limits_count():
    assert WorkerResult(1, "", "usage limit", 3).limit_hit
    assert not WorkerResult(0, "", "usage limit", 3).limit_hit
    assert not WorkerResult(1, "", "crash", 120).fast_failure


def test_scrubbed_env_excludes_provider_secrets(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "secret")
    monkeypatch.setenv("OPENROUTER_API_KEY", "secret")
    monkeypatch.setenv("PATH", "/usr/bin")
    env = scrubbed_env()
    assert env["PATH"] == "/usr/bin"
    assert "OPENAI_API_KEY" not in env
    assert "OPENROUTER_API_KEY" not in env


def test_codex_worker_builds_isolated_command(tmp_path):
    seen = {}

    def runner(cmd, **kwargs):
        seen["cmd"] = cmd
        output = cmd[cmd.index("--output-last-message") + 1]
        with open(output, "w", encoding="utf-8") as handle:
            json.dump(GOOD, handle)
        return subprocess.CompletedProcess(cmd, 0, "", "")

    result = CodexWorker(runner=runner).run_task("do it", tmp_path, model="gpt-5.4", effort="low")
    assert seen["cmd"][:3] == ["codex", "exec", "--ephemeral"]
    assert "--sandbox" in seen["cmd"] and "workspace-write" in seen["cmd"]
    assert result.handoff["status"] == "completed"


def test_codex_worker_falls_back_to_stdout(tmp_path):
    def runner(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, json.dumps(GOOD), "")

    assert CodexWorker(runner=runner).run_task("t", tmp_path).handoff["status"] == "completed"


def test_codex_worker_timeout_and_oserror(tmp_path):
    def timeout_runner(cmd, **kwargs):
        raise subprocess.TimeoutExpired(cmd, 5)

    assert CodexWorker(runner=timeout_runner).run_task("t", tmp_path).returncode == 124

    def os_error_runner(cmd, **kwargs):
        raise OSError("exec format error")

    assert CodexWorker(runner=os_error_runner).run_task("t", tmp_path).returncode == 127


def test_missing_executable_raises():
    with pytest.raises(RuntimeError, match="not found"):
        CodexWorker(executable="definitely-not-real")
