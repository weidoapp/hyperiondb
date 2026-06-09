#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3

q() { cl_q "$1" "$2"; }
try_write() { cl_q "$1" "INSERT INTO demo VALUES (\$tag\$$2\$tag\$)"; }

echo "=== cluster ready ==="
cl_wait_status "$P1" "decided_primary=1" 120
echo "  node1: $(q $P1 'SELECT replica.status()')"

echo
echo "=== sanity: primary (node 1) accepts writes while it has quorum ==="
W=$(try_write $P1 "with-quorum")
echo "  write result: $W"

echo
echo "=== induce loss of quorum: kill BOTH followers (node 2 + node 3) ==="
echo "  node 1 is now a minority of 1 — it MUST stop accepting writes on its own"
cl_kill 2
cl_kill 3

echo "  waiting for check_quorum self-demotion..."
for i in $(seq 1 40); do
  s=$(q "$P1" "SELECT replica.status()" 2>/dev/null)
  echo "$s" | grep -q "read_only=true" && break
  sleep 0.5
done
echo "  node1: $(q $P1 'SELECT replica.status()')"

echo
echo "=== attempt write on the isolated minority primary (must be REJECTED) ==="
W=$(try_write $P1 "split-brain-attempt")
echo "  write result: $W"
if echo "$W" | grep -qi "read-only"; then
  echo "  PASS: minority primary refused the write (no split-brain)"
  FENCED=1
else
  echo "  FAIL: minority primary ACCEPTED a write — split-brain!"
  FENCED=0
fi

echo
echo "=== restore quorum: bring node 2 + node 3 back ==="
cl_start 2
cl_start 3
echo "  waiting for node 1 to regain quorum + read-write..."
for i in $(seq 1 60); do
  s=$(q "$P1" "SELECT replica.status()" 2>/dev/null)
  echo "$s" | grep -q "quorum=true read_only=false" && break
  sleep 0.5
done
echo "  node1: $(q $P1 'SELECT replica.status()')"
W=$(try_write $P1 "quorum-restored")
echo "  write result after restore: $W"
if echo "$W" | grep -qi "INSERT"; then RESTORED=1; else RESTORED=0; fi

echo
echo "=== M4 result ==="
if [ "${FENCED:-0}" = 1 ] && [ "$RESTORED" = 1 ]; then
  echo "  PASS: lost-quorum self-demotion (read-only) + automatic recovery on quorum return"
else
  echo "  CHECK: fenced=$FENCED restored=$RESTORED (inspect above)"
fi
