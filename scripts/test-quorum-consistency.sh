#!/usr/bin/env bash
set -uo pipefail

export SYNCHRONOUS=on
B="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
R="${ROOT:-/tmp/hyperion-repl}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P1=54340 P2=54341 P3=54342
FAILOVER_LIMIT="${FAILOVER_LIMIT:-30}"

q() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "$2" 2>&1; }
new_primary() { for p in $P2 $P3; do [ "$(q $p 'SELECT pg_is_in_recovery()')" = "f" ] && { echo "$p"; return; }; done; }
break_stream() { q "$1" "ALTER SYSTEM SET primary_conninfo = 'host=127.0.0.1 port=1 user=replicator application_name=node$2'" >/dev/null; q "$1" "SELECT pg_reload_conf()" >/dev/null; q "$1" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type='walreceiver'" >/dev/null; }

echo "=== bring up cluster with pg_replica.synchronous = on ==="
bash "$SCRIPT_DIR/cluster-repl.sh" up >/dev/null 2>&1
for i in $(seq 1 80); do q "$P1" "SELECT replica.status()" | grep -q "decided_primary=1 seq=1 quorum=true read_only=false" && break; sleep 0.5; done
for i in $(seq 1 80); do q "$P1" "SHOW synchronous_standby_names" | grep -q "ANY" && q "$P1" "SELECT sync_state FROM pg_stat_replication" | grep -q "quorum" && break; sleep 0.5; done

echo
echo "=== A. the two quorums describe the SAME set (Postgres sync quorum == Raft consensus quorum) ==="
SSN="$(q $P1 'SHOW synchronous_standby_names')"
ST="$(q $P1 'SELECT replica.status()')"
echo "  synchronous_standby_names = '$SSN'"
echo "  status: $(echo "$ST" | sed 's/ | repl=.*//')"

K="$(echo "$SSN" | sed -n 's/^ANY \([0-9][0-9]*\) .*/\1/p')"
NAMES="$(echo "$SSN" | sed -n 's/.*(\(.*\)).*/\1/p' | tr -d ' ' | tr ',' '\n' | sed 's/node//' | sort -n | paste -sd, -)"
NODE_ID="$(echo "$ST" | sed -n 's/.*node_id=\([0-9][0-9]*\).*/\1/p')"
PEERS_FIELD="$(echo "$ST" | sed -n 's/.*peers=\[\([^]]*\)\].*/\1/p')"
VOTERS="$(echo "$PEERS_FIELD" | tr ',' '\n' | sed 's/@.*//' | sort -n)"
N="$(echo "$VOTERS" | grep -c .)"
MAJ=$(( N / 2 + 1 ))
EXP_K=$(( MAJ - 1 ))
EXP_NAMES="$(echo "$VOTERS" | grep -v "^${NODE_ID}$" | sort -n | paste -sd, -)"

echo "  raft voters={$(echo "$VOTERS" | paste -sd, -)} majority=$MAJ of $N  =>  expect sync quorum K=$EXP_K over standbys {$EXP_NAMES}"
echo "  parsed sync: K=${K:-?} over standbys {${NAMES:-?}}"
A_OK=1
[ "${K:-}" = "$EXP_K" ] || A_OK=0
[ "${NAMES:-}" = "$EXP_NAMES" ] || A_OK=0
[ "$A_OK" = 1 ] && echo "  -> AGREE: durability quorum and consensus quorum name the same standbys and the same count" \
                || echo "  -> MISMATCH: the two quorums disagree (K $K vs $EXP_K, names {$NAMES} vs {$EXP_NAMES})"

echo
echo "=== B. a write confirmed by ONE standby must be promoted onto THAT standby (no two-quorum drift on failover) ==="
echo "  severing node3's WAL stream (raft stays up, node1 keeps quorum, sync target still 'ANY 1 (node2,node3)')..."
break_stream $P3 3
sleep 2
for i in $(seq 1 20); do q "$P1" "SELECT count(*) FROM pg_stat_replication WHERE application_name='node2' AND sync_state='quorum'" | grep -q '^1$' && break; sleep 0.5; done
echo "  confirming standbys now: $(q $P1 "SELECT coalesce(string_agg(application_name,',' ORDER BY application_name),'(none)') FROM pg_stat_replication WHERE sync_state='quorum'")"

t0=$(date +%s)
timeout 10 "$B/psql" -h 127.0.0.1 -p $P1 -U postgres -v ON_ERROR_STOP=1 -tAc "INSERT INTO demo SELECT 'qs-'||g FROM generate_series(1,500) g" >/dev/null 2>&1
RC=$?; t1=$(date +%s); ELAPSED=$((t1 - t0))
ACKED="$(q $P1 "SELECT count(*) FROM demo WHERE t LIKE 'qs-%'")"
ON2="$(q $P2 "SELECT count(*) FROM demo WHERE t LIKE 'qs-%'")"
ON3="$(q $P3 "SELECT count(*) FROM demo WHERE t LIKE 'qs-%'")"
echo "  INSERT 500 under ANY 1: exit=$RC elapsed=${ELAPSED}s (single failure does NOT wedge writes)"
echo "  acked on primary=$ACKED  present on node2=$ON2  present on node3=$ON3 (node3 frozen => durability rests on node2 alone)"

echo "  KILL -9 the primary (node1)..."
"$B/pg_ctl" -D "$R/n1" stop -m immediate >/dev/null 2>&1
NP=""
for i in $(seq 1 $(( FAILOVER_LIMIT * 2 ))); do NP="$(new_primary)"; [ -n "$NP" ] && break; sleep 0.5; done
if [ -n "$NP" ]; then
  for i in $(seq 1 30); do [ "$(q $NP 'SHOW default_transaction_read_only')" = "off" ] && break; sleep 0.5; done
  SURVIVED="$(q $NP "SELECT count(*) FROM demo WHERE t LIKE 'qs-%'")"
  PN=$(( NP - P1 + 1 ))
else
  SURVIVED="?"; PN="?"
fi
echo "  promoted: node${PN} (port ${NP:-none})  has ${SURVIVED}/${ACKED} acked rows"

PROMOTED_CONFIRMER=0; [ "$NP" = "$P2" ] && PROMOTED_CONFIRMER=1
NOLOSS=0; [ "$SURVIVED" = "$ACKED" ] && [ "${ACKED:-0}" -gt 0 ] 2>/dev/null && NOLOSS=1

echo
echo "=== quorum-consistency result ==="
if [ "$A_OK" = 1 ] && [ "$RC" = 0 ] && [ "$PROMOTED_CONFIRMER" = 1 ] && [ "$NOLOSS" = 1 ]; then
  echo "  PASS: sync quorum '$SSN' == raft majority $MAJ of $N (K=$EXP_K over {$EXP_NAMES}); a node2-confirmed write was promoted onto node2 and all $SURVIVED/$ACKED rows survived (consensus and durability quorums stayed consistent across failover)"
else
  echo "  CHECK: a_ok=$A_OK(K=${K:-?}/$EXP_K names={${NAMES:-?}}/{$EXP_NAMES}) insert_rc=$RC(${ELAPSED}s) promoted=node${PN}/expected_node2 confirmer_promoted=$PROMOTED_CONFIRMER survived=${SURVIVED}/${ACKED}"
fi
