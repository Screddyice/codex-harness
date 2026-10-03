#!/usr/bin/env bash
# Manual live smoke for swarm — REAL Codex CLI.
#
# Verifies what the mocked suite structurally cannot: headless acceptEdits +
# allowedTools behavior, OAuth account selection, and the engine-commit flow
# against real worker output. Run once before first real use and after any
# CLI major upgrade. Never wired into CI.
#
# Usage: scripts/swarm/smoke_live.sh

set -eu

here="$(cd "$(dirname "$0")" && pwd)"

for cli in codex git python3; do
  command -v "$cli" >/dev/null 2>&1 || { echo "missing: $cli" >&2; exit 1; }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/swarm-smoke-XXXXXX")"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
export SWARM_HOME="$work/swarm-home"

git init -q -b main "$repo"
git -C "$repo" config user.email smoke@swarm
git -C "$repo" config user.name "Swarm Smoke"
echo "smoke repo" > "$repo/README.md"
git -C "$repo" add -A && git -C "$repo" commit -q -m "init"

cat > "$work/tasks.json" <<'EOF'
{
  "tasks": [
    {"id": "hello-codex", "via": "codex", "files": ["HELLO_CODEX.txt"],
     "task": "Create a file named HELLO_CODEX.txt containing exactly the single line: hello from codex"},
    {"id": "hello-codex-2", "via": "codex", "files": ["HELLO_CODEX_2.txt"],
     "task": "Create a file named HELLO_CODEX_2.txt containing exactly the single line: hello from codex"}
  ]
}
EOF

echo "== swarm run (2 real Codex workers) =="
set +e
python3 "$here/swarm.py" run --workspace "$repo" --tasks "$work/tasks.json" \
  --max-total 2 --task-timeout 600 --json > "$work/report.json"
code=$?
set -e
echo "exit code: $code (0=all, 2=partial, 3=none)"
python3 - "$work/report.json" <<'EOF'
import json, sys
report = json.load(open(sys.argv[1]))
for t in report["tasks"]:
    print(f"  {t['id']}: {t['status']}  branch={t['branch']}  files={t['changed_files']}")
    if t["status"] == "completed" and not t["changed_files"]:
        sys.exit(f"FAIL: {t['id']} completed but changed nothing")
run = report["run_id"]
open(sys.argv[1] + ".runid", "w").write(run)
EOF
run_id="$(cat "$work/report.json.runid")"

echo "== swarm status =="
python3 "$here/swarm.py" status "$run_id"

echo "== verify worker output on branches =="
for branch_file in "swarm/$run_id/hello-codex:HELLO_CODEX.txt" \
                   "swarm/$run_id/hello-codex-2:HELLO_CODEX_2.txt"; do
  branch="${branch_file%%:*}"; file="${branch_file##*:}"
  if git -C "$repo" rev-parse --verify -q "$branch" >/dev/null; then
    git -C "$repo" show "$branch:$file" | sed "s|^|  [$branch] |" || true
  else
    echo "  [$branch] MISSING (task did not complete)"
  fi
done

echo "== swarm clean --force =="
python3 "$here/swarm.py" clean "$run_id" --force

if [ "$code" -eq 0 ]; then
  echo "SMOKE PASS: both Codex workers completed end-to-end"
else
  echo "SMOKE PARTIAL/FAIL (exit $code) — read the statuses above; a" \
       "the statuses above explain the incomplete task"
fi
exit "$code"
