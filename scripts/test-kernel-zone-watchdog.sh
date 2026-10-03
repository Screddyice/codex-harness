#!/bin/bash
# Tests for kernel-zone-watchdog.sh. No sudo, no system changes: every test runs
# against a throwaway state dir and only reads the live zone table.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$HERE/kernel-zone-watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

run() { KERNEL_ZONE_WATCHDOG_STATE="$TMP/state" "$@"; }

# 1. --status lists zones with sizes
out=$(run "$WATCHDOG" --status 2>&1)
if grep -q '^ZONE' <<< "$out" && grep -qE '[0-9]+\.[0-9] (KB|MB|GB)' <<< "$out"; then
  ok "--status prints a zone table with human sizes"
else
  bad "--status prints a zone table with human sizes" "$out"
fi

# 2. A quiet sample exits 0 and appends one CSV row with a header
run "$WATCHDOG" >/dev/null 2>&1; rc=$?
csv="$TMP/state/samples.csv"
if [ "$rc" -eq 0 ] && [ -f "$csv" ] && [ "$(wc -l < "$csv")" -eq 2 ]; then
  ok "quiet sample exits 0 and writes header + one row"
else
  bad "quiet sample exits 0 and writes header + one row" "rc=$rc rows=$(wc -l < "$csv" 2>/dev/null)"
fi

# 3. CSV columns are the documented schema
if head -1 "$csv" | grep -qx 'epoch,iso,zone,elem_size,inuse,zone_bytes,wired_bytes'; then
  ok "CSV header matches the documented schema"
else
  bad "CSV header matches the documented schema" "$(head -1 "$csv")"
fi

# 4. zone_bytes really is elem_size * inuse
awk -F, 'NR==2 { exit !($4 * $5 == $6) }' "$csv" \
  && ok "zone_bytes = elem_size * inuse" \
  || bad "zone_bytes = elem_size * inuse" "$(sed -n 2p "$csv")"

# 5. Crossing WARN exits 1, writes an ALERT line, and captures a snapshot
rm -rf "$TMP/state"
KERNEL_ZONE_WATCHDOG_STATE="$TMP/state" KERNEL_ZONE_WARN_BYTES=1 KERNEL_ZONE_CRIT_BYTES=999999999999999 \
  "$WATCHDOG" >/dev/null 2>&1; rc=$?
snap=$(find "$TMP/state/snapshots" -maxdepth 1 -type d -name '*-warn' 2>/dev/null | head -1)
if [ "$rc" -eq 1 ] && grep -q '^WARN ' "$TMP/state/ALERT" 2>/dev/null && [ -n "$snap" ]; then
  ok "WARN threshold exits 1, logs an alert, and snapshots"
else
  bad "WARN threshold exits 1, logs an alert, and snapshots" "rc=$rc snap=$snap"
fi

# 6. The snapshot carries the evidence needed to attribute a leak
missing=""
for f in summary.txt zprint.txt vm_stat.txt ps-by-rss.txt ps-by-cputime.txt ps-by-age.txt process-histogram.txt launchctl.txt; do
  [ -s "$snap/$f" ] || missing="$missing $f"
done
[ -z "$missing" ] && ok "snapshot contains all evidence files" \
                  || bad "snapshot contains all evidence files" "missing:$missing"

# 7. Crossing CRIT exits 2
rm -rf "$TMP/state"
KERNEL_ZONE_WATCHDOG_STATE="$TMP/state" KERNEL_ZONE_WARN_BYTES=1 KERNEL_ZONE_CRIT_BYTES=1 \
  "$WATCHDOG" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "CRIT threshold exits 2" || bad "CRIT threshold exits 2" "rc=$rc"

# 8. Snapshot cooldown suppresses a second snapshot inside the window
before=$(find "$TMP/state/snapshots" -maxdepth 1 -type d | wc -l)
KERNEL_ZONE_WATCHDOG_STATE="$TMP/state" KERNEL_ZONE_WARN_BYTES=1 KERNEL_ZONE_CRIT_BYTES=1 \
  "$WATCHDOG" >/dev/null 2>&1
after=$(find "$TMP/state/snapshots" -maxdepth 1 -type d | wc -l)
[ "$before" -eq "$after" ] && ok "cooldown suppresses repeat snapshots" \
                           || bad "cooldown suppresses repeat snapshots" "before=$before after=$after"

# 9. --report summarises without crashing, on one row and on many
rm -rf "$TMP/state"; run "$WATCHDOG" >/dev/null 2>&1
out=$(run "$WATCHDOG" --report 2>&1)
if [ -z "$(grep -i 'unbound\|error' <<< "$out")" ] && grep -q '^latest:' <<< "$out"; then
  ok "--report works with a single sample"
else
  bad "--report works with a single sample" "$out"
fi
run "$WATCHDOG" >/dev/null 2>&1
out=$(run "$WATCHDOG" --report 2>&1)
grep -q '^growth:' <<< "$out" && ok "--report computes a growth rate" \
                              || bad "--report computes a growth rate" "$out"

# 10. Unknown options fail loudly rather than sampling silently
run "$WATCHDOG" --bogus >/dev/null 2>&1
[ $? -eq 64 ] && ok "unknown option exits 64" || bad "unknown option exits 64"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
