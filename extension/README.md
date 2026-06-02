# extension/

The `pg_replica` Postgres extension crate (Rust + [`pgrx`](https://github.com/pgcentralfoundation/pgrx)).

## Status: M0 (toolchain skeleton)

Present:
- `Cargo.toml` — pgrx `0.18.1` cdylib, PG 13–18 feature flags (default `pg18`).
- `pg_replica.control` — extension control file.
- `src/lib.rs` — `_PG_init` registers the `pg_replica supervisor` background
  worker (logs `pg_replica: up` every 10s) and exposes `replica.status()`.
- `src/config.rs` — GUCs `pg_replica.node_id` / `pg_replica.raft_port` /
  `pg_replica.peers`, surfaced through `replica.status()` (M1 step 1).

## Build & test (Linux / WSL — pgrx targets Linux/macOS, not native Windows)

```bash
# one-time toolchain (cargo-pgrx version MUST match the pgrx dep in Cargo.toml)
cargo install --locked cargo-pgrx --version 0.18.1
cargo pgrx init --pg18 download       # build just PG18 for dev
#   or reuse a system PG18:  cargo pgrx init --pg18 "$(which pg_config)"

# from this directory
cargo pgrx run pg18                   # builds, installs into a throwaway PG18, opens psql
#   then in psql:
#     CREATE EXTENSION pg_replica;    -- requires shared_preload_libraries (see below)
#     SELECT replica.status();

cargo pgrx test pg18                  # runs the pg_test suite
cargo pgrx package                    # produces the installable artifact for the server
```

To load the background worker, Postgres must preload the library:

```
# postgresql.conf
shared_preload_libraries = 'pg_replica'
```

(The `cargo pgrx test` harness sets this automatically via
`pg_test::postgresql_conf_options()`.)

## Planned module layout (M1+)

```
src/
  lib.rs                   # _PG_init: register bgworker + GUCs + SQL functions
  worker.rs                # background-worker event loop
  raft/
    mod.rs                 # raft-rs node wiring
    transport.rs           # TCP peer transport (length-prefixed)
    storage.rs             # durable log/snapshot in $PGDATA/pg_replica/
    statemachine.rs        # applies committed control entries
  pg/
    replication.rs         # primary_conninfo, slots, pg_basebackup, pg_rewind, pg_promote
    health.rs              # heartbeats + libpq SELECT 1 probes
    role.rs                # apply role: primary | standby | demoted
  failover.rs              # detect -> choose highest LSN -> fence -> promote -> reconfigure -> rejoin
  api.rs                   # SQL: status() / members() / failover() / add_node() / remove_node()
  config.rs                # GUCs
```

Build target: PostgreSQL 16 / 17. See ../docs/ARCHITECTURE.md and ../docs/ROADMAP.md.
