use pgrx::bgworkers::{BackgroundWorker, BackgroundWorkerBuilder, BgWorkerStartTime, SignalWakeFlags};
use pgrx::prelude::*;
use std::time::Duration;

mod apply;
mod config;
mod raft_node;
mod state;
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

    let mut node = raft_node::Node::new(node_id, voters);
    let mut last = String::new();
    let mut promoted = false;
    let mut fenced = false;
    let mut rejoining = false;
    let mut applied_leader: u64 = 0;

    while BackgroundWorker::wait_latch(Some(Duration::from_millis(100))) {
        while let Some((_from, payload)) = net.try_recv() {
            node.step_bytes(&payload);
        }
        node.tick();
        node.drain_ready(|to, bytes| net.send(to, bytes));

        let role = node.role_name();
        let leader = node.leader_id();
        let repl = if role == "leader" {
            String::from("primary")
        } else if leader != 0 {
            match pg_members.iter().find(|member| member.id == leader) {
                Some(member) => format!("standby<-{}", member.addr),
                None => String::from("standby<-?"),
            }
        } else {
            String::from("electing")
        };

        let in_recovery = unsafe { pg_sys::RecoveryInProgress() };
        let snapshot = format!(
            "{} term={} leader={} | repl={} in_recovery={}",
            role,
            node.term(),
            leader,
            repl,
            in_recovery
        );
        if snapshot != last {
            pgrx::log!("pg_replica: node {} -> {}", node_id, snapshot);
            state::write(node_id, &snapshot);

            if role == "leader" && in_recovery && !promoted {
                pgrx::log!("pg_replica: node {} APPLY promote (standby -> primary)", node_id);
                match apply::run_sql(&psql, &my_host, &my_port, "SELECT pg_promote(false)") {
                    Ok(_) => {
                        promoted = true;
                        let _ = apply::run_sql(
                            &psql,
                            &my_host,
                            &my_port,
                            "ALTER SYSTEM SET default_transaction_read_only = off",
                        );
                        let _ = apply::run_sql(&psql, &my_host, &my_port, "SELECT pg_reload_conf()");
                        fenced = false;
                    }
                    Err(error) => {
                        pgrx::log!("pg_replica: node {} promote failed: {}", node_id, error)
                    }
                }
            } else if role == "follower" && !in_recovery && leader != 0 {
                if !fenced {
                    pgrx::log!(
                        "pg_replica: node {} FENCE deposed primary -> read-only (leader is {})",
                        node_id,
                        leader
                    );
                    if apply::run_sql(
                        &psql,
                        &my_host,
                        &my_port,
                        "ALTER SYSTEM SET default_transaction_read_only = on",
                    )
                    .is_ok()
                    {
                        let _ = apply::run_sql(&psql, &my_host, &my_port, "SELECT pg_reload_conf()");
                        fenced = true;
                    }
                }
                if !rejoining && !rejoin_script.is_empty() {
                    if let Some(member) = pg_members.iter().find(|member| member.id == leader) {
                        let (leader_host, leader_port) = apply::split_host_port(&member.addr);
                        let datadir =
                            apply::run_sql(&psql, &my_host, &my_port, "SHOW data_directory")
                                .unwrap_or_default();
                        if !datadir.is_empty() {
                            pgrx::log!(
                                "pg_replica: node {} REJOIN spawn (rewind against leader {} {})",
                                node_id,
                                leader,
                                member.addr
                            );
                            apply::spawn_rejoin(
                                &rejoin_script,
                                &pgbin,
                                &datadir,
                                &leader_host,
                                &leader_port,
                                node_id,
                            );
                            rejoining = true;
                        }
                    }
                }
            } else if role == "follower" && in_recovery && leader != 0 && leader != applied_leader {
                if let Some(member) = pg_members.iter().find(|member| member.id == leader) {
                    let (leader_host, leader_port) = apply::split_host_port(&member.addr);
                    let conninfo = format!(
                        "host={} port={} user=replicator application_name=node{}",
                        leader_host, leader_port, node_id
                    );
                    pgrx::log!(
                        "pg_replica: node {} APPLY repoint standby -> leader {} ({})",
                        node_id,
                        leader,
                        member.addr
                    );
                    match apply::run_sql(
                        &psql,
                        &my_host,
                        &my_port,
                        &format!("ALTER SYSTEM SET primary_conninfo = '{}'", conninfo),
                    ) {
                        Ok(_) => {
                            let _ =
                                apply::run_sql(&psql, &my_host, &my_port, "SELECT pg_reload_conf()");
                            applied_leader = leader;
                        }
                        Err(error) => {
                            pgrx::log!("pg_replica: node {} repoint failed: {}", node_id, error)
                        }
                    }
                }
            }

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
