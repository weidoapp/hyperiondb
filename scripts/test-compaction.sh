#!/usr/bin/env bash
set -uo pipefail

export COMPACT_THRESHOLD="${COMPACT_THRESHOLD:-8}"
B="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
R="${ROOT:-/tmp/hyperion-repl}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P1=54340 P2=54341 P3=54342

q() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "$2" 2>&1; }
ins() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "INSERT INTO demo VALUES (\$t\$$2\$t\$)" 2>&1; }
seq_of() { q "$1" "SELECT replica.status()" | grep -oE "seq=[0-9]+" | head -1 | cut -d= -f2; }
fsize() { stat -c %s "/tmp/raft_log_$1.json" 2>/dev/null || echo 0; }
nlog() { python3 -c "import json;print(len(json.load(open('/tmp/raft_log_$1.json')).get('log',{})))" 2>/dev/null || echo -1; }
bgpid() { ps --ppid "$(head -1 "$R/n$1/postmaster.pid")" -o pid=,args= | grep -i "pg_replica supervisor" | awk '{print $1}' | head -1; }

echo "=== bring up cluster (compact_threshold=$COMPACT_THRESHOLD) ==="
bash "$SCRIPT_DIR/cluster-repl.sh" up >/dev/null 2>&1
for i in $(seq 1 80); do q "$P1" "SELECT replica.status()" | grep -q "decided_primary=1 seq=1 quorum=true read_only=false" && break; sleep 0.5; done
ins $P1 marker >/dev/null
SEQ0=$(seq_of $P1); SZ0=$(fsize 1)
echo "  start: seq=$SEQ0  raft_file_bytes(node1)=$SZ0"

echo
echo "=== pump decisions: repeatedly stall a follower (node2) so the leader re-ratifies (seq climbs) ==="
W2=$(bgpid 2)
echo "  node2 bgworker pid=$W2"
for r in $(seq 1 18); do
  kill -STOP "$W2" 2>/dev/null
  sleep 2
  kill -CONT "$W2" 2>/dev/null
  sleep 1.3
done
sleep 2

SEQ1=$(seq_of $P1); SZ1=$(fsize 1); SZ2=$(fsize 2); SZ3=$(fsize 3)
NLOG1=$(nlog 1)
echo "  after pumping: seq=$SEQ1"
echo "  raft log file bytes: node1=$SZ1 node2=$SZ2 node3=$SZ3"
echo "  retained log entries (node1): $NLOG1 (openraft purges applied entries after each snapshot)"

echo
echo "=== restart node3 AFTER compaction -> must recover from snapshot (not full log) ==="
$B/pg_ctl -D "$R/n3" -l "$R/n3.log" restart -m fast >/dev/null 2>&1
for i in $(seq 1 40); do q "$P3" "SELECT 1" 2>/dev/null | grep -q 1 && break; sleep 0.5; done
sleep 2
N3SEQ=$(seq_of $P3)
echo "  node3 restarted; seq after recovery = $N3SEQ (retained entries = $(nlog 3))"

echo
echo "=== cluster still healthy: write on primary replicates ==="
ins $P1 after-compaction >/dev/null
sleep 1
D1=$(q $P1 "SELECT count(*) FROM demo"); D3=$(q $P3 "SELECT count(*) FROM demo")
echo "  demo rows: node1=$D1 node3=$D3"

echo
echo "=== compaction result ==="
DECS=$(( SEQ1 - SEQ0 ))
if [ "$DECS" -ge 12 ] && [ "$NLOG1" -ge 0 ] && [ "$NLOG1" -lt "$DECS" ] && [ "$SZ1" -lt 8192 ] && [ "$N3SEQ" -ge "$SEQ1" ] 2>/dev/null && [ "$D1" = "$D3" ]; then
  echo "  PASS: $DECS decisions made, raft log purged to $NLOG1 retained entries (< $DECS made), file stayed bounded (${SZ1}B), node3 recovered (seq=$N3SEQ), data consistent"
else
  echo "  CHECK: decisions=$DECS retained_entries=$NLOG1 file_bytes=$SZ1 (start $SZ0) n3_seq=$N3SEQ seq=$SEQ1 demo n1=$D1 n3=$D3"
fi
