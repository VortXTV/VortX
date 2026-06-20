//! Conformance + property tests for the engine Home feed query, including parental enforcement through
//! the engine on the feed lanes.

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::{json, Value};
use vortx_engine::{dispatch, init_runtime, resolve_json, Action, Engine, InMemoryEnv};
use vortx_state::{maturity_allows_raw, ParentalFlags};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    request: Value,
    expect_lanes: Vec<ExpectLane>,
}

#[derive(Deserialize)]
struct ExpectLane {
    kind: String,
    items: Vec<String>,
}

const SUITE: &str = include_str!("../conformance/resolve_homefeed_vectors.json");

/// Extract (lane kind, [meta ids]) from a homefeed response.
fn lanes(out: &str) -> Vec<(String, Vec<String>)> {
    let parsed: Value = serde_json::from_str(out).expect("json");
    assert_eq!(parsed["kind"], "home_feed");
    parsed["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| {
            (
                l["kind"].as_str().unwrap().to_string(),
                l["items"].as_array().unwrap().iter().map(|i| i["meta_id"].as_str().unwrap().to_string()).collect(),
            )
        })
        .collect()
}

#[test]
fn owner_homefeed_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse homefeed suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let got = lanes(&resolve_json(&engine, &case.request.to_string()));
        let want: Vec<(String, Vec<String>)> =
            case.expect_lanes.iter().map(|e| (e.kind.clone(), e.items.clone())).collect();
        assert_eq!(got, want, "homefeed drifted for {}", case.name);
    }
}

fn kids_engine() -> Engine {
    let env = InMemoryEnv::new(1000);
    let mut engine = init_runtime("owner", "Owner");
    dispatch(&mut engine, Action::AddProfile { id: "kid".into(), name: "Kid".into() }, &env);
    dispatch(
        &mut engine,
        Action::SetParental { id: "kid".into(), kids: true, maturity_ceiling: None },
        &env,
    );
    dispatch(&mut engine, Action::SwitchProfile { id: "kid".into() }, &env);
    engine
}

#[test]
fn kids_homefeed_drops_blocked_trending_rows() {
    let engine = kids_engine();
    let req = json!({
        "kind": "home_feed",
        "trending": ["g", "r", "u"],
        "ratings": [
            { "meta_id": "g", "certification": "G" },
            { "meta_id": "r", "certification": "R" }
        ]
    })
    .to_string();
    let got = lanes(&resolve_json(&engine, &req));
    // R is over the kids ceiling; u is unrated -> fail-closed. Only g survives.
    assert_eq!(got, vec![("trending".to_string(), vec!["g".to_string()])]);
}

proptest! {
    /// A kids profile's Home feed never contains a parental-blocked item, for any trending list + ratings.
    #[test]
    fn kids_homefeed_never_shows_blocked_items(
        trending in prop::collection::vec("[a-e]", 0..6),
        rated in prop::collection::vec(("[a-e]", prop::option::of("(G|PG|R|TV-MA|18|NR)")), 0..6),
    ) {
        let engine = kids_engine();
        let ratings: Vec<Value> = rated.iter().map(|(id, cert)| {
            let mut m = json!({ "meta_id": id });
            if let Some(c) = cert { m["certification"] = json!(c); }
            m
        }).collect();
        let cert_of: std::collections::HashMap<&str, Option<&str>> =
            rated.iter().map(|(id, c)| (id.as_str(), c.as_deref())).collect();
        let req = json!({ "kind": "home_feed", "trending": trending, "ratings": ratings }).to_string();

        let kids = ParentalFlags { kids: true, ..Default::default() };
        for (_, items) in lanes(&resolve_json(&engine, &req)) {
            for id in items {
                let cert = cert_of.get(id.as_str()).copied().flatten();
                prop_assert!(maturity_allows_raw(&kids, cert), "blocked item {} surfaced", id);
            }
        }
    }
}
