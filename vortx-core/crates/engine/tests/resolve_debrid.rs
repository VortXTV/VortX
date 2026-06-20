//! Conformance + property tests for the engine debrid resolve query path.

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::{json, Value};
use vortx_engine::{init_runtime, resolve_json};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    request: Value,
    plan: Value,
}

const SUITE: &str = include_str!("../conformance/resolve_debrid_vectors.json");

#[test]
fn resolve_debrid_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse debrid suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let out = resolve_json(&engine, &case.request.to_string());
        let parsed: Value = serde_json::from_str(&out).expect("json");
        assert_eq!(parsed["kind"], "debrid", "{} kind", case.name);
        assert_eq!(parsed["plan"], case.plan, "debrid plan drifted for {}", case.name);
    }
}

proptest! {
    /// A debrid request always resolves to a debrid plan with one step per source, each rank in 0..=3, and
    /// the steps in non-decreasing rank order (the deterministic resolve priority).
    #[test]
    fn debrid_plan_is_one_step_per_source_in_rank_order(n in 0usize..6) {
        let sources: Vec<Value> = (0..n)
            .map(|i| json!({ "kind": "magnet", "infohash": format!("{:040x}", i) }))
            .collect();
        let req = json!({
            "kind": "debrid",
            "sources": sources,
            "userServices": ["realdebrid"],
            "cached": [],
            "now": 0
        })
        .to_string();
        let out = resolve_json(&init_runtime("o", "O"), &req);
        let parsed: Value = serde_json::from_str(&out).unwrap();
        prop_assert_eq!(parsed["kind"].as_str(), Some("debrid"));
        let plan = parsed["plan"].as_array().unwrap();
        prop_assert_eq!(plan.len(), n);
        let mut prev_rank = 0u64;
        for step in plan {
            let rank = step["rank"].as_u64().unwrap();
            prop_assert!(rank <= 3);
            prop_assert!(rank >= prev_rank);
            prev_rank = rank;
        }
    }
}
