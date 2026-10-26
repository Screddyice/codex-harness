#!/usr/bin/env python3
"""Fixture tests: no user config, model request, or worker is modified."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import shutil
import subprocess
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "capture", Path(__file__).with_name("configure-claudemem-capture.py"))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CapturePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.settings = self.root / "data" / "settings.json"
        self.settings.parent.mkdir()
        self.original_settings = {"secret": "fixture-only", "unrelated": {"keep": True}}
        self.settings.write_text(json.dumps(self.original_settings))
        self.plugin = self.root / "plugin"
        self.bundle = self.plugin / "scripts" / "worker-service.cjs"
        self.bundle.parent.mkdir(parents=True)
        self.original_bundle = (capture.OLD_FILTER + ";" + capture.OLD_HOOK).encode()
        self.patched_bundle = (capture.NEW_FILTER + ";" + capture.NEW_HOOK).encode()
        self.bundle.write_bytes(self.original_bundle)
        self.addCleanup(patch.stopall)
        patch.object(capture, "DEFAULT_SETTINGS", self.settings).start()
        patch.dict(os.environ, {"PATH": os.environ.get("PATH", "")}, clear=True).start()
        patch.object(capture, "ORIGINAL_SHA", capture.sha(self.original_bundle)).start()
        patch.object(capture, "PATCHED_SHA", capture.sha(self.patched_bundle)).start()

    def configure(self, apply=False, roots=None):
        return capture.configure(self.settings, roots or [self.plugin], apply=apply)

    def test_check_is_read_only(self):
        before = self.settings.read_bytes(), self.bundle.read_bytes()
        result = self.configure()
        self.assertEqual(result["status"], "changes_required")
        self.assertEqual(before, (self.settings.read_bytes(), self.bundle.read_bytes()))
        self.assertFalse((self.settings.parent / "backups").exists())

    def test_apply_preserves_unrelated_settings_and_has_private_backups(self):
        result = self.configure(apply=True)
        saved = json.loads(self.settings.read_text())
        self.assertEqual(saved["secret"], "fixture-only")
        self.assertEqual(saved["unrelated"], {"keep": True})
        self.assertEqual(saved["CLAUDE_MEM_SKIP_TOOLS"], "*")
        self.assertEqual(saved["CLAUDE_MEM_MAX_CONCURRENT_AGENTS"], "6")
        self.assertEqual(saved["CLAUDE_MEM_CODEX_MAX_CONCURRENT_AGENTS"], "6")
        self.assertEqual(self.bundle.read_bytes(), self.patched_bundle)
        backup = Path(result["backup_dir"])
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in backup.iterdir()))
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("fixture-only", json.dumps(result))

    def test_apply_is_idempotent_even_if_worker_is_running(self):
        self.configure(apply=True)
        before = self.settings.stat().st_mtime_ns, self.bundle.stat().st_mtime_ns
        (self.settings.parent / "worker.pid").write_text(json.dumps({"pid": os.getpid()}))
        self.assertEqual(self.configure(apply=True)["status"], "ready")
        self.assertEqual(before, (self.settings.stat().st_mtime_ns, self.bundle.stat().st_mtime_ns))

    def test_live_worker_blocks_changes(self):
        (self.settings.parent / "worker.pid").write_text(json.dumps({"pid": os.getpid()}))
        before = self.settings.read_bytes(), self.bundle.read_bytes()
        with self.assertRaisesRegex(ValueError, "worker.*running"):
            self.configure(apply=True)
        self.assertEqual(before, (self.settings.read_bytes(), self.bundle.read_bytes()))

    def test_unknown_build_rejects_entire_multi_root_apply(self):
        other = self.root / "other" / "scripts"
        other.mkdir(parents=True)
        (other / "worker-service.cjs").write_bytes(b"unknown build")
        before = self.settings.read_bytes(), self.bundle.read_bytes()
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            self.configure(apply=True, roots=[self.plugin, other.parent])
        self.assertEqual(before, (self.settings.read_bytes(), self.bundle.read_bytes()))

    def test_malformed_settings_are_not_overwritten(self):
        self.settings.write_text("not json")
        with self.assertRaises(ValueError):
            self.configure(apply=True)
        self.assertEqual(self.settings.read_text(), "not json")

    def test_invalid_pid_file_refuses_changes(self):
        (self.settings.parent / "worker.pid").write_text('{"pid":true}')
        with self.assertRaisesRegex(ValueError, "Invalid worker PID"):
            self.configure(apply=True)
        self.assertEqual(self.bundle.read_bytes(), self.original_bundle)

    def test_custom_data_directory_requires_effective_settings_and_checks_pid(self):
        custom = self.root / "custom"
        custom.mkdir()
        effective = custom / "settings.json"
        effective.write_text('{}')
        self.settings.write_text(json.dumps({"CLAUDE_MEM_DATA_DIR": str(custom)}))
        (custom / "worker.pid").write_text(json.dumps({"pid": os.getpid()}))
        with self.assertRaisesRegex(ValueError, "effective settings"):
            self.configure(apply=True)
        with self.assertRaisesRegex(ValueError, "worker.*running"):
            capture.configure(effective, [self.plugin], apply=True)
        self.assertEqual(self.bundle.read_bytes(), self.original_bundle)

    def test_environment_data_directory_takes_precedence(self):
        custom = self.root / "environment"
        custom.mkdir()
        effective = custom / "settings.json"
        effective.write_text('{}')
        with patch.dict(os.environ, {"CLAUDE_MEM_DATA_DIR": str(custom)}):
            with self.assertRaisesRegex(ValueError, "effective settings"):
                self.configure(apply=True)
            self.assertEqual(capture.configure(effective, [self.plugin])["status"], "changes_required")

    def test_conflicting_environment_cannot_report_ready_or_apply(self):
        self.configure(apply=True)
        before = self.settings.read_bytes(), self.bundle.read_bytes()
        with patch.dict(os.environ, {"CLAUDE_MEM_SKIP_TOOLS": "Read"}):
            for apply in [False, True]:
                with self.assertRaisesRegex(ValueError, "CLAUDE_MEM_SKIP_TOOLS"):
                    self.configure(apply=apply)
        self.assertEqual(before, (self.settings.read_bytes(), self.bundle.read_bytes()))

    def test_matching_environment_is_allowed(self):
        with patch.dict(os.environ, capture.UPDATES):
            self.configure(apply=True)
            self.assertEqual(self.configure()["status"], "ready")

    def test_edit_at_replacement_boundary_is_preserved(self):
        rename = os.rename

        def edit_before_detach(source, destination):
            if source == self.settings:
                self.settings.write_text('{"concurrent":true}')
            return rename(source, destination)

        with patch.object(capture.os, "rename", side_effect=edit_before_detach):
            with self.assertRaisesRegex(OSError, "changed during"):
                self.configure(apply=True)
        self.assertEqual(json.loads(self.settings.read_text()), {"concurrent": True})
        self.assertEqual(self.bundle.read_bytes(), self.original_bundle)

    def test_new_destination_during_detach_is_not_overwritten(self):
        link = os.link

        def competing_create(source, destination):
            if destination == self.settings and not destination.exists():
                destination.write_text('{"concurrent":true}')
            return link(source, destination)

        with patch.object(capture.os, "link", side_effect=competing_create):
            with self.assertRaisesRegex(OSError, "[Rr]ecovery"):
                self.configure(apply=True)
        self.assertEqual(json.loads(self.settings.read_text()), {"concurrent": True})
        self.assertTrue(list(self.settings.parent.glob('.capture-original-*')))
        self.assertEqual(self.bundle.read_bytes(), self.original_bundle)

    def test_rollback_continues_when_a_changed_file_disappears(self):
        other = self.root / "other" / "scripts"
        other.mkdir(parents=True)
        second = other / "worker-service.cjs"
        second.write_bytes(self.original_bundle)
        replace = capture.atomic_replace

        def remove_after_write(path, data, mode, expected):
            replace(path, data, mode, expected)
            if path == second:
                path.unlink()

        with patch.object(capture, "atomic_replace", side_effect=remove_after_write):
            with self.assertRaisesRegex(OSError, "[Rr]ollback"):
                self.configure(apply=True, roots=[self.plugin, other.parent])
        self.assertEqual(self.bundle.read_bytes(), self.original_bundle)
        self.assertEqual(json.loads(self.settings.read_text()), self.original_settings)

    @unittest.skipUnless(shutil.which("node"), "Node.js is needed for runtime expression checks")
    def test_runtime_gate_blocks_future_tools_but_preserves_summaries(self):
        # Exercise the exact expressions installed into the checksum-pinned bundle.
        script = r'''
const assert = require('node:assert/strict');
const [filter, hook] = JSON.parse(process.argv[1]);
const excluded = new Function('u', 't', 'return (' + filter + ');');
for (const name of ['unknown_future_connector', 'Read', 'email_send', 'merge_pull_request']) {
  assert.equal(excluded({CLAUDE_MEM_SKIP_TOOLS:'*'}, {toolName:name}), true);
}
assert.equal(excluded({CLAUDE_MEM_SKIP_TOOLS:'Read'}, {toolName:'Write'}), false);
const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
const execute = new AsyncFunction('i','r','e','t','d8','GS','V','ce','rw','$f', hook + 'return o;');
(async () => {
  let calls = 0;
  const observation = {execute: async () => {calls++; return {};}};
  const fileEdit = {execute: observation.execute};
  const summary = {execute: observation.execute};
  for (const handler of [observation, fileEdit, summary]) {
    await execute({}, 'test', handler, {}, observation, fileEdit,
      {loadFromFile:()=>({CLAUDE_MEM_SKIP_TOOLS:'*'})}, '', ()=>({}), ()=>{});
  }
  assert.equal(calls, 1, 'only the summary handler executes');
})().catch(error => {console.error(error); process.exitCode=1;});
'''
        subprocess.run([shutil.which("node"), "-e", script,
                        json.dumps([capture.NEW_FILTER, capture.NEW_HOOK])], check=True)

    def test_failed_write_rolls_back_prior_bundle_change(self):
        before = self.settings.read_bytes(), self.bundle.read_bytes()
        replace = capture.atomic_replace

        def fail_settings_once(path, data, mode, expected):
            if path == self.settings and data != before[0]:
                raise OSError("fixture write failure")
            return replace(path, data, mode, expected)

        with patch.object(capture, "atomic_replace", side_effect=fail_settings_once):
            with self.assertRaisesRegex(OSError, "fixture write failure"):
                self.configure(apply=True)
        self.assertEqual(before, (self.settings.read_bytes(), self.bundle.read_bytes()))

    def test_does_not_clobber_concurrent_settings_change(self):
        original = capture.atomic_replace

        def concurrent_change(path, data, mode, expected):
            original(path, data, mode, expected)
            if path == self.bundle:
                self.settings.write_text('{"concurrent":true}')

        with patch.object(capture, "atomic_replace", side_effect=concurrent_change):
            with self.assertRaisesRegex(ValueError, "changed during"):
                self.configure(apply=True)
        self.assertEqual(json.loads(self.settings.read_text()), {"concurrent": True})
        self.assertEqual(self.bundle.read_bytes(), self.original_bundle)


if __name__ == "__main__":
    unittest.main()
