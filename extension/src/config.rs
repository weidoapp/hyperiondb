use pgrx::guc::{GucContext, GucFlags, GucRegistry, GucSetting};
use std::ffi::CString;

pub static NODE_ID: GucSetting<i32> = GucSetting::<i32>::new(0);
pub static RAFT_PORT: GucSetting<i32> = GucSetting::<i32>::new(7400);
pub static PEERS: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);

pub fn init() {
    GucRegistry::define_int_guc(
        c"pg_replica.node_id",
        c"This node's Raft id, unique across the cluster.",
        c"A positive integer set in postgresql.conf. 0 means unconfigured.",
        &NODE_ID,
        0,
        i32::MAX,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_replica.raft_port",
        c"TCP port the Raft peer transport listens on.",
        c"Each node binds this port for peer-to-peer consensus traffic.",
        &RAFT_PORT,
        1,
        65535,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.peers",
        c"Cluster members as a comma-separated id@host:port list.",
        c"Example: 1@10.0.0.1:7400,2@10.0.0.2:7400,3@10.0.0.3:7400",
        &PEERS,
        GucContext::Postmaster,
        GucFlags::default(),
    );
}

pub fn node_id() -> i32 {
    NODE_ID.get()
}

pub fn raft_port() -> i32 {
    RAFT_PORT.get()
}

pub fn peers() -> String {
    PEERS
        .get()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default()
}
