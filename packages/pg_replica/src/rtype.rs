use std::io::Cursor;

use crate::failover::Decision;

openraft::declare_raft_types!(
    pub TypeConfig:
        D = Decision,
        R = (),
);

pub type NodeId = u64;
pub type Node = openraft::BasicNode;
