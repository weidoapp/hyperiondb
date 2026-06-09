#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3

q() { cl_q "$1" "$2"; }
recv() { q "$1" "SELECT pg_wal_lsn_diff(COALESCE(pg_last_wal_receive_lsn(),'0/0'),'0/0')::bigint"; }
status() { for p in $P1 $P2 $P3; do echo -n "  node $p: "; q "$p" "SELECT replica.status()"; done; }

echo "=== cluster ready ==="
echo "waiting for bootstrap decision (primary=1) + writable..."
cl_wait_status "$P1" "decided_primary=1 seq=1 quorum=true read_only=false" 60
status

echo
echo "=== baseline write on primary (node 1) ==="
q "$P1" "INSERT INTO demo SELECT 'base-'||g FROM generate_series(1,50) g" >/dev/null
sleep 1
echo "  rows: n1=$(q $P1 'SELECT count(*) FROM demo') n2=$(q $P2 'SELECT count(*) FROM demo') n3=$(q $P3 'SELECT count(*) FROM demo')"

echo
echo "=== make node 3 LAG: repoint it at a dead port + kill walreceiver so it CANNOT receive ==="
q "$P3" "ALTER SYSTEM SET primary_conninfo = 'host=node1 port=1 user=replicator'" >/dev/null
q "$P3" "SELECT pg_reload_conf()" >/dev/null
q "$P3" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type='walreceiver'" >/dev/null
sleep 3
echo "  node3 walreceiver status: $(q $P3 "SELECT coalesce(max(status),'(down)') FROM pg_stat_wal_receiver")"
L3_FROZEN=$(recv $P3)
echo "  node3 receive LSN frozen at: $L3_FROZEN"

echo "=== bulk write on primary (node 2 receives, node 3 does NOT) ==="
q "$P1" "INSERT INTO demo SELECT 'bulk-'||g FROM generate_series(1,2000) g" >/dev/null
q "$P1" "SELECT pg_switch_wal()" >/dev/null
sleep 2

L2=$(recv $P2); L3=$(recv $P3)
echo "  receive LSN: node2=$L2  node3=$L3  (node3 frozen=$L3_FROZEN)"
if [ "$L2" -gt "$L3" ]; then echo "  -> node 2 is strictly AHEAD of node 3 (as intended)"; else echo "  !! node 3 not behind; test inconclusive"; fi
echo "  rows visible: n2=$(q $P2 'SELECT count(*) FROM demo') n3=$(q $P3 'SELECT count(*) FROM demo')"

echo
echo "=== KILL primary (node 1) — system must promote the HIGHER-LSN survivor (node 2) ==="
cl_kill 1
for i in $(seq 1 60); do
  np=$(q "$P2" "SELECT replica.status()" 2>/dev/null)
  echo "$np" | grep -qE "decided_primary=(2|3)" && break
  sleep 0.5
done
for i in $(seq 1 30); do [ "$(q $P2 'SELECT pg_is_in_recovery()')" = "f" ] && break; sleep 0.5; done

echo "=== failover decision log ==="
{ cl_logs 2; cl_logs 3; } 2>/dev/null | grep -hE "PROPOSE|DECISION|APPLY promote" | tail -8

echo
echo "=== final status (survivors) ==="
for p in $P2 $P3; do echo -n "  node $p: "; q "$p" "SELECT replica.status()"; done

echo
echo "=== correctness check ==="
N2INREC=$(q $P2 "SELECT pg_is_in_recovery()")
N2ROWS=$(q $P2 "SELECT count(*) FROM demo")
echo "  new primary candidate node2: in_recovery=$N2INREC rows=$N2ROWS (expect f / 2050)"
if [ "$N2INREC" = "f" ] && [ "$N2ROWS" = "2050" ]; then
  echo "  PASS: highest-LSN survivor (node 2) promoted with all 2050 rows — no data loss"
else
  echo "  CHECK: inspect above (node2 in_recovery=$N2INREC rows=$N2ROWS)"
fi
