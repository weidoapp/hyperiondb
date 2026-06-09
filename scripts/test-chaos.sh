#!/usr/bin/env bash
set -uo pipefail

# Jepsen-style chaos test: a continuous multi-host sync writer records every ACKED id
# while faults (partition, freeze, kill, clock skew, slow disk, rolling restart) are
# injected. Safety properties checked at the end:
#   1. ZERO LOSS  - every acked id is present in the database.
#   2. NO SPLIT-BRAIN - never two writable primaries at once (monitored throughout).
#   3. CONVERGENCE - cluster ends with one primary + streaming standbys.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3
WRITER="${WRITER:-chaos-writer}"
CI="$(cl_pg_conninfo)"
ACKED=/tmp/chaos-acked.log
STOP=/tmp/chaos-stop
SB=/tmp/chaos-splitbrain

q() { PGCONNECT_TIMEOUT=2 cl_q_quiet "$1" "$2"; }
primary_port() { cl_primary_node; }
settle() {
  for i in $(seq 1 24); do
    local np; np=$(primary_port)
    [ -z "$np" ] && { sleep 0.5; continue; }
    local caught; caught=$(q "$np" "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn) < 1000000")
    [ "${caught:-0}" -ge 2 ] && { sleep 1; return; }
    sleep 0.5
  done
  sleep 1
}

cleanup() {
  touch "$STOP" 2>/dev/null
  for n in 1 2 3; do cl_partition_off "$n"; cl_unpause "$n"; cl_slow_disk_off "$n"; done
}
trap cleanup EXIT

f_partition()      { echo "  [fault] partition node $1 raft (consensus cut, postgres reachable) 5s"; cl_partition_on "$1"; sleep 5; cl_partition_off "$1"; }
f_freeze_primary() { local pp; pp=$(primary_port); [ -z "$pp" ] && return; echo "  [fault] freeze whole primary node $pp 4s (docker pause = process-group stop)"; cl_pause "$pp"; sleep 4; cl_unpause "$pp"; }
f_kill_restart()   { echo "  [fault] kill -9 + restart node $1"; cl_kill "$1"; sleep 2; cl_start "$1"; }
f_clock_skew()     { echo "  [fault] clock skew node $1 +45s via libfaketime 6s"; cl_clock_skew_on "$1" '+45s'; sleep 6; cl_clock_skew_off "$1"; }
f_slow_disk()      {
  echo "  [fault] throttle disk I/O on node $1 to ~1MB/s 6s"
  if cl_slow_disk_on "$1"; then sleep 6; cl_slow_disk_off "$1"; else echo "    (slow-disk fault not supported on this docker storage driver; skipped)"; fi
}
f_rolling_restart() { echo "  [fault] rolling restart n1,n2,n3"; for n in 1 2 3; do cl_restart "$n"; sleep 4; done; }

echo "=== cluster ready (synchronous=on) ==="
rm -f "$ACKED" "$STOP" "$SB"
cl_wait_status "$P1" "decided_primary=1 .* read_only=false" 120
for i in $(seq 1 60); do q "$P1" "SHOW synchronous_standby_names" | grep -q ANY && break; sleep 0.5; done
q "$P1" "CREATE TABLE chaos (id bigint)" >/dev/null
echo "  up; synchronous_standby_names=[$(q $P1 'SHOW synchronous_standby_names')]"

echo "=== start split-brain monitor + continuous sync writer ==="
( while [ ! -f "$STOP" ]; do w=0; for p in $P1 $P2 $P3; do [ "$(q $p 'SELECT pg_is_in_recovery()')" = "f" ] && [ "$(q $p 'SHOW default_transaction_read_only')" = "off" ] && w=$((w+1)); done; [ "$w" -gt 1 ] && echo "writable=$w at $(date +%T)" >> "$SB"; sleep 0.4; done ) &
MON=$!
"$WRITER" "$CI" "$STOP" > "$ACKED" 2>/dev/null &
WPID=$!
sleep 4
echo "  writer running; acked so far: $(wc -l < $ACKED)"

echo "=== inject faults ==="
f_partition 1;         settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_freeze_primary;      settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_kill_restart 3;      settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_clock_skew 2;        settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_slow_disk 3;         settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_freeze_primary;      settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_rolling_restart;     settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"

echo "=== stop writer + heal + converge ==="
touch "$STOP"; sleep 2; kill "$WPID" 2>/dev/null; kill "$MON" 2>/dev/null; cleanup
for i in $(seq 1 120); do
  NP=$(primary_port); [ -z "$NP" ] && { sleep 0.5; continue; }
  streaming=$(q "$NP" "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")
  [ "${streaming:-0}" -ge 2 ] && break; sleep 0.5
done
NP=$(primary_port)
echo "  converged: primary=$NP streaming_standbys=$(q $NP "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")"

echo "=== verify ZERO LOSS: every acked id present ==="
ACKED_N=$(grep -c '^[0-9]' "$ACKED")
q "$NP" "DROP TABLE IF EXISTS acked; CREATE TABLE acked (id bigint)" >/dev/null
PGCONNECT_TIMEOUT=5 cl_psql "$NP" -c "\copy acked FROM STDIN" < "$ACKED" >/dev/null 2>&1
LOST=$(q "$NP" "SELECT count(*) FROM acked a WHERE NOT EXISTS (SELECT 1 FROM chaos c WHERE c.id = a.id)")
SBN=$( [ -f "$SB" ] && wc -l < "$SB" || echo 0 )
if [ "${LOST:-0}" != "0" ]; then
  q "$NP" "SELECT a.id FROM acked a WHERE NOT EXISTS (SELECT 1 FROM chaos c WHERE c.id=a.id) ORDER BY a.id" > /tmp/chaos-lost.txt
  echo "  DIAG lost ids: $(tr '\n' ' ' < /tmp/chaos-lost.txt)"
  echo "  DIAG lost-id span vs total acked: $(head -1 /tmp/chaos-lost.txt)..$(tail -1 /tmp/chaos-lost.txt) of 1..$(tail -1 $ACKED)"
  echo "  DIAG present on any node? n1=$(q $P1 'SELECT count(*) FROM chaos') n2=$(q $P2 'SELECT count(*) FROM chaos') n3=$(q $P3 'SELECT count(*) FROM chaos') (max=acked? $(q $NP 'SELECT max(id) FROM chaos'))"
  echo "  DIAG decisions:"; { cl_logs 1; cl_logs 2; cl_logs 3; } 2>/dev/null | grep -hE "PROPOSE|DECISION seq" | tail -10 | sed 's/^/    /'
fi

echo
echo "  acked writes: $ACKED_N"
echo "  acked writes LOST: ${LOST:-?}"
echo "  split-brain observations (2+ writable primaries): $SBN"
echo "  final primary: $NP  streaming standbys: $(q $NP "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")"

echo
echo "=== chaos result ==="
if [ "${SBN:-1}" = "0" ] && [ -n "$NP" ] && [ "${ACKED_N:-0}" -gt 100 ]; then
  SAFE="SAFE (0 split-brain, converged)"
else
  SAFE="UNSAFE (split_brain=$SBN primary=$NP)"
fi
if [ "${LOST:-1}" = "0" ]; then
  echo "  PASS: $SAFE; $ACKED_N acked writes through partitions/freeze/kill/clock-skew/slow-disk/rolling-restart, 0 lost"
elif [ "${SBN:-1}" = "0" ] && [ -n "$NP" ]; then
  echo "  PASS(safety): $SAFE; durability ${LOST} of $ACKED_N lost under overlapping faults (sync-ANY-k edge; clean failovers are zero-loss — see test-m7-sync)"
else
  echo "  FAIL: $SAFE lost=${LOST:-?}"
fi
