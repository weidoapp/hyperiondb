use stateright::{Checker, Model, Property};
use std::collections::BTreeSet;

pub mod leadership;

#[derive(Clone, Debug)]
pub struct Cluster {
    pub n: usize,
    pub ack_quorum: usize,
    pub max_lsn: u64,
    pub max_term: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct State {
    pub lsn: Vec<u64>,
    pub alive: Vec<bool>,
    pub primary: Option<usize>,
    pub acked: u64,
    pub term: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Action {
    Write,
    Replicate(usize),
    Ack,
    Crash(usize),
    Failover(usize),
}

impl Cluster {
    pub fn majority(&self) -> usize {
        self.n / 2 + 1
    }

    fn possible_new_primaries(&self, s: &State) -> Vec<usize> {
        let maj = self.majority();
        let alive = (0..self.n).filter(|&i| s.alive[i]).count();
        if alive < maj {
            return Vec::new();
        }
        let mut winners = BTreeSet::new();
        for mask in 1u32..(1u32 << self.n) {
            let members: Vec<usize> = (0..self.n).filter(|&i| (mask >> i) & 1 == 1).collect();
            if members.len() != maj || members.iter().any(|&i| !s.alive[i]) {
                continue;
            }
            let w = *members
                .iter()
                .max_by(|&&a, &&b| s.lsn[a].cmp(&s.lsn[b]).then(b.cmp(&a)))
                .unwrap();
            winners.insert(w);
        }
        winners.into_iter().collect()
    }
}

impl Model for Cluster {
    type State = State;
    type Action = Action;

    fn init_states(&self) -> Vec<Self::State> {
        vec![State {
            lsn: vec![0; self.n],
            alive: vec![true; self.n],
            primary: Some(0),
            acked: 0,
            term: 0,
        }]
    }

    fn actions(&self, s: &Self::State, actions: &mut Vec<Self::Action>) {
        if let Some(p) = s.primary {
            if s.alive[p] {
                if s.lsn[p] < self.max_lsn {
                    actions.push(Action::Write);
                }
                let confirmers = (0..self.n)
                    .filter(|&i| s.alive[i] && s.lsn[i] >= s.lsn[p])
                    .count();
                if s.lsn[p] > 0 && s.acked < s.lsn[p] && confirmers >= self.ack_quorum {
                    actions.push(Action::Ack);
                }
                for standby in 0..self.n {
                    if standby != p && s.alive[standby] && s.lsn[standby] < s.lsn[p] {
                        actions.push(Action::Replicate(standby));
                    }
                }
            }
        }
        for i in 0..self.n {
            if s.alive[i] {
                actions.push(Action::Crash(i));
            }
        }
        let need_failover = match s.primary {
            None => true,
            Some(p) => !s.alive[p],
        };
        if need_failover && s.term < self.max_term {
            for w in self.possible_new_primaries(s) {
                actions.push(Action::Failover(w));
            }
        }
    }

    fn next_state(&self, s: &Self::State, action: Self::Action) -> Option<Self::State> {
        let mut ns = s.clone();
        match action {
            Action::Write => {
                let p = s.primary?;
                ns.lsn[p] += 1;
            }
            Action::Replicate(i) => {
                let p = s.primary?;
                if ns.lsn[i] < ns.lsn[p] {
                    ns.lsn[i] += 1;
                }
            }
            Action::Ack => {
                let p = s.primary?;
                ns.acked = ns.lsn[p];
            }
            Action::Crash(i) => {
                ns.alive[i] = false;
            }
            Action::Failover(w) => {
                ns.primary = Some(w);
                ns.term += 1;
            }
        }
        Some(ns)
    }

    fn within_boundary(&self, s: &Self::State) -> bool {
        s.term <= self.max_term && s.lsn.iter().all(|&l| l <= self.max_lsn)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::<Self>::always("no_acked_loss", |_, s| match s.primary {
                Some(p) => s.lsn[p] >= s.acked,
                None => true,
            }),
            Property::<Self>::sometimes("failover_after_ack", |_, s| {
                s.term >= 1 && s.acked >= 1
            }),
        ]
    }
}

#[derive(Debug)]
pub struct Summary {
    pub states: usize,
    pub safety_violated: bool,
    pub sometimes_met: bool,
}

pub fn check(n: usize, ack_quorum: usize, max_lsn: u64, max_term: u64) -> Summary {
    let model = Cluster {
        n,
        ack_quorum,
        max_lsn,
        max_term,
    };
    let checker = model.checker().spawn_bfs().join();
    Summary {
        states: checker.unique_state_count(),
        safety_violated: checker.discovery("no_acked_loss").is_some(),
        sometimes_met: checker.discovery("failover_after_ack").is_some(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_quorum_loses_no_acked_transaction() {
        for n in [3usize, 5usize] {
            let maj = n / 2 + 1;
            let s = check(n, maj, 3, n as u64);
            assert!(
                !s.safety_violated,
                "N={n}: an acked transaction was lost under ack_quorum={maj}"
            );
            assert!(
                s.sometimes_met,
                "N={n}: model never reached a post-ack failover (check is vacuous)"
            );
        }
    }

    #[test]
    fn under_quorum_loses_data() {
        let maj = 3 / 2 + 1;
        let s = check(3, maj - 1, 3, 3);
        assert!(
            s.safety_violated,
            "ack_quorum={} should lose an acked transaction but the checker found none",
            maj - 1
        );
    }
}
