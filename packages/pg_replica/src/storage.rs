use protobuf::Message as _;
use raft::prelude::*;
use raft::storage::MemStorage;
use raft::{GetEntriesContext, RaftState, Storage};
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

struct SnapState {
    index: u64,
    term: u64,
    data: Vec<u8>,
}

pub struct Recovered {
    pub fresh: bool,
    pub applied: u64,
    pub decision: Option<Vec<u8>>,
}

#[derive(Clone)]
pub struct DiskStorage {
    mem: MemStorage,
    file: Arc<PathBuf>,
    snap: Arc<Mutex<SnapState>>,
}

impl DiskStorage {
    pub fn new(node_id: u64, voters: Vec<u64>, dir: PathBuf) -> (Self, Recovered) {
        let file = dir.join(format!("pg_replica_raft_{}.bin", node_id));
        let mem = MemStorage::new();
        let mut snap = SnapState {
            index: 0,
            term: 0,
            data: Vec::new(),
        };
        let mut recovered = Recovered {
            fresh: true,
            applied: 0,
            decision: None,
        };

        match load(&file) {
            Some(loaded) => {
                {
                    let mut core = mem.wl();
                    if loaded.snap_index > 0 {
                        let mut snapshot = Snapshot::default();
                        let meta = snapshot.mut_metadata();
                        meta.index = loaded.snap_index;
                        meta.term = loaded.snap_term;
                        meta.set_conf_state(loaded.conf_state.clone());
                        snapshot.data = loaded.snap_data.clone().into();
                        let _ = core.apply_snapshot(snapshot);
                    } else {
                        core.set_conf_state(loaded.conf_state.clone());
                    }
                    core.set_hardstate(loaded.hard_state.clone());
                    if !loaded.entries.is_empty() {
                        let _ = core.append(&loaded.entries);
                    }
                }
                recovered.fresh = false;
                recovered.applied = loaded.snap_index;
                if !loaded.snap_data.is_empty() {
                    recovered.decision = Some(loaded.snap_data.clone());
                }
                snap = SnapState {
                    index: loaded.snap_index,
                    term: loaded.snap_term,
                    data: loaded.snap_data,
                };
            }
            None => {
                mem.wl()
                    .set_conf_state(ConfState::from((voters, vec![])));
            }
        }

        (
            DiskStorage {
                mem,
                file: Arc::new(file),
                snap: Arc::new(Mutex::new(snap)),
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
        let index = snapshot.get_metadata().index;
        let term = snapshot.get_metadata().term;
        let data = snapshot.get_data().to_vec();
        let _ = self.mem.wl().apply_snapshot(snapshot);
        {
            let mut snap = self.snap.lock().unwrap();
            snap.index = index;
            snap.term = term;
            if !data.is_empty() {
                snap.data = data;
            }
        }
        self.persist();
    }

    pub fn set_commit(&self, commit: u64) {
        self.mem.wl().mut_hard_state().set_commit(commit);
        self.persist();
    }

    pub fn set_snapshot_data(&self, data: Vec<u8>) {
        self.snap.lock().unwrap().data = data;
        self.persist();
    }

    pub fn compact(&self, up_to: u64) {
        let term = self.mem.term(up_to).unwrap_or(0);
        let conf_state = match self.mem.initial_state() {
            Ok(state) => state.conf_state,
            Err(_) => return,
        };
        let data = self.snap.lock().unwrap().data.clone();

        let mut snapshot = Snapshot::default();
        {
            let meta = snapshot.mut_metadata();
            meta.index = up_to;
            meta.term = term;
            meta.set_conf_state(conf_state);
        }
        snapshot.data = data.clone().into();

        if self.mem.wl().apply_snapshot(snapshot).is_ok() {
            let mut snap = self.snap.lock().unwrap();
            snap.index = up_to;
            snap.term = term;
            snap.data = data;
            drop(snap);
            self.persist();
        }
    }

    fn persist(&self) {
        let state = match self.mem.initial_state() {
            Ok(state) => state,
            Err(_) => return,
        };
        let (snap_index, snap_term, snap_data) = {
            let snap = self.snap.lock().unwrap();
            (snap.index, snap.term, snap.data.clone())
        };
        let last = self.mem.last_index().unwrap_or(0);
        let entries = if last > snap_index {
            self.mem
                .entries(
                    snap_index + 1,
                    last + 1,
                    None::<u64>,
                    GetEntriesContext::empty(false),
                )
                .unwrap_or_default()
        } else {
            Vec::new()
        };

        atomic_write(
            &self.file,
            &encode(
                snap_index,
                snap_term,
                &snap_data,
                &state.hard_state,
                &state.conf_state,
                &entries,
            ),
        );
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
        let mut snapshot = self.mem.snapshot(request_index, to)?;
        snapshot.data = self.snap.lock().unwrap().data.clone().into();
        Ok(snapshot)
    }
}

struct Loaded {
    snap_index: u64,
    snap_term: u64,
    snap_data: Vec<u8>,
    hard_state: HardState,
    conf_state: ConfState,
    entries: Vec<Entry>,
}

fn encode(
    snap_index: u64,
    snap_term: u64,
    snap_data: &[u8],
    hard_state: &HardState,
    conf_state: &ConfState,
    entries: &[Entry],
) -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(&snap_index.to_be_bytes());
    buf.extend_from_slice(&snap_term.to_be_bytes());
    put_frame(&mut buf, snap_data);
    put_frame(&mut buf, &hard_state.write_to_bytes().unwrap_or_default());
    put_frame(&mut buf, &conf_state.write_to_bytes().unwrap_or_default());
    buf.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    for entry in entries {
        put_frame(&mut buf, &entry.write_to_bytes().unwrap_or_default());
    }
    buf
}

fn load(path: &Path) -> Option<Loaded> {
    let data = fs::read(path).ok()?;
    let mut pos = 0usize;

    let snap_index = take_u64(&data, &mut pos)?;
    let snap_term = take_u64(&data, &mut pos)?;
    let snap_data = take_frame(&data, &mut pos)?.to_vec();

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

    Some(Loaded {
        snap_index,
        snap_term,
        snap_data,
        hard_state,
        conf_state,
        entries,
    })
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

fn take_u64(data: &[u8], pos: &mut usize) -> Option<u64> {
    if *pos + 8 > data.len() {
        return None;
    }
    let value = u64::from_be_bytes(data[*pos..*pos + 8].try_into().ok()?);
    *pos += 8;
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
