//! Conformance + property tests for engine catalog resolution, the proof that parental controls are
//! enforced THROUGH the engine: a kids profile, set via the dispatch path, never receives a blocked row.

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::{json, Value};
use vortx_engine::{dispatch, init_runtime, resolve_json, Action, InMemoryEnv};
use vortx_state::{maturity_allows, parse_certification, ParentalFlags};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    request: Value,
    expect_ids: Vec<String>,
}

const SUITE: &str = include_str!("../conformance/resolve_catalog_vectors.json");

fn ids(out: &str) -> Vec<String> {
    let parsed: Value = serde_json::from_str(out).expect("json");
    assert_eq!(parsed["kind"], "catalog");
    parsed["metas"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn owner_catalog_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse catalog suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let out = resolve_json(&engine, &case.request.to_string());
        assert_eq!(ids(&out), case.expect_ids, "catalog drifted for {}", case.name);
    }
}

/// Make a kids profile active via the real command path, then resolve a catalog.
fn kids_engine() -> vortx_engine::Engine {
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
fn kids_profile_catalog_is_filtered_through_the_engine() {
    let engine = kids_engine();
    let req = json!({"kind":"catalog","metas":[
        {"id":"g","type":"movie","name":"G","certification":"G"},
        {"id":"r","type":"movie","name":"R","certification":"R"},
        {"id":"u","type":"movie","name":"U"}
    ]})
    .to_string();
    let out = resolve_json(&engine, &req);
    // G (rating 0) is within the kids default ceiling 12; R (17) is over it; U is unrated -> fail-closed.
    assert_eq!(ids(&out), vec!["g"]);
}

proptest! {
    /// A kids profile NEVER receives a catalog row its parental gate disallows, for any certifications.
    #[test]
    fn kids_catalog_never_returns_a_blocked_row(
        certs in prop::collection::vec(prop::option::of("(G|PG|PG-13|R|TV-MA|18|NR)"), 0..8),
    ) {
        let engine = kids_engine();
        let metas: Vec<Value> = certs.iter().enumerate().map(|(i, c)| {
            let mut m = json!({"id": format!("m{i}"), "type": "movie", "name": format!("M{i}")});
            if let Some(cert) = c {
                m["certification"] = json!(cert);
            }
            m
        }).collect();
        let req = json!({"kind":"catalog","metas": metas}).to_string();
        let out = resolve_json(&engine, &req);

        let kids = ParentalFlags { kids: true, ..Default::default() };
        let parsed: Value = serde_json::from_str(&out).unwrap();
        for m in parsed["metas"].as_array().unwrap() {
            let cert = m["certification"].as_str();
            let rating = cert.and_then(parse_certification);
            prop_assert!(maturity_allows(&kids, rating), "blocked row {} surfaced", m["id"]);
        }
    }
}
