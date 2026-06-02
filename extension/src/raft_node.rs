use protobuf::Message as _;
use raft::prelude::*;
use raft::storage::MemStorage;
use raft::StateRole;

pub struct Node {
    raw: RawNode<MemStorage>,
}

impl Node {
    pub fn new(node_id: u64, voters: Vec<u64>) -> Self {
        let storage = MemStorage::new_with_conf_state(ConfState::from((voters, vec![])));
        let cfg = Config {
            id: node_id,
            election_tick: 10,
            heartbeat_tick: 3,
            max_size_per_msg: 1024 * 1024 * 1024,
            max_inflight_msgs: 256,
            applied: 0,
            ..Default::default()
        };
        let logger = slog::Logger::root(slog::Discard, slog::o!());
        let raw = RawNode::new(&cfg, storage, &logger).expect("raft init failed");
        Node { raw }
    }

    pub fn tick(&mut self) {
        self.raw.tick();
    }

    pub fn step_bytes(&mut self, bytes: &[u8]) {
        let mut msg = Message::new();
        if msg.merge_from_bytes(bytes).is_ok() {
            let _ = self.raw.step(msg);
        }
    }

    pub fn drain_ready<F: FnMut(u64, Vec<u8>)>(&mut self, mut send: F) {
        if !self.raw.has_ready() {
            return;
        }
        let store = self.raw.raft.raft_log.store.clone();
        let mut ready = self.raw.ready();

        if !ready.messages().is_empty() {
            emit(ready.take_messages(), &mut send);
        }
        if !ready.snapshot().is_empty() {
            let _ = store.wl().apply_snapshot(ready.snapshot().clone());
        }
        let _ = ready.take_committed_entries();
        if !ready.entries().is_empty() {
            let _ = store.wl().append(ready.entries());
        }
        if let Some(hs) = ready.hs() {
            store.wl().set_hardstate(hs.clone());
        }
        if !ready.persisted_messages().is_empty() {
            emit(ready.take_persisted_messages(), &mut send);
        }

        let mut light_rd = self.raw.advance(ready);
        if let Some(commit) = light_rd.commit_index() {
            store.wl().mut_hard_state().set_commit(commit);
        }
        emit(light_rd.take_messages(), &mut send);
        let _ = light_rd.take_committed_entries();
        self.raw.advance_apply();
    }

    pub fn role_name(&self) -> &'static str {
        match self.raw.raft.state {
            StateRole::Leader => "leader",
            StateRole::Follower => "follower",
            StateRole::Candidate => "candidate",
            StateRole::PreCandidate => "precandidate",
        }
    }

    pub fn term(&self) -> u64 {
        self.raw.raft.term
    }

    pub fn leader_id(&self) -> u64 {
        self.raw.raft.leader_id
    }
}

fn emit<F: FnMut(u64, Vec<u8>)>(messages: Vec<Message>, send: &mut F) {
    for msg in messages {
        let to = msg.to;
        if let Ok(bytes) = msg.write_to_bytes() {
            send(to, bytes);
        }
    }
}
