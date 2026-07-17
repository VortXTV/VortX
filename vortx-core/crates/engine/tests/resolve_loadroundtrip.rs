//! End-to-end proof of the host async I/O Env contract (blocker #1): the engine drives a FULL multi-source
//! stream LOAD as plan -> host fetch -> settle, with the host boundary stubbed by a deterministic in-memory
//! `Fetch` (no network, no async runtime). The two halves (StreamLoad / SettleStreams) are already
//! conformance-pinned individually; this stitches them with the canonical `execute_plan` bridge to prove the
//! whole round-trip works through the FFI-shaped JSON API. The real native (tokio/reqwest) and wasm (fetch)
//! `Fetch` impls are host-side and live OUTSIDE the pure kernel; this test pins the kernel contract they fill.

use std::collections::BTreeMap;

use proptest::prelude::*;
use serde_json::{json, Map, Value};
use vortx_engine::{init_runtime, resolve_json};
use vortx_source::{execute_plan, Fetch, FetchOutcome, FetchRequest};

/// A deterministic in-memory host fetcher: returns the canned items for a source id, or `Error` if the source
/// is not stocked (proving failure isolation through the whole round-trip).
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

/// One stremio_addon source-snapshot entry for the StreamLoad registry.
fn source(id: &str) -> Value {
    json!({
        "id": id,
        "url": format!("https://{id}.tv/manifest.json"),
        "kind": "stremio_addon",
        "capabilities": ["stream"],
        "types": [],
        "idPrefixes": ["tt"]
    })
}

/// A stream item as the host returns it inside an Ok outcome (a JSON-string-encoded Stream).
fn stream_item(url: &str, name: &str) -> String {
    json!({ "url": url, "name": name }).to_string()
}

/// Run the full LOAD round-trip through the JSON API: StreamLoad -> execute_plan(fake) -> SettleStreams.
fn roundtrip(sources: &[Value], fake: &FakeNet) -> Value {
    let engine = init_runtime("o", "O");

    // 1. PLAN: the engine routes the request over the host source snapshot and returns the fetch plan.
    let load = json!({
        "kind": "stream_load",
        "req": { "kind": "stream", "type": "movie", "id": "tt1" },
        "registrySnapshot": sources,
        "now": 0,
        "budgetMs": 5000
    })
    .to_string();
    let plan_resp: Value = serde_json::from_str(&resolve_json(&engine, &load)).unwrap();
    assert_eq!(plan_resp["kind"], "stream_load_plan");
    let plan: Vec<FetchRequest> = serde_json::from_value(plan_resp["requests"].clone()).unwrap();

    // 2. EXECUTE the plan through the host Fetch boundary (the canonical kernel bridge).
    let outcomes = execute_plan(&plan, fake);

    // 3. SETTLE: hand the plan + outcomes back; the engine returns the ranked streams + breaker snapshot.
    let outcomes_map: Map<String, Value> = outcomes
        .iter()
        .map(|(id, o)| (id.clone(), serde_json::to_value(o).unwrap()))
        .collect();
    let settle = json!({
        "kind": "settle_streams",
        "plan": serde_json::to_value(&plan).unwrap(),
        "outcomes": Value::Object(outcomes_map),
        "now": 0
    })
    .to_string();
    let settled: Value = serde_json::from_str(&resolve_json(&engine, &settle)).unwrap();
    assert_eq!(settled["kind"], "settled_streams");
    settled
}

#[test]
fn engine_drives_a_full_plan_fetch_settle_roundtrip_and_ranks() {
    let mut items = BTreeMap::new();
    items.insert(
        "a".into(),
        vec![stream_item("http://a/1", "2160p BluRay REMUX")],
    );
    items.insert("b".into(), vec![stream_item("http://b/1", "720p WEB-DL")]);
    let fake = FakeNet { items };

    let settled = roundtrip(&[source("a"), source("b")], &fake);
    let ranked = settled["ranked"].as_array().unwrap();
    assert_eq!(ranked.len(), 2); // both sources contributed a stream through the round-trip

    // The 4k remux (source a, merged first) outranks the 720p web.
    assert_eq!(ranked[0]["raw_index"], 0);
    assert!(ranked[0]["score"].as_i64().unwrap() > ranked[1]["score"].as_i64().unwrap());

    // Both planned sources are recorded in the returned breaker snapshot (both succeeded).
    assert_eq!(settled["circuitSnapshot"].as_object().unwrap().len(), 2);
}

#[test]
fn a_failing_source_is_isolated_through_the_roundtrip() {
    // Source a returns a stream; b is not stocked -> the fake returns Error. The good stream still surfaces.
    let mut items = BTreeMap::new();
    items.insert("a".into(), vec![stream_item("http://a/1", "1080p WEB-DL")]);
    let fake = FakeNet { items };

    let settled = roundtrip(&[source("a"), source("b")], &fake);
    let ranked = settled["ranked"].as_array().unwrap();
    assert_eq!(ranked.len(), 1); // only the good source contributed
    assert_eq!(ranked[0]["raw_index"], 0);
}

proptest! {
    // For N all-succeeding sources the round-trip yields exactly N ranked streams, deterministically, in
    // non-increasing score order: the plan -> fetch -> settle pipeline conserves every source's stream.
    #[test]
    fn roundtrip_conserves_one_stream_per_ok_source(n in 1usize..5) {
        let sources: Vec<Value> = (0..n).map(|i| source(&format!("s{i}"))).collect();
        let items: BTreeMap<String, Vec<String>> = (0..n)
            .map(|i| (format!("s{i}"), vec![stream_item(&format!("http://s{i}/1"), "1080p WEB-DL")]))
            .collect();
        let fake = FakeNet { items };

        let settled = roundtrip(&sources, &fake);
        let ranked = settled["ranked"].as_array().unwrap();
        prop_assert_eq!(ranked.len(), n);
        for w in ranked.windows(2) {
            prop_assert!(w[0]["score"].as_i64().unwrap() >= w[1]["score"].as_i64().unwrap());
        }
    }
}
