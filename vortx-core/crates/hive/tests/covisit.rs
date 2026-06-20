//! Cross-language conformance + property tests for the item-item co-visit fact.
//!
//! Conformance pins the deterministic, key-independent parts: the signing bytes (the cross-platform
//! signature anchor) and pair canonicalization + count cap. The properties prove the federation
//! guarantees: the merge is a convergent CRDT, and an under-quorum / untrusted pair never earns authority.

use std::sync::OnceLock;

use proptest::prelude::*;
use serde::Deserialize;
use vortx_hive::{
    authoritative_covisit_strength, covisit_signing_bytes_for, merge_covisit, pair_facts,
    CoVisitFact, CoVisitMap, NodeIdentity, TrustStore,
};

#[derive(Deserialize)]
struct Suite {
    signing_bytes: Vec<SbVec>,
    canonical: Vec<CanonVec>,
}

#[derive(Deserialize)]
struct SbVec {
    item_a: String,
    item_b: String,
    count: u32,
    verified_at: u64,
    ttl: u64,
    signer_pubkey: String,
    expect: String,
}

#[derive(Deserialize)]
struct CanonVec {
    item_x: String,
    item_y: String,
    count_in: u32,
    expect_a: String,
    expect_b: String,
    expect_count: u32,
}

const SUITE: &str = include_str!("../conformance/covisit_vectors.json");

#[test]
fn covisit_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse covisit suite");

    for v in &suite.signing_bytes {
        let bytes = covisit_signing_bytes_for(
            &v.item_a,
            &v.item_b,
            v.count,
            v.verified_at,
            v.ttl,
            &v.signer_pubkey,
        );
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            v.expect,
            "signing bytes drifted for {}|{}",
            v.item_a,
            v.item_b
        );
    }

    let me = NodeIdentity::generate().unwrap();
    for v in &suite.canonical {
        let f =
            CoVisitFact::create(&me, &v.item_x, &v.item_y, v.count_in, 1000, 86_400).unwrap();
        assert_eq!(f.item_a, v.expect_a, "item_a canonicalization");
        assert_eq!(f.item_b, v.expect_b, "item_b canonicalization");
        assert_eq!(f.count, v.expect_count, "count cap");
    }
}

// --- properties ---

const NOW: u64 = 100_000;
const TTL: u64 = 21_600;
const PAIRS: &[(&str, &str)] = &[("tt1", "tt2"), ("tt3", "tt4"), ("a", "z")];

/// A shared pool of identities so proptest cases can reference signers by index without re-keying.
fn pool() -> &'static Vec<NodeIdentity> {
    static P: OnceLock<Vec<NodeIdentity>> = OnceLock::new();
    P.get_or_init(|| (0..6).map(|_| NodeIdentity::generate().unwrap()).collect())
}

fn build(signer: usize, pair: usize, count: u32, verified_at: u64) -> CoVisitFact {
    let (a, b) = PAIRS[pair % PAIRS.len()];
    CoVisitFact::create(&pool()[signer % pool().len()], a, b, count, verified_at, TTL).unwrap()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(96))]

    /// The merge converges regardless of gossip order: merging the same facts forward, reversed, and
    /// rotated yields the identical map (commutative + associative + idempotent).
    #[test]
    fn merge_is_a_convergent_crdt(
        spec in prop::collection::vec(
            (0usize..6, 0usize..3, 0u32..1500, 90_000u64..=100_000),
            0..14,
        ),
    ) {
        let facts: Vec<CoVisitFact> = spec.iter().map(|&(s, p, c, v)| build(s, p, c, v)).collect();

        let mut forward = CoVisitMap::new();
        for f in &facts {
            merge_covisit(&mut forward, f.clone(), NOW);
        }
        let mut reversed = CoVisitMap::new();
        for f in facts.iter().rev() {
            merge_covisit(&mut reversed, f.clone(), NOW);
        }
        let mut rotated = CoVisitMap::new();
        let mid = facts.len() / 2;
        for f in facts[mid..].iter().chain(facts[..mid].iter()) {
            merge_covisit(&mut rotated, f.clone(), NOW);
        }
        // Re-merging everything once more changes nothing (idempotent).
        let mut again = forward.clone();
        for f in &facts {
            merge_covisit(&mut again, f.clone(), NOW);
        }

        prop_assert_eq!(&forward, &reversed);
        prop_assert_eq!(&forward, &rotated);
        prop_assert_eq!(&forward, &again);
    }

    /// Authority is fail-closed: with no own data, a pair earns strength ONLY when at least QUORUM_N
    /// distinct trusted signers confirm; below that it is exactly 0, and at/above it the strength is the
    /// sum of the trusted counts. Untrusted (public) signers never count.
    #[test]
    fn under_quorum_never_moves_a_recommendation(
        trusted in 0usize..6,
        public in 0usize..4,
        count in 1u32..50,
    ) {
        let me = NodeIdentity::generate().unwrap();
        let mut trust = TrustStore::new(me.public_b64url());

        let mut map = CoVisitMap::new();
        // `trusted` distinct trusted signers (pool indices 0..trusted).
        for i in 0..trusted {
            trust.trust(pool()[i].public_b64url());
            let f = CoVisitFact::create(&pool()[i], "tt1", "tt2", count, NOW, TTL).unwrap();
            merge_covisit(&mut map, f, NOW);
        }
        // `public` distinct untrusted signers (disjoint pool indices).
        for i in 0..public {
            let f = CoVisitFact::create(&pool()[6 - 1 - i], "tt1", "tt2", count, NOW, TTL).unwrap();
            merge_covisit(&mut map, f, NOW);
        }

        let facts = pair_facts(&map, "tt1", "tt2");
        let owned: Vec<CoVisitFact> = facts.into_iter().cloned().collect();
        let strength = authoritative_covisit_strength(&owned, &trust, NOW);

        // QUORUM_N is 3 in the hive constants.
        if trusted >= 3 {
            prop_assert_eq!(strength, count * trusted as u32);
        } else {
            prop_assert_eq!(strength, 0);
        }
    }

    /// Determinism: the same facts + trust yield the same strength every time.
    #[test]
    fn strength_is_deterministic(trusted in 3usize..6, count in 1u32..40) {
        let me = NodeIdentity::generate().unwrap();
        let mut trust = TrustStore::new(me.public_b64url());
        let mut facts = Vec::new();
        for i in 0..trusted {
            trust.trust(pool()[i].public_b64url());
            facts.push(CoVisitFact::create(&pool()[i], "tt1", "tt2", count, NOW, TTL).unwrap());
        }
        let a = authoritative_covisit_strength(&facts, &trust, NOW);
        let b = authoritative_covisit_strength(&facts, &trust, NOW);
        prop_assert_eq!(a, b);
    }
}
