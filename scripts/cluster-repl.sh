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

REPL_PW="${REPL_PW:-replpass}"
SU_PW="${SU_PW:-supass}"
PASSFILE="${PASSFILE:-$HOME/.pgpass}"
{ printf '*:*:*:replicator:%s\n' "$REPL_PW"; printf '*:*:*:postgres:%s\n' "$SU_PW"; } > "$PASSFILE"
chmod 600 "$PASSFILE"

P1="$ROOT/n1"
PGP1=$BASE_PGPORT
SU_PWFILE="$ROOT/.su_pwfile"
printf '%s\n' "$SU_PW" > "$SU_PWFILE"
"$PGBIN/initdb" -D "$P1" -U postgres -A scram-sha-256 --pwfile="$SU_PWFILE" --locale=C.UTF-8 >/dev/null
rm -f "$SU_PWFILE"
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
pg_replica.passfile = '$PASSFILE'
EOF
# No trust anywhere: initdb -A scram-sha-256 made every default pg_hba line SCRAM, and
# initdb --pwfile gave postgres its password (so even the first CREATE ROLE authenticates).
"$PGBIN/pg_ctl" -D "$P1" -l "$ROOT/n1.log" start >/dev/null
"$PGBIN/psql" -h 127.0.0.1 -p "$PGP1" -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PW';
GRANT pg_monitor TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO replicator;
CREATE EXTENSION pg_replica;
CREATE TABLE demo (t text);
SQL
echo "node 1 PRIMARY up on 127.0.0.1:$PGP1"

for i in 2 3; do
  d="$ROOT/n$i"
  pgp=$((BASE_PGPORT + i - 1))
  raft=$((BASE_RAFT + i - 1))
  PGPASSFILE="$PASSFILE" "$PGBIN/pg_basebackup" -h 127.0.0.1 -p "$PGP1" -U replicator -D "$d" -X stream >/dev/null
  cat >> "$d/postgresql.conf" <<EOF
port = $pgp
cluster_name = 'node$i'
pg_replica.node_id = $i
pg_replica.raft_port = $raft
EOF
  echo "primary_conninfo = 'host=127.0.0.1 port=$PGP1 user=replicator passfile=$PASSFILE application_name=node$i'" >> "$d/postgresql.auto.conf"
  touch "$d/standby.signal"
  "$PGBIN/pg_ctl" -D "$d" -l "$ROOT/n$i.log" start >/dev/null
  echo "node $i STANDBY up on 127.0.0.1:$pgp (streaming from 127.0.0.1:$PGP1)"
done

echo
echo "primary=127.0.0.1:$BASE_PGPORT  standbys=127.0.0.1:$((BASE_PGPORT+1)),127.0.0.1:$((BASE_PGPORT+2))"
echo "status:  for p in $BASE_PGPORT $((BASE_PGPORT+1)) $((BASE_PGPORT+2)); do $PGBIN/psql -h 127.0.0.1 -p \$p -U postgres -tAc 'SELECT replica.status()'; done"
echo "stop:    $0 down"
