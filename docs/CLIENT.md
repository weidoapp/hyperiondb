# Connecting clients (primary-following, no proxy)

pg_replica needs no router or VIP in front of it. Every node is an endpoint; the
client is handed all of them and finds the primary itself — exactly like a MongoDB
`mongodb://h1,h2,h3/?replicaSet=...` connection string.

## Why it just works

A `target_session_attrs=read-write` client decides "is this the primary?" by running
`SHOW transaction_read_only` on each host and keeping the one that returns `off`.
pg_replica's fence already sets that for us:

| node state | `transaction_read_only` | client verdict |
|---|---|---|
| authorized primary | `off` | connect here |
| standby (in recovery) | `on` | skip |
| fenced ex-primary / lost-quorum minority | `on` | skip |

So the client lands on the current authorized primary, and during a failover or a
loss-of-quorum window it finds **no** read-write host and fails fast — the app retries,
and there is never a write to a fenced node (no split-brain). On failover the only thing
the application does is reconnect.

The connection string (libpq keyword form):

```
host=10.0.0.1,10.0.0.2,10.0.0.3 port=5432 user=app dbname=weido target_session_attrs=read-write connect_timeout=2
```

## Rust — tokio-postgres (verified, see scripts/test-m6-routing.sh)

```rust
use std::str::FromStr;
use tokio_postgres::{Config, NoTls};

let config = Config::from_str(
    "host=10.0.0.1,10.0.0.2,10.0.0.3 port=5432 \
     user=app dbname=weido target_session_attrs=read-write connect_timeout=2",
)?;
let (client, connection) = config.connect(NoTls).await?; // lands on the primary
```

On a failed query after a failover, drop the client and call `connect` again — it
re-scans and lands on the new primary.

W. connection pool: https://github.com/djc/bb8 / https://github.com/fboulnois/nanopool

## psql / libpq / any libpq-based driver (psycopg, JDBC via pgjdbc, etc.)

```
psql "host=10.0.0.1,10.0.0.2,10.0.0.3 port=5432 user=app dbname=weido target_session_attrs=read-write"
```

## Read scaling (optional)

`target_session_attrs=read-only` (or `prefer-standby` on PG 14+) routes a connection to
a standby instead — useful for read-heavy / ParadeDB search queries that can tolerate
replication lag. Use a separate read-only pool for those.
