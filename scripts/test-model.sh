#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODEL_TARGET="${MODEL_TARGET:-$HOME/model-target}"

echo "=== formal model check: sync quorum vs Raft failover (stateright, exhaustive) ==="
echo "  proves the quorum math itself (ack = majority) never loses an acked transaction,"
echo "  over every reachable write/replicate/ack/crash/failover interleaving."
echo

if ! out="$(cd "$ROOT_DIR/packages/consensus-model" && CARGO_TARGET_DIR="$MODEL_TARGET" cargo run --release 2>/tmp/pgr-model-build.log)"; then
  tail -30 /tmp/pgr-model-build.log
  echo "  FAIL: model checker build/run error (see /tmp/pgr-model-build.log)"
  exit 1
fi
echo "$out"
