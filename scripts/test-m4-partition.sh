#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1

q() { cl_q "$1" "$2"; }
ins() { cl_ins "$1" "$2"; }
ro() { q "$1" "SHOW default_transaction_read_only"; }

cleanup() { cl_partition_off "$P1"; }
trap cleanup EXIT

echo "=== cluster ready ==="
cl_wait_status "$P1" "decided_primary=1 seq=1 quorum=true read_only=false" 120
echo "  node1: $(q $P1 'SELECT replica.status()')"
echo "  sanity write: $(ins $P1 healthy)"

echo
echo "=== PARTITION: firewall node1 raft inbound — postgres + control plane stay ALIVE, but cut off from quorum ==="
cl_partition_on "$P1"
echo "  iptables rule installed; node1 is now isolated from peers"
for i in $(seq 1 20); do [ "$(ro $P1)" = "on" ] && break; sleep 0.5; done

echo "  node1: $(q $P1 'SELECT replica.status()')"
echo "  node1 control-plane heartbeat age: $(cl_hb_age $P1)ms (fresh => bgworker ALIVE, this is a NETWORK partition not a hang)"
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
