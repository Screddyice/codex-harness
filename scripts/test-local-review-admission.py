#!/usr/bin/env python3
"""Exercise the shell reviewer against a local fake HTTP service, never a model."""
import json
import fcntl
import time
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOOK = Path(__file__).resolve().parent / "hooks/local-diff-review.sh"


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email", "test@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name", "Test"], check=True)
        (self.repo / "a").write_text("before\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "a"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "fixture"], check=True)
        (self.repo / "a").write_text("after\n")
        self.posts = []
        posts = self.posts
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"models": []}')
            def do_POST(self):
                posts.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"message": {"content": "LGTM"}}')
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.guard = self.root / "guard"
        self.env = dict(os.environ, LOCAL_REVIEW="1", LOCAL_REVIEW_CACHE_DIR=str(self.root / "cache"),
                        LOCAL_REVIEW_OLLAMA_URL=f"http://127.0.0.1:{self.server.server_port}",
                        LOCAL_REVIEW_PREFLIGHT=str(self.guard), LOCAL_REVIEW_DUMP_PROMPT="0")
        self.env["LLMJURY_LOCAL_LOCK"] = str(self.root / "compute.lock")

    def guard_result(self, result):
        self.guard.write_text("#!/bin/sh\n[ \"$1\" = preflight ] || exit 9\n"
                              "[ \"$2\" = --models ] || exit 9\n"
                              f"exit {result}\n")
        self.guard.chmod(0o700)

    def run_hook(self):
        result = subprocess.run([str(HOOK)], cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_blocked_review_never_requests_inference_or_consumes_diff(self):
        self.guard_result(1)
        self.run_hook()
        self.assertEqual(self.posts, [])
        self.assertEqual(list((self.root / "cache").glob("*.last")), [])

    def test_missing_guard_fails_closed(self):
        self.run_hook()
        self.assertEqual(self.posts, [])

    def test_shared_compute_lock_blocks_review_without_consuming_diff(self):
        self.guard_result(0)
        with open(self.env["LLMJURY_LOCAL_LOCK"], "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_hook()
            self.assertEqual(self.posts, [])
        self.run_hook()
        self.assertEqual(len(self.posts), 1)

    def test_cooldown_defers_changed_diff_then_retries_after_expiration(self):
        self.guard_result(0)
        self.run_hook()
        (self.repo / "a").write_text("another edit\n")
        self.run_hook()
        self.assertEqual(len(self.posts), 1)
        stamp = next((self.root / "cache").glob("*.last"))
        stamp.write_text(str(int(time.time()) - 100))
        self.env["LOCAL_REVIEW_COOLDOWN_SECONDS"] = "10"
        self.run_hook()
        self.assertEqual(len(self.posts), 2)

    def test_corrupt_cooldown_does_not_block_changed_diff(self):
        self.guard_result(0)
        self.run_hook()
        (self.repo / "a").write_text("another edit\n")
        next((self.root / "cache").glob("*.last")).write_text("invalid")
        self.run_hook()
        self.assertEqual(len(self.posts), 2)

    def test_same_diff_is_retried_after_pressure_clears(self):
        self.guard_result(1)
        self.run_hook()
        self.guard_result(0)
        self.run_hook()
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.posts[0]["options"]["num_ctx"], 24576)
        self.assertEqual(self.posts[0]["keep_alive"], "30s")
        self.run_hook()
        self.assertEqual(len(self.posts), 1)


if __name__ == "__main__":
    unittest.main()
