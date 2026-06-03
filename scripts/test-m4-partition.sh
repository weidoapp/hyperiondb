#!/usr/bin/env bash
set -uo pipefail

B="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
R="${ROOT:-/tmp/hyperion-repl}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P1=54340 RAFT1=7410

q() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "$2" 2>&1; }
ins() { "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "INSERT INTO demo VALUES (\$t\$$2\$t\$)" 2>&1; }
ro() { q "$1" "SHOW default_transaction_read_only"; }
SUDO() { echo "${SUDO_PW:-2422}" | sudo -S "$@" 2>/dev/null; }
hb_age() { echo $(( $(date +%s%3N) - $(cat /tmp/pg_replica_hb_1 2>/dev/null || echo 0) )); }

cleanup() { SUDO iptables -D INPUT -p tcp --dport "$RAFT1" -j DROP 2>/dev/null; }
trap cleanup EXIT

echo "=== bring up cluster ==="
bash "$SCRIPT_DIR/cluster-repl.sh" up >/dev/null 2>&1
for i in $(seq 1 80); do q "$P1" "SELECT replica.status()" | grep -q "decided_primary=1 seq=1 quorum=true read_only=false" && break; sleep 0.5; done
echo "  node1: $(q $P1 'SELECT replica.status()')"
echo "  sanity write: $(ins $P1 healthy)"

echo
echo "=== PARTITION: firewall node1 raft inbound (port $RAFT1) — postgres + control plane stay ALIVE, but cut off from quorum ==="
SUDO iptables -I INPUT 1 -p tcp --dport "$RAFT1" -j DROP
echo "  iptables rule installed; node1 is now isolated from peers"
for i in $(seq 1 20); do [ "$(ro $P1)" = "on" ] && break; sleep 0.5; done

echo "  node1: $(q $P1 'SELECT replica.status()')"
echo "  node1 control-plane heartbeat age: $(hb_age)ms (fresh => bgworker ALIVE, this is a NETWORK partition not a hang)"
W=$(ins $P1 split-brain-attempt)
echo "  write on isolated-but-running primary: $W"
FENCED=0
{ [ "$(ro $P1)" = "on" ] && echo "$W" | grep -qi "read-only"; } && FENCED=1
[ "$FENCED" = 1 ] && echo "  PASS: running, control-plane-healthy primary self-demoted to read-only when cut from quorum"

echo
echo "=== HEAL: remove firewall rule ==="
cleanup
for i in $(seq 1 60); do q "$P1" "SELECT replica.status()" | grep -q "quorum=true read_only=false" && break; sleep 0.5; done
echo "  node1: $(q $P1 'SELECT replica.status()')"
W=$(ins $P1 after-heal)
echo "  write after heal: $W"
echo "$W" | grep -q "INSERT 0" && RESTORED=1 || RESTORED=0

echo
echo "=== partition result ==="
if [ "$FENCED" = 1 ] && [ "$RESTORED" = 1 ]; then
  echo "  PASS: network-partitioned primary self-demoted (no split-brain) and recovered on heal"
else
  echo "  CHECK: fenced=$FENCED restored=$RESTORED"
fi
