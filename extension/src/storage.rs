use protobuf::Message as _;
use raft::prelude::*;
use raft::storage::MemStorage;
use raft::{GetEntriesContext, RaftState, Storage};
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Clone)]
pub struct DiskStorage {
    mem: MemStorage,
    file: Arc<PathBuf>,
}

impl DiskStorage {
    pub fn new(node_id: u64, voters: Vec<u64>, dir: PathBuf) -> (Self, bool) {
        let file = dir.join(format!("pg_replica_raft_{}.bin", node_id));
        let mem = MemStorage::new();

        let recovered = match load(&file) {
            Some((hard_state, conf_state, entries)) => {
                let mut core = mem.wl();
                core.set_conf_state(conf_state);
                core.set_hardstate(hard_state);
                if !entries.is_empty() {
                    let _ = core.append(&entries);
                }
                true
            }
            None => {
                mem.wl()
                    .set_conf_state(ConfState::from((voters, vec![])));
                false
            }
        };

        (
            DiskStorage {
                mem,
                file: Arc::new(file),
            },
            recovered,
        )
    }

    pub fn append(&self, entries: &[Entry]) {
        if entries.is_empty() {
            return;
        }
        let _ = self.mem.wl().append(entries);
        self.persist();
    }

    pub fn set_hardstate(&self, hard_state: HardState) {
        self.mem.wl().set_hardstate(hard_state);
        self.persist();
    }

    pub fn apply_snapshot(&self, snapshot: Snapshot) {
        let _ = self.mem.wl().apply_snapshot(snapshot);
        self.persist();
    }

    pub fn set_commit(&self, commit: u64) {
        self.mem.wl().mut_hard_state().set_commit(commit);
        self.persist();
    }

    fn persist(&self) {
        let state = match self.mem.initial_state() {
            Ok(state) => state,
            Err(_) => return,
        };
        let first = self.mem.first_index().unwrap_or(1);
        let last = self.mem.last_index().unwrap_or(0);
        let entries = if last >= first {
            self.mem
                .entries(first, last + 1, None::<u64>, GetEntriesContext::empty(false))
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        atomic_write(&self.file, &encode(&state.hard_state, &state.conf_state, &entries));
    }
}

impl Storage for DiskStorage {
    fn initial_state(&self) -> raft::Result<RaftState> {
        self.mem.initial_state()
    }

    fn entries(
        &self,
        low: u64,
        high: u64,
        max_size: impl Into<Option<u64>>,
        context: GetEntriesContext,
    ) -> raft::Result<Vec<Entry>> {
        self.mem.entries(low, high, max_size, context)
    }

    fn term(&self, idx: u64) -> raft::Result<u64> {
        self.mem.term(idx)
    }

    fn first_index(&self) -> raft::Result<u64> {
        self.mem.first_index()
    }

    fn last_index(&self) -> raft::Result<u64> {
        self.mem.last_index()
    }

    fn snapshot(&self, request_index: u64, to: u64) -> raft::Result<Snapshot> {
        self.mem.snapshot(request_index, to)
    }
}

fn encode(hard_state: &HardState, conf_state: &ConfState, entries: &[Entry]) -> Vec<u8> {
    let mut buf = Vec::new();
    put_frame(&mut buf, &hard_state.write_to_bytes().unwrap_or_default());
    put_frame(&mut buf, &conf_state.write_to_bytes().unwrap_or_default());
    buf.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    for entry in entries {
        put_frame(&mut buf, &entry.write_to_bytes().unwrap_or_default());
    }
    buf
}

fn load(path: &Path) -> Option<(HardState, ConfState, Vec<Entry>)> {
    let data = fs::read(path).ok()?;
    let mut pos = 0usize;

    let mut hard_state = HardState::new();
    hard_state.merge_from_bytes(take_frame(&data, &mut pos)?).ok()?;

    let mut conf_state = ConfState::new();
    conf_state.merge_from_bytes(take_frame(&data, &mut pos)?).ok()?;

    let count = take_u32(&data, &mut pos)? as usize;
    let mut entries = Vec::with_capacity(count);
    for _ in 0..count {
        let mut entry = Entry::new();
        entry.merge_from_bytes(take_frame(&data, &mut pos)?).ok()?;
        entries.push(entry);
    }

    Some((hard_state, conf_state, entries))
}

fn put_frame(buf: &mut Vec<u8>, bytes: &[u8]) {
    buf.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    buf.extend_from_slice(bytes);
}

fn take_u32(data: &[u8], pos: &mut usize) -> Option<u32> {
    if *pos + 4 > data.len() {
        return None;
    }
    let value = u32::from_be_bytes(data[*pos..*pos + 4].try_into().ok()?);
    *pos += 4;
    Some(value)
}

fn take_frame<'a>(data: &'a [u8], pos: &mut usize) -> Option<&'a [u8]> {
    let len = take_u32(data, pos)? as usize;
    if *pos + len > data.len() {
        return None;
    }
    let slice = &data[*pos..*pos + len];
    *pos += len;
    Some(slice)
}

fn atomic_write(path: &Path, bytes: &[u8]) {
    let tmp = path.with_extension("tmp");
    if let Ok(mut file) = File::create(&tmp) {
        if file.write_all(bytes).is_ok() && file.sync_all().is_ok() {
            let _ = fs::rename(&tmp, path);
        }
    }
}
