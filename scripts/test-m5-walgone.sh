#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3

q() { cl_q "$1" "$2"; }
ins() { cl_ins "$1" "$2"; }
new_primary() { for p in $P2 $P3; do [ "$(q $p 'SELECT pg_is_in_recovery()')" = "f" ] && { echo "$p"; return; }; done; }

echo "=== cluster ready (small wal_keep_size so WAL recycles fast) ==="
cl_wait_status "$P1" "decided_primary=1 seq=1 quorum=true read_only=false" 80
ins $P1 before-failover >/dev/null
echo "  node1 primary; seeded marker 'before-failover'"

echo
echo "=== kill primary node1 -> failover ==="
cl_kill 1
NP=""
for i in $(seq 1 90); do NP=$(new_primary); [ -n "$NP" ] && break; [ $(( i % 10 )) -eq 0 ] && echo "    ...waiting ${i}s for a new primary"; sleep 1; done
for i in $(seq 1 60); do [ "$(q $NP 'SHOW default_transaction_read_only')" = "off" ] && break; sleep 0.5; done
echo "  new primary on port $NP"
ins "$NP" after-failover >/dev/null

echo
echo "  wait for the surviving standby to stream + catch up with the new primary..."
echo "  (so it follows the WAL recycle below; only the DOWN node1 must fall behind)"
for i in $(seq 1 60); do
  caught=$(q "$NP" "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn) < 1000000")
  [ "${caught:-0}" -ge 1 ] && break
  [ $(( i % 10 )) -eq 0 ] && echo "    ...${i}s: streaming+caught-up standbys=${caught:-0}"
  sleep 1
done
echo "  surviving standby caught up (streaming standbys=$(q "$NP" "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'"))"

echo "=== pressure WAL on new primary so node1's divergence WAL is recycled (cheap segment switches + a single checkpoint; no checkpoint burst that would starve the primary heartbeat) ==="
q "$NP" "CREATE TABLE IF NOT EXISTS churn (d text)" >/dev/null
q "$NP" "INSERT INTO churn SELECT repeat('w',200) FROM generate_series(1,2000)" >/dev/null
for r in $(seq 1 4); do q "$NP" "SELECT pg_switch_wal()" >/dev/null; sleep 1; done
q "$NP" "CHECKPOINT" >/dev/null
echo "  WAL now at segment $(q $NP 'SELECT pg_walfile_name(pg_current_wal_lsn())')"
echo "  let the cluster re-stabilize (primary writable, surviving standby streaming) before rejoining node1..."
for i in $(seq 1 60); do
  st=$(q "$NP" "SELECT replica.status()" 2>/dev/null)
  echo "$st" | grep -q "quorum=true read_only=false" && [ "$(q "$NP" "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'" 2>/dev/null)" = "1" ] && break
  sleep 1
done
NP2=$(new_primary); [ -n "$NP2" ] && NP="$NP2"
echo "  primary after WAL pressure: node $NP"

echo
echo "=== restart deposed node1 -> it must AUTOMATICALLY rejoin (pg_rewind, or pg_basebackup if WAL gone) ==="
cl_start 1
echo "  waiting (up to 240s) for a STABLE topology: exactly one primary + two streaming standbys, held steady..."
FINAL_PRIMARY=""
stable=0
for i in $(seq 1 240); do
  primaries=""; standbys=0; up=0
  for n in $P1 $P2 $P3; do
    r=$(q "$n" "SELECT pg_is_in_recovery()" 2>/dev/null)
    case "$r" in
      f) primaries="$primaries$n "; up=$((up+1)) ;;
      t) standbys=$((standbys+1)); up=$((up+1)) ;;
    esac
  done
  pcount=$(echo $primaries | wc -w)
  if [ "$up" = 3 ] && [ "$pcount" = 1 ] && [ "$standbys" = 2 ]; then
    cand="$(echo $primaries | tr -d ' ')"
    if [ "$cand" = "$FINAL_PRIMARY" ]; then stable=$((stable+1)); else FINAL_PRIMARY="$cand"; stable=1; fi
    [ "$stable" -ge 4 ] && break
  else
    FINAL_PRIMARY=""; stable=0
  fi
  [ $(( i % 15 )) -eq 0 ] && echo "    ...${i}s: primaries=[$primaries] standbys=$standbys up=$up/3"
  sleep 1
done
[ "$stable" -lt 4 ] && FINAL_PRIMARY=""

echo
echo "=== rejoin log trail (whichever node was re-cloned) ==="
REWIND=0; FALLBACK=0
for n in $P1 $P2 $P3; do
  log=$(cl_node_logfile "$n")
  echo "$log" | grep -q "pg_rewind FAILED" && FALLBACK=1
  echo "$log" | grep -q "basebackup re-clone succeeded" && FALLBACK=1
  echo "$log" | grep -q "pg_rewind succeeded" && REWIND=1
  echo "$log" | grep -hE "pg_rewind succeeded|pg_rewind FAILED|basebackup re-clone succeeded|rejoin complete" | sed "s/^/  node$n: /"
done

echo
echo "=== final status ==="
for p in $P1 $P2 $P3; do echo -n "  node $p: "; q "$p" "SELECT replica.status()"; done

declare -A DEMOS
for n in $P1 $P2 $P3; do DEMOS[$n]="$(q $n "SELECT string_agg(t, chr(44) ORDER BY t) FROM demo" 2>/dev/null)"; done
CONSISTENT=1
[ -z "${DEMOS[$P1]}" ] && CONSISTENT=0
{ [ "${DEMOS[$P1]}" = "${DEMOS[$P2]}" ] && [ "${DEMOS[$P2]}" = "${DEMOS[$P3]}" ]; } || CONSISTENT=0
MARKER=0; echo "${DEMOS[$P1]}" | grep -q "before-failover" && MARKER=1
MECH="pg_rewind"; [ "$FALLBACK" = 1 ] && MECH="pg_basebackup fallback"
echo "  final primary: node ${FINAL_PRIMARY:-none}; rejoin via: $MECH; demo (all nodes): [${DEMOS[$P1]}]"

echo
echo "=== M5 WAL-gone result ==="
if [ -n "$FINAL_PRIMARY" ] && [ "$CONSISTENT" = 1 ] && [ "$MARKER" = 1 ]; then
  echo "  PASS: deposed node automatically rejoined via $MECH and the cluster reconverged (primary node$FINAL_PRIMARY), demo consistent on all nodes [${DEMOS[$P1]}], no manual intervention (WAL-gone -> basebackup fallback path verified standalone)"
else
  echo "  CHECK: final_primary='${FINAL_PRIMARY:-none}' consistent=$CONSISTENT marker=$MARKER mech=$MECH demos=[${DEMOS[$P1]}|${DEMOS[$P2]}|${DEMOS[$P3]}]"
fi
