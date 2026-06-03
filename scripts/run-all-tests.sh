#!/usr/bin/env bash
# Build the extension + test clients, then run the whole test suite and summarise.
# Usage:  bash scripts/run-all-tests.sh [--no-build]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PGCFG="${PGCFG:-$HOME/.pgrx/18.4/pgrx-install/bin/pg_config}"
export CARGO_TARGET_DIR_EXT="${CARGO_TARGET_DIR_EXT:-$HOME/pgrx-target}"
export PROBE_TARGET="${PROBE_TARGET:-$HOME/probe-target}"

# Deterministic tests (each must PASS) + the chaos stress test (safety must hold;
# durability is zero-loss for clean failovers, see note in test-chaos.sh).
TESTS=(test-m3-lsn test-m4-fence test-m4-watchdog test-m4-partition
       test-m5-rejoin test-m5-walgone test-compaction test-m6-routing test-m7-sync test-chaos)

if [ "${1:-}" != "--no-build" ]; then
  echo "== building + installing extension =="
  ( cd "$ROOT_DIR/packages/pg_replica" && CARGO_TARGET_DIR="$CARGO_TARGET_DIR_EXT" cargo pgrx install --release --pg-config "$PGCFG" ) \
    >/tmp/pgr-build.log 2>&1 || { echo "extension build FAILED (see /tmp/pgr-build.log)"; tail -20 /tmp/pgr-build.log; exit 1; }
  echo "== building test clients (tokio-postgres) =="
  ( cd "$ROOT_DIR/packages/failover-probe" && CARGO_TARGET_DIR="$PROBE_TARGET" cargo build --release ) >/tmp/pgr-probe.log 2>&1 || { echo "probe build FAILED"; tail -20 /tmp/pgr-probe.log; exit 1; }
  ( cd "$ROOT_DIR/packages/chaos-writer"  && CARGO_TARGET_DIR="$PROBE_TARGET" cargo build --release ) >/tmp/pgr-writer.log 2>&1 || { echo "writer build FAILED"; tail -20 /tmp/pgr-writer.log; exit 1; }
fi

pass=0; other=0
declare -a SUMMARY
for t in "${TESTS[@]}"; do
  bash "$SCRIPT_DIR/cluster-repl.sh" down >/dev/null 2>&1
  sleep 1
  echo "================ $t ================"
  out=$(bash "$SCRIPT_DIR/$t.sh" 2>&1 | grep -vE "screen size|FTS index")
  res=$(echo "$out" | grep -E "^  (PASS|FAIL|CHECK)" | head -1)
  echo "$out" | grep -E "^  (PASS|FAIL|CHECK)"
  if echo "$res" | grep -q "PASS"; then pass=$((pass+1)); mark="PASS"; else other=$((other+1)); mark="CHECK"; fi
  SUMMARY+=("$(printf '%-18s %s' "$t" "$mark")")
done
bash "$SCRIPT_DIR/cluster-repl.sh" down >/dev/null 2>&1

echo
echo "==================== SUMMARY ===================="
printf '%s\n' "${SUMMARY[@]}"
echo "------------------------------------------------"
echo "$pass passed, $other need-attention, of ${#TESTS[@]} tests"
[ "$other" -eq 0 ]
