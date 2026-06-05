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

## Public API

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

### C1 — Core pool
- [x] Reuse the `failover-probe` `Config` (multi-host, `target_session_attrs=read-write`,
      `connect_timeout`).
- [x] `createPool(opts)` → `#[napi]` class holding a `deadpool`/`bb8` pool.
- [x] `pool.query(sql, params)` async (`#[napi]` → JS Promise) returning rows as JS objects
      keyed by column name.
- [x] `pool.end()` graceful drain.

### C2 — Type marshalling
- [x] Results: PG `Row` → JS. Mappings: `bool`→boolean, `int2/4`→number, `int8`→**BigInt**,
      `oid`→number, `float4/8`→number, `numeric`→**string**, `text`/`varchar`/`bpchar`/`name`→
      string, `uuid`→string, `bytea`→**Buffer**, `json`/`jsonb`→parsed value,
      `timestamptz`/`timestamp`/`date`/`time`→**ISO 8601 string**, and arrays of all the above
      → JS arrays. Custom binary `numeric`→string decoder (arbitrary precision, no float).
- [x] Params: JS values → `tokio_postgres::types::ToSql` (null, boolean, number, **BigInt**,
      string, **Buffer**→bytea, **Date**→timestamptz, array→pg array when the column is an
      array type else jsonb, object→jsonb). Integer/float targets coerced by column type.
- [x] **Decision:** `int8`/`bigint` → **BigInt** (lossless 64-bit); `numeric` → **string**
      (arbitrary precision). `timestamptz` → ISO 8601 string; `bytea` → Buffer.

### C3 — Primary affinity & failover
- [x] Checkout validation: a `deadpool` `pre_recycle` hook runs `SHOW transaction_read_only`
      and evicts the connection when it is `on` (read-only-fence-without-disconnect window).
      Write pool only; fresh connections are already validated by `target_session_attrs`.
- [x] Recycle on connection error; new connections re-resolve the primary (the hook doubles
      as a liveness check — a failed `SHOW` evicts the dead connection).
- [x] Retry/backoff (50ms→500ms, capped) bounded by `acquireTimeoutMs` (default 5000),
      surfacing `no writable primary available after <ms>ms` as a typed error.
- [x] `mode: 'read-write' | 'read-only' | 'prefer-standby' | 'any'`. `read-only` →
      `target_session_attrs=read-only` (lands on standbys); `prefer-standby`/`any` →
      `target_session_attrs=any` + random host load-balancing. (tokio-postgres 0.7.x has no
      server-side standby *preference*, so `prefer-standby` spreads across all reachable nodes.)

### C4 — Ergonomics
- [x] Transactions: native `pool.begin() -> Transaction {query, commit, rollback}` (one
      dedicated connection held in an `Arc<Mutex<Option<Client>>>`), plus a `pool.transaction(cb)`
      helper (auto `BEGIN`/`COMMIT`, `ROLLBACK` on throw) in the JS wrapper.
- [x] Prepared statements: query paths use deadpool `prepare_cached`, so repeated SQL reuses
      a server-side named statement per connection. (Pipelining is inherent to tokio-postgres
      for concurrent queries on a connection.)
- [x] Query cancellation: `query(sql, params, { timeoutMs, signal })`. Both a timeout and an
      `AbortSignal` trip the connection's `tokio_postgres` `cancel_token` (server-side cancel).
      The `!Send` `Rc`-based `AbortSignal` is bridged on the JS thread (`on_abort` → a `Send`
      `Notify`) so the async query can `select!` on it.
- [x] Error mapping: PG errors carry the 5-char `SQLSTATE` on JS `err.code` (native formats
      `[SQLSTATE xxxxx] msg`; the JS wrapper parses it onto `.code` and cleans the message).
- [x] Hand-checked `client.d.ts` (precise `PoolOptions`/`Param`/`Row`/`QueryOptions`/`Pool`/
      `Transaction` types) is the published `types`; the napi-generated `index.d.ts` stays as
      the internal native binding. Architecture is now native core (`index.js`/`.node`) + a thin
      JS ergonomic layer (`client.js`) that adds `.code`, `transaction(cb)`, and option passing.

### C5 — Observability & resilience
- [x] Pool metrics: `pool.status()` → `{ maxSize, size, available, inUse, waiting }` (from
      deadpool's `Status`; `inUse = size − available`).
- [x] `statement_timeout`: `statementTimeoutMs` pool option sets it server-side on every
      connection (`options=-c statement_timeout=…`). Per-query cancellation is the C4
      `query(…, { timeoutMs, signal })` path (client-side `cancel_token`).
- [x] Optional logging hook: `logger(event)` pool option, called once per query with
      `{ sql, durationMs, rowCount? , error? }`; thrown logger errors are swallowed.

### C6 — Packaging & release
- [x] `@napi-rs/cli` prebuilds: `win32-x64-msvc`, `darwin` x64/arm64, `linux` x64/arm64
      (`gnu` + `musl`) — 7 targets (`napi.targets`). Linux builds cross-compile with
      `cargo-zigbuild` (`--cross-compile`); win/mac build natively.
- [x] GitHub Actions matrix (`.github/workflows/release.yml`) → `napi prepublish` publishes
      per-platform `hyperiondb-client-<triple>` packages and wires them as the main package's
      `optionalDependencies`. Triggered by `[cd]` in the commit message on `main`.
- [x] npm publish; the workflow bumps `npm version patch` and syncs `Cargo.toml` to match,
      commits the bump back (no `[cd]`, so it doesn't re-trigger), then publishes. (Needs an
      `NPM_TOKEN` secret.)
- [x] README: install, connect, failover behavior, read-scaling, type mapping, testing.

## Testing

`node-addon/test/` (`node:test`). `npm test` runs the type + fence tests against a running
cluster (primary on the first host); `npm run test:chaos` runs the failover test, which needs
to stop a node (`test/cluster.js`, defaults to the local pgrx cluster via WSL `pg_ctl`; set
`HYPERION_CTL`/env for docker). Connection + topology come from `HYPERION_*` env vars.

- [x] Unit: type round-trips (params ↔ rows) for every supported PG type — `test/types.test.js`
      (scalars, `int8`→BigInt, `numeric` precision, NULLs, date/time/void, arrays incl `int8[]`,
      Date/Buffer/array/jsonb params).
- [x] Integration: query load through the primary-following pool, stop the primary, assert
      reconnection to the new primary and **zero acked-write loss** — `test/chaos.test.js` (JS
      port of `packages/chaos-writer`; requires synchronous replication for true zero-loss).
- [x] Read-only-fence eviction (C3) explicitly — `test/fence.test.js` (fences the primary via
      `ALTER SYSTEM`, asserts the typed error + recovery; always resets the fence in teardown).

## Open decisions
- [x] Pool crate: `deadpool-postgres` (simpler, recycling built in)
- [x] Package + crate name (brand: HyperionDb).
- [x] `bigint`/`numeric` JS representation (C2).

## Not planned

- [ ] TLS backend (rustls vs native-tls) and default per environment.
