#!/usr/bin/env bash
set -uo pipefail

MODEL="${MODEL:-consensus-model}"

echo "=== formal model check: sync quorum vs Raft failover (stateright, exhaustive) ==="
echo "  proves the quorum math itself (ack = majority) never loses an acked transaction,"
echo "  over every reachable write/replicate/ack/crash/failover interleaving."
echo

if ! out="$("$MODEL" 2>/tmp/pgr-model.log)"; then
  tail -30 /tmp/pgr-model.log
  echo "  FAIL: model checker run error (see /tmp/pgr-model.log)"
  exit 1
fi
echo "$out"
