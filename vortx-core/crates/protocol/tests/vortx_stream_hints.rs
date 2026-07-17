//! Cross-language conformance + property tests for the typed behaviorHints.vortx side-channel
//! (VortxStreamHints). This is the byte-frozen contract the Singularity Worker emits and the engine
//! consumes: the engine ranks from these typed fields instead of regex-parsing the title, so a stream ranks
//! identically on every platform. The conformance suite pins each emitted wire object to the parsed fields,
//! authored in plain snake_case (decoupled from the camelCase wire renames) so the comparison independently
//! verifies BOTH the values AND that cachedServices/sizeBytes/fileIdx/nzbHash map to the right Rust fields.

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::{json, Value};
use vortx_protocol::{Stream, VortxStreamHints};

/// A plain-snake_case mirror of VortxStreamHints (NO serde renames), so the `expect` objects are authored
/// independently of the wire format. Equality against this proves the camelCase wire keys deserialized into
/// the correct Rust fields.
#[derive(Debug, Deserialize, PartialEq)]
struct ExpectHints {
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    cached_services: Vec<String>,
    #[serde(default)]
    seeders: Option<i64>,
    #[serde(default)]
    size_bytes: Option<i64>,
    #[serde(default)]
    resolution: Option<String>,
    #[serde(default)]
    languages: Vec<String>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    sources: Option<i64>,
    #[serde(default)]
    pack: Option<bool>,
    #[serde(default)]
    file_idx: Option<u32>,
    #[serde(default)]
    nzb_hash: Option<String>,
}

impl From<&VortxStreamHints> for ExpectHints {
    fn from(h: &VortxStreamHints) -> Self {
        ExpectHints {
            kind: h.kind.clone(),
            cached_services: h.cached_services.clone(),
            seeders: h.seeders,
            size_bytes: h.size_bytes,
            resolution: h.resolution.clone(),
            languages: h.languages.clone(),
            tags: h.tags.clone(),
            sources: h.sources,
            pack: h.pack,
            file_idx: h.file_idx,
            nzb_hash: h.nzb_hash.clone(),
        }
    }
}

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    json: Value,
    expect: ExpectHints,
}

const SUITE: &str = include_str!("../conformance/vortx_stream_hints_vectors.json");

#[test]
fn vortx_stream_hints_match_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse vortx hints suite");
    assert!(suite.cases.len() >= 4);
    for case in &suite.cases {
        let parsed: VortxStreamHints =
            serde_json::from_value(case.json.clone()).expect("deserialize wire object");
        let got = ExpectHints::from(&parsed);
        assert_eq!(got, case.expect, "vortx hints drifted for {}", case.name);
    }
}

#[test]
fn the_object_rides_on_stream_behavior_hints() {
    // It is not a standalone type: it must deserialize through Stream.behaviorHints.vortx, the actual wiring.
    let wire = json!({
        "url": "http://example/playlist.m3u8",
        "behaviorHints": {
            "vortx": {
                "kind": "torrent",
                "cachedServices": ["realdebrid"],
                "sizeBytes": 12884901888i64,
                "resolution": "2160p",
                "tags": ["remux", "dv"],
                "seeders": 88,
                "fileIdx": 2
            }
        }
    });
    let stream: Stream = serde_json::from_value(wire).expect("deserialize stream");
    let vortx = stream
        .behavior_hints
        .as_ref()
        .and_then(|h| h.vortx.as_ref())
        .expect("vortx side-channel present on the stream");
    assert_eq!(vortx.kind.as_deref(), Some("torrent"));
    assert_eq!(vortx.cached_services, vec!["realdebrid"]);
    assert_eq!(vortx.size_bytes, Some(12884901888));
    assert_eq!(vortx.resolution.as_deref(), Some("2160p"));
    assert_eq!(vortx.tags, vec!["remux", "dv"]);
    assert_eq!(vortx.seeders, Some(88));
    assert_eq!(vortx.file_idx, Some(2));
}

#[test]
fn a_plain_stremio_stream_has_no_vortx_object() {
    // The absence path: a plain Stremio stream (no vortx object) deserializes fine; the engine then falls
    // back to the title parser. behaviorHints present but without a vortx key must yield None, not an error.
    let wire = json!({ "url": "http://x", "behaviorHints": { "bingeGroup": "g" } });
    let stream: Stream = serde_json::from_value(wire).expect("deserialize plain stream");
    assert!(stream
        .behavior_hints
        .as_ref()
        .and_then(|h| h.vortx.as_ref())
        .is_none());
}

proptest! {
    // Deserializing an arbitrary partial wire object never panics, the camelCase renames map to the right
    // fields, and serialize -> deserialize round-trips to an equal value (skip_serializing_if defaults are
    // stable). Named args avoid any tuple-arity limit.
    #[test]
    fn deserialize_is_robust_and_roundtrips(
        kind in prop::option::of("[a-z]+"),
        cached in prop::collection::vec("[a-z]+", 0..3),
        size in prop::option::of(0i64..100_000_000_000i64),
        file_idx in prop::option::of(0u32..50),
        nzb in prop::option::of("[a-f0-9]{32}"),
        seeders in prop::option::of(0i64..1_000_000i64),
    ) {
        let mut obj = serde_json::Map::new();
        if let Some(k) = &kind { obj.insert("kind".into(), json!(k)); }
        obj.insert("cachedServices".into(), json!(cached));
        if let Some(s) = size { obj.insert("sizeBytes".into(), json!(s)); }
        if let Some(f) = file_idx { obj.insert("fileIdx".into(), json!(f)); }
        if let Some(n) = &nzb { obj.insert("nzbHash".into(), json!(n)); }
        if let Some(sd) = seeders { obj.insert("seeders".into(), json!(sd)); }

        let a: VortxStreamHints =
            serde_json::from_value(Value::Object(obj)).expect("never panics on a partial object");
        let s = serde_json::to_string(&a).expect("serialize");
        let b: VortxStreamHints = serde_json::from_str(&s).expect("re-deserialize");
        prop_assert_eq!(&a, &b);

        // The renamed wire keys landed in the right Rust fields.
        prop_assert_eq!(a.size_bytes, size);
        prop_assert_eq!(a.file_idx, file_idx);
        prop_assert_eq!(a.nzb_hash, nzb);
        prop_assert_eq!(a.kind, kind);
        prop_assert_eq!(a.cached_services, cached);
        prop_assert_eq!(a.seeders, seeders);
    }
}
