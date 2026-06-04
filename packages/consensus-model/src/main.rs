use consensus_model::check;
use consensus_model::leadership::check_split_brain;

fn main() {
    let mut ok = true;

    println!("  [1] durability: a committed (acked) transaction is never lost on failover");
    for n in [3usize, 5usize] {
        let maj = n / 2 + 1;
        let s = check(n, maj, 3, n as u64);
        let pass = !s.safety_violated && s.sometimes_met;
        ok &= pass;
        println!(
            "      N={n} sync (ack_quorum={maj}=majority of {n}): states={} acked_loss={} failover_after_ack_reached={}",
            s.states, s.safety_violated, s.sometimes_met
        );
    }
    let neg = check(3, 1, 3, 3);
    ok &= neg.safety_violated;
    println!(
        "      N=3 negative control (ack_quorum=1=majority-1): states={} counterexample_found={}",
        neg.states, neg.safety_violated
    );

    println!("  [2] split-brain: a resurrected stale-term primary never commits a conflicting write");
    for (n, max_term) in [(3usize, 4u64), (5usize, 3u64)] {
        let s = check_split_brain(n, max_term, true);
        let pass = !s.safety_violated && s.sometimes_met;
        ok &= pass;
        println!(
            "      N={n} fencing (commit needs majority still at leader's term): states={} split_brain={} stale_leader_reached={}",
            s.states, s.safety_violated, s.sometimes_met
        );
    }
    let neg2 = check_split_brain(3, 4, false);
    ok &= neg2.safety_violated;
    println!(
        "      N=3 negative control (no current-term quorum check): states={} counterexample_found={}",
        neg2.states, neg2.safety_violated
    );

    println!();
    if ok {
        println!("  PASS: model-checked (exhaustive) for N=3 and N=5 — sync quorum (ack=majority) loses no acked transaction, and a resurrected stale-term primary can never commit a split-brain write; both negative controls correctly produced counterexamples (the checker has teeth)");
        std::process::exit(0);
    } else {
        println!("  FAIL: model check did not meet expectations (see per-config lines above)");
        std::process::exit(1);
    }
}
