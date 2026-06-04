# Architecture

## 1. Split of responsibilities

```
            ┌─────────────────────────── node A (LEADER / primary) ──────────────────────────┐
            │  Postgres                                                                        │
            │   ├─ pg_replica extension (.so)                                                  │
            │   │    ├─ background worker: Raft node  ◄────raft RPC────┐                       │
            │   │    │     • election, membership, cluster state        │                      │
            │   │    │     • health checks, failover state machine      │                      │
            │   │    │     • executes promote / rewind / reconfigure     │                     │
            │   │    └─ SQL API:  pg_replica.status() / .members() / .failover() / .add_node() │
            │   └─ WAL  ──────────────physical streaming replication──────────────┐           │
            └──────────────────────────────────────────────────────────────────── │ ──────────┘
                         ▲ raft RPC                                                 │ WAL
                         │                                                          ▼
            ┌──────────── node B (follower / standby) ──┐   ┌──────── node C (follower / standby) ──┐
            │ Postgres + pg_replica bgworker (Raft)     │   │ Postgres + pg_replica bgworker (Raft) │
            │ recovery mode, primary_conninfo → A       │   │ recovery mode, primary_conninfo → A   │
            └───────────────────────────────────────────┘   └───────────────────────────────────────┘

  supervisor (systemd / docker restart=always) keeps each Postgres process alive; pg_replica decides its ROLE.
  clients reach the primary via libpq multi-host (target_session_attrs=read-write) or an HAProxy that reads pg_replica state.
```

**Two planes, deliberately separate:**

- **Control plane (Raft, tiny):** elects the leader, tracks membership and the
  authoritative "current primary + replication topology," and drives failover.
  The Raft log only ever carries small control entries (membership changes,
  leader term, failover decisions, fencing tokens). Megabytes, not gigabytes.

- **Data plane (Postgres WAL, large):** the actual rows/indexes/roles/DDL move
  over Postgres's own physical streaming replication. We configure it; we do not
  reimplement it. This is what makes "replicate *everything* including roles and
  DDL" true for free.

See [DECISIONS.md D1](DECISIONS.md#d1-raft-replicates-control-state-not-data) for
why Raft must **not** carry the data itself.

## 2. Components

### 2.1 `pg_replica` extension (Rust, via `pgrx`)
Built with [`pgrx`](https://github.com/pgcentralfoundation/pgrx) so it stays in
the same toolchain as ParadeDB-style extensions. Two parts:

1. **Background worker `pg_replica supervisor`** — registered via
   `RegisterBackgroundWorker` at `shared_preload_libraries`. Hosts:
   - the **Raft node** ([`openraft`](https://github.com/databendlabs/openraft), an
     async Raft) on a small embedded tokio runtime, with a peer transport
     (TCP, length-prefixed JSON RPC) that also multiplexes LSN gossip;
   - a durable **Raft log + snapshot store** in `$PGDATA/pg_replica/` (separate
     from Postgres WAL);
   - the **health monitor** (heartbeats + libpq `SELECT 1` probes of peers);
   - the **failover state machine** (detect → elect → choose → fence → promote →
     reconfigure → rejoin);
   - executors that call `pg_promote()`, edit `postgresql.auto.conf`
     (`primary_conninfo`), manage replication slots, and shell out to
     `pg_basebackup` / `pg_rewind`.

2. **SQL surface** (functions + views):
   - `pg_replica.status()` → this node's role, term, leader, LSNs, lag.
   - `pg_replica.members()` → cluster membership + health.
   - `pg_replica.failover([target])` → operator-initiated switchover.
   - `pg_replica.add_node(dsn)` / `pg_replica.remove_node(id)` → membership.
   - GUCs: `pg_replica.peers`, `pg_replica.raft_port`, `pg_replica.node_id`,
     `pg_replica.synchronous`, `pg_replica.failover_timeout_ms`,
     `pg_replica.bootstrap`.

### 2.2 The supervisor you already have
`pg_replica` does **not** start/stop the Postgres *process* — a chicken/egg an
in-Postgres worker can't solve. That job stays with **systemd** or the **Docker
restart policy** (`restart: always`). pg_replica decides each running node's
*role*; the OS supervisor guarantees the process keeps trying to run. This is the
honest reason it can be "just an extension" and still do failover (see
[DECISIONS.md D3](DECISIONS.md#d3-extension-bgworker--not-a-standalone-daemon)).

### 2.3 Client routing (not built, recommended)
pg_replica only **publishes** who the primary is. Pick one:
- **libpq multi-host:** `host=A,B,C ... target_session_attrs=read-write` — driver finds the writable node. Zero infra.
- **HAProxy** with an httpchk against `pg_replica`'s tiny health endpoint (`/primary` → 200 only on the leader).
- **Floating/virtual IP** moved by the leader on promotion.

## 3. Failover flow (primary dies)

1. **Detect.** Followers' health monitors miss `pg_replica.failover_timeout_ms`
   of heartbeats from the leader. Raft leadership lease expires.
2. **Elect (control plane).** Surviving nodes hold a Raft election; only the
   **majority partition** can elect — a minority (incl. an isolated old primary)
   cannot, which is what prevents split-brain.
3. **Self-fence the loser.** A primary that loses quorum **demotes itself**
   (drops to read-only / shuts down) via a loss-of-quorum watchdog, *before* a new
   one is promoted. A monotonic **fencing token** (Raft term) guards against a
   paused old primary resuming.
4. **Choose the most-advanced replica.** The new Raft leader queries each
   survivor's `pg_last_wal_replay_lsn()` / `pg_last_wal_receive_lsn()` and picks
   the highest, minimizing data loss. Decision is committed to the Raft log.
5. **Promote.** `SELECT pg_promote()` on the chosen standby.
6. **Reconfigure the rest.** Remaining standbys get `primary_conninfo` repointed
   at the new primary; slots recreated; reload.
7. **Rejoin the loser.** When the old primary returns, `pg_rewind` it against the
   new primary to discard diverged WAL, then start it as a standby.
8. **Publish.** New primary recorded in Raft state; routing layer (HAProxy/VIP) follows.

## 4. Data-loss posture (sync vs async)

Configurable via `pg_replica.synchronous`:
- **async (default):** lowest latency; failover may lose the last unreplicated
  commits (bounded by replica lag).
- **quorum-sync:** sets `synchronous_standby_names = 'ANY 1 (nodeB,nodeC)'` so a
  commit is acked by ≥1 standby → failover loses **nothing**. Cost: write latency,
  and writes stall if too few sync standbys are up. pg_replica keeps
  `synchronous_standby_names` in step with live membership so a single failure
  never wedges writes.

## 5. The hard problems (and our stance)

| Problem | Stance |
|--------|--------|
| **Split-brain** | Raft majority quorum + self-fence on quorum loss + fencing token (term). Never two writable primaries. |
| **Promoting a stale replica** | Always pick highest LSN among survivors; `pg_rewind` the others. |
| **Old primary resurrecting** | Loss-of-quorum watchdog demotes it; term-based fencing token rejects its stale writes/role. |
| **Quorum math** | Odd cluster sizes (3 → tolerate 1, 5 → tolerate 2). 2-node HA is impossible safely; document it. |
| **Raft node dies with Postgres** | Fine: a down node doesn't need to vote; survivors keep quorum. OS supervisor restarts Postgres → bgworker rejoins. |
| **Hung (not dead) Postgres** | Watchdog timer; if the bgworker can't make progress, it stops accepting the leader role. |
| **Bootstrap / new replica** | `pg_basebackup` from the leader, register in Raft, stream. |
| **Network partition flapping** | Election timeouts + leader leases + openraft's pre-vote to avoid term churn. |

## 6. On-disk / network footprint

- Raft state: `$PGDATA/pg_replica/{raft-log, snapshot, meta}` — small.
- Peer transport: one TCP port per node (`pg_replica.raft_port`), mTLS optional.
- No external store, no JVM, no Go control plane. Memory target: a few MB of
  resident bgworker overhead beyond Postgres itself.
