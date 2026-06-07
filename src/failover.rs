pub struct Gossip {
    pub lsn: u64,
    pub in_recovery: bool,
    pub reconfirm: bool,
}

pub fn encode_gossip(lsn: u64, in_recovery: bool, reconfirm: bool) -> Vec<u8> {
    let mut buf = Vec::with_capacity(10);
    buf.extend_from_slice(&lsn.to_be_bytes());
    buf.push(in_recovery as u8);
    buf.push(reconfirm as u8);
    buf
}

pub fn decode_gossip(bytes: &[u8]) -> Option<Gossip> {
    if bytes.len() < 9 {
        return None;
    }
    let mut lsn = [0u8; 8];
    lsn.copy_from_slice(&bytes[..8]);
    Some(Gossip {
        lsn: u64::from_be_bytes(lsn),
        in_recovery: bytes[8] != 0,
        reconfirm: bytes.get(9).map_or(false, |byte| *byte != 0),
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Decision {
    pub seq: u64,
    pub primary: u64,
}

pub fn choose_primary(candidates: &[(u64, u64, bool)]) -> Option<u64> {
    candidates
        .iter()
        .max_by(|a, b| {
            a.1.cmp(&b.1)
                .then((!a.2 as u8).cmp(&(!b.2 as u8)))
                .then(b.0.cmp(&a.0))
        })
        .map(|candidate| candidate.0)
}
