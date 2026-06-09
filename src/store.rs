use std::collections::BTreeMap;
use std::fmt::Debug;
use std::io::{Cursor, Write};
use std::ops::RangeBounds;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex as StdMutex;

use openraft::storage::{
    LogFlushed, LogState, RaftLogReader, RaftLogStorage, RaftSnapshotBuilder, RaftStateMachine,
    Snapshot,
};
use openraft::{
    Entry, EntryPayload, LogId, OptionalSend, SnapshotMeta, StorageError, StorageIOError,
    StoredMembership, Vote,
};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

use crate::failover::Decision;
use crate::rtype::{Node, NodeId, TypeConfig};

#[derive(Clone, Default)]
pub struct SharedDecision(Arc<StdMutex<Option<Decision>>>);

impl SharedDecision {
    pub fn current(&self) -> Option<Decision> {
        *self.0.lock().unwrap()
    }
    fn set(&self, decision: Option<Decision>) {
        *self.0.lock().unwrap() = decision;
    }
}

#[derive(Serialize, Deserialize, Default)]
struct LogStoreState {
    vote: Option<Vote<NodeId>>,
    last_purged: Option<LogId<NodeId>>,
    committed: Option<LogId<NodeId>>,
    log: BTreeMap<u64, Entry<TypeConfig>>,
}

#[derive(Clone)]
pub struct LogStore {
    path: PathBuf,
    state: Arc<RwLock<LogStoreState>>,
}

impl LogStore {
    async fn persist(&self) -> Result<(), StorageError<NodeId>> {
        let bytes = {
            let state = self.state.read().await;
            serde_json::to_vec(&*state).map_err(|e| StorageIOError::write_logs(&e))?
        };
        atomic_write(&self.path, &bytes).map_err(|e| StorageIOError::write_logs(&e))?;
        Ok(())
    }
}

impl RaftLogReader<TypeConfig> for LogStore {
    async fn try_get_log_entries<RB: RangeBounds<u64> + Clone + Debug + OptionalSend>(
        &mut self,
        range: RB,
    ) -> Result<Vec<Entry<TypeConfig>>, StorageError<NodeId>> {
        let state = self.state.read().await;
        Ok(state.log.range(range).map(|(_, entry)| entry.clone()).collect())
    }
}

impl RaftLogStorage<TypeConfig> for LogStore {
    type LogReader = Self;

    async fn get_log_state(&mut self) -> Result<LogState<TypeConfig>, StorageError<NodeId>> {
        let state = self.state.read().await;
        let last = state.log.iter().next_back().map(|(_, entry)| entry.log_id);
        let last_purged = state.last_purged;
        Ok(LogState {
            last_purged_log_id: last_purged,
            last_log_id: last.or(last_purged),
        })
    }

    async fn get_log_reader(&mut self) -> Self::LogReader {
        self.clone()
    }

    async fn save_vote(&mut self, vote: &Vote<NodeId>) -> Result<(), StorageError<NodeId>> {
        {
            let mut state = self.state.write().await;
            state.vote = Some(*vote);
        }
        self.persist().await
    }

    async fn read_vote(&mut self) -> Result<Option<Vote<NodeId>>, StorageError<NodeId>> {
        Ok(self.state.read().await.vote)
    }

    async fn save_committed(
        &mut self,
        committed: Option<LogId<NodeId>>,
    ) -> Result<(), StorageError<NodeId>> {
        {
            let mut state = self.state.write().await;
            state.committed = committed;
        }
        self.persist().await
    }

    async fn read_committed(&mut self) -> Result<Option<LogId<NodeId>>, StorageError<NodeId>> {
        Ok(self.state.read().await.committed)
    }

    async fn append<I>(
        &mut self,
        entries: I,
        callback: LogFlushed<TypeConfig>,
    ) -> Result<(), StorageError<NodeId>>
    where
        I: IntoIterator<Item = Entry<TypeConfig>> + OptionalSend,
        I::IntoIter: OptionalSend,
    {
        {
            let mut state = self.state.write().await;
            for entry in entries {
                state.log.insert(entry.log_id.index, entry);
            }
        }
        self.persist().await?;
        callback.log_io_completed(Ok(()));
        Ok(())
    }

    async fn truncate(&mut self, log_id: LogId<NodeId>) -> Result<(), StorageError<NodeId>> {
        {
            let mut state = self.state.write().await;
            let keys: Vec<u64> = state.log.range(log_id.index..).map(|(k, _)| *k).collect();
            for key in keys {
                state.log.remove(&key);
            }
        }
        self.persist().await
    }

    async fn purge(&mut self, log_id: LogId<NodeId>) -> Result<(), StorageError<NodeId>> {
        {
            let mut state = self.state.write().await;
            state.last_purged = Some(log_id);
            let keys: Vec<u64> = state.log.range(..=log_id.index).map(|(k, _)| *k).collect();
            for key in keys {
                state.log.remove(&key);
            }
        }
        self.persist().await
    }
}

#[derive(Serialize, Deserialize, Default, Clone)]
struct SmState {
    last_applied: Option<LogId<NodeId>>,
    last_membership: StoredMembership<NodeId, Node>,
    decision: Option<Decision>,
}

struct StoredSnapshot {
    meta: SnapshotMeta<NodeId, Node>,
    data: Vec<u8>,
}

#[derive(Clone)]
pub struct StateMachine {
    path: PathBuf,
    sm: Arc<RwLock<SmState>>,
    snapshot: Arc<RwLock<Option<Arc<StoredSnapshot>>>>,
    snapshot_idx: Arc<StdMutex<u64>>,
    shared: SharedDecision,
}

impl StateMachine {
    async fn persist(&self) -> Result<(), StorageError<NodeId>> {
        let bytes = {
            let sm = self.sm.read().await;
            serde_json::to_vec(&*sm).map_err(|e| StorageIOError::write_state_machine(&e))?
        };
        atomic_write(&self.path, &bytes).map_err(|e| StorageIOError::write_state_machine(&e))?;
        Ok(())
    }
}

impl RaftSnapshotBuilder<TypeConfig> for StateMachine {
    async fn build_snapshot(&mut self) -> Result<Snapshot<TypeConfig>, StorageError<NodeId>> {
        let (data, last_applied, last_membership) = {
            let sm = self.sm.read().await;
            let data =
                serde_json::to_vec(&*sm).map_err(|e| StorageIOError::read_state_machine(&e))?;
            (data, sm.last_applied, sm.last_membership.clone())
        };
        let idx = {
            let mut guard = self.snapshot_idx.lock().unwrap();
            *guard += 1;
            *guard
        };
        let snapshot_id = match last_applied {
            Some(log_id) => format!("{}-{}-{}", log_id.leader_id, log_id.index, idx),
            None => format!("--{}", idx),
        };
        let meta = SnapshotMeta {
            last_log_id: last_applied,
            last_membership,
            snapshot_id,
        };
        {
            let mut current = self.snapshot.write().await;
            *current = Some(Arc::new(StoredSnapshot {
                meta: meta.clone(),
                data: data.clone(),
            }));
        }
        Ok(Snapshot {
            meta,
            snapshot: Box::new(Cursor::new(data)),
        })
    }
}

impl RaftStateMachine<TypeConfig> for StateMachine {
    type SnapshotBuilder = Self;

    async fn applied_state(
        &mut self,
    ) -> Result<(Option<LogId<NodeId>>, StoredMembership<NodeId, Node>), StorageError<NodeId>> {
        let sm = self.sm.read().await;
        Ok((sm.last_applied, sm.last_membership.clone()))
    }

    async fn apply<I>(&mut self, entries: I) -> Result<Vec<()>, StorageError<NodeId>>
    where
        I: IntoIterator<Item = Entry<TypeConfig>> + OptionalSend,
        I::IntoIter: OptionalSend,
    {
        let mut responses = Vec::new();
        let mut changed = false;
        let decision;
        {
            let mut sm = self.sm.write().await;
            for entry in entries {
                sm.last_applied = Some(entry.log_id);
                match entry.payload {
                    EntryPayload::Blank => {}
                    EntryPayload::Normal(value) => {
                        sm.decision = Some(value);
                        changed = true;
                    }
                    EntryPayload::Membership(membership) => {
                        sm.last_membership =
                            StoredMembership::new(Some(entry.log_id), membership);
                    }
                }
                responses.push(());
            }
            decision = sm.decision;
        }
        self.persist().await?;
        if changed {
            self.shared.set(decision);
        }
        Ok(responses)
    }

    async fn get_snapshot_builder(&mut self) -> Self::SnapshotBuilder {
        self.clone()
    }

    async fn begin_receiving_snapshot(
        &mut self,
    ) -> Result<Box<Cursor<Vec<u8>>>, StorageError<NodeId>> {
        Ok(Box::new(Cursor::new(Vec::new())))
    }

    async fn install_snapshot(
        &mut self,
        meta: &SnapshotMeta<NodeId, Node>,
        snapshot: Box<Cursor<Vec<u8>>>,
    ) -> Result<(), StorageError<NodeId>> {
        let data = snapshot.into_inner();
        let new_sm: SmState = serde_json::from_slice(&data)
            .map_err(|e| StorageIOError::read_snapshot(Some(meta.signature()), &e))?;
        let decision = new_sm.decision;
        {
            let mut sm = self.sm.write().await;
            *sm = new_sm;
        }
        {
            let mut current = self.snapshot.write().await;
            *current = Some(Arc::new(StoredSnapshot {
                meta: meta.clone(),
                data,
            }));
        }
        self.persist().await?;
        self.shared.set(decision);
        Ok(())
    }

    async fn get_current_snapshot(
        &mut self,
    ) -> Result<Option<Snapshot<TypeConfig>>, StorageError<NodeId>> {
        match &*self.snapshot.read().await {
            Some(snapshot) => Ok(Some(Snapshot {
                meta: snapshot.meta.clone(),
                snapshot: Box::new(Cursor::new(snapshot.data.clone())),
            })),
            None => Ok(None),
        }
    }
}

pub fn open(dir: &Path, node_id: NodeId) -> (LogStore, StateMachine, SharedDecision) {
    let log_path = dir.join(format!("raft_log_{}.json", node_id));
    let sm_path = dir.join(format!("raft_sm_{}.json", node_id));
    let log_state: LogStoreState = load(&log_path);
    let sm_state: SmState = load(&sm_path);
    let shared = SharedDecision(Arc::new(StdMutex::new(sm_state.decision)));
    let log_store = LogStore {
        path: log_path,
        state: Arc::new(RwLock::new(log_state)),
    };
    let state_machine = StateMachine {
        path: sm_path,
        sm: Arc::new(RwLock::new(sm_state)),
        snapshot: Arc::new(RwLock::new(None)),
        snapshot_idx: Arc::new(StdMutex::new(0)),
        shared: shared.clone(),
    };
    (log_store, state_machine, shared)
}

fn load<T>(path: &Path) -> T
where
    T: Default + for<'de> Deserialize<'de>,
{
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
            panic!(
                "pg_replica: durable raft state at {} is present but unreadable ({}); refusing to start with empty state",
                path.display(),
                e
            )
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => T::default(),
        Err(e) => panic!(
            "pg_replica: cannot read raft state at {} ({}); refusing to start",
            path.display(),
            e
        ),
    }
}

fn atomic_write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp, path)?;
    if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
        std::fs::File::open(dir)?.sync_all()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use openraft::testing::{StoreBuilder, Suite};

    struct TestDir(PathBuf);

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    struct Builder;

    impl StoreBuilder<TypeConfig, LogStore, StateMachine, TestDir> for Builder {
        async fn build(&self) -> Result<(TestDir, LogStore, StateMachine), StorageError<NodeId>> {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let dir = std::env::temp_dir().join(format!("pgr-store-test-{}-{}", std::process::id(), nanos));
            std::fs::create_dir_all(&dir).unwrap();
            let (log_store, state_machine, _shared) = open(&dir, 1);
            Ok((TestDir(dir), log_store, state_machine))
        }
    }

    #[test]
    fn storage_conformance_suite() -> Result<(), StorageError<NodeId>> {
        Suite::test_all(Builder)
    }
}
