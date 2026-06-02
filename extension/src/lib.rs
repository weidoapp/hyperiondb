use pgrx::bgworkers::{BackgroundWorker, BackgroundWorkerBuilder, SignalWakeFlags};
use pgrx::prelude::*;
use std::time::Duration;

mod config;

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
        .load();
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_replica_supervisor_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    pgrx::log!(
        "pg_replica: supervisor started (node_id={}, raft_port={}, peers=[{}])",
        config::node_id(),
        config::raft_port(),
        config::peers()
    );

    while BackgroundWorker::wait_latch(Some(Duration::from_secs(10))) {
        pgrx::log!("pg_replica: up");
    }

    pgrx::log!("pg_replica: supervisor shutting down");
}

#[pg_schema]
mod replica {
    use pgrx::prelude::*;

    #[pg_extern]
    fn status() -> String {
        format!(
            "pg_replica M1: node_id={} raft_port={} peers=[{}] (consensus not started)",
            crate::config::node_id(),
            crate::config::raft_port(),
            crate::config::peers()
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
        assert!(reported.contains("pg_replica M1"));
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec!["shared_preload_libraries = 'pg_replica'"]
    }
}
