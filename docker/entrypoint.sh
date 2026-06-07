#!/usr/bin/env bash
# Per-node entrypoint for the pg_replica + ParadeDB integration cluster.
# Node 1 seeds (initdb + roles + extensions); nodes 2/3 pg_basebackup from it.
# All inter-node + client auth is SCRAM (no trust). pg_replica drives failover.
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGBIN="$(pg_config --bindir)"
PASSFILE=/var/lib/postgresql/.pgpass

: "${NODE_ID:?NODE_ID required}"
: "${RAFT_PORT:=7400}"
: "${PEERS:?PEERS required}"
: "${PG_ADDRS:?PG_ADDRS required}"
: "${SEED_HOST:=node1}"
: "${SU_PASSWORD:?SU_PASSWORD required}"
: "${REPL_PASSWORD:?REPL_PASSWORD required}"
: "${APP_USER:=weido}"
: "${APP_PASSWORD:=weido_pw}"
: "${APP_DB:=weido}"
: "${SYNCHRONOUS:=off}"

# Running as root (image default): fix ownership, then drop to the postgres user.
if [ "$(id -u)" = '0' ]; then
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$(dirname "$PGDATA")" /opt/pg_replica
  exec gosu postgres "$0" "$@"
fi

write_passfile() {
  {
    printf '*:*:*:replicator:%s\n' "$REPL_PASSWORD"
    printf '*:*:*:postgres:%s\n'   "$SU_PASSWORD"
  } > "$PASSFILE"
  chmod 600 "$PASSFILE"
}

node_conf() {
  cat >> "$PGDATA/postgresql.conf" <<EOF

listen_addresses = '*'
cluster_name = 'node$NODE_ID'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
wal_log_hints = on
wal_keep_size = '512MB'
shared_preload_libraries = 'pg_search,pg_replica'
pg_replica.node_id = $NODE_ID
pg_replica.raft_port = $RAFT_PORT
pg_replica.peers = '$PEERS'
pg_replica.pg_addrs = '$PG_ADDRS'
pg_replica.psql = '$PGBIN/psql'
pg_replica.passfile = '$PASSFILE'
pg_replica.synchronous = $SYNCHRONOUS
EOF
}

write_passfile
export PGPASSFILE="$PASSFILE"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  if [ "$NODE_ID" = "1" ]; then
    echo "[node1] seeding: initdb (scram) + roles + extensions"
    printf '%s\n' "$SU_PASSWORD" > /tmp/su.pw
    "$PGBIN/initdb" -D "$PGDATA" -U postgres -A scram-sha-256 --pwfile=/tmp/su.pw --locale=C.UTF-8 >/dev/null
    rm -f /tmp/su.pw
    {
      echo "host all         all all scram-sha-256"
      echo "host replication all all scram-sha-256"
    } >> "$PGDATA/pg_hba.conf"
    node_conf

    "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses=127.0.0.1" -w start >/dev/null
    "$PGBIN/psql" -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASSWORD';
GRANT pg_monitor TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO replicator;
CREATE ROLE "$APP_USER" WITH LOGIN PASSWORD '$APP_PASSWORD';
CREATE DATABASE "$APP_DB" OWNER "$APP_USER";
CREATE EXTENSION IF NOT EXISTS pg_replica;
SQL
    "$PGBIN/psql" -h 127.0.0.1 -U postgres -d "$APP_DB" -v ON_ERROR_STOP=1 \
      -c 'CREATE EXTENSION IF NOT EXISTS pg_search;' >/dev/null
    "$PGBIN/pg_ctl" -D "$PGDATA" -w stop >/dev/null
    echo "[node1] seed complete"
  else
    echo "[node$NODE_ID] waiting for seed $SEED_HOST, then pg_basebackup"
    until "$PGBIN/pg_isready" -h "$SEED_HOST" -p 5432 -U postgres -d postgres >/dev/null 2>&1; do sleep 2; done
    until "$PGBIN/pg_basebackup" -h "$SEED_HOST" -p 5432 -U replicator -D "$PGDATA" -X stream >/dev/null 2>&1; do
      echo "[node$NODE_ID] basebackup not ready (seed still seeding); retrying"; sleep 3
    done
    # basebackup cloned node1's config; override only the per-node identity.
    cat >> "$PGDATA/postgresql.conf" <<EOF

cluster_name = 'node$NODE_ID'
pg_replica.node_id = $NODE_ID
EOF
    echo "primary_conninfo = 'host=$SEED_HOST port=5432 user=replicator passfile=$PASSFILE application_name=node$NODE_ID'" \
      >> "$PGDATA/postgresql.auto.conf"
    touch "$PGDATA/standby.signal"
    echo "[node$NODE_ID] standby ready"
  fi
fi

chmod 0700 "$PGDATA"
exec "$PGBIN/postgres" -D "$PGDATA"
