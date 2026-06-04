# Design decisions (ADR-style)

Each entry: the decision, the rationale, and the alternative we rejected.

---

## D1 — Raft replicates control state, NOT data

**Decision.** The Raft log carries only small cluster-control entries (membership,
leader term, failover decisions, fencing tokens). The actual database content is
replicated by **Postgres physical (WAL) streaming replication**.

**Why.** "Use Raft to replicate the full database" means putting every write
through a Raft log and rebuilding storage on top of it — that is what CockroachDB
and TiKV do, and it is a *multi-year* engineering effort that throws away
Postgres's WAL, MVCC, and on-disk format. It would also make us *not Postgres*.
Physical WAL replication already copies **everything we want** — heap, indexes,
and the shared catalog `pg_authid` (roles/users + SCRAM verifiers) — correctly and
fast. So Raft's job is consensus on *who leads*, not moving bytes.

**Rejected.** Data-over-Raft (reimplementing the storage engine). Too big, and it
discards the entire reason to stay on Postgres.

**Consequence.** "Replicates roles and DDL" is satisfied by physical replication,
not by us. We must never claim otherwise.

---

## D2 — Physical replication, not logical

**Decision.** Use streaming **physical** replication as the data plane.

**Why.** Only physical replication copies **global objects** — roles live in the
cluster-wide `pg_authid`, which logical replication and pgactive explicitly do
**not** carry. Since "replicate roles + DDL + everything" is the whole point,
physical is the only fit. Replicas are read-only; that's acceptable (single-writer
HA, like a Mongo replica set).

**Rejected.** Logical replication (no roles/DDL/globals) and active-active
(pgactive: no global objects, conflict hell). Both fail the core requirement.

---

## D3 — Extension + bgworker, not a standalone daemon

**Decision.** Ship as a Postgres **extension** whose **background worker** hosts
the Raft node and orchestration. Rely on the existing OS supervisor
(systemd / Docker `restart: always`) for the Postgres *process* lifecycle.

**Why.** The user wants "a Postgres plugin," and most of the work *can* live in a
bgworker: a node whose Postgres is down doesn't need to vote (survivors hold
quorum); standbys being promoted are *up*, so their bgworker can `pg_promote()`
itself; a deposed primary that's up runs its own bgworker and self-demotes on
quorum loss. The one thing a bgworker genuinely cannot do is **start a Postgres
that is down** (chicken/egg) — so we delegate *only that* to systemd/Docker, which
every deployment already has.

**Rejected.** A separate Go/Rust daemon à la Patroni/Stolon. It would work, but
it's heavier and contradicts the "plugin" goal. We accept one honest limitation
(process lifecycle is the supervisor's job) to keep the plugin form factor.

**Risk.** A *hung but not dead* Postgres can wedge its bgworker. Mitigation: a
watchdog timer that makes a stuck node refuse/relinquish leadership.

---

## D4 — Embedded Raft, no external DCS

**Decision.** Embed Raft (`openraft`) inside the extension. No etcd, Consul, or k8s.

**Why.** The stated goal is fewer moving parts than CloudNativePG/Patroni-etcd.
An embedded quorum removes an entire external system to deploy, secure, and
operate. Patroni's `raft` (pysyncobj) mode proves the pattern is viable; we do it
natively and lighter.

**Rejected.** External DCS (operational weight) and single-monitor designs like
pg_auto_failover (the monitor is itself a SPOF and not a quorum).

---

## D5 — Rust + pgrx + openraft

**Decision.** Implement in Rust: the extension via **pgrx**, consensus via
**openraft** (async, event-driven Raft) hosted on a small embedded tokio runtime
inside the background worker.

**Why.** "Light on resources" rules out the JVM and argues against a Go control
plane; Rust gives a small static `.so` with no GC pauses in the failover path.
pgrx keeps us in the same toolchain as the ParadeDB-style stack already in use.
openraft leaves storage and transport to us (a single versioned `Decision` value
plus a tiny TCP/JSON RPC — both trivial here).

---

## D6 — Quorum-only, odd node counts

**Decision.** Support 3 and 5 nodes; refuse to pretend 2-node is safe.

**Why.** Raft needs a majority; 2 nodes can't form a safe majority on partition
(both think they're right, or neither can proceed). 3 tolerates 1 failure, 5
tolerates 2. We document this loudly rather than offering a footgun.

---

## D7 — Safety over availability by default

**Decision.** Default to **never two writable primaries**, even at the cost of a
brief write outage during failover. Synchronous (zero-loss) mode is opt-in.

**Why.** A search/cache can be rebuilt; a system of record that double-writes is
corrupted. Fencing + quorum + most-advanced-replica selection prioritize
correctness. Operators who want zero data loss enable quorum-sync and accept the
latency.
