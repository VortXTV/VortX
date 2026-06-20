//! Conformance + property tests for the collaborative re-rank.
//!
//! Conformance pins the integer affinity core. The properties prove the load-bearing invariant carried up
//! from the hive primitive: an under-quorum / untrusted co-visit map never reorders recommendations, and
//! the re-rank is deterministic.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_hive::{CoVisitFact, CoVisitMap, NodeIdentity, TrustStore, merge_covisit};
use vortx_reco::{affinity_from_strengths, rerank_with_collab, CollabModel, CollabPrefs};

// Recommendation is re-exported; reconstruct via the public reco API surface.
use vortx_reco::{Reason, Recommendation};

#[derive(Deserialize)]
struct Suite {
    affinity: Vec<AffVec>,
}

#[derive(Deserialize)]
struct AffVec {
    strengths: Vec<u32>,
    expect: u32,
}

const SUITE: &str = include_str!("../conformance/collab_vectors.json");

#[test]
fn affinity_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse collab suite");
    assert!(suite.affinity.len() >= 5);
    for v in &suite.affinity {
        assert_eq!(affinity_from_strengths(&v.strengths), v.expect, "affinity drifted");
    }
}

fn rec(id: &str, score: f32) -> Recommendation {
    Recommendation {
        meta_id: id.into(),
        score,
        reasons: vec![Reason::Trending],
    }
}

/// Plain score-desc, meta-id-asc order, the baseline a 0-boost re-rank must reproduce.
fn baseline(recs: &[Recommendation]) -> Vec<String> {
    let mut v: Vec<(String, f32)> = recs.iter().map(|r| (r.meta_id.clone(), r.score)).collect();
    v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap().then_with(|| a.0.cmp(&b.0)));
    v.into_iter().map(|(id, _)| id).collect()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(80))]

    /// A map built only from UNTRUSTED (public) signers is never authoritative, so the re-rank must equal
    /// the plain score order: an under-quorum co-visit never moves a recommendation.
    #[test]
    fn untrusted_covisit_never_reorders(
        scores in prop::collection::vec(0.0f32..1.0, 1..6),
        attest in prop::collection::vec((0usize..5, 0usize..5, 1u32..500), 0..10),
    ) {
        let ids: Vec<String> = (0..scores.len()).map(|i| format!("m{i}")).collect();
        let recs: Vec<Recommendation> =
            ids.iter().zip(&scores).map(|(id, s)| rec(id, *s)).collect();

        // Build a co-visit map from random PUBLIC signers (none added to the trust allowlist).
        let me = NodeIdentity::generate().unwrap();
        let trust = TrustStore::new(me.public_b64url());
        let mut map = CoVisitMap::new();
        for &(a, b, c) in &attest {
            if a == b { continue; }
            let signer = NodeIdentity::generate().unwrap();
            let f = CoVisitFact::create(&signer, &format!("m{a}"), &format!("m{b}"), c, 1000, 21_600).unwrap();
            merge_covisit(&mut map, f, 1000);
        }
        let model = CollabModel { map: &map, trust: &trust, now: 1000 };
        let out = rerank_with_collab(recs.clone(), &ids, &model, &CollabPrefs::default());
        let got: Vec<String> = out.iter().map(|r| r.meta_id.clone()).collect();
        prop_assert_eq!(got, baseline(&recs));
    }

    /// Empty seeds: nothing to relate against, order is the plain score order.
    #[test]
    fn empty_seeds_preserve_order(scores in prop::collection::vec(0.0f32..1.0, 1..6)) {
        let recs: Vec<Recommendation> =
            scores.iter().enumerate().map(|(i, s)| rec(&format!("m{i}"), *s)).collect();
        let me = NodeIdentity::generate().unwrap();
        let trust = TrustStore::new(me.public_b64url());
        let map = CoVisitMap::new();
        let model = CollabModel { map: &map, trust: &trust, now: 1000 };
        let out = rerank_with_collab(recs.clone(), &[], &model, &CollabPrefs::default());
        let got: Vec<String> = out.iter().map(|r| r.meta_id.clone()).collect();
        prop_assert_eq!(got, baseline(&recs));
    }

    /// Determinism: identical inputs yield the identical re-ranked order.
    #[test]
    fn rerank_is_deterministic(scores in prop::collection::vec(0.0f32..1.0, 1..6)) {
        let recs: Vec<Recommendation> =
            scores.iter().enumerate().map(|(i, s)| rec(&format!("m{i}"), *s)).collect();
        let me = NodeIdentity::generate().unwrap();
        let trust = TrustStore::new(me.public_b64url());
        let map = CoVisitMap::new();
        let model = CollabModel { map: &map, trust: &trust, now: 1000 };
        let a = rerank_with_collab(recs.clone(), &["m0".into()], &model, &CollabPrefs::default());
        let b = rerank_with_collab(recs, &["m0".into()], &model, &CollabPrefs::default());
        prop_assert_eq!(a, b);
    }
}
