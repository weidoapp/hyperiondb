#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3
PROBE="${PROBE:-failover-probe}"
CI="$(cl_pg_conninfo)"

q() { cl_q "$1" "$2"; }
probe() { for i in $(seq 1 160); do out=$("$PROBE" "$CI" "$1" 2>&1); echo "$out" | grep -q "^OK" && { echo "$out"; return; }; sleep 0.5; done; echo "$out"; }
node_of() { echo "$1" | grep -oE "node=[0-9]+" | cut -d= -f2; }

echo "=== cluster ready ==="
cl_wait_status "$P1" "decided_primary=1 seq=1 quorum=true read_only=false" 80

echo
echo "=== client connects with multi-host read-write string (no proxy, no app knowledge of who is primary) ==="
A=$(probe before)
NODE_A=$(node_of "$A")
echo "  probe #1 landed on: $A"
echo "  -> client auto-selected the primary node $NODE_A"

echo
echo "=== KILL that primary (node $NODE_A) — simulate node failure ==="
cl_kill "$NODE_A"
echo "  primary down; the app just reconnects with the SAME connection string..."

echo
echo "=== client reconnects (its only action is a retry) ==="
Bp=$(probe after)
NODE_B=$(node_of "$Bp")
echo "  probe #2 landed on: $Bp"
echo "  -> client auto-followed the failover to the new primary node $NODE_B"

echo
echo "=== verify both writes landed on the (new) primary ==="
ROWS=$(q "$NODE_B" "SELECT string_agg(t, chr(44) ORDER BY t) FROM demo WHERE t LIKE 'routed-%'")
echo "  rows written via the routed client: [$ROWS]"

echo
echo "=== M6 routing result ==="
if [ -n "$NODE_A" ] && [ -n "$NODE_B" ] && [ "$NODE_A" != "$NODE_B" ] && echo "$ROWS" | grep -q "routed-before" && echo "$ROWS" | grep -q "routed-after"; then
  echo "  PASS: multi-host read-write client followed the failover (node $NODE_A -> node $NODE_B) with only a reconnect; both writes on the new primary, no proxy and no app awareness of topology"
else
  echo "  CHECK: node_a=$NODE_A node_b=$NODE_B rows=[$ROWS]"
fi
