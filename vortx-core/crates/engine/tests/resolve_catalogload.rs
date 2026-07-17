//! End-to-end + conformance tests for the CATALOG LOAD: the catalog twin of the stream LOAD, proving the
//! SAME plan -> host fetch -> settle effect model works for catalog rows (not just streams). The plan reuses
//! the resource-generic plan_streams planner; settle parses MetaPreviews and enforces parental controls. The
//! host boundary is stubbed by a deterministic in-memory Fetch (no network).

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

/// A catalog-capable stremio_addon source entry.
fn source(id: &str) -> Value {
    json!({
        "id": id,
        "url": format!("https://{id}.tv/manifest.json"),
        "kind": "stremio_addon",
        "capabilities": ["catalog"],
        "types": ["movie"],
        "idPrefixes": []
    })
}

/// A catalog row as the host returns it inside an Ok outcome (a JSON-string-encoded MetaPreview).
fn meta_item(id: &str, name: &str) -> String {
    json!({ "id": id, "type": "movie", "name": name }).to_string()
}

/// Drive the full catalog LOAD round-trip through the JSON API: CatalogLoad -> execute_plan(fake) -> SettleCatalog.
fn roundtrip(sources: &[Value], fake: &FakeNet) -> Value {
    let engine = init_runtime("o", "O");

    let load = json!({
        "kind": "catalog_load",
        "req": { "kind": "catalog", "type": "movie", "id": "top" },
        "registrySnapshot": sources,
        "now": 0,
        "budgetMs": 5000
    })
    .to_string();
    let plan_resp: Value = serde_json::from_str(&resolve_json(&engine, &load)).unwrap();
    assert_eq!(plan_resp["kind"], "catalog_load_plan");
    let plan: Vec<FetchRequest> = serde_json::from_value(plan_resp["requests"].clone()).unwrap();

    let outcomes = execute_plan(&plan, fake);
    let outcomes_map: Map<String, Value> = outcomes
        .iter()
        .map(|(id, o)| (id.clone(), serde_json::to_value(o).unwrap()))
        .collect();
    let settle = json!({
        "kind": "settle_catalog",
        "plan": serde_json::to_value(&plan).unwrap(),
        "outcomes": Value::Object(outcomes_map),
        "now": 0
    })
    .to_string();
    let settled: Value = serde_json::from_str(&resolve_json(&engine, &settle)).unwrap();
    assert_eq!(settled["kind"], "settled_catalog");
    settled
}

#[test]
fn catalog_load_plan_is_a_sorted_circuit_filtered_subset() {
    let engine = init_runtime("o", "O");
    let load = json!({
        "kind": "catalog_load",
        "req": { "kind": "catalog", "type": "movie", "id": "top" },
        "registrySnapshot": [source("zeta"), source("alpha")],
        "now": 0,
        "budgetMs": 5000
    })
    .to_string();
    let resp: Value = serde_json::from_str(&resolve_json(&engine, &load)).unwrap();
    assert_eq!(resp["kind"], "catalog_load_plan");
    let reqs = resp["requests"].as_array().unwrap();
    let ids: Vec<&str> = reqs
        .iter()
        .map(|r| r["addon_id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec!["alpha", "zeta"]); // sorted by addon id
                                            // The catalog resource URL is built from the manifest base (byte-exact Stremio grammar).
    assert_eq!(reqs[0]["url"], "https://alpha.tv/catalog/movie/top.json");
}

#[test]
fn catalog_roundtrip_merges_rows_and_isolates_failures() {
    let mut items = BTreeMap::new();
    items.insert("alpha".into(), vec![meta_item("tt1", "Alpha Movie")]);
    items.insert("zeta".into(), vec![meta_item("tt2", "Zeta Movie")]);
    let fake = FakeNet { items };

    let settled = roundtrip(&[source("alpha"), source("zeta")], &fake);
    let metas = settled["metas"].as_array().unwrap();
    assert_eq!(metas.len(), 2);
    assert_eq!(metas[0]["id"], "tt1"); // sorted-id merge: alpha before zeta
    assert_eq!(metas[1]["id"], "tt2");
    assert_eq!(settled["circuitSnapshot"].as_object().unwrap().len(), 2);

    // A not-stocked source returns Error -> isolated; the good rows still surface.
    let mut items2 = BTreeMap::new();
    items2.insert("alpha".into(), vec![meta_item("tt1", "Alpha Movie")]);
    let settled2 = roundtrip(
        &[source("alpha"), source("zeta")],
        &FakeNet { items: items2 },
    );
    assert_eq!(settled2["metas"].as_array().unwrap().len(), 1);
}

proptest! {
    // For N catalog sources all returning one row, the round-trip conserves exactly N rows (the owner profile
    // has no parental ceiling, so nothing is filtered), deterministically.
    #[test]
    fn catalog_roundtrip_conserves_one_row_per_ok_source(n in 1usize..5) {
        let sources: Vec<Value> = (0..n).map(|i| source(&format!("s{i}"))).collect();
        let items: BTreeMap<String, Vec<String>> = (0..n)
            .map(|i| (format!("s{i}"), vec![meta_item(&format!("tt{i}"), "Movie")]))
            .collect();
        let settled = roundtrip(&sources, &FakeNet { items });
        prop_assert_eq!(settled["metas"].as_array().unwrap().len(), n);
    }
}
