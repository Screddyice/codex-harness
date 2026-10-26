#!/usr/bin/env python3
"""Opt-in, version-checked ClaudeMem summaries-and-explicit-notes policy."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

DEFAULT_SETTINGS = Path.home() / ".claude-mem" / "settings.json"
ORIGINAL_SHA = "0269d1c20c16215cf56989cca42a9dda1773438737391dcaa9dced2c8d45d582"
PATCHED_SHA = "4ed29a4575de6e509c195cd8ee9f249c29dd3a59506c97284a02c64dc3e610ab"
OLD_FILTER = 'new Set(u.CLAUDE_MEM_SKIP_TOOLS.split(",").map(C=>C.trim().toLowerCase()).filter(Boolean)).has(t.toolName.toLowerCase())'
NEW_FILTER = 'u.CLAUDE_MEM_SKIP_TOOLS.split(",").some(C=>[t.toolName.toLowerCase(),"*"].includes(C.trim().toLowerCase()))'.ljust(len(OLD_FILTER))
OLD_HOOK = 'i.platform=r;let o=await e.execute(i);$f(t,o);'
NEW_HOOK = 'i.platform=r;let o=(e===d8||e===GS)&&V.loadFromFile(ce).CLAUDE_MEM_SKIP_TOOLS.split(",").some(a=>a.trim()==="*")?rw("observation"):await e.execute(i);$f(t,o);'
UPDATES = {
    "CLAUDE_MEM_SKIP_TOOLS": "*",
    "CLAUDE_MEM_SKIP_SUBAGENT_OBSERVATIONS": "true",
    "CLAUDE_MEM_CAPTURE_ADVISOR_CALLS": "false",
    "CLAUDE_MEM_MAX_CONCURRENT_AGENTS": "6",
    "CLAUDE_MEM_CODEX_MAX_CONCURRENT_AGENTS": "6",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def patch_bundle(data):
    digest = sha(data)
    if digest == PATCHED_SHA:
        return data
    if digest != ORIGINAL_SHA:
        raise ValueError("Unsupported ClaudeMem build; review compatibility before applying")
    source = data.decode("utf-8")
    if source.count(OLD_FILTER) != 1 or source.count(OLD_HOOK) != 1:
        raise ValueError("Unsupported ClaudeMem capture layout")
    result = source.replace(OLD_FILTER, NEW_FILTER).replace(OLD_HOOK, NEW_HOOK).encode()
    if sha(result) != PATCHED_SHA:
        raise ValueError("Patched bundle checksum does not match the reviewed build")
    return result


def validate_effective_settings(settings):
    # Match the pinned worker's environment -> default settings -> default dir lookup.
    data_dir = os.environ.get("CLAUDE_MEM_DATA_DIR")
    if not data_dir and DEFAULT_SETTINGS.exists():
        bootstrap = json.loads(DEFAULT_SETTINGS.read_bytes())
        if not isinstance(bootstrap, dict):
            raise ValueError("Default settings must be a JSON object")
        bootstrap = bootstrap.get("env", bootstrap)
        if not isinstance(bootstrap, dict):
            raise ValueError("Default settings env must be a JSON object")
        data_dir = bootstrap.get("CLAUDE_MEM_DATA_DIR")
        if data_dir is not None and not isinstance(data_dir, str):
            raise ValueError("Invalid default data directory")
    directory = Path(data_dir).expanduser() if data_dir else DEFAULT_SETTINGS.parent
    effective = (directory / "settings.json").resolve()
    if settings != effective:
        raise ValueError(f"Name the effective settings file: {effective}")


def worker_running(settings):
    pid_file = settings.parent / "worker.pid"
    if not pid_file.exists():
        return False
    pid = json.loads(pid_file.read_text())["pid"]
    if isinstance(pid, bool) or not isinstance(pid, int) or pid < 1:
        raise ValueError("Invalid worker PID file; inspect worker state before applying")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def atomic_replace(path, data, mode, expected):
    """Publish without clobbering a concurrent path writer; retain conflicted originals."""
    descriptor, temporary = tempfile.mkstemp(prefix=".capture-", dir=path.parent)
    holding = None
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        descriptor, name = tempfile.mkstemp(prefix=".capture-original-", dir=path.parent)
        os.close(descriptor)
        holding = Path(name)
        holding.unlink()
        os.rename(path, holding)
        try:
            if holding.read_bytes() != expected:
                raise ValueError("Configuration changed during apply; refusing to overwrite it")
            # link creates exclusively, so an intervening new destination survives.
            os.link(temporary, path)
        except BaseException as error:
            try:
                os.link(holding, path)
            except OSError as restore_error:
                raise OSError(f"Original retained for recovery at {holding}; {restore_error}") from error
            holding.unlink()
            holding = None
            raise
        holding.unlink()
        holding = None
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure(settings, plugin_roots, apply=False):
    conflicts = [key for key, value in UPDATES.items()
                 if key in os.environ and os.environ[key] != value]
    if conflicts:
        raise ValueError("Conflicting environment overrides: " + ", ".join(conflicts))
    settings = Path(settings).expanduser().resolve(strict=True)
    validate_effective_settings(settings)
    original_settings = settings.read_bytes()
    values = json.loads(original_settings)
    if not isinstance(values, dict):
        raise ValueError("Settings must be a JSON object")
    # Do not silently flatten upstream's alternate nested settings representation.
    if "env" in values:
        raise ValueError("Nested settings are unsupported; migrate with ClaudeMem first")
    roots = list(dict.fromkeys(Path(p).expanduser().resolve(strict=True) for p in plugin_roots))
    if not roots:
        raise ValueError("Name at least one installed plugin root")
    planned = []
    bundle_changes = 0
    for root in roots:
        path = (root / "scripts" / "worker-service.cjs").resolve(strict=True)
        if not path.is_relative_to(root):
            raise ValueError("Worker bundle escapes the named plugin root")
        before = path.read_bytes()
        after = patch_bundle(before)
        if after != before:
            bundle_changes += 1
            planned.append((path, before, after, path.stat().st_mode & 0o777))
    changed_keys = [key for key, value in UPDATES.items() if values.get(key) != value]
    updated = {**values, **UPDATES}
    if changed_keys:
        planned.append((settings, original_settings,
                        (json.dumps(updated, indent=2) + "\n").encode(), 0o600))
    report = {"status": "changes_required" if planned else "ready",
              "plugin_roots": len(roots), "bundle_changes": bundle_changes,
              "settings_changes": changed_keys, "worker_restarted": False}
    if not apply or not planned:
        return report
    if worker_running(settings):
        raise ValueError("ClaudeMem worker is running; drain its queue and stop it before applying")
    backup_parent = settings.parent / "backups"
    backup_parent.mkdir(mode=0o700, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix="summary-capture-", dir=backup_parent))
    applied = []
    for index, (_, before, _, _) in enumerate(planned):
        with os.fdopen(os.open(backup / f"{index}.backup", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "wb") as output:
            output.write(before)
    try:
        for path, before, after, mode in planned:
            if path.read_bytes() != before:
                raise ValueError("Configuration changed during apply; refusing to overwrite it")
            applied.append((path, before, after, mode))
            atomic_replace(path, after, mode, before)
            if path.read_bytes() != after:
                raise OSError("Readback did not match the applied capture policy")
    except BaseException as error:
        failures = []
        for path, before, after, mode in reversed(applied):
            try:
                current = path.read_bytes()
                if current == before:
                    continue
                if current != after:
                    raise ValueError("File changed after apply; leaving current contents intact")
                atomic_replace(path, before, mode, after)
            except (OSError, ValueError) as rollback_error:
                failures.append(f"{path}: {rollback_error}")
        if failures:
            raise OSError(f"{error}; rollback incomplete; backups at {backup}: " + "; ".join(failures)) from error
        raise
    report.update(status="applied", backup_dir=str(backup))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "apply"])
    parser.add_argument("--settings", type=Path, required=True, help="Existing ClaudeMem settings file")
    parser.add_argument("--plugin-root", type=Path, required=True, action="append",
                        help="Installed plugin root; repeat for every active profile")
    args = parser.parse_args()
    try:
        report = configure(args.settings, args.plugin_root, apply=args.command == "apply")
    except (OSError, ValueError, KeyError) as error:
        print(json.dumps({"status": "error", "message": str(error)}))
        return 1
    print(json.dumps(report))
    return 1 if report["status"] == "changes_required" else 0


if __name__ == "__main__":
    raise SystemExit(main())
