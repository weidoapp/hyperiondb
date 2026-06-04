use std::sync::mpsc::Sender as StdSender;
use std::sync::Arc;

use openraft::error::{
    InstallSnapshotError, NetworkError, RPCError, RaftError, RemoteError, Unreachable,
};
use openraft::network::{RPCOption, RaftNetwork, RaftNetworkFactory};
use openraft::raft::{
    AppendEntriesRequest, AppendEntriesResponse, InstallSnapshotRequest, InstallSnapshotResponse,
    VoteRequest, VoteResponse,
};
use openraft::{BasicNode, Raft};
use serde::de::DeserializeOwned;
use serde::Serialize;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};
use tokio::sync::OnceCell;

use crate::rtype::{NodeId, TypeConfig};

pub struct Peer {
    pub id: u64,
    pub addr: String,
}

pub fn parse_peers(spec: &str) -> Vec<Peer> {
    spec.split(',')
        .filter_map(|entry| {
            let entry = entry.trim();
            if entry.is_empty() {
                return None;
            }
            let (id_part, addr_part) = entry.split_once('@')?;
            let id = id_part.trim().parse::<u64>().ok()?;
            Some(Peer {
                id,
                addr: addr_part.trim().to_string(),
            })
        })
        .collect()
}

pub const KIND_RAFT: u8 = 0;
pub const KIND_GOSSIP: u8 = 1;
const RPC_APPEND: u8 = 0;
const RPC_VOTE: u8 = 1;
const RPC_SNAPSHOT: u8 = 2;
const MAX_FRAME: usize = 256 * 1024 * 1024;

pub type RaftSlot = Arc<OnceCell<Raft<TypeConfig>>>;
type RpcError<E = RaftError<NodeId>> = RPCError<NodeId, BasicNode, E>;

async fn write_frame<S: AsyncWrite + Unpin>(stream: &mut S, bytes: &[u8]) -> std::io::Result<()> {
    stream.write_all(&(bytes.len() as u32).to_be_bytes()).await?;
    stream.write_all(bytes).await?;
    stream.flush().await
}

async fn read_frame<S: AsyncRead + Unpin>(stream: &mut S) -> std::io::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    stream.read_exact(&mut len).await?;
    let n = u32::from_be_bytes(len) as usize;
    if n > MAX_FRAME {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "frame too large"));
    }
    let mut buf = vec![0u8; n];
    stream.read_exact(&mut buf).await?;
    Ok(buf)
}

pub fn spawn_server(
    listener: std::net::TcpListener,
    slot: RaftSlot,
    gossip_in: StdSender<(u64, Vec<u8>)>,
) {
    tokio::spawn(async move {
        let listener = match TcpListener::from_std(listener) {
            Ok(l) => l,
            Err(_) => return,
        };
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    let slot = slot.clone();
                    let gossip_in = gossip_in.clone();
                    tokio::spawn(handle_conn(stream, slot, gossip_in));
                }
                Err(_) => tokio::time::sleep(std::time::Duration::from_millis(100)).await,
            }
        }
    });
}

async fn handle_conn(mut stream: TcpStream, slot: RaftSlot, gossip_in: StdSender<(u64, Vec<u8>)>) {
    loop {
        let frame = match read_frame(&mut stream).await {
            Ok(frame) => frame,
            Err(_) => return,
        };
        if frame.is_empty() {
            return;
        }
        match frame[0] {
            KIND_GOSSIP => {
                if frame.len() >= 9 {
                    let from = u64::from_be_bytes(frame[1..9].try_into().unwrap());
                    let _ = gossip_in.send((from, frame[9..].to_vec()));
                }
            }
            KIND_RAFT => match dispatch_raft(&frame[1..], &slot).await {
                Some(resp) => {
                    if write_frame(&mut stream, &resp).await.is_err() {
                        return;
                    }
                }
                None => return,
            },
            _ => return,
        }
    }
}

async fn dispatch_raft(payload: &[u8], slot: &RaftSlot) -> Option<Vec<u8>> {
    if payload.is_empty() {
        return None;
    }
    let raft = slot.get()?;
    let body = &payload[1..];
    match payload[0] {
        RPC_APPEND => {
            let req: AppendEntriesRequest<TypeConfig> = serde_json::from_slice(body).ok()?;
            let res = raft.append_entries(req).await;
            serde_json::to_vec(&res).ok()
        }
        RPC_VOTE => {
            let req: VoteRequest<NodeId> = serde_json::from_slice(body).ok()?;
            let res = raft.vote(req).await;
            serde_json::to_vec(&res).ok()
        }
        RPC_SNAPSHOT => {
            let req: InstallSnapshotRequest<TypeConfig> = serde_json::from_slice(body).ok()?;
            let res = raft.install_snapshot(req).await;
            serde_json::to_vec(&res).ok()
        }
        _ => None,
    }
}

#[derive(Clone)]
pub struct NetworkFactory;

impl RaftNetworkFactory<TypeConfig> for NetworkFactory {
    type Network = Connection;

    async fn new_client(&mut self, target: NodeId, node: &BasicNode) -> Self::Network {
        Connection {
            target,
            addr: node.addr.clone(),
        }
    }
}

pub struct Connection {
    target: NodeId,
    addr: String,
}

impl Connection {
    async fn call<Req, Resp, Err>(&self, rpc: u8, req: &Req) -> Result<Resp, RpcError<Err>>
    where
        Req: Serialize,
        Resp: DeserializeOwned,
        Err: std::error::Error + DeserializeOwned,
    {
        let mut payload = Vec::with_capacity(2);
        payload.push(KIND_RAFT);
        payload.push(rpc);
        payload.extend_from_slice(
            &serde_json::to_vec(req).map_err(|e| RPCError::Network(NetworkError::new(&e)))?,
        );

        let mut stream = TcpStream::connect(&self.addr)
            .await
            .map_err(|e| RPCError::Unreachable(Unreachable::new(&e)))?;
        write_frame(&mut stream, &payload)
            .await
            .map_err(|e| RPCError::Network(NetworkError::new(&e)))?;
        let resp = read_frame(&mut stream)
            .await
            .map_err(|e| RPCError::Network(NetworkError::new(&e)))?;

        let res: Result<Resp, Err> =
            serde_json::from_slice(&resp).map_err(|e| RPCError::Network(NetworkError::new(&e)))?;
        res.map_err(|e| RPCError::RemoteError(RemoteError::new(self.target, e)))
    }
}

impl RaftNetwork<TypeConfig> for Connection {
    async fn append_entries(
        &mut self,
        req: AppendEntriesRequest<TypeConfig>,
        _option: RPCOption,
    ) -> Result<AppendEntriesResponse<NodeId>, RpcError> {
        self.call(RPC_APPEND, &req).await
    }

    async fn install_snapshot(
        &mut self,
        req: InstallSnapshotRequest<TypeConfig>,
        _option: RPCOption,
    ) -> Result<InstallSnapshotResponse<NodeId>, RpcError<RaftError<NodeId, InstallSnapshotError>>> {
        self.call(RPC_SNAPSHOT, &req).await
    }

    async fn vote(
        &mut self,
        req: VoteRequest<NodeId>,
        _option: RPCOption,
    ) -> Result<VoteResponse<NodeId>, RpcError> {
        self.call(RPC_VOTE, &req).await
    }
}

#[derive(Clone)]
pub struct GossipHandle {
    tx: UnboundedSender<Vec<u8>>,
}

impl GossipHandle {
    pub fn broadcast(&self, from: u64, payload: &[u8]) {
        let mut frame = Vec::with_capacity(9 + payload.len());
        frame.push(KIND_GOSSIP);
        frame.extend_from_slice(&from.to_be_bytes());
        frame.extend_from_slice(payload);
        let _ = self.tx.send(frame);
    }
}

pub fn spawn_gossip_sender(my_id: u64, peers: Vec<(u64, String)>) -> GossipHandle {
    let (tx, mut rx) = unbounded_channel::<Vec<u8>>();
    tokio::spawn(async move {
        while let Some(frame) = rx.recv().await {
            for (id, addr) in &peers {
                if *id == my_id {
                    continue;
                }
                if let Ok(mut stream) = TcpStream::connect(addr).await {
                    let _ = write_frame(&mut stream, &frame).await;
                }
            }
        }
    });
    GossipHandle { tx }
}
