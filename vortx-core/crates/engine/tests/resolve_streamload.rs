//! Conformance + property tests for the engine stream LOAD plan query: the pure stateless half of the LOAD
//! effect model. The engine routes a request over a host-supplied source snapshot and returns the fetch
//! plan, holding no source state and doing no I/O. The plan must be identical across platforms (it drives
//! the host fan-out), so it is pinned by shared vectors.

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
    requests: Value,
}

const SUITE: &str = include_str!("../conformance/resolve_streamload_vectors.json");

#[test]
fn resolve_streamload_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse streamload suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let out = resolve_json(&engine, &case.request.to_string());
        let parsed: Value = serde_json::from_str(&out).expect("json");
        assert_eq!(parsed["kind"], "stream_load_plan", "{} kind", case.name);
        assert_eq!(
            parsed["requests"], case.requests,
            "streamload plan drifted for {}",
            case.name
        );
    }
}

proptest! {
    /// A stream LOAD always resolves to a stream_load_plan whose requests are a subset of the supplied
    /// source ids, sorted by addon id, with no duplicates (the deterministic, circuit-filtered plan).
    #[test]
    fn streamload_plan_is_sorted_subset_of_sources(n in 0usize..6) {
        let entries: Vec<Value> = (0..n)
            .map(|i| json!({
                "id": format!("src{i}"),
                "url": format!("https://h{i}.tv/manifest.json"),
                "kind": "stremio_addon",
                "capabilities": ["stream"],
                "types": [],
                "idPrefixes": ["tt"]
            }))
            .collect();
        let req = json!({
            "kind": "stream_load",
            "req": { "kind": "stream", "type": "movie", "id": "tt1" },
            "registrySnapshot": entries,
            "now": 0,
            "budgetMs": 5000
        })
        .to_string();
        let out = resolve_json(&init_runtime("o", "O"), &req);
        let parsed: Value = serde_json::from_str(&out).unwrap();
        prop_assert_eq!(parsed["kind"].as_str(), Some("stream_load_plan"));
        let plan = parsed["requests"].as_array().unwrap();
        // One request per source (all match), sorted by addon id, unique.
        prop_assert_eq!(plan.len(), n);
        let ids: Vec<&str> = plan.iter().map(|r| r["addon_id"].as_str().unwrap()).collect();
        let mut sorted = ids.clone();
        sorted.sort_unstable();
        prop_assert_eq!(&ids, &sorted);
        for w in ids.windows(2) {
            prop_assert!(w[0] != w[1]);
        }
    }
}
