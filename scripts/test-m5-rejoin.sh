#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3

q() { cl_q "$1" "$2"; }
ins() { cl_ins "$1" "$2"; }
primary_port() { for p in $P1 $P2 $P3; do q "$p" "SELECT 1" >/dev/null 2>&1 && [ "$(q $p 'SELECT pg_is_in_recovery()')" = "f" ] && { echo "$p"; return; }; done; }

echo "=== cluster ready ==="
cl_wait_status "$P1" "decided_primary=1 seq=1 quorum=true read_only=false" 60
ins $P1 "before-failover" >/dev/null
echo "  seeded 1 row on node1; n1=$(q $P1 'SELECT count(*) FROM demo')"

echo
echo "=== kill primary node1 -> failover ==="
cl_kill 1
NP=""
for i in $(seq 1 60); do NP=$(primary_port); [ -n "$NP" ] && [ "$NP" != "$P1" ] && break; sleep 0.5; done
echo "  new primary port: $NP"
for i in $(seq 1 30); do q "$NP" "SELECT replica.status()" | grep -q "read_only=false" && break; sleep 0.5; done
ins "$NP" "after-failover" >/dev/null
echo "  wrote 'after-failover' on new primary; rows=$(q $NP 'SELECT count(*) FROM demo')"

echo
echo "=== restart deposed primary node1 -> must NOT accept writes, must rejoin as standby ==="
cl_start 1
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
for p in $P1 $P2 $P3; do echo -n "  node $p: "; q "$p" "SELECT replica.status()"; done
echo "  data: n1=[$(q $P1 'SELECT string_agg(t,$$,$$ ORDER BY t) FROM demo')] new_primary=[$(q $NP 'SELECT string_agg(t,$$,$$ ORDER BY t) FROM demo')]"

echo
echo "=== M5 result ==="
N1INREC=$(q $P1 "SELECT pg_is_in_recovery()")
if [ "$SAW_WRITABLE" = 0 ] && [ "$N1INREC" = "t" ]; then
  echo "  PASS: deposed primary never accepted a write and rejoined as a standby"
else
  echo "  CHECK: saw_writable=$SAW_WRITABLE node1_in_recovery=$N1INREC"
fi
