#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3

q() { cl_q "$1" "$2"; }
ins() { cl_ins "$1" "$2"; }
ro() { q "$1" "SHOW default_transaction_read_only"; }
new_primary() { for p in $P2 $P3; do [ "$(q $p 'SELECT pg_is_in_recovery()')" = "f" ] && { echo "$p"; return; }; done; }

echo "=== cluster ready ==="
cl_wait_status "$P1" "decided_primary=1 seq=1 quorum=true read_only=false" 120
echo "  node1: $(q $P1 'SELECT replica.status()')"
echo "  sanity write on node1: $(ins $P1 healthy)"

WPID=$(cl_supervisor_pid 1)
echo
echo "=== SIMULATE HANG: SIGSTOP node1 control plane (pid $WPID) — postgres keeps serving, bgworker cannot fence itself ==="
cl_freeze_supervisor 1
echo "  waiting for watchdog fence + peer failover..."
NP=""
for i in $(seq 1 40); do
  NP=$(new_primary)
  [ "$(ro $P1)" = "on" ] && [ -n "$NP" ] && break
  sleep 0.5
done

echo "  node1 (hung primary) read_only=$(ro $P1); new primary on port: ${NP:-none}"
W1=$(ins $P1 zombie-on-hung-primary)
[ -n "$NP" ] && { for i in $(seq 1 30); do [ "$(ro $NP)" = "off" ] && break; sleep 0.5; done; W2=$(ins "$NP" via-new-primary); } || W2="(no new primary)"
echo "  write on hung node1 : $W1"
echo "  write on new primary: $W2"
echo "  watchdog log: $(cl_watchdog_log 1 | tail -1)"

NODE1_FENCED=0; ONE_WRITABLE=0
echo "$W1" | grep -qi "read-only" && NODE1_FENCED=1
{ echo "$W1" | grep -qi "read-only" && echo "$W2" | grep -q "INSERT 0"; } && ONE_WRITABLE=1
if [ "$ONE_WRITABLE" = 1 ]; then
  echo "  PASS: hung primary fenced by watchdog while new primary serves -> exactly one writable node (no split-brain)"
fi

echo
echo "=== RECOVER: SIGCONT node1 -> rejoins as standby ==="
cl_thaw_supervisor 1
for i in $(seq 1 80); do [ "$(q $P1 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "t" ] && break; sleep 0.5; done
N1REC=$(q $P1 "SELECT pg_is_in_recovery()")
echo "  node1: $(q $P1 'SELECT replica.status()')"
echo "  data: node1=[$(q $P1 'SELECT string_agg(t,$$,$$ ORDER BY t) FROM demo')] new_primary=[$(q ${NP:-$P2} 'SELECT string_agg(t,$$,$$ ORDER BY t) FROM demo')]"

echo
echo "=== watchdog result ==="
if [ "$NODE1_FENCED" = 1 ] && [ "$ONE_WRITABLE" = 1 ] && [ "$N1REC" = "t" ]; then
  echo "  PASS: hung control plane fenced (no split-brain); node recovered as standby"
else
  echo "  CHECK: node1_fenced=$NODE1_FENCED one_writable=$ONE_WRITABLE node1_standby=$N1REC"
fi
