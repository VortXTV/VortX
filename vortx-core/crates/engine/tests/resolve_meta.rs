//! Conformance + property tests for engine meta resolution: a single title detail is parental-gated
//! through the engine, so a kids profile cannot open an over-ceiling title even via a direct deep link.

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
    expect_id: String,
}

const SUITE: &str = include_str!("../conformance/resolve_meta_vectors.json");

#[test]
fn owner_meta_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse meta suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let out = resolve_json(&engine, &case.request.to_string());
        let parsed: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(parsed["kind"], "meta", "{} kind", case.name);
        assert_eq!(
            parsed["meta"]["id"].as_str(),
            Some(case.expect_id.as_str()),
            "{} id",
            case.name
        );
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

fn resolve_meta(engine: &Engine, cert: Option<&str>) -> Value {
    let mut meta = json!({ "id": "tt1", "type": "movie", "name": "A" });
    if let Some(c) = cert {
        meta["certification"] = json!(c);
    }
    let out = resolve_json(engine, &json!({ "kind": "meta", "meta": meta }).to_string());
    serde_json::from_str(&out).unwrap()
}

#[test]
fn kids_deep_link_to_blocked_meta_returns_null() {
    let engine = kids_engine();
    assert!(resolve_meta(&engine, Some("R"))["meta"].is_null(), "R is blocked for kids");
    assert!(resolve_meta(&engine, None)["meta"].is_null(), "unrated is fail-closed for kids");
    assert!(!resolve_meta(&engine, Some("G"))["meta"].is_null(), "G is within the kids ceiling");
}

proptest! {
    /// A kids profile never receives a blocked meta, for any certification.
    #[test]
    fn kids_meta_is_never_blocked_content(cert in prop::option::of("(G|PG|PG-13|R|TV-MA|18|NR)")) {
        let engine = kids_engine();
        let resp = resolve_meta(&engine, cert.as_deref());
        let kids = ParentalFlags { kids: true, ..Default::default() };
        if resp["meta"].is_null() {
            // Blocked: the gate must agree it is not allowed.
            prop_assert!(!maturity_allows_raw(&kids, cert.as_deref()));
        } else {
            prop_assert!(maturity_allows_raw(&kids, cert.as_deref()));
        }
    }
}
