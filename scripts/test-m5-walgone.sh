#!/usr/bin/env bash
set -uo pipefail

export WAL_KEEP="${WAL_KEEP:-8MB}"
export MAX_WAL="${MAX_WAL:-64MB}"
B="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
R="${ROOT:-/tmp/hyperion-repl}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P1=54340 P2=54341 P3=54342

q() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "$2" 2>&1; }
ins() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "INSERT INTO demo VALUES (\$t\$$2\$t\$)" 2>&1; }
new_primary() { for p in $P2 $P3; do [ "$(q $p 'SELECT pg_is_in_recovery()')" = "f" ] && { echo "$p"; return; }; done; }

echo "=== bring up cluster (wal_keep_size=$WAL_KEEP so WAL recycles fast) ==="
bash "$SCRIPT_DIR/cluster-repl.sh" up >/dev/null 2>&1
for i in $(seq 1 80); do q "$P1" "SELECT replica.status()" | grep -q "decided_primary=1 seq=1 quorum=true read_only=false" && break; sleep 0.5; done
ins $P1 before-failover >/dev/null
echo "  node1 primary; seeded marker 'before-failover'"

echo
echo "=== kill primary node1 -> failover ==="
"$B/pg_ctl" -D "$R/n1" stop -m immediate >/dev/null 2>&1
NP=""
for i in $(seq 1 60); do NP=$(new_primary); [ -n "$NP" ] && break; sleep 0.5; done
for i in $(seq 1 30); do [ "$(q $NP 'SHOW default_transaction_read_only')" = "off" ] && break; sleep 0.5; done
echo "  new primary on port $NP"
ins "$NP" after-failover >/dev/null

echo
echo "=== churn >> $WAL_KEEP of WAL on new primary so node1's divergence WAL is RECYCLED (pg_rewind must fail) ==="
q "$NP" "CREATE TABLE IF NOT EXISTS churn (d text)" >/dev/null
for r in 1 2 3; do
  q "$NP" "INSERT INTO churn SELECT repeat('w',200) FROM generate_series(1,40000)" >/dev/null
  q "$NP" "CHECKPOINT" >/dev/null
  q "$NP" "SELECT pg_switch_wal()" >/dev/null
done
echo "  WAL now at segment $(q $NP 'SELECT pg_walfile_name(pg_current_wal_lsn())')"

echo
echo "=== restart deposed node1 -> pg_rewind should FAIL -> basebackup fallback re-clones ==="
"$B/pg_ctl" -D "$R/n1" -l "$R/n1.log" start >/dev/null 2>&1
for i in $(seq 1 120); do [ "$(q $P1 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "t" ] && break; sleep 0.5; done
for i in $(seq 1 200); do c=$(q $P1 "SELECT count(*) FROM churn" 2>/dev/null); [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] && break; sleep 0.5; done

echo
echo "=== rejoin log trail (node1) ==="
grep -hE "pg_rewind|basebackup|rejoin complete" "$R/n1.log" | tail -6

echo
echo "=== final status ==="
for p in $P1 $P2 $P3; do echo -n "  $p: "; q "$p" "SELECT replica.status()"; done
N1REC=$(q $P1 "SELECT pg_is_in_recovery()")
N1DEMO=$(q $P1 "SELECT string_agg(t, chr(44) ORDER BY t) FROM demo")
NPDEMO=$(q $NP "SELECT string_agg(t, chr(44) ORDER BY t) FROM demo")
N1CHURN=$(q $P1 "SELECT count(*) FROM churn")
echo "  node1: in_recovery=$N1REC demo=[$N1DEMO] churn_rows=$N1CHURN"
echo "  newpri: demo=[$NPDEMO]"

echo
echo "=== M5 WAL-gone result ==="
USED_FALLBACK=0; grep -q "basebackup re-clone succeeded" "$R/n1.log" && USED_FALLBACK=1
if [ "$USED_FALLBACK" = 1 ] && [ "$N1REC" = "t" ] && [ -n "$N1DEMO" ] && [ "$N1DEMO" = "$NPDEMO" ] && [ "$N1CHURN" -gt 0 ]; then
  echo "  PASS: pg_rewind WAL-gone -> automatic pg_basebackup fallback -> node1 rejoined as standby; demo=[$N1DEMO] churn=$N1CHURN match (no manual intervention)"
else
  echo "  CHECK: used_fallback=$USED_FALLBACK node1_standby=$N1REC demo='$N1DEMO' vs '$NPDEMO' churn=$N1CHURN"
fi
