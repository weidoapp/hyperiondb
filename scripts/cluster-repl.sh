#!/usr/bin/env bash
set -euo pipefail

PGBIN="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
ROOT="${ROOT:-/tmp/hyperion-repl}"
BASE_PGPORT="${BASE_PGPORT:-54340}"
BASE_RAFT="${BASE_RAFT:-7410}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PEERS=""
PG_ADDRS=""
for i in 1 2 3; do
  PEERS+="${i}@127.0.0.1:$((BASE_RAFT + i - 1)),"
  PG_ADDRS+="${i}@127.0.0.1:$((BASE_PGPORT + i - 1)),"
done
PEERS="${PEERS%,}"
PG_ADDRS="${PG_ADDRS%,}"

stop_all() {
  pkill -f "/watchdog.sh " >/dev/null 2>&1 || true
  for d in "$ROOT"/n*; do
    [ -d "$d" ] && "$PGBIN/pg_ctl" -D "$d" stop -m fast >/dev/null 2>&1 || true
  done
}

if [ "${1:-up}" = "down" ]; then
  stop_all
  echo "stopped."
  exit 0
fi

stop_all
rm -rf "$ROOT"
mkdir -p "$ROOT"
rm -f /tmp/pg_replica_*.state
rm -f /tmp/pg_replica_raft_*.bin
rm -f /tmp/pg_replica_hb_* /tmp/pg_replica_wd_*.log

P1="$ROOT/n1"
PGP1=$BASE_PGPORT
"$PGBIN/initdb" -D "$P1" -U postgres --locale=C.UTF-8 >/dev/null
cat >> "$P1/postgresql.conf" <<EOF
port = $PGP1
listen_addresses = '127.0.0.1'
cluster_name = 'node1'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
wal_log_hints = on
wal_keep_size = '${WAL_KEEP:-512MB}'
max_wal_size = '${MAX_WAL:-1GB}'
shared_preload_libraries = 'pg_replica'
pg_replica.node_id = 1
pg_replica.raft_port = $BASE_RAFT
pg_replica.synchronous = ${SYNCHRONOUS:-off}
pg_replica.compact_threshold = ${COMPACT_THRESHOLD:-64}
pg_replica.peers = '$PEERS'
pg_replica.pg_addrs = '$PG_ADDRS'
pg_replica.psql = '$PGBIN/psql'
pg_replica.rejoin_script = '$SCRIPT_DIR/rejoin.sh'
pg_replica.watchdog_script = '$SCRIPT_DIR/watchdog.sh'
EOF
echo "host replication replicator 127.0.0.1/32 trust" >> "$P1/pg_hba.conf"
echo "host all         all        127.0.0.1/32 trust" >> "$P1/pg_hba.conf"

"$PGBIN/pg_ctl" -D "$P1" -l "$ROOT/n1.log" start >/dev/null
"$PGBIN/psql" -h 127.0.0.1 -p "$PGP1" -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN;
CREATE EXTENSION pg_replica;
CREATE TABLE demo (t text);
SQL
echo "node 1 PRIMARY up on 127.0.0.1:$PGP1"

for i in 2 3; do
  d="$ROOT/n$i"
  pgp=$((BASE_PGPORT + i - 1))
  raft=$((BASE_RAFT + i - 1))
  "$PGBIN/pg_basebackup" -h 127.0.0.1 -p "$PGP1" -U replicator -D "$d" -R -X stream >/dev/null
  cat >> "$d/postgresql.conf" <<EOF
port = $pgp
cluster_name = 'node$i'
pg_replica.node_id = $i
pg_replica.raft_port = $raft
EOF
  "$PGBIN/pg_ctl" -D "$d" -l "$ROOT/n$i.log" start >/dev/null
  echo "node $i STANDBY up on 127.0.0.1:$pgp (streaming from 127.0.0.1:$PGP1)"
done

echo
echo "primary=127.0.0.1:$BASE_PGPORT  standbys=127.0.0.1:$((BASE_PGPORT+1)),127.0.0.1:$((BASE_PGPORT+2))"
echo "status:  for p in $BASE_PGPORT $((BASE_PGPORT+1)) $((BASE_PGPORT+2)); do $PGBIN/psql -h 127.0.0.1 -p \$p -U postgres -tAc 'SELECT replica.status()'; done"
echo "stop:    $0 down"
