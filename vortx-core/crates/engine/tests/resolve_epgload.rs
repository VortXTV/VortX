//! End-to-end tests for the EPG LOAD: the FIRST live LOAD, bringing live TV onto the same plan -> fetch ->
//! settle effect model as VOD. UNLIKE the other LOADs, the item key is the WHOLE XMLTV document text (one per
//! source), which the engine parses with the LT2 tz -> UTC fence. EPG is singular per source (first document
//! that parses non-empty wins). The host boundary is stubbed by a deterministic in-memory Fetch (no network).

use std::collections::BTreeMap;

use proptest::prelude::*;
use serde_json::{json, Map, Value};
use vortx_engine::{init_runtime, resolve_json};
use vortx_source::{execute_plan, Fetch, FetchOutcome, FetchRequest};

struct FakeNet {
    items: BTreeMap<String, Vec<String>>,
}

impl Fetch for FakeNet {
    fn fetch(&self, req: &FetchRequest) -> FetchOutcome {
        match self.items.get(&req.addon_id) {
            Some(items) => FetchOutcome::Ok {
                items: items.clone(),
            },
            None => FetchOutcome::Error,
        }
    }
}

/// An EPG-capable stremio_addon source entry.
fn source(id: &str) -> Value {
    json!({
        "id": id,
        "url": format!("https://{id}.tv/manifest.json"),
        "kind": "stremio_addon",
        "capabilities": ["epg"],
        "types": ["tv"],
        "idPrefixes": []
    })
}

/// A small XMLTV document: one channel + one programme at a known UTC instant (the LT2 conformance vector).
/// 2026-06-29 14:00:00 UTC = 1782741600000 ms.
const XMLTV: &str = "<tv><channel id=\"cnn.us\"><display-name>CNN</display-name></channel>\
    <programme start=\"20260629140000 +0000\" stop=\"20260629150000 +0000\" channel=\"cnn.us\">\
    <title>World News</title></programme></tv>";

/// Drive the full EPG LOAD round-trip through the JSON API: EpgLoad -> execute_plan(fake) -> SettleEpg.
fn roundtrip(sources: &[Value], fake: &FakeNet) -> Value {
    let engine = init_runtime("o", "O");

    let load = json!({
        "kind": "epg_load",
        "req": { "kind": "epg", "type": "tv", "id": "cnn.us" },
        "registrySnapshot": sources,
        "now": 0,
        "budgetMs": 5000
    })
    .to_string();
    let plan_resp: Value = serde_json::from_str(&resolve_json(&engine, &load)).unwrap();
    assert_eq!(plan_resp["kind"], "epg_load_plan");
    let plan: Vec<FetchRequest> = serde_json::from_value(plan_resp["requests"].clone()).unwrap();

    let outcomes = execute_plan(&plan, fake);
    let outcomes_map: Map<String, Value> = outcomes
        .iter()
        .map(|(id, o)| (id.clone(), serde_json::to_value(o).unwrap()))
        .collect();
    let settle = json!({
        "kind": "settle_epg",
        "plan": serde_json::to_value(&plan).unwrap(),
        "outcomes": Value::Object(outcomes_map),
        "now": 0
    })
    .to_string();
    let settled: Value = serde_json::from_str(&resolve_json(&engine, &settle)).unwrap();
    assert_eq!(settled["kind"], "settled_epg");
    settled
}

#[test]
fn epg_load_plan_uses_the_byte_exact_epg_url() {
    let engine = init_runtime("o", "O");
    let load = json!({
        "kind": "epg_load",
        "req": { "kind": "epg", "type": "tv", "id": "cnn.us" },
        "registrySnapshot": [source("alpha")],
        "now": 0,
        "budgetMs": 5000
    })
    .to_string();
    let resp: Value = serde_json::from_str(&resolve_json(&engine, &load)).unwrap();
    assert_eq!(resp["kind"], "epg_load_plan");
    assert_eq!(
        resp["requests"][0]["url"],
        "https://alpha.tv/epg/tv/cnn.us.json"
    );
}

#[test]
fn epg_roundtrip_parses_the_xmltv_with_utc_ms_times() {
    let mut items = BTreeMap::new();
    items.insert("alpha".into(), vec![XMLTV.to_string()]);
    let settled = roundtrip(&[source("alpha")], &FakeNet { items });

    let epg = &settled["epg"];
    assert_eq!(epg["channels"][0]["id"], "cnn.us");
    assert_eq!(epg["channels"][0]["display_names"][0], "CNN");
    let prog = &epg["programs"][0];
    assert_eq!(prog["channel_id"], "cnn.us");
    assert_eq!(prog["start_utc_ms"], 1_782_741_600_000i64); // LT2 tz->UTC fence applied
    assert_eq!(prog["stop_utc_ms"], 1_782_745_200_000i64);
    assert_eq!(prog["title"], "World News");
    assert_eq!(settled["circuitSnapshot"].as_object().unwrap().len(), 1);
}

#[test]
fn epg_roundtrip_falls_through_a_malformed_source_to_the_next() {
    // alpha returns junk (parses to an empty Epg) -> the first NON-EMPTY parse (zeta) wins.
    let mut items = BTreeMap::new();
    items.insert("alpha".into(), vec!["not xmltv at all".to_string()]);
    items.insert("zeta".into(), vec![XMLTV.to_string()]);
    let settled = roundtrip(&[source("alpha"), source("zeta")], &FakeNet { items });
    assert_eq!(settled["epg"]["channels"][0]["id"], "cnn.us");
    assert_eq!(settled["epg"]["programs"].as_array().unwrap().len(), 1);
}

#[test]
fn epg_roundtrip_is_empty_when_no_source_answers() {
    let settled = roundtrip(
        &[source("alpha")],
        &FakeNet {
            items: BTreeMap::new(),
        },
    );
    assert!(settled["epg"]["channels"].as_array().unwrap().is_empty());
    assert!(settled["epg"]["programs"].as_array().unwrap().is_empty());
}

proptest! {
    // Settling arbitrary document bytes never panics and is deterministic; a body that parses to no channels
    // and no programmes yields an empty Epg (never a partial/garbage result).
    #[test]
    fn settle_epg_is_panic_free_and_deterministic(doc in ".*") {
        let mut items = BTreeMap::new();
        items.insert("alpha".into(), vec![doc]);
        let fake = FakeNet { items };
        let a = roundtrip(&[source("alpha")], &fake);
        let b = roundtrip(&[source("alpha")], &fake);
        prop_assert_eq!(&a, &b);
        prop_assert!(a["epg"]["channels"].is_array());
    }
}
