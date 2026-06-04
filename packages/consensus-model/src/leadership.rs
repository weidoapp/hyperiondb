use crate::Summary;
use stateright::{Checker, Model, Property};

#[derive(Clone, Debug)]
pub struct Leadership {
    pub n: usize,
    pub max_term: u64,
    pub fencing: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct LState {
    pub cur_term: Vec<u64>,
    pub writable: Vec<bool>,
    pub alive: Vec<bool>,
    pub max_committed_term: u64,
    pub committed_leader: Option<usize>,
    pub split_brain: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum LAction {
    Elect { winner: usize, voters: u32 },
    Commit(usize),
    Crash(usize),
    Recover(usize),
}

impl Leadership {
    fn majority(&self) -> usize {
        self.n / 2 + 1
    }
}

impl Model for Leadership {
    type State = LState;
    type Action = LAction;

    fn init_states(&self) -> Vec<LState> {
        let mut writable = vec![false; self.n];
        writable[0] = true;
        vec![LState {
            cur_term: vec![1; self.n],
            writable,
            alive: vec![true; self.n],
            max_committed_term: 0,
            committed_leader: None,
            split_brain: false,
        }]
    }

    fn actions(&self, s: &LState, actions: &mut Vec<LAction>) {
        let maj = self.majority();
        let max_term = *s.cur_term.iter().max().unwrap();
        if max_term < self.max_term {
            for mask in 1u32..(1u32 << self.n) {
                let members: Vec<usize> = (0..self.n).filter(|&i| (mask >> i) & 1 == 1).collect();
                if members.len() != maj || members.iter().any(|&i| !s.alive[i]) {
                    continue;
                }
                for &winner in &members {
                    actions.push(LAction::Elect {
                        winner,
                        voters: mask,
                    });
                }
            }
        }
        for w in 0..self.n {
            if s.alive[w] && s.writable[w] {
                actions.push(LAction::Commit(w));
            }
        }
        for i in 0..self.n {
            if s.alive[i] {
                actions.push(LAction::Crash(i));
            } else {
                actions.push(LAction::Recover(i));
            }
        }
    }

    fn next_state(&self, s: &LState, a: LAction) -> Option<LState> {
        let maj = self.majority();
        let mut ns = s.clone();
        match a {
            LAction::Elect { winner, voters } => {
                let new_term = s.cur_term.iter().max().unwrap() + 1;
                for i in 0..self.n {
                    if (voters >> i) & 1 == 1 {
                        ns.cur_term[i] = new_term;
                        ns.writable[i] = i == winner;
                    }
                }
            }
            LAction::Commit(w) => {
                let t = s.cur_term[w];
                let quorum_at_term = (0..self.n)
                    .filter(|&i| s.alive[i] && s.cur_term[i] == t)
                    .count();
                let allowed = if self.fencing {
                    quorum_at_term >= maj
                } else {
                    true
                };
                if !allowed {
                    return None;
                }
                if t < ns.max_committed_term {
                    ns.split_brain = true;
                } else if t == ns.max_committed_term {
                    if let Some(prev) = ns.committed_leader {
                        if prev != w {
                            ns.split_brain = true;
                        }
                    }
                    ns.committed_leader = Some(w);
                } else {
                    ns.max_committed_term = t;
                    ns.committed_leader = Some(w);
                }
            }
            LAction::Crash(i) => {
                ns.alive[i] = false;
            }
            LAction::Recover(i) => {
                ns.alive[i] = true;
            }
        }
        Some(ns)
    }

    fn within_boundary(&self, s: &LState) -> bool {
        s.cur_term.iter().all(|&t| t <= self.max_term)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::<Self>::always("no_split_brain", |_, s| !s.split_brain),
            Property::<Self>::sometimes("stale_writable_leader_present", |_, s| {
                let mx = *s.cur_term.iter().max().unwrap();
                (0..s.cur_term.len())
                    .any(|i| s.alive[i] && s.writable[i] && s.cur_term[i] < mx)
            }),
        ]
    }
}

pub fn check_split_brain(n: usize, max_term: u64, fencing: bool) -> Summary {
    let model = Leadership {
        n,
        max_term,
        fencing,
    };
    let checker = model.checker().spawn_bfs().join();
    Summary {
        states: checker.unique_state_count(),
        safety_violated: checker.discovery("no_split_brain").is_some(),
        sometimes_met: checker.discovery("stale_writable_leader_present").is_some(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fencing_prevents_split_brain() {
        for (n, max_term) in [(3usize, 4u64), (5usize, 3u64)] {
            let s = check_split_brain(n, max_term, true);
            assert!(
                !s.safety_violated,
                "N={n}: a resurrected stale-term leader committed a split-brain write"
            );
            assert!(
                s.sometimes_met,
                "N={n}: model never reached a stale-writable-leader state (check is vacuous)"
            );
        }
    }

    #[test]
    fn without_fencing_split_brain_occurs() {
        let s = check_split_brain(3, 4, false);
        assert!(
            s.safety_violated,
            "without the current-term quorum check, a split-brain commit should be reachable"
        );
    }
}
