//! Cross-language conformance + property tests for the engine subtitle resolution query path.

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
    expect_index: Option<usize>,
}

const SUITE: &str = include_str!("../conformance/resolve_subtitles_vectors.json");

#[test]
fn resolve_subtitles_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse subtitle suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let out = resolve_json(&engine, &case.request.to_string());
        let parsed: Value = serde_json::from_str(&out).expect("json");
        assert_eq!(parsed["kind"], "subtitles", "{} kind", case.name);
        match case.expect_index {
            None => assert!(parsed["selected"].is_null(), "{} expected null", case.name),
            Some(i) => assert_eq!(
                parsed["selected"]["track_index"].as_u64(),
                Some(i as u64),
                "{} index",
                case.name
            ),
        }
    }
}

proptest! {
    /// Whatever tracks come in, the selection is always one of the provided track indices (or null), never
    /// out of range. The host can trust the index it gets back.
    #[test]
    fn selected_index_is_always_in_range(n in 0usize..6, lang_pref in prop::option::of("[a-z]{2}")) {
        let langs = ["en", "es", "fr", "de", "ja", "ko"];
        let tracks: Vec<Value> = (0..n)
            .map(|i| json!({
                "id": format!("t{i}"),
                "lang": langs[i],
                "forced": false,
                "hearing_impaired": false,
                "format": "srt",
                "tier": "embedded",
                "rating": null
            }))
            .collect();
        let prefs = match &lang_pref {
            Some(l) => json!({ "languages": [l] }),
            None => json!({}),
        };
        let req = json!({ "kind": "subtitles", "tracks": tracks, "prefs": prefs }).to_string();
        let out = resolve_json(&engine_for_test(), &req);
        let parsed: Value = serde_json::from_str(&out).unwrap();
        prop_assert_eq!(parsed["kind"].as_str(), Some("subtitles"));
        if let Some(idx) = parsed["selected"]["track_index"].as_u64() {
            prop_assert!((idx as usize) < n);
        }
    }
}

fn engine_for_test() -> vortx_engine::Engine {
    init_runtime("owner", "Owner")
}
