# Durability & zero-loss guide

How close `pg_replica` (+ the `hyperiondb-client` pool) can get to "no lost writes or reads,"
what configuration that requires, and the failure modes that no configuration removes.

"Zero loss" is really three separate guarantees, with three different mechanisms:

| Guarantee | Means | Achievable? |
|-----------|-------|-------------|
| **Durability** | every *acked* (committed) write survives a failover | **Yes**, within the cluster's fault budget — with synchronous quorum commit |
| **Availability** | no *failed* requests during a failover | **Not automatically** — there is a ~5 s window; needs app-level retry + idempotency |
| **Read correctness** | no stale / split-brain reads | **Yes** from the primary; standby reads are eventually-consistent |

---

## A. Durability — zero acked-write loss

A failover can only be lossless if every acked transaction is already on a node that can be
promoted. That requires **synchronous quorum commit**.

### Configuration

Set one GUC; `pg_replica` does the rest:

```ini
# postgresql.conf  (pg_replica.synchronous is a Postmaster GUC — needs a restart)
pg_replica.synchronous = on
```

When on, the primary continuously maintains

```
synchronous_standby_names = 'ANY <majority-1> (peer1, peer2, ...)'
```

so a `COMMIT` is not acked until the WAL is flushed on a **majority of nodes**. Because the
sync quorum (`ANY majority-1` standbys + the primary = a majority) is the *same* majority Raft
elects a leader from, every acked write is guaranteed to be on whichever node wins the next
election. `test-quorum-consistency` exists to prove these two quorums never drift apart.

| Cluster | `synchronous_standby_names` set by pg_replica | Tolerates (zero-loss) |
|---------|------------------------------------------------|-----------------------|
| 3 nodes | `ANY 1 (n2, n3)` | **1** node/leader failure |
| 5 nodes | `ANY 2 (n2, n3, n4, n5)` | **2** simultaneous failures |

Also required (these are PostgreSQL defaults — do **not** weaken them):

- **`synchronous_commit = on`** (the default). Never `local`, `off`, or `remote_write`
  (`remote_write` acks before the standby fsyncs, so a standby crash can still lose it).
  Use `remote_apply` if you additionally want a committed row to be *visible* on the
  confirming standbys before the ack (helps read-your-writes — see section C).
- **`data_checksums = on`** at `initdb` time, so silent disk corruption is detected, not
  replicated as truth.

### What synchronous mode costs

- **Latency:** a commit waits for a standby flush (one extra network round-trip).
- **Availability:** if fewer than `majority-1` standbys are caught up, writes **block** until
  one returns. That is the correct trade — blocking beats acking a write that could be lost.
  (With `pg_replica.synchronous = off` you get async replication: lower latency, but a primary
  can ack a commit and crash before replicating it → that write is lost on failover.)

### The residual durability risk

Even fully synchronous, a 3-node `ANY 1` cluster can lose an acked write **only** if a fault
impairs the sync-confirming standby *at the same time* as the primary, mid-failover (the
"sync-ANY-k edge" noted in `test-chaos`). Clean single failovers are zero-loss; to survive two
overlapping faults, run **5 nodes / `ANY 2`**.

---

## B. Availability — failed requests during a failover

A failover takes **~5 s** to a writable new primary. During that window there is **no
writable primary**, and the client cannot hide that for you:

- `hyperiondb-client` retries the *connection checkout* with backoff up to `acquireTimeoutMs`
  (default 5000), then throws `no writable primary available after <ms>ms`.
- **It does not replay your SQL** — only the connection acquisition. A transaction in flight
  when the primary dies **fails**, and your application must retry it.
- **Ambiguous COMMIT:** if the connection drops *after* `COMMIT` was sent but before the ack,
  the transaction may have committed and replicated. The client correctly reports an error,
  but a blind retry would **double-apply**. This is the in-doubt-transaction problem and
  cannot be solved at the pool layer.

To make failovers invisible to end users, the application needs all three:

1. **Retry** on the typed `no writable primary…` error and on connection-drop errors.
2. **`acquireTimeoutMs` ≥ your failover time** (raise it above ~5 s so a single failover
   surfaces as a delay, not an error).
3. **Idempotent writes**, so retrying an ambiguous commit is safe — e.g. a client-generated
   UUID with `INSERT … ON CONFLICT DO NOTHING`, or an outbox/dedup key. Reads are inherently
   safe to retry.

---

## C. Reads

Reads never get "lost" (they don't mutate), but they can be **stale** or, without fencing,
**wrong**:

- A `mode: 'read-only'` / `prefer-standby` pool reads from standbys, which lag the primary.
  For **read-your-writes** consistency, read from the **read-write pool (primary)**, or use
  `synchronous_commit = remote_apply` (makes a commit visible on the *confirming* standbys
  before it acks — still not on *all* standbys).
- **Split-brain reads are prevented:** a demoted or minority-partitioned primary fences itself
  read-only (`default_transaction_read_only = on`), and the client's checkout validation
  (`SHOW transaction_read_only`) evicts those connections — so you never read from a stale
  ex-primary as if it were current (`test-m4-fence`, `test-m4-partition`).

---

## Failure modes at a glance

| Layer | Failure | Effect | Mitigation |
|-------|---------|--------|------------|
| Postgres repl | async / weak `synchronous_commit` | acked write lost on failover | `pg_replica.synchronous = on`, keep `synchronous_commit = on` |
| pg_replica | quorum lost (≥2 of 3 down) | no leader → writes **block** | correct (safety > availability); 5 nodes to tolerate 2 |
| pg_replica | minority-partitioned primary | that side can't write | self-fences → no split-brain |
| pg_replica | primary + sync standby fault together, mid-failover | rare acked-write loss | 5-node `ANY 2`; backups |
| client | failover window (~5 s) | queries fail | retry + raise `acquireTimeoutMs` |
| client | ambiguous COMMIT | unknown outcome | **idempotent writes** |
| client | read-only pool | stale reads | read the primary for strong reads |
| infra | supervisor doesn't restart PG | capacity shrinks → quorum risk | reliable systemd / Docker restart policy |
| infra | single DC / disk corruption / bad SQL (`DELETE` w/o `WHERE`) | total or logical loss | multi-AZ, `data_checksums`, **backups + PITR** |

---

## What this does *not* replace

Raft + synchronous replication protect against **node and leader failure inside one cluster**.
They do nothing for:

- **Logical errors / bad migrations** → you still need **backups + PITR** (pgBackRest, wal-g).
- **Correlated loss** (one rack / AZ / DC / region) → spread nodes across AZs, or add a remote
  (optionally synchronous) standby, at a latency cost.
- **Bugs / operator error** → backups, again.

Backups and PITR are an explicit non-goal of `pg_replica` (see the README) — they remain
**mandatory** for real durability.

---

## Verdict

- **Zero loss of acknowledged writes:** achievable and *tested* for the failures pg_replica is
  built for (single node/leader failure, clean failover) **iff** `pg_replica.synchronous = on`
  with `synchronous_commit = on`. Not absolute: overlapping faults beyond the budget,
  correlated/DC loss, corruption, and logical errors still need 5-node clusters, multi-AZ,
  checksums, and backups.
- **Zero failed requests:** only with **app-level retry + idempotency**; the ~5 s failover
  window is real and the pool will not replay statements for you.
- **Zero stale reads:** read from the primary (or `remote_apply`); standby reads are
  eventually-consistent by design.

"Zero loss" end-to-end is a property of **cluster config + application retry/idempotency +
backups together** — not of `pg_replica` or the client alone.

## Validated by

| Property | Test (`scripts/`) |
|----------|-------------------|
| Quorum-sync = zero committed-transaction loss on failover | `test-m7-sync` |
| Sync quorum and Raft quorum name the same nodes | `test-quorum-consistency` |
| Continuous writer, faults injected, 0 split-brain + zero-loss for clean failovers | `test-chaos` |
| Highest-LSN survivor is promoted (no data loss) | `test-m3-lsn` |
| Minority primary self-fences read-only | `test-m4-fence`, `test-m4-partition` |
| Client follows the failover with only a reconnect | `test-m6-routing` |

See also [ARCHITECTURE.md](ARCHITECTURE.md), [DECISIONS.md](DECISIONS.md), and the client
guide [CLIENT.md](CLIENT.md).
