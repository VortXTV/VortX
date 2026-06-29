//! End-to-end tests for the META LOAD: the third leg of the stream/catalog/meta LOAD trio. Same plan -> host
//! fetch -> settle effect model, but meta is SINGULAR (the highest-priority source that answered wins) and
//! parental-gated. The host boundary is stubbed by a deterministic in-memory Fetch (no network).

use std::collections::BTreeMap;

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

/// A meta-capable stremio_addon source entry (tt id-space).
fn source(id: &str) -> Value {
    json!({
        "id": id,
        "url": format!("https://{id}.tv/manifest.json"),
        "kind": "stremio_addon",
        "capabilities": ["meta"],
        "types": ["movie"],
        "idPrefixes": ["tt"]
    })
}

/// A meta detail as the host returns it inside an Ok outcome (a JSON-string-encoded MetaDetail).
fn meta_item(id: &str, name: &str, certification: Option<&str>) -> String {
    match certification {
        Some(c) => {
            json!({ "id": id, "type": "movie", "name": name, "certification": c }).to_string()
        }
        None => json!({ "id": id, "type": "movie", "name": name }).to_string(),
    }
}

/// Drive the full meta LOAD round-trip through the JSON API: MetaLoad -> execute_plan(fake) -> SettleMeta.
fn roundtrip(sources: &[Value], fake: &FakeNet) -> Value {
    let engine = init_runtime("o", "O");

    let load = json!({
        "kind": "meta_load",
        "req": { "kind": "meta", "type": "movie", "id": "tt1" },
        "registrySnapshot": sources,
        "now": 0,
        "budgetMs": 5000
    })
    .to_string();
    let plan_resp: Value = serde_json::from_str(&resolve_json(&engine, &load)).unwrap();
    assert_eq!(plan_resp["kind"], "meta_load_plan");
    let plan: Vec<FetchRequest> = serde_json::from_value(plan_resp["requests"].clone()).unwrap();

    let outcomes = execute_plan(&plan, fake);
    let outcomes_map: Map<String, Value> = outcomes
        .iter()
        .map(|(id, o)| (id.clone(), serde_json::to_value(o).unwrap()))
        .collect();
    let settle = json!({
        "kind": "settle_meta",
        "plan": serde_json::to_value(&plan).unwrap(),
        "outcomes": Value::Object(outcomes_map),
        "now": 0
    })
    .to_string();
    let settled: Value = serde_json::from_str(&resolve_json(&engine, &settle)).unwrap();
    assert_eq!(settled["kind"], "settled_meta");
    settled
}

#[test]
fn meta_load_plan_uses_the_byte_exact_meta_url() {
    let engine = init_runtime("o", "O");
    let load = json!({
        "kind": "meta_load",
        "req": { "kind": "meta", "type": "movie", "id": "tt1" },
        "registrySnapshot": [source("alpha")],
        "now": 0,
        "budgetMs": 5000
    })
    .to_string();
    let resp: Value = serde_json::from_str(&resolve_json(&engine, &load)).unwrap();
    assert_eq!(resp["kind"], "meta_load_plan");
    assert_eq!(
        resp["requests"][0]["url"],
        "https://alpha.tv/meta/movie/tt1.json"
    );
}

#[test]
fn meta_roundtrip_picks_the_first_surviving_source() {
    // alpha and zeta both answer; the highest-priority (sorted-id) source's detail wins.
    let mut items = BTreeMap::new();
    items.insert("alpha".into(), vec![meta_item("tt1", "Alpha Detail", None)]);
    items.insert("zeta".into(), vec![meta_item("tt1", "Zeta Detail", None)]);
    let settled = roundtrip(&[source("alpha"), source("zeta")], &FakeNet { items });
    assert_eq!(settled["meta"]["name"], "Alpha Detail");
    assert_eq!(settled["circuitSnapshot"].as_object().unwrap().len(), 2);
}

#[test]
fn meta_roundtrip_is_none_when_no_source_answers() {
    // Neither source is stocked -> both Error -> no meta.
    let settled = roundtrip(
        &[source("alpha"), source("zeta")],
        &FakeNet {
            items: BTreeMap::new(),
        },
    );
    assert_eq!(settled["meta"], Value::Null);
}

#[test]
fn meta_roundtrip_falls_through_to_the_next_source_when_the_first_is_malformed() {
    // alpha returns an unparseable body (no valid meta), zeta returns a valid one -> zeta's detail surfaces.
    let mut items = BTreeMap::new();
    items.insert("alpha".into(), vec!["not a meta".into()]);
    items.insert("zeta".into(), vec![meta_item("tt1", "Zeta Detail", None)]);
    let settled = roundtrip(&[source("alpha"), source("zeta")], &FakeNet { items });
    assert_eq!(settled["meta"]["name"], "Zeta Detail");
}
