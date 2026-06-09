#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3

q() { cl_q "$1" "$2"; }
new_primary() { for p in $P2 $P3; do [ "$(q $p 'SELECT pg_is_in_recovery()')" = "f" ] && { echo "$p"; return; }; done; }
break_stream() { q "$1" "ALTER SYSTEM SET primary_conninfo = 'host=node1 port=1 user=replicator application_name=node$2'" >/dev/null; q "$1" "SELECT pg_reload_conf()" >/dev/null; q "$1" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type='walreceiver'" >/dev/null; }
restore_stream() { q "$1" "ALTER SYSTEM SET primary_conninfo = 'host=node1 port=5432 user=replicator application_name=node$2'" >/dev/null; q "$1" "SELECT pg_reload_conf()" >/dev/null; }

echo "=== cluster ready (pg_replica.synchronous = on) ==="
cl_wait_status "$P1" "decided_primary=1 seq=1 quorum=true read_only=false" 80
for i in $(seq 1 80); do q "$P1" "SHOW synchronous_standby_names" | grep -q "ANY" && q "$P1" "SELECT sync_state FROM pg_stat_replication" | grep -q "quorum" && break; sleep 0.5; done

echo
echo "=== A. sync replication is configured ==="
echo "  synchronous_standby_names = '$(q $P1 'SHOW synchronous_standby_names')'"
echo "  pg_stat_replication:"
q "$P1" "SELECT '    '||application_name||' state='||state||' sync_state='||sync_state FROM pg_stat_replication ORDER BY application_name"
SYNC_OK=0
q "$P1" "SELECT sync_state FROM pg_stat_replication" | grep -q "quorum" && SYNC_OK=1

echo
echo "=== B. ENFORCEMENT: with no standby able to confirm, a commit must BLOCK (not ack) ==="
echo "  breaking WAL streaming on both standbys (raft stays up, so node1 keeps quorum and is NOT fenced)..."
break_stream $P2 2
break_stream $P3 3
sleep 3
echo "  node1 still a writable primary? read_only=$(q $P1 'SHOW default_transaction_read_only')  (raft quorum kept)"
t0=$(date +%s)
cl_psql_t 6 $P1 -v ON_ERROR_STOP=1 -tAc "INSERT INTO demo VALUES ('sync-blocked')" >/dev/null 2>&1
RC=$?; t1=$(date +%s); ELAPSED=$((t1 - t0))
echo "  commit with no confirming standby: exit=$RC elapsed=${ELAPSED}s (blocked => sync withheld the ack)"
BLOCKED=0; [ "$RC" -ne 0 ] && [ "$ELAPSED" -ge 4 ] && BLOCKED=1

echo "  restoring streaming..."
restore_stream $P2 2
restore_stream $P3 3
for i in $(seq 1 30); do [ "$(q $P1 "SELECT count(*) FROM pg_stat_replication")" -ge 1 ] 2>/dev/null && break; sleep 0.5; done
t0=$(date +%s)
cl_psql $P1 -tAc "INSERT INTO demo VALUES ('sync-ok')" >/dev/null 2>&1
RC2=$?; t1=$(date +%s); ELAPSED2=$((t1 - t0))
echo "  commit WITH a confirming standby: exit=$RC2 elapsed=${ELAPSED2}s (proceeds once a standby has it)"
UNBLOCKED=0; [ "$RC2" -eq 0 ] && [ "$ELAPSED2" -le 3 ] && UNBLOCKED=1

echo
echo "=== C. ZERO LOSS across a hard failover ==="
q "$P1" "INSERT INTO demo SELECT 'zl-'||g FROM generate_series(1,500) g" >/dev/null
ACKED=$(q $P1 "SELECT count(*) FROM demo WHERE t LIKE 'zl-%'")
echo "  $ACKED rows committed under sync (each acked => on a quorum)"
echo "  KILL -9 the primary immediately..."
cl_kill 1
NP=""; for i in $(seq 1 60); do NP=$(new_primary); [ -n "$NP" ] && break; sleep 0.5; done
for i in $(seq 1 30); do [ "$(q $NP 'SHOW default_transaction_read_only')" = "off" ] && break; sleep 0.5; done
SURVIVED=$(q $NP "SELECT count(*) FROM demo WHERE t LIKE 'zl-%'")
echo "  new primary on port $NP has $SURVIVED of $ACKED acked rows"

echo
echo "=== M7 quorum-sync result ==="
if [ "$SYNC_OK" = 1 ] && [ "$BLOCKED" = 1 ] && [ "$UNBLOCKED" = 1 ] && [ "$SURVIVED" = "$ACKED" ] && [ "$ACKED" -gt 0 ]; then
  echo "  PASS: sync rep configured (quorum); commit blocks without a confirming standby and proceeds with one; all $ACKED acked rows survived a hard failover (zero committed-transaction loss)"
else
  echo "  CHECK: sync_ok=$SYNC_OK blocked=$BLOCKED(rc=$RC ${ELAPSED}s) unblocked=$UNBLOCKED(rc=$RC2 ${ELAPSED2}s) survived=$SURVIVED/$ACKED"
fi
