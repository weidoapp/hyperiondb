#!/usr/bin/env bash
set -uo pipefail

B="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
R="${ROOT:-/tmp/hyperion-repl}"
PROBE="${PROBE:-$HOME/probe-target/release/failover-probe}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P1=54340 P2=54341 P3=54342
SU_PW="${SU_PW:-supass}"
CI="host=127.0.0.1,127.0.0.1,127.0.0.1 port=$P1,$P2,$P3 user=postgres password=$SU_PW dbname=postgres target_session_attrs=read-write connect_timeout=2"

q() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "$2" 2>&1; }
datadir_for() { echo "$R/n$(( $1 - P1 + 1 ))"; }
probe() { for i in $(seq 1 40); do out=$("$PROBE" "$CI" "$1" 2>&1); echo "$out" | grep -q "^OK" && { echo "$out"; return; }; sleep 0.5; done; echo "$out"; }

echo "=== bring up cluster ==="
bash "$SCRIPT_DIR/cluster-repl.sh" up >/dev/null 2>&1
for i in $(seq 1 80); do q "$P1" "SELECT replica.status()" | grep -q "decided_primary=1 seq=1 quorum=true read_only=false" && break; sleep 0.5; done

echo
echo "=== client connects with multi-host read-write string (no proxy, no app knowledge of who is primary) ==="
A=$(probe before)
PORT_A=$(echo "$A" | grep -oE "port=[0-9]+" | cut -d= -f2)
echo "  probe #1 landed on: $A"
echo "  -> client auto-selected the primary on port $PORT_A"

echo
echo "=== KILL that primary (port $PORT_A) — simulate node failure ==="
"$B/pg_ctl" -D "$(datadir_for "$PORT_A")" stop -m immediate >/dev/null 2>&1
echo "  primary down; the app just reconnects with the SAME connection string..."

echo
echo "=== client reconnects (its only action is a retry) ==="
Bp=$(probe after)
PORT_B=$(echo "$Bp" | grep -oE "port=[0-9]+" | cut -d= -f2)
echo "  probe #2 landed on: $Bp"
echo "  -> client auto-followed the failover to the new primary on port $PORT_B"

echo
echo "=== verify both writes landed on the (new) primary ==="
ROWS=$(q "$PORT_B" "SELECT string_agg(t, chr(44) ORDER BY t) FROM demo WHERE t LIKE 'routed-%'")
echo "  rows written via the routed client: [$ROWS]"

echo
echo "=== M6 routing result ==="
if [ -n "$PORT_A" ] && [ -n "$PORT_B" ] && [ "$PORT_A" != "$PORT_B" ] && echo "$ROWS" | grep -q "routed-before" && echo "$ROWS" | grep -q "routed-after"; then
  echo "  PASS: multi-host read-write client followed the failover ($PORT_A -> $PORT_B) with only a reconnect; both writes on the new primary, no proxy and no app awareness of topology"
else
  echo "  CHECK: port_a=$PORT_A port_b=$PORT_B rows=[$ROWS]"
fi
