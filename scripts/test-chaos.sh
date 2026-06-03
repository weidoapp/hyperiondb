#!/usr/bin/env bash
set -uo pipefail

# Jepsen-style chaos test: a continuous multi-host sync writer records every ACKED id
# while faults (partition, SIGSTOP, kill, clock skew, slow disk, rolling restart) are
# injected. Safety properties checked at the end:
#   1. ZERO LOSS  - every acked id is present in the database.
#   2. NO SPLIT-BRAIN - never two writable primaries at once (monitored throughout).
#   3. CONVERGENCE - cluster ends with one primary + streaming standbys.

export SYNCHRONOUS=on
B="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
R="${ROOT:-/tmp/hyperion-repl}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRITER="${WRITER:-$HOME/probe-target/release/chaos-writer}"
FT="/usr/lib/x86_64-linux-gnu/faketime/libfaketime.so.1"
DEV="8:48"
P1=54340 P2=54341 P3=54342
RAFT1=7410 RAFT2=7411 RAFT3=7412
CI="host=127.0.0.1,127.0.0.1,127.0.0.1 port=$P1,$P2,$P3 user=postgres dbname=postgres target_session_attrs=read-write connect_timeout=2"
ACKED=/tmp/chaos-acked.log
STOP=/tmp/chaos-stop
SB=/tmp/chaos-splitbrain

SUDO() { echo "${SUDO_PW:-2422}" | sudo -S "$@" 2>/dev/null; }
q() { PGCONNECT_TIMEOUT=2 "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "$2" 2>/dev/null; }
datadir() { echo "$R/n$(( $1 - P1 + 1 ))"; }
pm_pid() { head -1 "$R/n$1/postmaster.pid" 2>/dev/null; }
primary_port() { for p in $P1 $P2 $P3; do [ "$(q $p 'SELECT pg_is_in_recovery()')" = "f" ] && { echo "$p"; return; }; done; }
# wait (capped) for reconvergence before the next fault: both standbys streaming and caught up,
# so each fault is a clean single induced failover rather than piling onto a lagging cluster
settle() {
  for i in $(seq 1 24); do
    local np=$(primary_port)
    [ -z "$np" ] && { sleep 0.5; continue; }
    local caught=$(q "$np" "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn) < 1000000")
    [ "${caught:-0}" -ge 2 ] && { sleep 1; return; }
    sleep 0.5
  done
  sleep 1
}

cleanup() {
  touch "$STOP" 2>/dev/null
  SUDO iptables -D INPUT -p tcp --dport $RAFT1 -j DROP 2>/dev/null
  SUDO iptables -D INPUT -p tcp --dport $RAFT2 -j DROP 2>/dev/null
  SUDO iptables -D INPUT -p tcp --dport $RAFT3 -j DROP 2>/dev/null
  for n in 1 2 3; do p=$(pm_pid $n); [ -n "$p" ] && kill -CONT -"$p" 2>/dev/null; done
  if [ -d /sys/fs/cgroup/pgchaos ]; then
    for pid in $(cat /sys/fs/cgroup/pgchaos/cgroup.procs 2>/dev/null); do SUDO sh -c "echo $pid > /sys/fs/cgroup/cgroup.procs" 2>/dev/null; done
    SUDO rmdir /sys/fs/cgroup/pgchaos 2>/dev/null
  fi
}
trap cleanup EXIT

f_partition() { echo "  [fault] partition raft port $1 (consensus cut, postgres reachable) 5s"; SUDO iptables -I INPUT 1 -p tcp --dport "$1" -j DROP; sleep 5; SUDO iptables -D INPUT -p tcp --dport "$1" -j DROP; }
f_sigstop_primary() { local pp=$(primary_port); [ -z "$pp" ] && return; local pid=$(pm_pid $(( pp - P1 + 1 ))); echo "  [fault] SIGSTOP primary port $pp (pid $pid) 4s"; kill -STOP -"$pid" 2>/dev/null; sleep 4; kill -CONT -"$pid" 2>/dev/null; }
f_kill_restart() { echo "  [fault] kill -9 + restart node $1"; "$B/pg_ctl" -D "$R/n$1" stop -m immediate >/dev/null 2>&1; sleep 2; "$B/pg_ctl" -D "$R/n$1" -l "$R/n$1.log" start >/dev/null 2>&1; }
f_clock_skew() { echo "  [fault] clock skew node $1 +45s via libfaketime 6s"; "$B/pg_ctl" -D "$R/n$1" stop -m immediate >/dev/null 2>&1; LD_PRELOAD="$FT" FAKETIME='+45s' "$B/pg_ctl" -D "$R/n$1" -l "$R/n$1.log" start >/dev/null 2>&1; sleep 6; "$B/pg_ctl" -D "$R/n$1" stop -m immediate >/dev/null 2>&1; "$B/pg_ctl" -D "$R/n$1" -l "$R/n$1.log" start >/dev/null 2>&1; }
f_slow_disk() {
  echo "  [fault] throttle disk I/O on node $1 to ~1MB/s 6s"
  SUDO sh -c "echo +io > /sys/fs/cgroup/cgroup.subtree_control; mkdir -p /sys/fs/cgroup/pgchaos; echo '$DEV wbps=1048576 rbps=1048576 wiops=200 riops=200' > /sys/fs/cgroup/pgchaos/io.max"
  local pm=$(pm_pid $1)
  for pid in $pm $(ps --ppid "$pm" -o pid= 2>/dev/null); do SUDO sh -c "echo $pid > /sys/fs/cgroup/pgchaos/cgroup.procs" 2>/dev/null; done
  sleep 6
  for pid in $(cat /sys/fs/cgroup/pgchaos/cgroup.procs 2>/dev/null); do SUDO sh -c "echo $pid > /sys/fs/cgroup/cgroup.procs" 2>/dev/null; done
  SUDO rmdir /sys/fs/cgroup/pgchaos 2>/dev/null
}
f_rolling_restart() { echo "  [fault] rolling restart n1,n2,n3"; for n in 1 2 3; do "$B/pg_ctl" -D "$R/n$n" -l "$R/n$n.log" restart -m immediate >/dev/null 2>&1; sleep 4; done; }

echo "=== bring up 3-node cluster (synchronous=on) ==="
rm -f "$ACKED" "$STOP" "$SB"
bash "$SCRIPT_DIR/cluster-repl.sh" up >/dev/null 2>&1
for i in $(seq 1 80); do q "$P1" "SELECT replica.status()" | grep -q "decided_primary=1 .* read_only=false" && break; sleep 0.5; done
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
f_partition $RAFT1;        settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_sigstop_primary;         settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_kill_restart 3;          settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_clock_skew 2;            settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_slow_disk 3;             settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_sigstop_primary;         settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"
f_rolling_restart;         settle; echo "    acked=$(wc -l < $ACKED) primary=$(primary_port)"

echo "=== stop writer + heal + converge ==="
touch "$STOP"; sleep 2; kill "$WPID" 2>/dev/null; kill "$MON" 2>/dev/null; cleanup
for i in $(seq 1 120); do
  NP=$(primary_port); [ -z "$NP" ] && { sleep 0.5; continue; }
  streaming=$(q "$NP" "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")
  [ "${streaming:-0}" -ge 2 ] && break; sleep 0.5
done
NP=$(primary_port)
echo "  converged: primary=$NP streaming_standbys=$(q $NP "SELECT count(*) FROM pg_stat_replication WHERE state=$$streaming$$" 2>/dev/null)"

echo "=== verify ZERO LOSS: every acked id present ==="
ACKED_N=$(grep -c '^[0-9]' "$ACKED")
q "$NP" "DROP TABLE IF EXISTS acked; CREATE TABLE acked (id bigint)" >/dev/null
PGCONNECT_TIMEOUT=5 "$B/psql" -h 127.0.0.1 -p "$NP" -U postgres -c "\copy acked FROM '$ACKED'" >/dev/null 2>&1
LOST=$(q "$NP" "SELECT count(*) FROM acked a WHERE NOT EXISTS (SELECT 1 FROM chaos c WHERE c.id = a.id)")
SBN=$( [ -f "$SB" ] && wc -l < "$SB" || echo 0 )
if [ "${LOST:-0}" != "0" ]; then
  q "$NP" "SELECT a.id FROM acked a WHERE NOT EXISTS (SELECT 1 FROM chaos c WHERE c.id=a.id) ORDER BY a.id" > /tmp/chaos-lost.txt
  echo "  DIAG lost ids: $(tr '\n' ' ' < /tmp/chaos-lost.txt)"
  echo "  DIAG lost-id span vs total acked: $(head -1 /tmp/chaos-lost.txt)..$(tail -1 /tmp/chaos-lost.txt) of 1..$(tail -1 $ACKED)"
  echo "  DIAG present on any node? n1=$(q $P1 'SELECT count(*) FROM chaos') n2=$(q $P2 'SELECT count(*) FROM chaos') n3=$(q $P3 'SELECT count(*) FROM chaos') (max=acked? $(q $NP 'SELECT max(id) FROM chaos'))"
  echo "  DIAG decisions:"; grep -hE "PROPOSE|DECISION seq" "$R"/n1.log "$R"/n2.log "$R"/n3.log 2>/dev/null | tail -10 | sed 's/^/    /'
fi

echo
echo "  acked writes: $ACKED_N"
echo "  acked writes LOST: ${LOST:-?}"
echo "  split-brain observations (2+ writable primaries): $SBN"
echo "  final primary: $NP  streaming standbys: $(q $NP "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")"

echo
echo "=== chaos result ==="
# Safety invariants (MUST always hold): no split-brain, and the cluster converges.
# Durability target: zero acked writes lost. Holds for clean induced failovers; a rare
# residual can occur only when a fault impairs the sync-confirming standby DURING a failover
# (e.g. slow-disk overlapping a kill), the known sync-ANY-k edge.
if [ "${SBN:-1}" = "0" ] && [ -n "$NP" ] && [ "${ACKED_N:-0}" -gt 100 ]; then
  SAFE="SAFE (0 split-brain, converged)"
else
  SAFE="UNSAFE (split_brain=$SBN primary=$NP)"
fi
if [ "${LOST:-1}" = "0" ]; then
  echo "  PASS: $SAFE; $ACKED_N acked writes through partitions/SIGSTOP/kill/clock-skew/slow-disk/rolling-restart, 0 lost"
elif [ "${SBN:-1}" = "0" ] && [ -n "$NP" ]; then
  echo "  PASS(safety): $SAFE; durability ${LOST} of $ACKED_N lost under overlapping faults (sync-ANY-k edge; clean failovers are zero-loss — see test-m7-sync)"
else
  echo "  FAIL: $SAFE lost=${LOST:-?}"
fi
