//! Conformance + property tests for defensive addon fan-out.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_source::{aggregate, AddonResult, Aggregate, BreakerRegistry, CircuitConfig, Outcome};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    results: Vec<AddonResult>,
    config: CircuitConfig,
    now: u64,
    expect: Aggregate,
}

const SUITE: &str = include_str!("../conformance/fanout_vectors.json");

#[test]
fn fanout_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse fanout suite");
    for case in &suite.cases {
        let mut breakers = BreakerRegistry::new();
        let got = aggregate(&case.results, &mut breakers, &case.config, case.now);
        assert_eq!(got, case.expect, "fanout diverged for case '{}'", case.name);
    }
}

fn outcome() -> impl Strategy<Value = Outcome> {
    prop_oneof![
        prop::collection::vec("[a-z]{1,4}", 0..3).prop_map(|items| Outcome::Ok { items }),
        Just(Outcome::Malformed),
        Just(Outcome::Timeout),
        Just(Outcome::Error),
    ]
}

fn result() -> impl Strategy<Value = AddonResult> {
    ("[a-h]{1,3}", outcome()).prop_map(|(addon_id, outcome)| AddonResult { addon_id, outcome })
}

proptest! {
    #[test]
    fn a_failure_never_empties_a_non_empty_union(results in prop::collection::vec(result(), 0..16)) {
        let mut breakers = BreakerRegistry::new();
        let agg = aggregate(&results, &mut breakers, &CircuitConfig::default(), 1000);
        // If any addon returned a non-empty Ok, the merged result is non-empty (failures isolated).
        let any_nonempty_ok = results.iter().any(|r| matches!(&r.outcome, Outcome::Ok { items } if !items.is_empty()));
        prop_assert_eq!(any_nonempty_ok, !agg.items.is_empty());
    }

    #[test]
    fn survivors_and_failed_partition_the_addons(raw in prop::collection::vec(result(), 0..16)) {
        // A real fan-out queries each addon once; dedup the generated input by addon_id to model that.
        let mut seen = std::collections::HashSet::new();
        let results: Vec<AddonResult> = raw.into_iter().filter(|r| seen.insert(r.addon_id.clone())).collect();

        let mut breakers = BreakerRegistry::new();
        let agg = aggregate(&results, &mut breakers, &CircuitConfig::default(), 1000);
        // Each input result is accounted for exactly once (survivor or failed).
        prop_assert_eq!(agg.survivors.len() + agg.failed.len(), results.len());
        // No id is both a survivor and a failure.
        for f in &agg.failed {
            prop_assert!(!agg.survivors.contains(&f.addon_id));
        }
    }

    #[test]
    fn aggregate_is_deterministic(results in prop::collection::vec(result(), 0..16)) {
        let mut b1 = BreakerRegistry::new();
        let mut b2 = BreakerRegistry::new();
        let a1 = aggregate(&results, &mut b1, &CircuitConfig::default(), 1000);
        let a2 = aggregate(&results, &mut b2, &CircuitConfig::default(), 1000);
        prop_assert_eq!(a1, a2);
        prop_assert_eq!(b1, b2);
    }

    #[test]
    fn repeated_failures_open_the_breaker(n in 1u32..8) {
        let cfg = CircuitConfig { failure_threshold: 3, cooldown_secs: 100 };
        let mut breakers = BreakerRegistry::new();
        let bad = vec![AddonResult { addon_id: "bad".into(), outcome: Outcome::Timeout }];
        for _ in 0..n {
            aggregate(&bad, &mut breakers, &cfg, 1000);
        }
        let b = breakers.get("bad").unwrap();
        // Open exactly when failures reached the threshold.
        prop_assert_eq!(b.should_attempt(&cfg, 1000), n < 3);
    }
}
