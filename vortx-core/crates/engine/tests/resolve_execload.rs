//! The exec seam through the engine's JSON query surface: a JS provider (Nuvio getStreams scraper) is
//! PLANNED by the kernel (`stream_load` -> `execRequests`), executed HOST-side (never here), and SETTLED
//! (`settle_streams` -> ranked + breakers) through the exact same machinery as an HTTP addon.
//!
//! Pins, in order: (1) the plan phase emits deterministic ExecRequests beside the HTTP fetch plan and the
//! WIRE STAYS FROZEN for registries without JS providers (no `execRequests` key at all); (2) fixed
//! recorded `getStreams()` outputs settle to pinned ranked projections + breaker snapshots (the shared
//! conformance vectors); (3) a provider that keeps failing TRIPS ITS CIRCUIT exactly like a dead HTTP
//! addon and the next plan skips it; (4) settlement is byte-deterministic.

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
    ranked: Value,
    #[serde(rename = "circuitSnapshot")]
    circuit_snapshot: Value,
}

const SUITE: &str = include_str!("../conformance/resolve_execsettle_vectors.json");

/// Project the engine's ranked array to the pinned {raw_index, score} shape (reasons/tags not pinned).
fn project(ranked: &Value) -> Value {
    Value::Array(
        ranked
            .as_array()
            .unwrap()
            .iter()
            .map(|r| json!({ "raw_index": r["raw_index"], "score": r["score"] }))
            .collect(),
    )
}

fn nuvio_entry(id: &str) -> Value {
    json!({
        "id": id,
        "url": "https://repo.example/nuvio",
        "kind": "nuvio_provider",
        "capabilities": ["stream"],
        "types": ["movie"],
        "scriptHash": "f00df00df00df00df00df00df00df00df00df00df00df00df00df00df00df00d",
        "permissions": ["net:api.vidfast.example", "hive:contribute"]
    })
}

fn http_entry(id: &str) -> Value {
    json!({
        "id": id,
        "url": "https://h.tv/manifest.json",
        "kind": "stremio_addon",
        "capabilities": ["stream"],
        "types": ["movie"],
        "idPrefixes": ["tt"]
    })
}

fn stream_load(registry: Value, circuit: Value) -> Value {
    json!({
        "kind": "stream_load",
        "req": { "kind": "stream", "type": "movie", "id": "tt0468569" },
        "registrySnapshot": registry,
        "circuitSnapshot": circuit,
        "now": 1000,
        "budgetMs": 5000
    })
}

#[test]
fn stream_load_plans_exec_requests_beside_the_http_plan() {
    let engine = init_runtime("owner", "Owner");
    let out = resolve_json(
        &engine,
        &stream_load(json!([nuvio_entry("vidfast"), http_entry("http-addon")]), json!({})).to_string(),
    );
    let plan: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(plan["kind"], "stream_load_plan");
    // The HTTP half is untouched: only the stremio addon gets a fetch URL.
    assert_eq!(plan["requests"].as_array().unwrap().len(), 1);
    assert_eq!(plan["requests"][0]["addon_id"], "http-addon");
    // The exec half: the pinned script, the entrypoint, the deterministic args, the derived policy.
    let exec = plan["execRequests"].as_array().expect("execRequests planned");
    assert_eq!(exec.len(), 1);
    assert_eq!(
        exec[0],
        json!({
            "provider_id": "vidfast",
            "script_hash": "f00df00df00df00df00df00df00df00df00df00df00df00df00df00df00df00d",
            "entrypoint": "getStreams",
            "args_json": "[\"tt0468569\",\"movie\"]",
            "budgetMs": 5000,
            "net_policy": {
                "host_allowlist": ["api.vidfast.example"],
                "max_requests": 32,
                "max_total_bytes": 8388608
            }
        })
    );
}

#[test]
fn the_plan_wire_stays_frozen_without_js_providers() {
    // A registry with no JS provider must serialize the PRE-EXEC wire byte-shape: no execRequests key.
    let engine = init_runtime("owner", "Owner");
    let out = resolve_json(
        &engine,
        &stream_load(json!([http_entry("http-addon")]), json!({})).to_string(),
    );
    assert!(!out.contains("execRequests"), "wire drifted: {out}");
    let plan: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(plan["requests"][0]["addon_id"], "http-addon");
}

#[test]
fn resolve_execsettle_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse exec settle suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let out = resolve_json(&engine, &case.request.to_string());
        let parsed: Value = serde_json::from_str(&out).expect("json");
        assert_eq!(parsed["kind"], "settled_streams", "{} kind", case.name);
        assert_eq!(project(&parsed["ranked"]), case.ranked, "ranked drifted for {}", case.name);
        assert_eq!(
            parsed["circuitSnapshot"], case.circuit_snapshot,
            "breaker snapshot drifted for {}",
            case.name
        );
    }
}

#[test]
fn settlement_is_byte_deterministic() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse exec settle suite");
    let engine = init_runtime("owner", "Owner");
    for case in &suite.cases {
        let a = resolve_json(&engine, &case.request.to_string());
        let b = resolve_json(&engine, &case.request.to_string());
        assert_eq!(a.as_bytes(), b.as_bytes(), "{} not deterministic", case.name);
    }
}

#[test]
fn a_repeatedly_failing_provider_trips_its_breaker_and_the_next_plan_skips_it() {
    // The full circuit: three consecutive Threw settles (threshold 3) open the provider's breaker,
    // exactly like a dead HTTP addon; the NEXT stream_load plans no exec for it; after the cooldown
    // (300s default) the one trial is allowed again.
    let engine = init_runtime("owner", "Owner");
    let mut circuit = json!({});
    for round in 0..3 {
        let settle = json!({
            "kind": "settle_streams",
            "plan": [],
            "outcomes": {},
            "execPlan": [{
                "provider_id": "vidfast",
                "script_hash": "f00df00df00df00df00df00df00df00df00df00df00df00df00df00df00df00d",
                "entrypoint": "getStreams",
                "args_json": "[\"tt0468569\",\"movie\"]",
                "budgetMs": 5000,
                "net_policy": { "host_allowlist": [], "max_requests": 32, "max_total_bytes": 8388608 }
            }],
            "execOutcomes": { "vidfast": { "status": "threw", "message": "boom" } },
            "circuitSnapshot": circuit,
            "now": 1000
        });
        let out: Value = serde_json::from_str(&resolve_json(&engine, &settle.to_string())).unwrap();
        assert_eq!(out["kind"], "settled_streams", "round {round}");
        circuit = out["circuitSnapshot"].clone();
    }
    assert_eq!(circuit["vidfast"]["consecutive_failures"], 3);
    assert_eq!(circuit["vidfast"]["state"], "open");

    // Still cooling at now=1100 -> the provider is NOT planned.
    let cooled_out = resolve_json(
        &engine,
        &json!({
            "kind": "stream_load",
            "req": { "kind": "stream", "type": "movie", "id": "tt0468569" },
            "registrySnapshot": [nuvio_entry("vidfast")],
            "circuitSnapshot": circuit,
            "now": 1100,
            "budgetMs": 5000
        })
        .to_string(),
    );
    assert!(!cooled_out.contains("execRequests"), "open breaker still planned: {cooled_out}");

    // Past the cooldown (opened_at 1000 + 300) the one trial is allowed again.
    let trial: Value = serde_json::from_str(&resolve_json(
        &engine,
        &json!({
            "kind": "stream_load",
            "req": { "kind": "stream", "type": "movie", "id": "tt0468569" },
            "registrySnapshot": [nuvio_entry("vidfast")],
            "circuitSnapshot": circuit,
            "now": 1301,
            "budgetMs": 5000
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(trial["execRequests"].as_array().unwrap().len(), 1);
}

#[test]
fn a_malformed_getstreams_return_is_isolated_as_malformed() {
    // A provider whose Ok json is not a Nuvio stream array answered garbage: same classification as an
    // HTTP addon returning an unparseable body (Malformed -> breaker failure, nothing ranked).
    let engine = init_runtime("owner", "Owner");
    let settle = json!({
        "kind": "settle_streams",
        "plan": [],
        "outcomes": {},
        "execPlan": [{
            "provider_id": "vidfast",
            "script_hash": "f00df00df00df00df00df00df00df00df00df00df00df00df00df00df00df00d",
            "entrypoint": "getStreams",
            "args_json": "[\"tt0468569\",\"movie\"]",
            "budgetMs": 5000,
            "net_policy": { "host_allowlist": [], "max_requests": 32, "max_total_bytes": 8388608 }
        }],
        "execOutcomes": { "vidfast": { "status": "ok", "json": "{\"not\":\"an array\"}" } },
        "now": 1000
    });
    let out: Value = serde_json::from_str(&resolve_json(&engine, &settle.to_string())).unwrap();
    assert_eq!(out["ranked"].as_array().unwrap().len(), 0);
    assert_eq!(out["circuitSnapshot"]["vidfast"]["consecutive_failures"], 1);
}
