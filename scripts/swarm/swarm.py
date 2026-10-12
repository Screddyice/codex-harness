#!/usr/bin/env python3
"""swarm CLI — fan bounded tasks out to Codex workers in git worktrees.

Exit codes for `run` (eng review D11): 0 every task completed, 2 partial,
3 none completed, 1 preflight/usage error. `status` and `clean` exit 0/1.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from swarmlib import engine  # noqa: E402
from swarmlib.engine import SwarmEngine, SwarmError, load_tasks  # noqa: E402
from swarmlib.manifest import swarm_home  # noqa: E402


def cmd_run(args):
    try:
        raw = json.loads(Path(args.tasks).read_text(encoding="utf-8"))
        tasks = load_tasks(raw, args.via)
    except (OSError, json.JSONDecodeError) as exc:
        sys.exit(f"error: cannot read tasks file: {exc}")
    except SwarmError as exc:
        sys.exit(f"error: {exc}")
    eng = SwarmEngine(
        args.workspace, tasks,
        max_parallel=args.max_parallel, max_total=args.max_total,
        fallback=args.fallback, allow_dirty=args.allow_dirty,
        timeout=args.task_timeout,
        echo=(lambda *_: None) if args.json else print,
    )
    try:
        code, report = eng.run()
    except SwarmError as exc:
        sys.exit(f"error: {exc}")
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        counts = report["counts"]
        print(f"\nrun {report['run_id']}: "
              + ", ".join(f"{v} {k}" for k, v in counts.items() if v))
        print(f"manifest: {swarm_home() / (report['run_id'] + '.json')}")
        print("next: review each branch diff, `git merge --squash` the ones you "
              f"accept, then `swarm clean {report['run_id']}`")
    sys.exit(code)


def cmd_status(args):
    try:
        view = engine.status(args.run_id)
    except FileNotFoundError as exc:
        sys.exit(f"error: {exc}")
    if args.json:
        print(json.dumps(view, indent=2))
    else:
        print(f"run {view['run_id']} [{view['status']}] base {view['base_sha'][:8]}")
        for task in view["tasks"]:
            git = task["git"]
            notes = []
            if task.get("branch") and not git["branch_exists"]:
                notes.append("branch MISSING")
            if git["worktree_dirty"]:
                notes.append("worktree dirty (uncommitted)")
            if git["ahead"]:
                notes.append(f"{git['ahead']} commit(s) ahead")
            print(f"  {task['id']:<20} {task['status']:<22} via {task['via']:<7} "
                  + (task.get("branch") or "-")
                  + (f"  [{'; '.join(notes)}]" if notes else ""))
    sys.exit(0)


def cmd_clean(args):
    try:
        cleaned, refused = engine.clean(args.run_id, force=args.force)
    except FileNotFoundError as exc:
        sys.exit(f"error: {exc}")
    for line in refused:
        print(f"refused: {line}", file=sys.stderr)
    if refused:
        print("fold the work in first (git merge --squash <branch>) or pass --force "
              "to discard it", file=sys.stderr)
    print(f"cleaned: {', '.join(cleaned) if cleaned else '(nothing)'}")
    sys.exit(1 if refused else 0)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="swarm",
        description="Dispatch bounded tasks to headless Codex workers, "
                    "each in an isolated git worktree. Workers edit; the engine "
                    "commits; you review and fold.")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="fan tasks out and wait for the fleet")
    run.add_argument("--workspace", default=".", help="git repo to work in (default: .)")
    run.add_argument("--tasks", required=True, help="tasks.json path")
    run.add_argument("--via", default="codex", choices=("codex",),
                     help="default provider for tasks without one (default: codex)")
    run.add_argument("--max-parallel", type=int, default=3,
                     help="max concurrent workers per provider (default: 3)")
    run.add_argument("--max-total", type=int, default=4,
                     help="max concurrent workers across ALL providers (default: 4)")
    run.add_argument("--fallback", action="store_true",
                     help="retain the manifest field; no alternate provider is used")
    run.add_argument("--allow-dirty", action="store_true",
                     help="run despite uncommitted tracked changes (workers will not see them)")
    run.add_argument("--task-timeout", type=int, default=1800,
                     help="per-worker timeout in seconds (default: 1800)")
    run.add_argument("--json", action="store_true", help="machine-readable report")
    run.set_defaults(func=cmd_run)

    st = sub.add_parser("status", help="show a run's manifest reconciled against git")
    st.add_argument("run_id")
    st.add_argument("--json", action="store_true")
    st.set_defaults(func=cmd_status)

    cl = sub.add_parser("clean", help="remove a run's worktrees and scratch branches")
    cl.add_argument("run_id")
    cl.add_argument("--force", action="store_true",
                    help="also discard unfolded or uncommitted work")
    cl.set_defaults(func=cmd_clean)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
