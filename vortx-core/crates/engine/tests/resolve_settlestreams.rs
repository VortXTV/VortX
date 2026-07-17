//! Conformance + property tests for the engine stream LOAD settle query: the host hands back the plan it
//! executed + the per-source outcomes, and the engine returns the ranked order + the updated breaker
//! snapshot. The plan->settle pair must be identical across platforms, so the settled order and the breaker
//! snapshot are pinned by shared vectors. ranked is compared as a {raw_index, score} projection.

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
    ranked: Value,
    #[serde(rename = "circuitSnapshot")]
    circuit_snapshot: Value,
}

const SUITE: &str = include_str!("../conformance/resolve_settlestreams_vectors.json");

/// Project the engine's ranked array to the pinned {raw_index, score} shape (reasons/tags are not pinned).
fn project(ranked: &Value) -> Value {
    Value::Array(
        ranked
            .as_array()
            .unwrap()
            .iter()
            .map(|r| json!({ "raw_index": r["raw_index"], "score": r["score"] }))
            .collect(),
    )
}

#[test]
fn resolve_settlestreams_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse settlestreams suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let out = resolve_json(&engine, &case.request.to_string());
        let parsed: Value = serde_json::from_str(&out).expect("json");
        assert_eq!(parsed["kind"], "settled_streams", "{} kind", case.name);
        assert_eq!(project(&parsed["ranked"]), case.ranked, "ranked drifted for {}", case.name);
        assert_eq!(
            parsed["circuitSnapshot"], case.circuit_snapshot,
            "breaker snapshot drifted for {}",
            case.name
        );
    }
}

proptest! {
    /// Settling is deterministic and total: any plan + outcomes resolves to a settled_streams response whose
    /// ranked order is non-increasing by score, and every planned source appears in the returned breaker
    /// snapshot (success resets, a missing/failed source records a failure).
    #[test]
    fn settle_is_deterministic_and_snapshots_every_planned_source(n in 1usize..5) {
        let plan: Vec<Value> = (0..n)
            .map(|i| json!({ "addon_id": format!("a{i}"), "url": format!("http://h{i}"), "budgetMs": 5000 }))
            .collect();
        // Only the even-indexed sources return an outcome; odd ones go missing -> Timeout.
        let mut outcomes = serde_json::Map::new();
        for i in (0..n).step_by(2) {
            outcomes.insert(
                format!("a{i}"),
                json!({ "status": "ok", "items": [format!("{{\"url\":\"http://h{i}/1\",\"name\":\"720p WEB-DL\"}}")] }),
            );
        }
        let req = json!({
            "kind": "settle_streams",
            "plan": plan,
            "outcomes": Value::Object(outcomes),
            "now": 0
        })
        .to_string();

        let engine = init_runtime("o", "O");
        let a = resolve_json(&engine, &req);
        let b = resolve_json(&engine, &req);
        prop_assert_eq!(&a, &b); // deterministic

        let parsed: Value = serde_json::from_str(&a).unwrap();
        prop_assert_eq!(parsed["kind"].as_str(), Some("settled_streams"));
        // Non-increasing score order.
        let ranked = parsed["ranked"].as_array().unwrap();
        for w in ranked.windows(2) {
            prop_assert!(w[0]["score"].as_i64().unwrap() >= w[1]["score"].as_i64().unwrap());
        }
        // Every planned source is in the returned breaker snapshot.
        let snap = parsed["circuitSnapshot"].as_object().unwrap();
        prop_assert_eq!(snap.len(), n);
    }
}
