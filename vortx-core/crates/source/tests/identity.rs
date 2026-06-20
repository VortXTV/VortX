//! Conformance + property tests for cross-namespace id reconciliation.

use proptest::prelude::*;
use vortx_source::{reconcile, CanonicalId, IdSet};

use serde::Deserialize;

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    sets: Vec<Vec<String>>,
    expect: Vec<CanonicalId>,
}

const SUITE: &str = include_str!("../conformance/identity_vectors.json");

fn build_sets(raw: &[Vec<String>]) -> Vec<IdSet> {
    raw.iter()
        .map(|s| IdSet::parse(&s.iter().map(String::as_str).collect::<Vec<_>>()))
        .collect()
}

#[test]
fn reconcile_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse identity suite");
    for case in &suite.cases {
        let got = reconcile(&build_sets(&case.sets));
        assert_eq!(
            got, case.expect,
            "reconcile diverged for case '{}'",
            case.name
        );
    }
}

// A raw id token: an imdb tt-id, or a namespaced id over a small pool, so collisions actually happen.
fn raw_id() -> impl Strategy<Value = String> {
    prop_oneof![
        (0u32..6).prop_map(|n| format!("tt{n}")),
        (0u32..6).prop_map(|n| format!("tmdb:{n}")),
        (0u32..6).prop_map(|n| format!("tvdb:{n}")),
    ]
}

fn id_set() -> impl Strategy<Value = Vec<String>> {
    prop::collection::vec(raw_id(), 1..4)
}

proptest! {
    #[test]
    fn reconcile_is_commutative(sets in prop::collection::vec(id_set(), 0..10)) {
        let forward = reconcile(&build_sets(&sets));
        let mut rev = sets.clone();
        rev.reverse();
        let backward = reconcile(&build_sets(&rev));
        prop_assert_eq!(forward, backward); // output is sorted, so order-independent
    }

    #[test]
    fn reconcile_is_idempotent(sets in prop::collection::vec(id_set(), 0..10)) {
        let once = reconcile(&build_sets(&sets));
        // Feed the canonical identities back in as id sets.
        let as_sets: Vec<IdSet> = once.iter().map(|c| IdSet { ids: c.external_ids() }).collect();
        let twice = reconcile(&as_sets);
        let ids_once: Vec<_> = once.iter().map(|c| c.ids.clone()).collect();
        let ids_twice: Vec<_> = twice.iter().map(|c| c.ids.clone()).collect();
        prop_assert_eq!(ids_once, ids_twice);
    }

    #[test]
    fn disjoint_sets_never_merge(n in 1usize..8) {
        // Each set has a unique imdb id shared with nothing else.
        let sets: Vec<Vec<String>> = (0..n).map(|i| vec![format!("tt{}00", i)]).collect();
        let out = reconcile(&build_sets(&sets));
        prop_assert_eq!(out.len(), n); // never fuses two distinct titles
    }

    #[test]
    fn no_namespace_is_dropped(sets in prop::collection::vec(id_set(), 1..10)) {
        let out = reconcile(&build_sets(&sets));
        // A conflicted namespace keeps only the smallest value, but no whole namespace ever vanishes.
        for set in &sets {
            for raw in set {
                let ns = raw.split_once(':').map(|(n, _)| n).unwrap_or("imdb");
                let present = out.iter().any(|c| c.ids.contains_key(ns));
                prop_assert!(present, "namespace {ns} (from {raw}) missing from output");
            }
        }
    }
}
