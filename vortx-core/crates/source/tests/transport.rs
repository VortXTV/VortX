//! Cross-language conformance + property tests for the deadline-bounded fan-out orchestration over the host
//! Fetch boundary. Proves the substrate logic with zero I/O: a mock Fetch stands in for the host, so the
//! engine's plan/realize/settle path (skip circuit-open sources, isolate failures, settle partial results)
//! is exercised deterministically.

use std::collections::BTreeMap;

use proptest::prelude::*;
use serde::Deserialize;
use vortx_source::{
    run_fanout, Aggregate, BreakerRegistry, CircuitConfig, Fetch, FetchOutcome, FetchRequest,
};

/// A mock host fetcher: returns the mapped outcome for a planned request, else `Timeout` (a source the host
/// could not settle by the deadline).
struct MockFetch {
    map: BTreeMap<String, FetchOutcome>,
}

impl Fetch for MockFetch {
    fn fetch(&self, req: &FetchRequest) -> FetchOutcome {
        self.map
            .get(&req.addon_id)
            .cloned()
            .unwrap_or(FetchOutcome::Timeout)
    }
}

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    candidates: Vec<(String, String)>,
    #[serde(default)]
    breakers: BreakerRegistry,
    now: u64,
    budget_ms: u64,
    outcomes: BTreeMap<String, FetchOutcome>,
    expect: Aggregate,
}

const SUITE: &str = include_str!("../conformance/transport_vectors.json");

#[test]
fn transport_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse transport suite");
    assert!(suite.cases.len() >= 4);
    for case in &suite.cases {
        let mut breakers = case.breakers.clone();
        let fetch = MockFetch {
            map: case.outcomes.clone(),
        };
        let agg = run_fanout(
            &fetch,
            &case.candidates,
            &mut breakers,
            &CircuitConfig::default(),
            case.now,
            case.budget_ms,
        );
        assert_eq!(agg, case.expect, "transport fan-out drifted for {}", case.name);
    }
}

fn outcome() -> impl Strategy<Value = FetchOutcome> {
    prop_oneof![
        prop::collection::vec("[a-z][0-9]", 0..3).prop_map(|items| FetchOutcome::Ok { items }),
        Just(FetchOutcome::Malformed),
        Just(FetchOutcome::Timeout),
        Just(FetchOutcome::Error),
    ]
}

fn entries() -> impl Strategy<Value = BTreeMap<String, FetchOutcome>> {
    prop::collection::btree_map("[a-e]", outcome(), 0..5)
}

fn candidates_of(entries: &BTreeMap<String, FetchOutcome>) -> Vec<(String, String)> {
    entries
        .keys()
        .map(|k| (k.clone(), format!("http://{k}")))
        .collect()
}

proptest! {
    // Same inputs (no open breakers) always settle to the same Aggregate, however the host parallelizes.
    #[test]
    fn run_fanout_is_deterministic(entries in entries(), now in 0u64..10_000) {
        let candidates = candidates_of(&entries);
        let fetch = MockFetch { map: entries.clone() };
        let mut b1 = BreakerRegistry::new();
        let mut b2 = BreakerRegistry::new();
        let a1 = run_fanout(&fetch, &candidates, &mut b1, &CircuitConfig::default(), now, 5000);
        let a2 = run_fanout(&fetch, &candidates, &mut b2, &CircuitConfig::default(), now, 5000);
        prop_assert_eq!(a1, a2);
    }

    // A failing or timed-out source never removes an item from a succeeding sibling, and survivors+failed
    // exactly partition the planned set.
    #[test]
    fn no_ok_item_is_dropped_by_a_sibling_failure(entries in entries()) {
        let candidates = candidates_of(&entries);
        let fetch = MockFetch { map: entries.clone() };
        let mut breakers = BreakerRegistry::new();
        let agg = run_fanout(&fetch, &candidates, &mut breakers, &CircuitConfig::default(), 1000, 5000);

        for (id, o) in &entries {
            match o {
                FetchOutcome::Ok { items } => {
                    for it in items {
                        prop_assert!(agg.items.contains(it), "dropped {} from {}", it, id);
                    }
                    prop_assert!(agg.survivors.contains(id));
                }
                _ => prop_assert!(agg.failed.iter().any(|f| &f.addon_id == id)),
            }
        }
        // No open breakers, so every candidate is planned and ends up either a survivor or a failure.
        prop_assert_eq!(agg.survivors.len() + agg.failed.len(), entries.len());
    }
}
