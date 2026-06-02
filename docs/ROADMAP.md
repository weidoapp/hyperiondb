# Roadmap

Phased so each milestone is independently testable and de-risks the *next* one.
The riskiest unknowns (raft-rs↔pgrx integration, fencing correctness) are pulled early.

---

### M0 — Skeleton & toolchain  *(de-risk: build system)*
- pgrx extension that loads via `shared_preload_libraries` and registers an empty
  background worker that logs "pg_replica up".
- `CREATE EXTENSION pg_replica;` works; `pg_replica.status()` returns a stub.
- CI: build the `.so` for PG 16/17, run `pgrx test`.
- **Done when:** the extension installs and the bgworker starts on a single node.

### M1 — Raft core in the bgworker  *(de-risk: raft-rs in-process)*
- Embed `raft-rs`; durable log/snapshot in `$PGDATA/pg_replica/`.
- TCP peer transport (length-prefixed bincode/protobuf), `pg_replica.peers` GUC.
- 3 single-node Postgres instances form a Raft group and **elect a leader** (no
  Postgres replication yet).
- `pg_replica.members()` shows term, leader, peer health.
- **Done when:** kill the leader's bgworker → a new leader is elected within the
  timeout; rejoining re-syncs via snapshot.

### M2 — Manage streaming replication  *(data plane wiring)*
- Bootstrap a standby with `pg_basebackup`; write `primary_conninfo` to
  `postgresql.auto.conf`; create/drop replication slots.
- Leader-elected node is configured as **primary**; others as **standbys** following it.
- `pg_replica.status()` reports role, `pg_last_wal_replay_lsn()`, and lag.
- **Done when:** a write on the primary appears on both standbys, including a new
  **role** and a **DDL** change (proves full-cluster fidelity).

### M3 — Automatic failover  *(the headline feature)*
- Failover state machine: detect → choose highest-LSN survivor → `pg_promote()` →
  repoint other standbys → publish new primary.
- Decision is committed through Raft so all nodes agree on the new primary.
- **Done when:** `kill -9` the primary's Postgres → a standby is promoted and the
  other standby follows it automatically, no human action.

### M4 — Fencing & split-brain safety  *(correctness)*
- Loss-of-quorum self-demotion (old primary → read-only/stop).
- Monotonic fencing token (Raft term); reject stale-primary actions.
- Watchdog timer for hung-but-alive nodes.
- **Done when:** a partition test (isolate the primary) shows the minority side
  goes read-only and **never** accepts writes while the majority promotes.

### M5 — Rejoin & repair
- `pg_rewind` the deposed primary against the new one; restart as standby.
- Automatic slot cleanup; handle a node that was down for a long time
  (basebackup fallback when WAL is gone).
- **Done when:** old primary rejoins as a healthy standby after every failover,
  with no manual intervention.

### M6 — Client routing & ergonomics
- Tiny health endpoint (`/primary` → 200 only on leader) for HAProxy `httpchk`;
  documented libpq multi-host and VIP recipes.
- `pg_replica.failover([target])` for planned switchover (maintenance).
- `pg_replica.synchronous` quorum-sync mode keeping `synchronous_standby_names`
  in step with live membership.
- **Done when:** clients survive a failover with only a retry (e.g. `retryWrites`).

### M7 — Hardening
- Chaos/Jepsen-style tests: partitions, clock skew, slow disks, pause/resume
  (SIGSTOP) the primary, rolling restarts.
- mTLS on the Raft transport; authn for SQL control functions.
- Metrics (Prometheus) + structured logs; docs for 3- and 5-node topologies.
- Packaging: `.deb` + Docker image bundling Postgres + the extension preloaded.
- **Done when:** the chaos suite is green and a documented 3-node Docker Compose
  brings up a self-healing cluster from scratch.

---

## Explicitly out of scope (keep "one job, done well")
- Sharding / write scale-out (that's Citus).
- Connection pooling / a bundled proxy (use HAProxy / libpq multi-host).
- Backups / PITR (use pgBackRest / wal-g).
- Logical or multi-master replication.

## Validation targets
- 3-node cluster tolerates 1 node loss with automatic failover < ~10 s (async).
- Quorum-sync mode: **zero** committed-transaction loss across induced failovers.
- A newly created role/DDL on the primary is present on a freshly promoted node.
- Resident memory overhead of the bgworker: single-digit MB beyond Postgres.
