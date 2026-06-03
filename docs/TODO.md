# TODO

- Packaging
- Connection pooling/ client
- Docs
- Logs
- slow-disk + kill at once, edge ~0.05% loss remains. Fully closing it needs committed-LSN tracking in the Raft log (Patroni-style)
- Integration tests

## Explicitly out of scope for open source

- mTLS on the Raft transport (https://github.com/rustls/rustls); authn for SQL control functions.
- Metrics (Prometheus) + structured logs
- Sharding / write scale-out (that's Citus).
- Backups / PITR (use pgBackRest / wal-g).
- Logical or multi-master replication.

## Validation targets

- 3-node cluster tolerates 1 node loss with automatic failover < ~10 s (async).
- Quorum-sync mode: **zero** committed-transaction loss across induced failovers.
- A newly created role/DDL on the primary is present on a freshly promoted node.
- Resident memory overhead of the bgworker: single-digit MB beyond Postgres.
