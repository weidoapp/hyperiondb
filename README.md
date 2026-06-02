# HyperionDb

[image](media/header.jpg)

A PostgreSQL extension that gives a small cluster of **vanilla Postgres** nodes
**automatic, consensus-driven failover** — full-cluster replication (tables,
roles, DDL, *everything*) with a **built-in Raft group** and **no external
dependencies**: no etcd, no Consul, no Kubernetes.

One job: keep a single leader elected and the data byte-identical across N nodes,
and fail over automatically when the leader dies. Do that one job well.

---

## The one idea

**Don't reinvent replication.** Postgres already ships **physical (WAL) streaming
replication**, which copies *everything* byte-for-byte — heap, indexes, and the
**shared catalog `pg_authid`** (i.e. roles/users and their SCRAM verifiers).
That is exactly why physical replicas have the same roles as the primary, while
logical replication / active-active (pgactive) do not.

`pg_replica` adds the *only* piece Postgres itself lacks: **automatic leader
election and failover**, using an **embedded Raft quorum** instead of an external
DCS.

| Plane | Who does it |
|-------|-------------|
| **Data** (tables, indexes, roles, DDL) | Postgres streaming replication — untouched, battle-tested |
| **Leadership & failover** | Embedded Raft, running inside a Postgres background worker |
| **Process lifecycle** (start/restart Postgres) | Your existing supervisor — systemd or Docker restart policy |

Result: roles, DDL, and data stay consistent on every node, and a dead primary
is replaced in seconds — with no human, no etcd, no Kubernetes.

> The naive version of this project is "use Raft to replicate the data." That is
> the wrong design and we explicitly reject it — see
> [docs/DECISIONS.md](docs/DECISIONS.md#d1-raft-replicates-control-state-not-data).
> Raft replicates only the tiny **cluster-control state** (who is leader, who is
> in the group, failover decisions). The bulk data rides Postgres WAL.

---

## Goals / non-goals

**Goals**
- Automatic failover on a 3- or 5-node cluster (Raft majority quorum).
- Full-cluster fidelity: roles, GRANTs, DDL, extensions, data — all replicated
  (free, via physical replication).
- Zero external coordination services (Raft is embedded).
- Lightweight: one `.so` extension + Postgres; no JVM, no Go control plane, no k8s.
- Safe by default: quorum-gated, fences the old primary, picks the most-advanced
  replica, rejoins the loser with `pg_rewind`.
- Operable from SQL: `SELECT pg_replica.status();`, `pg_replica.failover()`, etc.

**Non-goals (v1)**
- Sharding / horizontal write scale-out → that is Citus, a different axis.
- Connection pooling / proxy → recommend HAProxy or libpq multi-host
  (`target_session_attrs=read-write`). pg_replica only *publishes* who the primary is.
- Backups / PITR → recommend pgBackRest or wal-g.
- Logical / multi-master replication → out of scope by design.

---

## Positioning (honest prior art)

| Tool | Consensus | External deps | Form factor |
|------|-----------|---------------|-------------|
| **CloudNativePG** | k8s control plane | **Kubernetes required** | operator |
| **Patroni** | etcd/Consul/k8s — *or* `pysyncobj` Raft mode | DCS (or its raft lib) | Python agent |
| **pg_auto_failover** | single **monitor** node (not quorum) | a monitor Postgres | C ext + agent |
| **Stolon** | external store (etcd/consul) | DCS | Go agents |
| **repmgr** | none (manual/assisted) | — | C ext + CLI |
| **pg_replica** (this) | **embedded Raft quorum** | **none** | **Postgres extension** |

The niche: embedded quorum (unlike pg_auto_failover's single monitor), **no
external DCS** (unlike Patroni-etcd / Stolon), **no Kubernetes** (unlike CNPG),
shipped as a plain Postgres extension. Closest existing thing is Patroni's
`raft` DCS mode — pg_replica aims to be that idea, but native, in-process, and Rust-light.

---

## Do you actually need this?

Straight talk before you build a distributed system: **if your Postgres is a
derived, rebuildable cache (e.g. a search index sourced from another database),
you probably don't need HA at all** — rebuild beats replicate, and a shared
static role per node is simpler than everything here.

Build `pg_replica` when Postgres is a **system of record** that must survive node
loss with **no manual ops**, *and* you refuse to run etcd/Consul/Kubernetes. If
either of those isn't true, use the simpler option (rebuild, or Patroni/pg_auto_failover).

---

## Status

**Design / planning.** No code yet. Start with:
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — components, failover flow, fencing, the hard problems.
- [docs/DECISIONS.md](docs/DECISIONS.md) — the load-bearing design choices and why.
- [docs/ROADMAP.md](docs/ROADMAP.md) — phased milestones with "done" criteria.
