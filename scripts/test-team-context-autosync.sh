#!/usr/bin/env bash

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
hook="$repo_root/scripts/hooks/team-context-autosync.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

origin="$tmp/origin.git"
repo="$tmp/team-context"

git init -q --bare "$origin"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name Test
git -C "$repo" remote add origin "$origin"
mkdir -p "$repo/memory"
printf 'base\n' > "$repo/memory/records.jsonl"
git -C "$repo" add memory/records.jsonl
git -C "$repo" commit -qm base
git -C "$repo" push -q origin main

printf 'main local record\n' >> "$repo/memory/records.jsonl"
TEAM_CONTEXT_DIR="$repo" "$hook" now

[ -z "$(git -C "$repo" status --porcelain -- memory projects-context)" ] \
  || { echo "FAIL: protected-branch sync should commit tracked paths locally" >&2; exit 1; }
[ "$(git --git-dir="$origin" rev-list --count main)" = "1" ] \
  || { echo "FAIL: protected-branch sync should not push to main" >&2; exit 1; }
grep -q 'skipped: on main (protected)' "$repo/.memory-autosync.log" \
  || { echo "FAIL: protected-branch push skip was not logged" >&2; exit 1; }

git -C "$repo" switch -qc feat/sync
printf 'branch\n' >> "$repo/memory/records.jsonl"
git -C "$repo" commit -qam branch

bad_origin="$tmp/missing-origin.git"
git -C "$repo" remote set-url origin "$bad_origin"
printf 'local record\n' >> "$repo/memory/records.jsonl"
TEAM_CONTEXT_DIR="$repo" "$hook" now

[ -z "$(git -C "$repo" status --porcelain -- memory projects-context)" ] \
  || { echo "FAIL: first sync should leave tracked paths clean after committing" >&2; exit 1; }
! git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 \
  || { echo "FAIL: failed first push should not have an upstream yet" >&2; exit 1; }
grep -q 'fail: push' "$repo/.memory-autosync.log" \
  || { echo "FAIL: failed push was not logged" >&2; exit 1; }

git -C "$repo" remote set-url origin "$origin"
TEAM_CONTEXT_DIR="$repo" "$hook" now

[ "$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" = "origin/feat/sync" ] \
  || { echo "FAIL: retry push should establish upstream tracking" >&2; exit 1; }
[ "$(git -C "$repo" rev-list --count '@{upstream}..HEAD')" = "0" ] \
  || { echo "FAIL: second sync should push the clean, already-committed record" >&2; exit 1; }
grep -q 'pushed .* -> feat/sync' "$repo/.memory-autosync.log" \
  || { echo "FAIL: retry push was not logged" >&2; exit 1; }

echo "PASS team-context autosync push retry"

# ── A blocked sync must be visible, and a placeholder must not block ─────────────────
# 2026-09-11 → 09-17: one record quoting the WhatsApp JID shape `digits@s.whatsapp.net`
# matched the email scan, so every Stop-hook sync for six days logged BLOCKED to a file
# nobody reads while 54 records piled up uncommitted.
blocked="$repo/.memory-autosync-blocked"

printf '{"note":"WhatsApp ids look like digits@s.whatsapp.net"}\n' >> "$repo/memory/records.jsonl"
TEAM_CONTEXT_DIR="$repo" "$hook" now
[ -z "$(git -C "$repo" status --porcelain -- memory projects-context)" ] \
  || { echo "FAIL: a placeholder local part (digits@) should not block the sync" >&2; exit 1; }
[ ! -f "$blocked" ] || { echo "FAIL: a clean sync should leave no blocked marker" >&2; exit 1; }
[ -z "$(TEAM_CONTEXT_DIR="$repo" "$hook" check)" ] \
  || { echo "FAIL: check should print nothing when the last sync was not blocked" >&2; exit 1; }

printf '{"note":"reach jane.doe@clientco.com"}\n' >> "$repo/memory/records.jsonl"
TEAM_CONTEXT_DIR="$repo" "$hook" now 2>/dev/null
[ -n "$(git -C "$repo" status --porcelain -- memory)" ] \
  || { echo "FAIL: a named person's address must still block the sync" >&2; exit 1; }
[ -f "$blocked" ] && grep -q 'jane.doe@clientco.com' "$blocked" \
  || { echo "FAIL: a blocked sync should record what blocked it" >&2; exit 1; }
out="$(TEAM_CONTEXT_DIR="$repo" "$hook" check)"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["continue"] is True; assert "BLOCKED" in d["systemMessage"] and "jane.doe@clientco.com" in d["systemMessage"]' \
  || { echo "FAIL: check should emit a SessionStart systemMessage naming the blocked address: $out" >&2; exit 1; }

sed -i.bak 's/jane.doe@clientco.com/the client contact/' "$repo/memory/records.jsonl" && rm -f "$repo/memory/records.jsonl.bak"
TEAM_CONTEXT_DIR="$repo" "$hook" now
[ -z "$(git -C "$repo" status --porcelain -- memory)" ] \
  || { echo "FAIL: the scrubbed record should sync" >&2; exit 1; }
[ ! -f "$blocked" ] || { echo "FAIL: a successful sync should clear the blocked marker" >&2; exit 1; }

echo "PASS team-context autosync surfaces blocks"
