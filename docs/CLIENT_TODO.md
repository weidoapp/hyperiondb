# Node.js cluster client (napi-rs) — build plan

A native Node.js addon, written in Rust with **napi-rs**, that gives JS/TS an efficient
connection **pool over the N-node pg_replica cluster** and follows the primary
automatically. The host-racing, primary detection, pooling, and failover recovery live in
Rust — JS never loops over connections.

## Why this shape

- **Not WASM** — WASM has no raw TCP; the PG wire protocol needs a socket. A native addon
  loads into Node and uses real sockets, so `tokio-postgres` works unmodified.
- **Not JS probe-loop** — pure-JS `pg` is single-host ([#1470](https://github.com/brianc/node-postgres/issues/1470)),
  and the libpq path can't be reached cleanly through `pg`'s parser. We push that logic
  down into Rust instead of hand-rolling it in JS (see [CLIENT.md](CLIENT.md)).
- **Reuse what's verified** — `tokio-postgres` already does multi-host +
  `target_session_attrs=read-write` (proven in `packages/failover-probe`,
  `scripts/test-m6-routing.sh`). The addon reuses that exact `Config`.

## Core idea (why this is small)

A `tokio-postgres` `Config` with the host list + `target_session_attrs=read-write` lands
each connection on the current primary by itself. Wrap that `Config` in an async pool
(`bb8-postgres`) and you get an N-node, primary-following pool with
almost no custom routing code: every pooled connection resolves the primary at connect
time, and broken connections (after a failover) are replaced by fresh ones that re-resolve
to the new primary. The pool crate also spawns each `Connection` future for us.

The one non-trivial case to handle explicitly: a primary that is **fenced read-only
without dropping its sessions** (pg_replica sets `default_transaction_read_only=on`).
An already-open pooled connection to that node stays connected but can no longer write.
So the pool needs a **checkout validation** that confirms the connection is still on a
writable primary (`SHOW transaction_read_only` → `off`) and evicts it otherwise.

## Public API (TS sketch, names TBD)

```ts
import { createPool } from 'hyperiondb-client'

const pool = createPool({
  hosts: ['10.0.0.1', '10.0.0.2', '10.0.0.3'],
  port: 5432,
  user: 'app',
  password: '…',
  database: 'weido',
  mode: 'read-write',
  poolSize: 10,
  connectTimeoutMs: 2000,
})

const rows = await pool.query<{ id: number }>('select id from t where x = $1', [42])

await pool.transaction(async (tx) => {
  await tx.query('insert into t (x) values ($1)', [1])
  await tx.query('update t set x = x + 1 where x = $1', [1])
})

await pool.end()
```

A separate `mode: 'read-only'` (or `'prefer-standby'` on PG 14+) pool routes read-heavy
work (ParadeDB search) to standbys.

## Milestones

### C0 — Scaffold
- [ ] New crate under `packages/node-addon`: `Cargo.toml` (`napi`,
      `napi-derive`, `tokio-postgres`, pool crate) + `package.json` + `@napi-rs/cli`.
- [ ] `crate-type = ["cdylib"]`; one `#[napi]` hello export building to a `.node`.
- [ ] `napi build` produces a loadable addon; `napi`-generated `index.d.ts`.

### C1 — Core pool
- [ ] Reuse the `failover-probe` `Config` (multi-host, `target_session_attrs=read-write`,
      `connect_timeout`).
- [ ] `createPool(opts)` → `#[napi]` class holding a `deadpool`/`bb8` pool.
- [ ] `pool.query(sql, params)` async (`#[napi]` → JS Promise) returning rows as JS objects
      keyed by column name.
- [ ] `pool.end()` graceful drain.

### C2 — Type marshalling
- [ ] Results: PG `Row` → JS. Decide mappings for `int2/4/8`, `float4/8`, `bool`, `text`,
      `json`/`jsonb`, `uuid`, `bytea`, `timestamptz`, arrays.
- [ ] Params: JS values → `tokio_postgres::types::ToSql`.
- [ ] **Decision:** `numeric` and `int8`/`bigint` → string vs `BigInt` vs `number`
      (fidelity vs ergonomics).

### C3 — Primary affinity & failover
- [ ] Checkout validation: evict connections where `transaction_read_only != off`
      (handles the read-only-fence-without-disconnect window).
- [ ] Recycle on connection error; new connections re-resolve the primary.
- [ ] Retry/backoff policy + surfacing "no writable primary" as a typed error.
- [ ] `mode: 'read-only' | 'prefer-standby'` read pool variant.

### C4 — Ergonomics
- [ ] Transactions (checked-out client or `transaction(cb)` with auto BEGIN/COMMIT/ROLLBACK).
- [ ] Prepared statements / pipelining.
- [ ] Query cancellation (`AbortSignal` → `tokio_postgres` cancel token).
- [ ] Error mapping: PG `SQLSTATE` → JS `Error` with `.code`.
- [ ] Hand-checked `index.d.ts` over the napi-generated types.

### C5 — Observability & resilience
- [ ] Pool metrics: size, idle, in-use, waiters.
- [ ] `statement_timeout` / per-query timeout.
- [ ] Optional logging/tracing hook.

### C6 — Packaging & release
- [ ] `@napi-rs/cli` prebuilds: `win32`/`darwin`/`linux` × `x64`/`arm64` (+ `linux-musl`).
- [ ] GitHub Actions matrix → per-platform `@scope/name-<triple>` optional deps.
- [ ] npm publish + version pinned to the addon's `Cargo.toml` version.
- [ ] README: install, connect, failover behavior, read-scaling.

## Testing
- [ ] Unit: type round-trips (params ↔ rows) for each supported PG type.
- [ ] Integration against the `docker/` 3-node cluster: query load, `docker compose stop`
      the primary, assert reconnection and **zero failed committed writes** — a JS port of
      `packages/chaos-writer`.
- [ ] Validate the read-only-fence eviction path (C3) explicitly.

## Open decisions
- [ ] Pool crate: `deadpool-postgres` (simpler, recycling built in) vs `bb8-postgres`
      (referenced in [CLIENT.md](CLIENT.md)). Lean `deadpool`.
- [ ] Package + crate name (brand: HyperionDb).
- [ ] `bigint`/`numeric` JS representation (C2).
- [ ] TLS backend (rustls vs native-tls) and default per environment.
