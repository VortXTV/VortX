//! End-to-end tests for the SUBTITLES LOAD: the 4th leg of the stream/catalog/meta/subtitles LOAD quartet.
//! The LOAD fetches subtitle tracks from every source, merges them (sorted-addon-id), and the engine runs the
//! EXISTING select over the multi-source merge (the same selection logic as the one-shot Subtitles, now fed by
//! a real fetch). The host boundary is stubbed by a deterministic in-memory Fetch (no network).

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

/// A subtitles-capable stremio_addon source entry.
fn source(id: &str) -> Value {
    json!({
        "id": id,
        "url": format!("https://{id}.tv/manifest.json"),
        "kind": "stremio_addon",
        "capabilities": ["subtitles"],
        "types": ["movie"],
        "idPrefixes": ["tt"]
    })
}

/// A subtitle track as the host returns it inside an Ok outcome (a JSON-string-encoded SubtitleTrack).
fn track_item(id: &str, lang: &str) -> String {
    json!({ "id": id, "lang": lang, "format": "srt", "tier": "provider" }).to_string()
}

/// Drive the full subtitles LOAD round-trip: SubtitlesLoad -> execute_plan(fake) -> SettleSubtitles(prefs).
fn roundtrip(sources: &[Value], fake: &FakeNet, prefs: Value) -> Value {
    let engine = init_runtime("o", "O");

    let load = json!({
        "kind": "subtitles_load",
        "req": { "kind": "subtitles", "type": "movie", "id": "tt1" },
        "registrySnapshot": sources,
        "now": 0,
        "budgetMs": 5000
    })
    .to_string();
    let plan_resp: Value = serde_json::from_str(&resolve_json(&engine, &load)).unwrap();
    assert_eq!(plan_resp["kind"], "subtitles_load_plan");
    let plan: Vec<FetchRequest> = serde_json::from_value(plan_resp["requests"].clone()).unwrap();

    let outcomes = execute_plan(&plan, fake);
    let outcomes_map: Map<String, Value> = outcomes
        .iter()
        .map(|(id, o)| (id.clone(), serde_json::to_value(o).unwrap()))
        .collect();
    let settle = json!({
        "kind": "settle_subtitles",
        "plan": serde_json::to_value(&plan).unwrap(),
        "outcomes": Value::Object(outcomes_map),
        "prefs": prefs,
        "now": 0
    })
    .to_string();
    let settled: Value = serde_json::from_str(&resolve_json(&engine, &settle)).unwrap();
    assert_eq!(settled["kind"], "settled_subtitles");
    settled
}

#[test]
fn subtitles_load_plan_uses_the_byte_exact_subtitles_url() {
    let engine = init_runtime("o", "O");
    let load = json!({
        "kind": "subtitles_load",
        "req": { "kind": "subtitles", "type": "movie", "id": "tt1" },
        "registrySnapshot": [source("alpha")],
        "now": 0,
        "budgetMs": 5000
    })
    .to_string();
    let resp: Value = serde_json::from_str(&resolve_json(&engine, &load)).unwrap();
    assert_eq!(resp["kind"], "subtitles_load_plan");
    assert_eq!(
        resp["requests"][0]["url"],
        "https://alpha.tv/subtitles/movie/tt1.json"
    );
}

#[test]
fn subtitles_roundtrip_merges_two_sources_and_selects_the_preferred_language() {
    // alpha serves English (merged index 0), zeta Spanish (index 1). Prefs prefer Spanish -> index 1.
    let mut items = BTreeMap::new();
    items.insert("alpha".into(), vec![track_item("a1", "en")]);
    items.insert("zeta".into(), vec![track_item("z1", "es")]);
    let settled = roundtrip(
        &[source("alpha"), source("zeta")],
        &FakeNet { items },
        json!({ "languages": ["es"] }),
    );
    assert_eq!(settled["selected"]["track_index"], 1); // the Spanish track from the merged list
    assert_eq!(settled["circuitSnapshot"].as_object().unwrap().len(), 2);
}

#[test]
fn subtitles_roundtrip_selects_null_when_no_source_answers() {
    let settled = roundtrip(
        &[source("alpha"), source("zeta")],
        &FakeNet {
            items: BTreeMap::new(),
        },
        json!({}),
    );
    assert_eq!(settled["selected"], Value::Null);
}
