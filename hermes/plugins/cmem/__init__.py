"""Hermes memory provider backed by cmem.

Writes go to the LOCAL worker (http://127.0.0.1:37701): `sessions/init` stores text
verbatim as a prompt, `sessions/summarize` lets the worker compress the session. The
worker queues durably before any AI work and syncs to the cmem.ai hub, so a restart
loses nothing. Reads use the hosted MCP `memory_search` (every device's memory),
falling back to the local worker's /api/search when the cloud is unreachable.

Identity: one project per Hermes box, `CMEM_PROJECT` if set, else mapped from the
hostname (`hermes-src`, `hermes-r2h`, `hermes-tmn`). The remember category becomes a
tag inside the text, never a separate project.

Nothing is written at initialize. Every `hermes -z` one-shot (the corpus classifier,
the compressor shim) constructs a provider, and posting a "session start" placeholder
there produced 900+ empty sessions a day on the hub. A session reaches the worker only
when something is remembered, or when a conversation with at least two user turns ends.
"""
from __future__ import annotations

import json, logging, os, re, socket, threading, time, urllib.error, urllib.parse, urllib.request, uuid
from typing import Any, Dict, List

from agent.memory_provider import MemoryProvider

logger = logging.getLogger(__name__)
_LOCAL = os.environ.get("CMEM_LOCAL_URL", "http://127.0.0.1:37701")
_MCP = os.environ.get("CMEM_MCP_URL", "https://cmem.ai/api/mcp")
_CRED = os.path.expanduser("~/.hermes/cmem.env")
_TIMEOUT = 20.0
_HOST_PROJECTS = {"src": "hermes-src", "reddy2help": "hermes-r2h", "neb-ops-gcp": "hermes-tmn"}


def _project() -> str:
    p = os.environ.get("CMEM_PROJECT", "").strip()
    if p:
        return p
    host = socket.gethostname().split(".", 1)[0]
    return _HOST_PROJECTS.get(host, f"hermes-{host}")


_PROJECT = _project()


def _token() -> str:
    t = os.environ.get("CMEM_PRO_TOKEN", "")
    if not t and os.path.exists(_CRED):
        m = re.search(r"^CMEM_PRO_TOKEN=(.*)$", open(_CRED).read(), re.M)
        t = m.group(1).strip().strip("\"'") if m else ""
    return t


def _post(url: str, body: dict, headers: Dict[str, str] | None = None, timeout: float = _TIMEOUT):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read().decode()
    # streamable-HTTP MCP may answer as SSE; take the first JSON object
    for line in raw.splitlines():
        line = line[5:].strip() if line.startswith("data:") else line.strip()
        if line.startswith("{"):
            return json.loads(line)
    return json.loads(raw) if raw.strip().startswith("{") else {}


class CmemMemoryProvider(MemoryProvider):
    def __init__(self) -> None:
        self._session = f"{_PROJECT}-{uuid.uuid4().hex[:12]}"
        self._written = False
        self._failures = 0
        self._opened_at = 0.0
        self._lock = threading.Lock()
        self._prefetched: Dict[str, str] = {}

    # ---- identity ---------------------------------------------------------
    @property
    def name(self) -> str:
        return "cmem"

    def is_available(self) -> bool:
        return True

    def initialize(self, session_id: str, **kwargs) -> None:
        # Identity only. The worker hears about this session on the first real write.
        self._session = f"{_PROJECT}-{session_id or uuid.uuid4().hex[:12]}"
        self._written = False

    # ---- breaker ----------------------------------------------------------
    def _breaker_open(self) -> bool:
        return self._failures >= 3 and (time.time() - self._opened_at) < 120

    def _ok(self) -> None:
        self._failures = 0

    def _fail(self) -> None:
        self._failures += 1
        if self._failures == 3:
            self._opened_at = time.time()
            logger.warning("cmem: breaker opened after 3 failures")

    # ---- recall / remember ------------------------------------------------
    def _recall(self, query: str, top_k: int = 5) -> List[str]:
        if self._breaker_open():
            return []
        tok = _token()
        try:
            if tok:
                r = _post(_MCP, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                 "params": {"name": "memory_search", "arguments": {"query": query, "limit": top_k}}},
                          headers={"Authorization": f"Bearer {tok}", "Accept": "application/json, text/event-stream"})
                texts = [c.get("text", "") for c in r.get("result", {}).get("content", []) if c.get("type") == "text"]
                if texts:
                    self._ok(); return texts
            req = urllib.request.Request(f"{_LOCAL}/api/search?query={urllib.parse.quote(query)}&limit={top_k}")
            with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:
                r = json.loads(resp.read().decode())
            self._ok()
            return [c.get("text", "") for c in r.get("content", []) if c.get("type") == "text"]
        except Exception as e:
            self._fail(); logger.warning("cmem: recall failed: %s", e); return []

    def _write(self, text: str) -> None:
        _post(f"{_LOCAL}/api/sessions/init", {"contentSessionId": self._session, "project": _PROJECT,
                                              "prompt": text, "platformSource": "hermes"})
        self._written = True

    def _remember(self, content: str, category: str = "user") -> None:
        try:
            self._write(f"[{category}] {content}" if category and category != "user" else content)
            self._ok()
        except Exception as e:
            self._fail(); logger.warning("cmem: remember failed: %s", e); raise

    # ---- prompt integration -----------------------------------------------
    def system_prompt_block(self) -> str:
        return ("Durable memory is cmem. Use cmem_search to recall facts across every "
                "agent and machine, and cmem_remember to store a durable fact. Never store secret values.")

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        def run():
            hits = self._recall(query, top_k=5)
            with self._lock:
                self._prefetched[session_id or "default"] = "\n---\n".join(h for h in hits if h)
        threading.Thread(target=run, daemon=True).start()

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        with self._lock:
            got = self._prefetched.pop(session_id or "default", None)
        if got is None:
            got = "\n---\n".join(h for h in self._recall(query, top_k=5) if h)
        return got

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        return [
            {"name": "cmem_search", "description": "Recall durable memory across all agents and machines.",
             "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "top_k": {"type": "integer"}}, "required": ["query"]}},
            {"name": "cmem_remember", "description": "Store a durable fact (locations of secrets, never values).",
             "parameters": {"type": "object", "properties": {"content": {"type": "string"}, "category": {"type": "string", "enum": ["user", "project", "agent", "tmn", "r2h", "src"]}}, "required": ["content"]}},
        ]

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        try:
            if tool_name == "cmem_search":
                hits = self._recall(str(args.get("query", "")), int(args.get("top_k", 5) or 5))
                return "\n---\n".join(hits) if hits else "No memories matched."
            if tool_name == "cmem_remember":
                self._remember(str(args.get("content", "")), str(args.get("category", "user")))
                return "Stored (durable queue; syncs to cmem.ai)."
        except Exception as e:
            return json.dumps({"error": str(e)})
        return json.dumps({"error": f"unknown tool {tool_name}"})

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        users = [str(m.get("content", "")) for m in messages if m.get("role") == "user"]
        if not self._written and len(users) < 2:
            return  # a one-shot `hermes -z` run: nothing worth a session on the hub
        last_user = users[-1] if users else ""
        last_asst = next((m.get("content", "") for m in reversed(messages) if m.get("role") == "assistant"), "")
        try:
            if not self._written:
                self._write(users[0][:4000])
            _post(f"{_LOCAL}/api/sessions/summarize", {"contentSessionId": self._session, "platformSource": "hermes",
                                                       "last_user_message": str(last_user)[:4000], "last_assistant_message": str(last_asst)[:4000]})
        except Exception as e:
            logger.warning("cmem: summarize failed: %s", e)

    def shutdown(self) -> None:
        pass
