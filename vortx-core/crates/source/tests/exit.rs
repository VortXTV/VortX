//! Cross-language conformance + property tests for quality-aware fan-out early termination.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_source::{should_stop, ExitConfig, ExitDecision, PartialResult};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    partial: Vec<PartialResult>,
    config: ExitConfig,
    expect: ExitDecision,
}

const SUITE: &str = include_str!("../conformance/exit_vectors.json");

#[test]
fn exit_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse exit suite");
    assert!(suite.cases.len() >= 5);
    for case in &suite.cases {
        assert_eq!(
            should_stop(&case.partial, &case.config),
            case.expect,
            "exit decision drifted for {}",
            case.name
        );
    }
}

fn partial() -> impl Strategy<Value = PartialResult> {
    (any::<bool>(), 0u16..3000).prop_map(|(cached, height)| PartialResult { cached, height })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// Monotone: once should_stop says StopNow, appending more results never flips it back to Continue.
    /// (A growing result set can only make stopping more justified.)
    #[test]
    fn stop_is_monotone_under_more_results(
        results in prop::collection::vec(partial(), 0..40),
        extra in prop::collection::vec(partial(), 0..10),
        min_cached in 0u32..6,
        target in prop::sample::select(vec![720u16, 1080, 2160]),
        min_total in 0u32..20,
    ) {
        let cfg = ExitConfig { min_cached_at_target: min_cached, target_height: target, min_total };
        if let ExitDecision::StopNow { .. } = should_stop(&results, &cfg) {
            let mut more = results.clone();
            more.extend(extra);
            let still_stops = matches!(should_stop(&more, &cfg), ExitDecision::StopNow { .. });
            prop_assert!(still_stops);
        }
        // Determinism.
        prop_assert_eq!(should_stop(&results, &cfg), should_stop(&results, &cfg));
    }

    /// StopNow is never returned before a threshold is actually met (no premature stop).
    #[test]
    fn never_stops_before_a_threshold_is_met(
        results in prop::collection::vec(partial(), 0..40),
    ) {
        // Thresholds that nothing in 0..40 random results can satisfy: huge cached requirement, huge total.
        let cfg = ExitConfig { min_cached_at_target: 1000, target_height: 1080, min_total: 1000 };
        prop_assert_eq!(should_stop(&results, &cfg), ExitDecision::Continue);
    }
}
