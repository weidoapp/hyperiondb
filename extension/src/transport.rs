use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread;
use std::time::Duration;

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

pub struct Transport {
    inbound: Receiver<(u64, Vec<u8>)>,
    outbound: HashMap<u64, Sender<Vec<u8>>>,
}

impl Transport {
    pub fn start(node_id: u64, listen_port: u16, peers: &[Peer]) -> std::io::Result<Self> {
        let (in_tx, in_rx) = channel::<(u64, Vec<u8>)>();

        let listener = TcpListener::bind(("0.0.0.0", listen_port))?;
        thread::spawn(move || accept_loop(listener, in_tx));

        let mut outbound = HashMap::new();
        for peer in peers {
            if peer.id == node_id {
                continue;
            }
            let (out_tx, out_rx) = channel::<Vec<u8>>();
            let addr = peer.addr.clone();
            thread::spawn(move || sender_loop(addr, node_id, out_rx));
            outbound.insert(peer.id, out_tx);
        }

        Ok(Transport {
            inbound: in_rx,
            outbound,
        })
    }

    pub fn send(&self, to: u64, payload: Vec<u8>) {
        if let Some(tx) = self.outbound.get(&to) {
            let _ = tx.send(payload);
        }
    }

    pub fn broadcast(&self, payload: &[u8]) {
        for tx in self.outbound.values() {
            let _ = tx.send(payload.to_vec());
        }
    }

    pub fn try_recv(&self) -> Option<(u64, Vec<u8>)> {
        self.inbound.try_recv().ok()
    }
}

fn accept_loop(listener: TcpListener, in_tx: Sender<(u64, Vec<u8>)>) {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let tx = in_tx.clone();
                thread::spawn(move || read_loop(stream, tx));
            }
            Err(_) => thread::sleep(Duration::from_millis(200)),
        }
    }
}

fn read_loop(mut stream: TcpStream, in_tx: Sender<(u64, Vec<u8>)>) {
    loop {
        let mut len_buf = [0u8; 4];
        if stream.read_exact(&mut len_buf).is_err() {
            return;
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        if len < 8 {
            return;
        }
        let mut frame = vec![0u8; len];
        if stream.read_exact(&mut frame).is_err() {
            return;
        }
        let mut from_buf = [0u8; 8];
        from_buf.copy_from_slice(&frame[..8]);
        let from = u64::from_be_bytes(from_buf);
        let payload = frame[8..].to_vec();
        if in_tx.send((from, payload)).is_err() {
            return;
        }
    }
}

fn sender_loop(addr: String, from: u64, out_rx: Receiver<Vec<u8>>) {
    let mut stream: Option<TcpStream> = None;
    while let Ok(payload) = out_rx.recv() {
        if stream.is_none() {
            stream = TcpStream::connect(&addr).ok();
        }
        if let Some(active) = stream.as_mut() {
            let len = (8 + payload.len()) as u32;
            let mut frame = Vec::with_capacity(4 + 8 + payload.len());
            frame.extend_from_slice(&len.to_be_bytes());
            frame.extend_from_slice(&from.to_be_bytes());
            frame.extend_from_slice(&payload);
            if active.write_all(&frame).is_err() {
                stream = None;
            }
        }
    }
}
