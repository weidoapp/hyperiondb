use crate::storage::{DiskStorage, Recovered};
use protobuf::Message as _;
use raft::prelude::*;
use raft::StateRole;
use std::path::PathBuf;

pub struct Applied {
    pub committed: Vec<Vec<u8>>,
    pub snapshot: Option<Vec<u8>>,
}

pub struct Node {
    raw: RawNode<DiskStorage>,
}

impl Node {
    pub fn new(node_id: u64, voters: Vec<u64>, raft_dir: PathBuf) -> (Self, Recovered) {
        let (storage, recovered) = DiskStorage::new(node_id, voters, raft_dir);
        let cfg = Config {
            id: node_id,
            election_tick: 10,
            heartbeat_tick: 3,
            max_size_per_msg: 1024 * 1024 * 1024,
            max_inflight_msgs: 256,
            applied: recovered.applied,
            pre_vote: true,
            check_quorum: true,
            ..Default::default()
        };
        let logger = slog::Logger::root(slog::Discard, slog::o!());
        let raw = RawNode::new(&cfg, storage, &logger).expect("raft init failed");
        (Node { raw }, recovered)
    }

    pub fn set_snapshot_data(&self, data: Vec<u8>) {
        self.raw.raft.raft_log.store.set_snapshot_data(data);
    }

    pub fn maybe_compact(&self, threshold: u64) -> Option<u64> {
        let applied = self.raw.raft.raft_log.applied;
        let store = &self.raw.raft.raft_log.store;
        let first = store.first_index().unwrap_or(1);
        let last = store.last_index().unwrap_or(0);
        if applied == last && applied > first && applied - first >= threshold {
            store.compact(applied);
            Some(applied)
        } else {
            None
        }
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

    pub fn is_leader(&self) -> bool {
        matches!(self.raw.raft.state, StateRole::Leader)
    }

    pub fn propose(&mut self, data: Vec<u8>) -> bool {
        self.raw.propose(vec![], data).is_ok()
    }

    pub fn drain_ready<F: FnMut(u64, Vec<u8>)>(&mut self, mut send: F) -> Applied {
        let mut applied = Applied {
            committed: Vec::new(),
            snapshot: None,
        };
        if !self.raw.has_ready() {
            return applied;
        }
        let store = self.raw.raft.raft_log.store.clone();
        let mut ready = self.raw.ready();

        if !ready.messages().is_empty() {
            emit(ready.take_messages(), &mut send);
        }
        if !ready.snapshot().is_empty() {
            let snapshot = ready.snapshot().clone();
            let data = snapshot.get_data().to_vec();
            store.apply_snapshot(snapshot);
            if !data.is_empty() {
                applied.snapshot = Some(data);
            }
        }
        collect_committed(ready.take_committed_entries(), &mut applied.committed);
        if !ready.entries().is_empty() {
            store.append(ready.entries());
        }
        if let Some(hs) = ready.hs() {
            store.set_hardstate(hs.clone());
        }
        if !ready.persisted_messages().is_empty() {
            emit(ready.take_persisted_messages(), &mut send);
        }

        let mut light_rd = self.raw.advance(ready);
        if let Some(commit) = light_rd.commit_index() {
            store.set_commit(commit);
        }
        emit(light_rd.take_messages(), &mut send);
        collect_committed(light_rd.take_committed_entries(), &mut applied.committed);
        self.raw.advance_apply();
        applied
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

fn collect_committed(entries: Vec<Entry>, out: &mut Vec<Vec<u8>>) {
    for entry in entries {
        if entry.get_entry_type() == EntryType::EntryNormal {
            let data = entry.get_data();
            if !data.is_empty() {
                out.push(data.to_vec());
            }
        }
    }
}
