#!/usr/bin/env bash
set -uo pipefail

B="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
R="${ROOT:-/tmp/hyperion-repl}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P1=54340 P2=54341 P3=54342

q() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "$2" 2>&1; }
ins() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "INSERT INTO demo VALUES (\$t\$$2\$t\$)" 2>&1; }
primary_port() { for p in $P1 $P2 $P3; do q "$p" "SELECT 1" >/dev/null 2>&1 && [ "$(q $p 'SELECT pg_is_in_recovery()')" = "f" ] && { echo "$p"; return; }; done; }

echo "=== bring up cluster ==="
bash "$SCRIPT_DIR/cluster-repl.sh" up >/dev/null 2>&1
for i in $(seq 1 60); do q "$P1" "SELECT replica.status()" | grep -q "decided_primary=1 seq=1 quorum=true read_only=false" && break; sleep 0.5; done
ins $P1 "before-failover" >/dev/null
echo "  seeded 1 row on node1; n1=$(q $P1 'SELECT count(*) FROM demo')"

echo
echo "=== kill primary node1 -> failover ==="
"$B/pg_ctl" -D "$R/n1" stop -m immediate >/dev/null 2>&1
NP=""
for i in $(seq 1 60); do NP=$(primary_port); [ -n "$NP" ] && [ "$NP" != "$P1" ] && break; sleep 0.5; done
echo "  new primary port: $NP"
for i in $(seq 1 30); do q "$NP" "SELECT replica.status()" | grep -q "read_only=false" && break; sleep 0.5; done
ins "$NP" "after-failover" >/dev/null
echo "  wrote 'after-failover' on new primary; rows=$(q $NP 'SELECT count(*) FROM demo')"

echo
echo "=== restart deposed primary node1 -> must NOT accept writes, must rejoin as standby ==="
"$B/pg_ctl" -D "$R/n1" -l "$R/n1.log" start >/dev/null 2>&1
SAW_WRITABLE=0
for i in $(seq 1 50); do
  up=$(q $P1 "SELECT 1" 2>/dev/null)
  if [ "$up" = "1" ]; then
    inrec=$(q $P1 "SELECT pg_is_in_recovery()")
    if [ "$inrec" = "f" ]; then
      W=$(ins $P1 "ZOMBIE-WRITE")
      echo "$W" | grep -q "INSERT 0" && { SAW_WRITABLE=1; echo "  !! node1 accepted a write while deposed: $W"; }
    else
      break
    fi
  fi
  sleep 0.3
done
for i in $(seq 1 60); do [ "$(q $P1 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "t" ] && break; sleep 0.5; done

echo
echo "=== final status ==="
for p in $P1 $P2 $P3; do echo -n "  $p: "; q "$p" "SELECT replica.status()"; done
echo "  data: n1=[$(q $P1 'SELECT string_agg(t,$$,$$ ORDER BY t) FROM demo')] new_primary=[$(q $NP 'SELECT string_agg(t,$$,$$ ORDER BY t) FROM demo')]"

echo
echo "=== M5 result ==="
N1INREC=$(q $P1 "SELECT pg_is_in_recovery()")
if [ "$SAW_WRITABLE" = 0 ] && [ "$N1INREC" = "t" ]; then
  echo "  PASS: deposed primary never accepted a write and rejoined as a standby"
else
  echo "  CHECK: saw_writable=$SAW_WRITABLE node1_in_recovery=$N1INREC"
fi
