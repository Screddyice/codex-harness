#!/usr/bin/env bash

# Shared local-model reviewer. Codex consumes the exit status and plain-text
# findings through the Codex Stop hook.

set -u

[ "${LOCAL_REVIEW:-1}" = "1" ] || exit 0
# Small model by default (2026-07-31). gemma3:12b meant a 13 GB load onto the GPU
# on every Stop with a changed diff.
#
# The "~3 GB" this comment used to claim for qwen3.5:4b was the weights only, and
# that was wrong in the expensive direction: Ollama sizes KV as num_ctx x
# OLLAMA_NUM_PARALLEL, so at 24576 ctx the tag measured 7.5 GB resident with
# `ollama ps`. Combined with a council on the same server that over-committed a
# 36 GB host and panicked it twice. Use the plain tag rather than -64k (same model
# ID, and num_ctx below is explicit anyway) so a dropped num_ctx cannot silently
# fall back to a 64k default. Set LOCAL_REVIEW_MODEL to override.
model="${LOCAL_REVIEW_MODEL:-qwen3.5:4b}"
ollama="${LOCAL_REVIEW_OLLAMA_URL:-http://127.0.0.1:11434}"
max_diff_bytes="${LOCAL_REVIEW_MAX_DIFF_BYTES:-60000}"
cache_dir="${LOCAL_REVIEW_CACHE_DIR:-$HOME/.cache/local-diff-review}"
# Minimum gap between reviews of the same repo. Collapses a burst of rapid turns
# into one review over the accumulated diff instead of one per turn.
cooldown="${LOCAL_REVIEW_COOLDOWN_SECONDS:-1200}"
# How long Ollama keeps the model resident after a review. Deliberately short: with
# a 20 minute cooldown the next review is far away, so lingering only holds GB that
# a council or another session needs. Trades a few seconds of reload for ~6 GB back.
keep_alive="${LOCAL_REVIEW_KEEP_ALIVE:-30s}"
preflight="${LOCAL_REVIEW_PREFLIGHT:-llmjury}"
if [ "$preflight" = llmjury ] && ! command -v llmjury >/dev/null 2>&1; then
  preflight="$HOME/.local/bin/llmjury"
fi

top="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
origin="$(git -C "$top" remote get-url origin 2>/dev/null || true)"
case "$(printf %s "$origin" | tr '[:upper:]' '[:lower:]')" in
  *rs21*) exit 0 ;;
esac

base="$(git -C "$top" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||')"
[ -n "$base" ] || base="origin/main"
merge_base="$(git -C "$top" merge-base HEAD "$base" 2>/dev/null || true)"
excludes=(':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.min.*'
          ':(exclude)dist/*' ':(exclude)build/*' ':(exclude)node_modules/*')
if [ -n "$merge_base" ]; then
  diff="$(git -C "$top" diff "$merge_base" -- . "${excludes[@]}" 2>/dev/null)"
else
  diff="$(git -C "$top" diff HEAD -- . "${excludes[@]}" 2>/dev/null)"
fi
[ -n "$diff" ] || exit 0
[ "${#diff}" -le "$max_diff_bytes" ] || exit 0

mkdir -p "$cache_dir"
repo_key="$(printf %s "$top" | shasum -a 256 | cut -c1-16)"
diff_hash="$(printf %s "$diff" | shasum -a 256 | cut -c1-16)"
marker="$cache_dir/$repo_key"
stamp="$cache_dir/$repo_key.last"
[ "$(cat "$marker" 2>/dev/null)" = "$diff_hash" ] && exit 0

# Cooldown. Checked BEFORE the diff-hash marker is stamped: stamping on a skip
# would mark this diff "already reviewed", so an unchanged diff would never get
# reviewed once the cooldown expired.
now="$(date +%s)"
last="$(cat "$stamp" 2>/dev/null || true)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ "$(( now - last ))" -lt "$cooldown" ] && exit 0

# LOCAL_REVIEW_DUMP_PROMPT prints the assembled system prompt and stops before
# any inference, so the memory wiring can be checked without loading a model onto
# a host that may already be holding one.
[ "${LOCAL_REVIEW_DUMP_PROMPT:-0}" = "1" ] || curl -sf -m 5 "$ollama/api/tags" >/dev/null 2>&1 || exit 0

if [ -n "${CODEX_LOCAL_REVIEWER:-}" ]; then
  set +e
  review="$("$CODEX_LOCAL_REVIEWER" 2>&1)"
  reviewer_status=$?
  set -e
  [ "$reviewer_status" -eq 2 ] || exit 0
else
review="$(DIFF="$diff" MODEL="$model" OLLAMA="$ollama" KEEP_ALIVE="$keep_alive" \
  REVIEW_PREFLIGHT="$preflight" \
  DUMP_PROMPT="${LOCAL_REVIEW_DUMP_PROMPT:-0}" python3 - <<'PY' 2>/dev/null
import fcntl
import json
import os
import subprocess
import urllib.request


system = (
    "You are a strict code reviewer. Review this git diff and report ONLY "
    "definite defects: logic errors, broken behavior, security problems, "
    "data loss, crashes. Ignore style, naming, formatting, comments, and "
    "hypothetical concerns. For each defect give file, line context, and a "
    "one-sentence explanation. If there are no definite defects, output "
    "exactly: LGTM"
)

if os.environ.get("DUMP_PROMPT") == "1":
    print(system)
    raise SystemExit(0)

# One background review across repositories at a time. The kernel releases this
# lock on exit, including a killed process; there is no stale PID directory.
lock_path = os.environ.get("LLMJURY_LOCAL_LOCK") or os.path.expanduser("~/.cache/llmjury/local-compute.lock")
os.makedirs(os.path.dirname(os.path.abspath(lock_path)), exist_ok=True)
lock = open(lock_path, "a")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(1)

# This read-only probe shares council ownership and pressure policy.
# A missing/old CLI, failed probe, or refusal skips without consuming the diff.
probe = subprocess.run(
    [os.environ["REVIEW_PREFLIGHT"], "preflight", "--models", os.environ["MODEL"],
     "--num-ctx", "24576", "--host", os.environ["OLLAMA"]],
    capture_output=True, text=True, timeout=45,
)
if probe.returncode != 0:
    raise SystemExit(1)

payload = {
    "model": os.environ["MODEL"],
    "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": os.environ["DIFF"]},
    ],
    "stream": False,
    # Unload promptly. The cooldown means the next review is ~20 min out, so
    # staying resident only denies the GPU to whatever else needs it.
    "keep_alive": os.environ.get("KEEP_ALIVE", "30s"),
    "options": {"num_ctx": 24576, "num_predict": 600},
}
request = urllib.request.Request(
    os.environ["OLLAMA"] + "/api/chat",
    data=json.dumps(payload).encode(),
    headers={"content-type": "application/json"},
)
response = json.load(urllib.request.urlopen(request, timeout=480))
print((response.get("message", {}).get("content") or "").strip())
PY
)" || exit 0
fi

if [ "${LOCAL_REVIEW_DUMP_PROMPT:-0}" = "1" ]; then
  printf '%s\n' "$review"
  exit 0
fi

[ -n "$review" ] || exit 0
printf %s "$diff_hash" > "$marker"
date +%s > "$stamp"
case "$review" in LGTM*|lgtm*) exit 0 ;; esac

repo_name="$(basename "$top")"
printf 'Local reviewer (%s) flagged the current diff in %s:\n\n%s\n' "$model" "$repo_name" "$review"
exit 2
