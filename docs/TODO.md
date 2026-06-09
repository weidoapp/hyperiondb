# TODO

[] all configs via client only
[] optimizations

## Explicitly out of scope for open source

- mTLS on the Raft transport (https://github.com/rustls/rustls); authn for SQL control functions.
- Metrics (Prometheus) + structured logs
- Sharding / write scale-out (that's Citus).
- Backups / PITR (use pgBackRest / wal-g).
- Logical or multi-master replication.

## Validation targets

- Raft consensus node loss acceptance with automatic failover with 0 messages lost.
- Quorum-sync mode: **zero** committed-transaction loss across induced failovers.
- A newly created role/DDL on the primary is present on a freshly promoted node.
- Resident memory overhead of the bgworker: single-digit MB beyond Postgres.
