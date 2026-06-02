#!/usr/bin/env bash
set -euo pipefail

PGBIN="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
ROOT="${ROOT:-/tmp/hyperion-cluster}"
NODES="${NODES:-3}"
BASE_PGPORT="${BASE_PGPORT:-54330}"
BASE_RAFT="${BASE_RAFT:-7400}"

if [ ! -x "$PGBIN/initdb" ]; then
  echo "initdb not found at $PGBIN — set PGBIN to your pgrx postgres bin dir" >&2
  exit 1
fi

stop_cluster() {
  for d in "$ROOT"/n*; do
    [ -d "$d" ] && "$PGBIN/pg_ctl" -D "$d" stop -m fast >/dev/null 2>&1 || true
  done
}

if [ "${1:-up}" = "down" ]; then
  stop_cluster
  echo "stopped."
  exit 0
fi

PEERS=""
for i in $(seq 1 "$NODES"); do
  PEERS+="${i}@127.0.0.1:$((BASE_RAFT + i - 1)),"
done
PEERS="${PEERS%,}"

stop_cluster
rm -rf "$ROOT"
mkdir -p "$ROOT"

for i in $(seq 1 "$NODES"); do
  d="$ROOT/n$i"
  pgport=$((BASE_PGPORT + i - 1))
  raft=$((BASE_RAFT + i - 1))

  "$PGBIN/initdb" -D "$d" -U postgres --locale=C.UTF-8 >/dev/null

  cat >> "$d/postgresql.conf" <<EOF
port = $pgport
listen_addresses = '127.0.0.1'
shared_preload_libraries = 'pg_replica'
pg_replica.node_id = $i
pg_replica.raft_port = $raft
pg_replica.peers = '$PEERS'
EOF

  "$PGBIN/pg_ctl" -D "$d" -l "$d/pg.log" start >/dev/null
  "$PGBIN/psql" -h 127.0.0.1 -p "$pgport" -U postgres -d postgres \
    -c "CREATE EXTENSION pg_replica;" >/dev/null
  echo "node $i  pg=127.0.0.1:$pgport  raft=127.0.0.1:$raft  log=$d/pg.log"
done

echo
echo "watch consensus traffic:"
echo "  tail -f $ROOT/n*/pg.log | grep --line-buffered pg_replica"
echo "stop:"
echo "  $0 down"
