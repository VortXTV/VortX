//! Cross-language conformance + property tests for the debrid cache flywheel.
//!
//! The rate budget is integer-only, so it is pinned byte-for-byte by the JSON vectors (every platform
//! must allow/deny the same calls). The writeback half is validated by properties: a probe ALWAYS yields
//! a signed fact (positive or negative), and `should_probe` never spends a call on a hash the hive already
//! knows fresh nor exceeds the budget.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_debrid::{should_probe, writeback_fact, ProbeResult, RateBudget, RateMeter};
use vortx_hive::{DebridService, NodeIdentity};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    cached_per_min: u32,
    uncached_per_hour: u32,
    calls: Vec<Call>,
    expect_allowed: Vec<bool>,
}

#[derive(Deserialize)]
struct Call {
    kind: String,
    now: u64,
}

const SUITE: &str = include_str!("../conformance/flywheel_vectors.json");

#[test]
fn rate_budget_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse flywheel suite");
    assert!(suite.cases.len() >= 4, "expected the full vector set");
    for case in &suite.cases {
        let budget = RateBudget {
            cached_per_min: case.cached_per_min,
            uncached_per_hour: case.uncached_per_hour,
        };
        let mut meter = RateMeter::default();
        let got: Vec<bool> = case
            .calls
            .iter()
            .map(|c| match c.kind.as_str() {
                "cached" => meter.try_cached(&budget, c.now),
                "uncached" => meter.try_uncached(&budget, c.now),
                other => panic!("unknown call kind {other} in {}", case.name),
            })
            .collect();
        assert_eq!(got, case.expect_allowed, "rate budget drifted for {}", case.name);
    }
}

const IH: &str = "aabbccddeeff00112233445566778899aabbccdd";

proptest! {
    /// In any single minute window, the number of allowed cached calls never exceeds the budget.
    #[test]
    fn cached_budget_is_never_exceeded_in_a_window(budget in 0u32..8, attempts in 1usize..40) {
        let b = RateBudget { cached_per_min: budget, uncached_per_hour: 1000 };
        let mut meter = RateMeter::default();
        let allowed = (0..attempts).filter(|_| meter.try_cached(&b, 0)).count();
        prop_assert!(allowed as u32 <= budget);
    }

    /// A known-fresh hash is never probed, regardless of budget headroom.
    #[test]
    fn should_probe_never_spends_on_a_known_hash(budget in 0u32..8, now in 0u64..100_000) {
        let b = RateBudget { cached_per_min: budget, uncached_per_hour: 1000 };
        let mut meter = RateMeter::default();
        prop_assert!(!should_probe(&mut meter, &b, true, now));
        // And the skipped probe consumed nothing: a real unknown probe still has full budget.
        let spent = should_probe(&mut meter, &b, false, now);
        prop_assert_eq!(spent, budget > 0);
    }

    /// Every probe outcome mints a signed fact whose `cached` flag matches the probe.
    #[test]
    fn every_probe_yields_a_verifiable_writeback_fact(cached in any::<bool>(), file_idx in proptest::option::of(0u32..50)) {
        let id = NodeIdentity::generate().unwrap();
        let probe = ProbeResult {
            infohash: IH.into(),
            service: DebridService::RealDebrid,
            file_idx,
            cached,
        };
        let fact = writeback_fact(&id, &probe, 1_000, 86_400).unwrap();
        prop_assert_eq!(fact.cached, cached);
        prop_assert!(fact.verify_signed().is_ok());
    }
}
