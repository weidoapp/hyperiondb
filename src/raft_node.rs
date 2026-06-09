use std::collections::BTreeMap;
use std::path::Path;
use std::sync::mpsc::Receiver as StdReceiver;
use std::sync::Arc;
use std::time::Duration;

use openraft::{BasicNode, Config, Raft, RaftMetrics, ServerState, SnapshotPolicy};
use tokio::runtime::Runtime;
use tokio::sync::watch::Receiver as WatchReceiver;
use tokio::sync::OnceCell;

use crate::failover::Decision;
use crate::rpc::{self, GossipHandle, NetworkFactory, RaftSlot};
use crate::rtype::{Node, NodeId, TypeConfig};
use crate::store::{self, SharedDecision};

pub struct RaftHandle {
    runtime: Runtime,
    raft: Raft<TypeConfig>,
    metrics: WatchReceiver<RaftMetrics<NodeId, Node>>,
    decision: SharedDecision,
    gossip_out: GossipHandle,
    gossip_in: StdReceiver<(u64, Vec<u8>)>,
    members: BTreeMap<NodeId, BasicNode>,
}

impl RaftHandle {
    pub fn start(
        node_id: NodeId,
        listen_port: u16,
        peers: &[(u64, String)],
        raft_dir: &str,
        compact_threshold: u64,
    ) -> std::io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .on_thread_start(|| unsafe { block_all_signals() })
            .build()?;

        let listener = std::net::TcpListener::bind(("0.0.0.0", listen_port))?;
        listener.set_nonblocking(true)?;

        let members: BTreeMap<NodeId, BasicNode> = peers
            .iter()
            .map(|(id, addr)| (*id, BasicNode::new(addr.clone())))
            .collect();

        let (gossip_tx, gossip_in) = std::sync::mpsc::channel::<(u64, Vec<u8>)>();
        let raft_dir = raft_dir.to_string();
        let peers_owned = peers.to_vec();

        let (raft, metrics, decision, gossip_out) = runtime.block_on(async move {
            let (log_store, state_machine, decision) = store::open(Path::new(&raft_dir), node_id);

            let config = Config {
                cluster_name: "pg_replica".to_string(),
                heartbeat_interval: 250,
                election_timeout_min: 1000,
                election_timeout_max: 2000,
                snapshot_policy: SnapshotPolicy::LogsSinceLast(compact_threshold),
                max_in_snapshot_log_to_keep: 0,
                ..Default::default()
            }
            .validate()
            .expect("invalid raft config");

            let slot: RaftSlot = Arc::new(OnceCell::new());
            rpc::spawn_server(listener, slot.clone(), gossip_tx);
            let gossip_out = rpc::spawn_gossip_sender(node_id, peers_owned);

            let raft = Raft::new(
                node_id,
                Arc::new(config),
                NetworkFactory,
                log_store,
                state_machine,
            )
            .await
            .expect("raft init failed");
            let _ = slot.set(raft.clone());
            let metrics = raft.metrics();
            (raft, metrics, decision, gossip_out)
        });

        Ok(RaftHandle {
            runtime,
            raft,
            metrics,
            decision,
            gossip_out,
            gossip_in,
            members,
        })
    }

    pub fn bootstrap(&self) {
        let raft = self.raft.clone();
        let members = self.members.clone();
        self.runtime.spawn(async move {
            let _ = raft.initialize(members).await;
        });
    }

    pub fn is_leader(&self) -> bool {
        self.metrics.borrow().state.is_leader()
    }

    pub fn term(&self) -> u64 {
        self.metrics.borrow().current_term
    }

    pub fn leader_id(&self) -> u64 {
        self.metrics.borrow().current_leader.unwrap_or(0)
    }

    pub fn role_name(&self) -> &'static str {
        match self.metrics.borrow().state {
            ServerState::Leader => "leader",
            ServerState::Follower => "follower",
            ServerState::Candidate => "candidate",
            ServerState::Learner => "learner",
            ServerState::Shutdown => "shutdown",
        }
    }

    pub fn current_decision(&self) -> Option<Decision> {
        self.decision.current()
    }

    pub fn propose(&self, decision: Decision) {
        let raft = self.raft.clone();
        self.runtime.spawn(async move {
            let _ = tokio::time::timeout(
                Duration::from_millis(800),
                raft.client_write(decision),
            )
            .await;
        });
    }

    pub fn gossip_broadcast(&self, from: u64, payload: &[u8]) {
        self.gossip_out.broadcast(from, payload);
    }

    pub fn try_recv_gossip(&self) -> Option<(u64, Vec<u8>)> {
        self.gossip_in.try_recv().ok()
    }

    pub fn shutdown(&self) {
        let _ = self.runtime.block_on(self.raft.shutdown());
    }
}

unsafe fn block_all_signals() {
    let mut all: libc::sigset_t = std::mem::zeroed();
    let mut old: libc::sigset_t = std::mem::zeroed();
    libc::sigfillset(&mut all);
    libc::pthread_sigmask(libc::SIG_SETMASK, &all, &mut old);
}
