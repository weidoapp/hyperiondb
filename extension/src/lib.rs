use pgrx::bgworkers::{BackgroundWorker, BackgroundWorkerBuilder, BgWorkerStartTime, SignalWakeFlags};
use pgrx::prelude::*;
use std::collections::HashMap;
use std::time::{Duration, Instant};

mod apply;
mod config;
mod failover;
mod raft_node;
mod state;
mod storage;
mod transport;

pgrx::pg_module_magic!();

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    if !unsafe { pg_sys::process_shared_preload_libraries_in_progress } {
        return;
    }

    config::init();

    BackgroundWorkerBuilder::new("pg_replica supervisor")
        .set_function("pg_replica_supervisor_main")
        .set_library("pg_replica")
        .set_restart_time(Some(Duration::from_secs(5)))
        .set_start_time(BgWorkerStartTime::ConsistentState)
        .load();
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_replica_supervisor_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);

    let node_id = config::node_id() as u64;
    let port = config::raft_port() as u16;
    let peers = transport::parse_peers(&config::peers());
    let voters: Vec<u64> = peers.iter().map(|peer| peer.id).collect();

    pgrx::log!(
        "pg_replica: supervisor started (node_id={}, raft_port={}, voters={:?})",
        node_id,
        port,
        voters
    );

    if node_id == 0 || voters.is_empty() {
        pgrx::log!("pg_replica: not configured (node_id/peers unset); idling");
        while BackgroundWorker::wait_latch(Some(Duration::from_secs(10))) {}
        return;
    }

    let net = match transport::Transport::start(node_id, port, &peers) {
        Ok(net) => net,
        Err(error) => {
            pgrx::log!("pg_replica: transport bind failed on {}: {}", port, error);
            return;
        }
    };

    let pg_members = transport::parse_peers(&config::pg_addrs());
    let psql = config::psql();
    let pgbin = apply::parent_dir(&psql);
    let rejoin_script = config::rejoin_script();
    let (my_host, my_port) = apply::split_host_port(
        &pg_members
            .iter()
            .find(|member| member.id == node_id)
            .map(|member| member.addr.clone())
            .unwrap_or_default(),
    );

    let majority = voters.len() / 2 + 1;
    let raft_dir = config::raft_dir();
    let heartbeat_file = format!("{}/pg_replica_hb_{}", raft_dir, node_id);
    let watchdog_script = config::watchdog_script();
    if !watchdog_script.is_empty() {
        if apply::spawn_watchdog(&watchdog_script, &psql, &my_host, &my_port, &heartbeat_file, node_id)
        {
            pgrx::log!("pg_replica: node {} deadman watchdog spawned", node_id);
        }
    }

    let (mut node, recovered) =
        raft_node::Node::new(node_id, voters, std::path::PathBuf::from(&raft_dir));
    pgrx::log!(
        "pg_replica: node {} raft storage {}",
        node_id,
        if recovered {
            "recovered from disk"
        } else {
            "initialized fresh"
        }
    );
    let mut last = String::new();
    let mut peers_lsn: HashMap<u64, (u64, bool, Instant)> = HashMap::new();
    let mut last_heard: HashMap<u64, Instant> = HashMap::new();
    let mut peers_reconfirm: HashMap<u64, bool> = HashMap::new();
    let mut reconfirm_pending = false;
    let mut decided: Option<failover::Decision> = None;
    let mut last_proposed: (u64, u64) = (0, 0);
    let mut promoted = false;
    let mut rejoining = false;
    let mut applied_primary: u64 = 0;
    let mut applied_read_only: Option<bool> = None;
    let mut authorized_since: Option<Instant> = None;
    let mut ticks: u64 = 0;
    let gossip_every: u64 = 5;
    let dead_timeout = Duration::from_millis(2500);
    let confirm_window = Duration::from_millis(1500);
    let quorum_lease = Duration::from_millis(1200);
    let stall_threshold = Duration::from_millis(1500);
    let mut last_loop = Instant::now();

    while BackgroundWorker::wait_latch(Some(Duration::from_millis(100))) {
        let loop_now = Instant::now();
        if loop_now.duration_since(last_loop) > stall_threshold {
            applied_read_only = None;
            authorized_since = None;
            reconfirm_pending = true;
        }
        last_loop = loop_now;
        apply::write_heartbeat(&heartbeat_file);

        while let Some((from, payload)) = net.try_recv() {
            last_heard.insert(from, Instant::now());
            if payload.is_empty() {
                continue;
            }
            match payload[0] {
                failover::KIND_RAFT => node.step_bytes(&payload[1..]),
                failover::KIND_GOSSIP => {
                    if let Some(gossip) = failover::decode_gossip(&payload[1..]) {
                        peers_lsn.insert(from, (gossip.lsn, gossip.in_recovery, Instant::now()));
                        peers_reconfirm.insert(from, gossip.reconfirm);
                    }
                }
                _ => {}
            }
        }

        node.tick();
        let committed = node.drain_ready(|to, bytes| {
            let mut framed = Vec::with_capacity(1 + bytes.len());
            framed.push(failover::KIND_RAFT);
            framed.extend_from_slice(&bytes);
            net.send(to, framed);
        });

        let mut newest: Option<failover::Decision> = None;
        for data in &committed {
            if let Some(decision) = failover::decode_decision(data) {
                if newest.map_or(true, |current| decision.seq > current.seq) {
                    newest = Some(decision);
                }
            }
        }
        if let Some(decision) = newest {
            if decided.map_or(true, |current| decision.seq > current.seq) {
                decided = Some(decision);
                promoted = false;
                rejoining = false;
                applied_primary = 0;
                reconfirm_pending = false;
                pgrx::log!(
                    "pg_replica: node {} DECISION seq={} primary={}",
                    node_id,
                    decision.seq,
                    decision.primary
                );
            }
        }

        let in_recovery = unsafe { pg_sys::RecoveryInProgress() };

        ticks += 1;
        if ticks % gossip_every == 0 {
            let lsn = apply::wal_lsn(&psql, &my_host, &my_port, in_recovery);
            peers_lsn.insert(node_id, (lsn, in_recovery, Instant::now()));
            let payload = failover::encode_gossip(lsn, in_recovery, reconfirm_pending);
            let mut framed = Vec::with_capacity(1 + payload.len());
            framed.push(failover::KIND_GOSSIP);
            framed.extend_from_slice(&payload);
            net.broadcast(&framed);
        }

        if node.is_leader() {
            let now = Instant::now();
            let live: Vec<(u64, u64, bool)> = peers_lsn
                .iter()
                .filter(|(id, (_, _, seen))| {
                    **id == node_id || now.duration_since(*seen) < dead_timeout
                })
                .map(|(id, (lsn, recovery, _))| (*id, *lsn, *recovery))
                .collect();

            let current_primary = decided.map(|decision| decision.primary).unwrap_or(0);
            let primary_alive =
                current_primary != 0 && live.iter().any(|candidate| candidate.0 == current_primary);
            let needs_reconfirm = reconfirm_pending
                || live
                    .iter()
                    .any(|member| peers_reconfirm.get(&member.0).copied().unwrap_or(false));

            let candidate = if decided.is_none() {
                live.iter()
                    .filter(|member| !member.2)
                    .map(|member| member.0)
                    .min()
            } else if !primary_alive {
                failover::choose_primary(&live)
            } else if needs_reconfirm {
                Some(current_primary)
            } else {
                None
            };

            if live.len() >= majority {
                if let Some(candidate) = candidate {
                    let seq = decided.map(|decision| decision.seq).unwrap_or(0) + 1;
                    if last_proposed != (seq, candidate) {
                        let decision = failover::Decision {
                            seq,
                            primary: candidate,
                        };
                        if node.propose(failover::encode_decision(decision)) {
                            last_proposed = (seq, candidate);
                            pgrx::log!(
                                "pg_replica: node {} PROPOSE seq={} primary={} live={:?}",
                                node_id,
                                seq,
                                candidate,
                                live
                            );
                        }
                    }
                }
            }
        }

        let decided_primary = decided.map(|decision| decision.primary).unwrap_or(0);
        let contact_now = Instant::now();
        let reachable = last_heard
            .iter()
            .filter(|(id, seen)| {
                **id != node_id && contact_now.duration_since(**seen) < quorum_lease
            })
            .count();
        let quorum_ok = 1 + reachable >= majority;

        if in_recovery {
            applied_read_only = None;
            authorized_since = None;
            if decided_primary == node_id {
                if !promoted {
                    pgrx::log!("pg_replica: node {} APPLY promote (standby -> primary)", node_id);
                    match apply::run_sql(&psql, &my_host, &my_port, "SELECT pg_promote(false)") {
                        Ok(_) => promoted = true,
                        Err(error) => {
                            pgrx::log!("pg_replica: node {} promote failed: {}", node_id, error)
                        }
                    }
                }
            } else if decided_primary != 0 && applied_primary != decided_primary {
                if let Some(member) = pg_members.iter().find(|member| member.id == decided_primary) {
                    let (primary_host, primary_port) = apply::split_host_port(&member.addr);
                    let conninfo = format!(
                        "host={} port={} user=replicator application_name=node{}",
                        primary_host, primary_port, node_id
                    );
                    pgrx::log!(
                        "pg_replica: node {} APPLY repoint standby -> primary {} ({})",
                        node_id,
                        decided_primary,
                        member.addr
                    );
                    if apply::run_sql(
                        &psql,
                        &my_host,
                        &my_port,
                        &format!("ALTER SYSTEM SET primary_conninfo = '{}'", conninfo),
                    )
                    .is_ok()
                    {
                        let _ = apply::run_sql(&psql, &my_host, &my_port, "SELECT pg_reload_conf()");
                        applied_primary = decided_primary;
                    }
                }
            }
        } else {
            let raw_auth = match decided {
                None => true,
                Some(decision) => {
                    decision.primary == node_id && quorum_ok && !reconfirm_pending
                }
            };
            let authorized = if !raw_auth {
                authorized_since = None;
                false
            } else if decided.is_none() || applied_read_only == Some(false) {
                authorized_since = Some(Instant::now());
                true
            } else {
                let since = *authorized_since.get_or_insert_with(Instant::now);
                Instant::now().duration_since(since) >= confirm_window
            };
            let want_read_only = !authorized;
            if applied_read_only != Some(want_read_only) {
                let sql = if want_read_only {
                    "ALTER SYSTEM SET default_transaction_read_only = on"
                } else {
                    "ALTER SYSTEM SET default_transaction_read_only = off"
                };
                if apply::run_sql(&psql, &my_host, &my_port, sql).is_ok() {
                    let _ = apply::run_sql(&psql, &my_host, &my_port, "SELECT pg_reload_conf()");
                    applied_read_only = Some(want_read_only);
                    pgrx::log!(
                        "pg_replica: node {} {} (decided_primary={} quorum_ok={})",
                        node_id,
                        if want_read_only {
                            "FENCE -> read-only"
                        } else {
                            "UNFENCE -> read-write"
                        },
                        decided_primary,
                        quorum_ok
                    );
                }
            }

            if !authorized
                && decided_primary != 0
                && decided_primary != node_id
                && !rejoining
                && !rejoin_script.is_empty()
            {
                if let Some(member) = pg_members.iter().find(|member| member.id == decided_primary) {
                    let (primary_host, primary_port) = apply::split_host_port(&member.addr);
                    let datadir = apply::run_sql(&psql, &my_host, &my_port, "SHOW data_directory")
                        .unwrap_or_default();
                    if !datadir.is_empty() {
                        pgrx::log!(
                            "pg_replica: node {} REJOIN spawn (rewind against primary {} {})",
                            node_id,
                            decided_primary,
                            member.addr
                        );
                        apply::spawn_rejoin(
                            &rejoin_script,
                            &pgbin,
                            &datadir,
                            &primary_host,
                            &primary_port,
                            node_id,
                        );
                        rejoining = true;
                    }
                }
            }
        }

        let repl = if decided_primary == node_id {
            String::from("primary")
        } else if decided_primary != 0 {
            match pg_members.iter().find(|member| member.id == decided_primary) {
                Some(member) => format!("standby<-{}", member.addr),
                None => String::from("standby<-?"),
            }
        } else {
            String::from("bootstrap")
        };

        let snapshot = format!(
            "{} term={} leader={} decided_primary={} seq={} quorum={} read_only={} reconfirm={} | repl={} in_recovery={}",
            node.role_name(),
            node.term(),
            node.leader_id(),
            decided_primary,
            decided.map(|decision| decision.seq).unwrap_or(0),
            quorum_ok,
            applied_read_only == Some(true),
            reconfirm_pending,
            repl,
            in_recovery
        );
        if snapshot != last {
            pgrx::log!("pg_replica: node {} -> {}", node_id, snapshot);
            state::write(node_id, &snapshot);
            last = snapshot;
        }
    }

    state::write(node_id, "stopped");
    pgrx::log!("pg_replica: supervisor shutting down");
}

#[pg_schema]
mod replica {
    use pgrx::prelude::*;

    #[pg_extern]
    fn status() -> String {
        let node_id = crate::config::node_id();
        let live = crate::state::read(node_id as u64)
            .unwrap_or_else(|| String::from("consensus not started"));
        format!(
            "pg_replica node_id={} raft_port={} peers=[{}] | {}",
            node_id,
            crate::config::raft_port(),
            crate::config::peers(),
            live
        )
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn status_is_reported() {
        let reported = Spi::get_one::<String>("SELECT replica.status()")
            .expect("SPI failed")
            .expect("status() returned NULL");
        assert!(reported.contains("node_id="));
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec!["shared_preload_libraries = 'pg_replica'"]
    }
}
