#!/bin/bash
# kernel-zone-watchdog.sh — catch a kernel zone-map leak before it panics the Mac.
#
# On 2026-09-04 this Mac panicked with:
#   zalloc[3]: zone map exhausted while allocating from zone [data.kalloc.1024],
#   likely due to memory leak in zone [data.kalloc.1024] (20G, 21218528 elements allocated)
#
# The leak lives in the KERNEL, so Activity Monitor shows nothing: app RSS stays
# normal while "wired" climbs. Nothing in the panic log says which subsystem did
# it, because zone allocation backtraces need the zlog= boot-arg. This watchdog
# samples the zone table on an interval instead, and snapshots system state the
# moment a zone crosses a threshold — so the next occurrence is attributable.
#
# Usage:
#   kernel-zone-watchdog.sh            # one sample (what the LaunchAgent runs)
#   kernel-zone-watchdog.sh --watch    # sample forever on INTERVAL_SECS
#   kernel-zone-watchdog.sh --report   # summarise the sample history
#   kernel-zone-watchdog.sh --status   # current largest zones, human readable

set -uo pipefail

STATE_DIR="${KERNEL_ZONE_WATCHDOG_STATE:-$HOME/.local/state/kernel-zone-watchdog}"
SAMPLES="$STATE_DIR/samples.csv"
SNAP_DIR="$STATE_DIR/snapshots"
ALERT_FILE="$STATE_DIR/ALERT"

# Idle baseline for data.kalloc.1024 on this machine is ~1.5-2k elements (~2 MB).
# The panic hit 21.2M elements (20 GB). Warn far below danger, page loudly above.
WARN_BYTES="${KERNEL_ZONE_WARN_BYTES:-$((1024 * 1024 * 1024))}"     # 1 GiB
CRIT_BYTES="${KERNEL_ZONE_CRIT_BYTES:-$((6 * 1024 * 1024 * 1024))}" # 6 GiB
INTERVAL_SECS="${KERNEL_ZONE_INTERVAL_SECS:-60}"
SNAPSHOT_COOLDOWN_SECS="${KERNEL_ZONE_SNAPSHOT_COOLDOWN_SECS:-1800}"

mkdir -p "$STATE_DIR" "$SNAP_DIR"

# zprint rows are "<name> <elem> <cur> <max> <#elts> <max#elts> <inuse> <alloc> <count> [flags]".
# Zone names can contain spaces and rows can carry trailing flag letters, so anchor
# on the numeric columns rather than counting fields.
zone_table() {
  zprint 2>/dev/null | perl -ne '
    next unless /^(.*?)\s+(\d+)\s+\S+\s+\S+\s+(\d+)\s+(\d+)\s+(\d+)\s/;
    my ($name, $elem, $inuse) = ($1, $2, $5);
    $name =~ s/^\s+|\s+$//g;
    next unless length $name;
    printf "%s\t%d\t%d\t%d\n", $name, $elem, $inuse, $elem * $inuse;
  '
}

largest_zone() { zone_table | sort -t"$(printf '\t')" -k4 -n -r | head -1; }

wired_bytes() {
  local pages page_size
  pages=$(vm_stat | awk -F: '/Pages wired down/ {gsub(/[ .]/,"",$2); print $2}')
  page_size=$(vm_stat | head -1 | grep -o '[0-9]\+')
  echo $(( ${pages:-0} * ${page_size:-16384} ))
}

human() { awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.1f %s", b, u[i]}'; }

take_snapshot() {
  local reason="$1" zone="$2" bytes="$3"
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  local dir="$SNAP_DIR/$stamp-$reason"
  mkdir -p "$dir"
  {
    echo "reason:    $reason"
    echo "zone:      $zone"
    echo "zone_size: $(human "$bytes") ($bytes bytes)"
    echo "wired:     $(human "$(wired_bytes)")"
    echo "uptime:    $(uptime)"
    echo "date:      $(date)"
  } > "$dir/summary.txt"
  zprint > "$dir/zprint.txt" 2>&1
  vm_stat > "$dir/vm_stat.txt" 2>&1
  netstat -m > "$dir/netstat-m.txt" 2>&1
  ps -Ao rss,pid,ppid,%cpu,lstart,command -m 2>/dev/null | head -60 > "$dir/ps-by-rss.txt"
  # RSS alone misses the shape that mattered in the 2026-09-04 panic: the two processes
  # driving it held 0.1 MB resident while burning 4.5 h of KERNEL cpu and 4.15 billion
  # page faults. Rank by cumulative CPU time and by wall-clock age too, or the snapshot
  # will show every big app and none of the actual culprits.
  ps -Ao time,pid,ppid,%cpu,etime,lstart,command 2>/dev/null | sort -k1 -r | head -40 > "$dir/ps-by-cputime.txt"
  ps -Ao etime,time,pid,%cpu,command 2>/dev/null | sort -r | head -40 > "$dir/ps-by-age.txt"
  top -l 1 -n 30 -o cpu -stats pid,command,cpu,time,mem,pageins 2>/dev/null > "$dir/top.txt"
  ps -Ao pid,ppid,command 2>/dev/null | wc -l > "$dir/process-count.txt"
  ps -Ao command 2>/dev/null | sed 's/ .*//' | sort | uniq -c | sort -rn | head -40 > "$dir/process-histogram.txt"
  launchctl list > "$dir/launchctl.txt" 2>&1
  echo "$dir"
}

notify() {
  local title="$1" msg="$2"
  osascript -e "display notification \"${msg//\"/\'}\" with title \"${title//\"/\'}\"" >/dev/null 2>&1 || true
  logger -t kernel-zone-watchdog "$title: $msg" 2>/dev/null || true
}

cooldown_ok() {
  local marker="$STATE_DIR/.last-$1"
  local now last
  now=$(date +%s)
  last=$(cat "$marker" 2>/dev/null || echo 0)
  if (( now - last >= SNAPSHOT_COOLDOWN_SECS )); then
    echo "$now" > "$marker"
    return 0
  fi
  return 1
}

sample_once() {
  local row name elem inuse bytes wired
  row=$(largest_zone)
  [ -n "$row" ] || { echo "kernel-zone-watchdog: zprint returned nothing" >&2; return 1; }
  IFS=$'\t' read -r name elem inuse bytes <<< "$row"
  wired=$(wired_bytes)

  [ -f "$SAMPLES" ] || echo "epoch,iso,zone,elem_size,inuse,zone_bytes,wired_bytes" > "$SAMPLES"
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$elem" "$inuse" "$bytes" "$wired" >> "$SAMPLES"

  if (( bytes >= CRIT_BYTES )); then
    if cooldown_ok crit; then
      local dir; dir=$(take_snapshot critical "$name" "$bytes")
      printf 'CRITICAL %s zone %s at %s — snapshot %s\n' "$(date)" "$name" "$(human "$bytes")" "$dir" >> "$ALERT_FILE"
      notify "Kernel zone leak — CRITICAL" "$name at $(human "$bytes"). Panic risk. Snapshot: $dir"
    fi
    return 2
  elif (( bytes >= WARN_BYTES )); then
    if cooldown_ok warn; then
      local dir; dir=$(take_snapshot warn "$name" "$bytes")
      printf 'WARN %s zone %s at %s — snapshot %s\n' "$(date)" "$name" "$(human "$bytes")" "$dir" >> "$ALERT_FILE"
      notify "Kernel zone leak building" "$name at $(human "$bytes"). Snapshot: $dir"
    fi
    return 1
  fi
  return 0
}

report() {
  [ -f "$SAMPLES" ] || { echo "no samples yet at $SAMPLES"; return 0; }
  local last_line
  last_line=$(awk -F, 'NR>1' "$SAMPLES" | tail -1)
  # A pipeline runs `read` in a subshell, so feed the line in via a here-string.
  IFS=, read -r _ iso zone elem inuse bytes wired <<< "$last_line"
  echo "samples:   $(( $(wc -l < "$SAMPLES") - 1 ))"
  echo "latest:    $iso  $zone  $(human "${bytes:-0}")  (wired $(human "${wired:-0}"))"
  local first_epoch first_bytes last_epoch last_bytes
  first_epoch=$(awk -F, 'NR==2{print $1}' "$SAMPLES"); first_bytes=$(awk -F, 'NR==2{print $6}' "$SAMPLES")
  last_epoch=$(awk -F, 'END{print $1}' "$SAMPLES");    last_bytes=$(awk -F, 'END{print $6}' "$SAMPLES")
  if [ -n "${first_epoch:-}" ] && [ "$last_epoch" != "$first_epoch" ]; then
    awk -v fb="$first_bytes" -v lb="$last_bytes" -v fe="$first_epoch" -v le="$last_epoch" \
      'BEGIN{ printf "growth:    %.1f MB/hour over %.1f h\n", (lb-fb)/1048576/((le-fe)/3600), (le-fe)/3600 }'
  else
    # Every sample landed in the same second, so a rate would divide by zero.
    echo "growth:    n/a (samples span 0s)"
  fi
  [ -s "$ALERT_FILE" ] && { echo "--- alerts ---"; tail -10 "$ALERT_FILE"; }
  return 0
}

status() {
  printf '%-34s %10s %12s %12s\n' ZONE ELEM INUSE SIZE
  zone_table | sort -t"$(printf '\t')" -k4 -n -r | head -10 | while IFS=$'\t' read -r n e i b; do
    printf '%-34s %10s %12s %12s\n' "$n" "$e" "$i" "$(human "$b")"
  done
  echo
  echo "wired: $(human "$(wired_bytes)") of $(human "$(sysctl -n hw.memsize)")"
}

case "${1:-}" in
  --watch)  while :; do sample_once; sleep "$INTERVAL_SECS"; done ;;
  --report) report ;;
  --status) status ;;
  --help|-h) sed -n '2,20p' "$0" ;;
  "")       sample_once ;;
  *)        echo "unknown option: $1" >&2; exit 64 ;;
esac
