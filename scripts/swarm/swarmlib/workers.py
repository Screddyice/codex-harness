"""Headless Codex worker adapter, edit-only, one task each.

Workers NEVER run git (the engine commits — D9), never push, never open PRs,
and are told not to run llmjury/local models or spawn subagents (D10 — four
cloud workers each booting a local Ollama council is how this machine kernel
panicked on 2026-07-31).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

FAST_FAIL_SECS = 60

HANDOFF_KEYS = {"status", "summary", "checks", "blockers"}

HANDOFF_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "status": {"type": "string", "enum": ["completed", "blocked"]},
        "summary": {"type": "string"},
        "checks": {"type": "array", "items": {"type": "string"}},
        "blockers": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["status", "summary", "checks", "blockers"],
}

WORKER_PROMPT = """\
You are a swarm worker agent executing ONE bounded task in an isolated git worktree.

Rules:
- Work ONLY inside the current working directory (your worktree). Never read or
  modify files outside it.
- Read the repository's AGENTS.md if present and follow its conventions.
- Implement the task below, then run the most relevant available checks (tests,
  lint, build) for what you changed.
- Do NOT run any git write command (commit, push, branch, tag), and do NOT open
  pull requests. The engine commits your work for you.
- Do NOT run llmjury, ollama, or any local model, and do NOT spawn subagents.
  Do the work directly yourself.
- Stay in scope. Do not broaden the task.

End your reply with ONLY a JSON object (inside a ```json fence) with exactly these
keys: "status" ("completed" or "blocked"), "summary" (one paragraph, string),
"checks" (array of strings — the exact check commands you ran), "blockers"
(array of strings, empty when completed).

TASK
----
{task}
"""

ENV_ALLOWLIST = (
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "LC_ALL",
    "LC_CTYPE", "TMPDIR", "TZ", "CODEX_HOME",
    "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
)

_LIMIT_RE = re.compile(
    r"(?:\b429\b|usage[ _-]?limit|rate[ _-]?limit|quota|too many requests|"
    r"overloaded|out of (?:usage|credits))",
    re.IGNORECASE,
)


def limit_signature(text):
    return bool(_LIMIT_RE.search(text or ""))


def scrubbed_env(extra=None):
    env = {k: os.environ[k] for k in ENV_ALLOWLIST if k in os.environ}
    env.update(extra or {})
    return env


class WorkerResult:
    def __init__(self, returncode, stdout, stderr, duration, handoff=None):
        self.returncode = returncode
        self.stdout = stdout or ""
        self.stderr = stderr or ""
        self.duration = duration
        self.handoff = handoff

    @property
    def ok(self):
        return self.returncode == 0

    @property
    def fast_failure(self):
        return not self.ok and self.duration < FAST_FAIL_SECS

    @property
    def limit_hit(self):
        return not self.ok and limit_signature(self.stdout + "\n" + self.stderr)


def parse_handoff(text):
    """Best-effort handoff extraction. Garbage degrades to None (the task is
    marked blocked); it must never raise."""
    if not text:
        return None
    candidates = []
    fenced = re.findall(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    candidates.extend(reversed(fenced))
    stripped = text.strip()
    if stripped.startswith("{"):
        candidates.append(stripped)
    brace = stripped.rfind("{")
    if brace >= 0:
        candidates.append(stripped[brace:])
    for candidate in candidates:
        try:
            payload = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict) or payload.get("status") not in ("completed", "blocked"):
            continue
        return {
            "status": payload["status"],
            "summary": str(payload.get("summary", "")),
            "checks": [str(c) for c in payload.get("checks") or []],
            "blockers": [str(b) for b in payload.get("blockers") or []],
        }
    return None


class CliWorker:
    """Shared runner mechanics for the Codex provider."""

    provider = ""
    executable = ""

    def __init__(self, timeout=1800, runner=None, executable=None):
        self.timeout = timeout
        self.runner = runner or subprocess.run
        if executable:
            self.executable = executable
        if runner is None and not shutil.which(self.executable):
            raise RuntimeError(f"{self.executable} CLI not found on PATH")

    def _run(self, cmd, cwd, env):
        start = time.monotonic()
        try:
            # stdin MUST be an immediate EOF: codex exec with a readable
            # non-TTY stdin blocks forever waiting to consume piped input
            # before its first API call (caught live in E2E validation —
            # 21 min asleep, zero sockets open).
            completed = self.runner(
                cmd, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                timeout=self.timeout, check=False, cwd=str(cwd), env=env,
            )
            return WorkerResult(completed.returncode, completed.stdout,
                                completed.stderr, time.monotonic() - start)
        except subprocess.TimeoutExpired:
            return WorkerResult(124, "", f"{self.provider} worker timed out after {self.timeout}s",
                                time.monotonic() - start)
        except OSError as exc:
            return WorkerResult(127, "", f"cannot run {self.executable}: {exc}",
                                time.monotonic() - start)

    def run_task(self, task_text, worktree, model=None, effort=None):
        raise NotImplementedError


class CodexWorker(CliWorker):
    provider = "codex"
    executable = "codex"

    def run_task(self, task_text, worktree, model=None, effort=None):
        prompt = WORKER_PROMPT.format(task=task_text.strip())
        with tempfile.TemporaryDirectory(prefix="swarm-codex-") as tmp:
            schema_path = Path(tmp) / "handoff.schema.json"
            output_path = Path(tmp) / "handoff.json"
            schema_path.write_text(json.dumps(HANDOFF_SCHEMA), encoding="utf-8")
            cmd = [
                self.executable, "exec", "--ephemeral",
                "--sandbox", "workspace-write",
                "--color", "never",
                "--cd", str(worktree),
                "--output-schema", str(schema_path),
                "--output-last-message", str(output_path),
                "-c", "shell_environment_policy.inherit=core",
            ]
            if model:
                cmd.extend(["--model", model])
            if effort:
                cmd.extend(["-c", f'model_reasoning_effort="{effort}"'])
            cmd.append(prompt)
            result = self._run(cmd, worktree, scrubbed_env())
            if result.ok:
                try:
                    result.handoff = parse_handoff(output_path.read_text(encoding="utf-8"))
                except OSError:
                    result.handoff = parse_handoff(result.stdout)
            return result


WORKER_TYPES = {"codex": CodexWorker}
