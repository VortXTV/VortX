//! Cross-language conformance + property tests for the engine resolution query path.

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::Value;
use vortx_engine::{init_runtime, resolve_json};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    request: Value,
    expect_ranked: Vec<Expect>,
}

#[derive(Deserialize)]
struct Expect {
    raw_index: usize,
    score: i64,
}

const SUITE: &str = include_str!("../conformance/resolve_vectors.json");

#[test]
fn resolve_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse resolve suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let out = resolve_json(&engine, &case.request.to_string());
        let parsed: Value = serde_json::from_str(&out).expect("response is json");
        assert_eq!(parsed["kind"], "streams", "{} not a streams response", case.name);
        let ranked = parsed["ranked"].as_array().expect("ranked array");
        let got: Vec<(usize, i64)> = ranked
            .iter()
            .map(|r| {
                (
                    r["raw_index"].as_u64().unwrap() as usize,
                    r["score"].as_i64().unwrap(),
                )
            })
            .collect();
        let want: Vec<(usize, i64)> =
            case.expect_ranked.iter().map(|e| (e.raw_index, e.score)).collect();
        assert_eq!(got, want, "resolution drifted for {}", case.name);
    }
}

proptest! {
    /// resolve_json never panics and always returns parseable JSON tagged streams or error, whatever the
    /// input. The host can trust the FFI query contract no matter what crosses it.
    #[test]
    fn resolve_json_is_total_and_parseable(s in ".{0,80}") {
        let engine = init_runtime("owner", "Owner");
        let out = resolve_json(&engine, &s);
        let parsed: Value = serde_json::from_str(&out).expect("always json");
        let kind = parsed["kind"].as_str().unwrap_or("");
        prop_assert!(kind == "streams" || kind == "error");
    }

    /// A well-formed streams request always resolves to a streams response with exactly the input count
    /// (the ranker keeps every stream that passes the default prefs, which apply no filters).
    #[test]
    fn streams_request_resolves_all_inputs(n in 0usize..6) {
        let engine = init_runtime("owner", "Owner");
        let labels = ["2160p WEB-DL", "1080p BluRay", "720p HDTV", "480p WEBRip", "2160p REMUX", "1080p WEB-DL"];
        let streams: Vec<Value> = (0..n).map(|i| serde_json::json!({"name": labels[i]})).collect();
        let req = serde_json::json!({"kind": "streams", "streams": streams}).to_string();
        let out = resolve_json(&engine, &req);
        let parsed: Value = serde_json::from_str(&out).unwrap();
        prop_assert_eq!(parsed["kind"].as_str(), Some("streams"));
        prop_assert_eq!(parsed["ranked"].as_array().unwrap().len(), n);
    }
}
