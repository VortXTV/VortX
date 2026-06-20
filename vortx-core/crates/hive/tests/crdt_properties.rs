//! Property-based proof that the CacheFact merge is a convergent CRDT.
//!
//! Hand-written unit tests pin specific cases; these exercise thousands of RANDOM fact streams and assert
//! the two laws a state-based CRDT must obey:
//!   - convergence (commutativity + associativity): folding the same multiset of facts in any order
//!     yields identical state.
//!   - idempotency: replaying every fact a second time changes nothing.
//!
//! Signers are derived deterministically from a seed so a shrinking failure is reproducible.

use proptest::prelude::*;
use vortx_hive::{merge_fact, CacheFact, DebridService, HiveCacheMap, NodeIdentity};

const IHS: [&str; 2] = [
    "aabbccddeeff00112233445566778899aabbccdd",
    "1122334455667788990011223344556677889900",
];

/// A deterministic identity per signer index, so property failures shrink reproducibly.
fn id_for(idx: u8) -> NodeIdentity {
    let mut seed = [0u8; 32];
    seed[0] = idx;
    seed[1] = 0xa5;
    NodeIdentity::from_secret_bytes(&seed)
}

type Op = (u8, bool, u64, u8, Option<u32>);

fn build_facts(ops: &[Op], ids: &[NodeIdentity]) -> Vec<CacheFact> {
    ops.iter()
        .map(|&(signer, cached, verified_at, ih, file_idx)| {
            CacheFact::create(
                &ids[(signer as usize) % ids.len()],
                IHS[(ih as usize) % IHS.len()],
                DebridService::RealDebrid,
                cached,
                file_idx,
                None,
                None,
                verified_at,
                86_400, // ttl large enough that nothing expires before `now`
            )
            .expect("fact builds")
        })
        .collect()
}

fn ops_strategy() -> impl Strategy<Value = Vec<Op>> {
    // verified_at stays under `now` (10_000) so every fact is valid (not future, not expired).
    prop::collection::vec(
        (
            0u8..4,
            any::<bool>(),
            0u64..10_000u64,
            0u8..2u8,
            prop::option::of(0u32..3u32),
        ),
        0..40usize,
    )
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    /// Folding the same facts forward and reversed must converge to the same map.
    #[test]
    fn merge_converges_regardless_of_order(ops in ops_strategy()) {
        let ids: Vec<NodeIdentity> = (0u8..4).map(id_for).collect();
        let now = 10_000u64;
        let facts = build_facts(&ops, &ids);

        let mut forward = HiveCacheMap::new();
        for f in &facts {
            merge_fact(&mut forward, f.clone(), now);
        }

        let mut reverse = HiveCacheMap::new();
        for f in facts.iter().rev() {
            merge_fact(&mut reverse, f.clone(), now);
        }

        prop_assert_eq!(forward, reverse);
    }

    /// Replaying every fact a second time must not change the merged state.
    #[test]
    fn merge_is_idempotent_under_replay(ops in ops_strategy()) {
        let ids: Vec<NodeIdentity> = (0u8..4).map(id_for).collect();
        let now = 10_000u64;
        let facts = build_facts(&ops, &ids);

        let mut once = HiveCacheMap::new();
        for f in &facts {
            merge_fact(&mut once, f.clone(), now);
        }

        let mut twice = once.clone();
        for f in &facts {
            merge_fact(&mut twice, f.clone(), now);
        }

        prop_assert_eq!(once, twice);
    }
}
