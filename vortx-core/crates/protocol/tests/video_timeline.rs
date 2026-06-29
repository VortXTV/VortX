//! Conformance + property tests for the SH5 timeline schema additions (Video.durationMs + Video.chapters,
//! MetaDetail.durationMs). The critical invariant: these are skip_serializing_if-default, so a plain Stremio
//! Video/MetaDetail serializes BYTE-IDENTICALLY to before SH5. The chapter wire keys (startMs/endMs) are the
//! cross-platform contract for per-chapter resume.

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::{json, Value};
use vortx_protocol::{MetaDetail, Video};

#[derive(Deserialize)]
struct Suite {
    videos: Vec<VCase>,
}

#[derive(Deserialize)]
struct VCase {
    name: String,
    json: Value,
    duration_ms: Option<i64>,
    chapters: Vec<ExpChapter>,
}

/// A plain-snake_case mirror of Chapter (Chapter is not PartialEq, matching Video), so the `chapters`
/// expectation is authored independently of the camelCase wire keys.
#[derive(Deserialize, Debug, PartialEq)]
struct ExpChapter {
    #[serde(default)]
    start_ms: i64,
    #[serde(default)]
    end_ms: Option<i64>,
    #[serde(default)]
    title: Option<String>,
}

const SUITE: &str = include_str!("../conformance/video_timeline_vectors.json");

#[test]
fn video_timeline_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse video timeline suite");
    for case in &suite.videos {
        let v: Video = serde_json::from_value(case.json.clone()).expect("deserialize video");
        assert_eq!(v.duration_ms, case.duration_ms, "duration drifted for {}", case.name);
        let got: Vec<ExpChapter> = v
            .chapters
            .iter()
            .map(|c| ExpChapter {
                start_ms: c.start_ms,
                end_ms: c.end_ms,
                title: c.title.clone(),
            })
            .collect();
        assert_eq!(got, case.chapters, "chapters drifted for {}", case.name);
    }
}

#[test]
fn a_plain_video_serializes_byte_identically_to_pre_sh5() {
    // The no-regression guarantee: a Video with no timeline data emits no new keys.
    let v: Video = serde_json::from_str(r#"{"id":"x"}"#).unwrap();
    assert_eq!(serde_json::to_string(&v).unwrap(), r#"{"id":"x"}"#);
}

#[test]
fn a_plain_meta_detail_serializes_without_duration_ms() {
    let m: MetaDetail = serde_json::from_str(r#"{"id":"m","type":"movie","name":"M"}"#).unwrap();
    let s = serde_json::to_string(&m).unwrap();
    assert!(!s.contains("durationMs"), "plain meta must not emit durationMs: {s}");
    // And the precise duration parses when present.
    let m2: MetaDetail =
        serde_json::from_str(r#"{"id":"m","type":"movie","name":"M","durationMs":7200000}"#).unwrap();
    assert_eq!(m2.duration_ms, Some(7200000));
}

proptest! {
    // A Video with arbitrary timeline data round-trips through serialize -> deserialize, and the camelCase
    // chapter wire keys map to the snake_case fields. Deserializing never panics.
    #[test]
    fn video_timeline_roundtrips(
        dur in prop::option::of(0i64..50_000_000),
        chapters in prop::collection::vec(
            (0i64..50_000_000, prop::option::of(0i64..50_000_000), prop::option::of("[A-Za-z ]{0,8}")),
            0..4,
        ),
    ) {
        let mut obj = serde_json::Map::new();
        obj.insert("id".into(), json!("tt1:1:1"));
        if let Some(d) = dur { obj.insert("durationMs".into(), json!(d)); }
        let ch_json: Vec<Value> = chapters.iter().map(|(s, e, t)| {
            let mut c = serde_json::Map::new();
            c.insert("startMs".into(), json!(s));
            if let Some(e) = e { c.insert("endMs".into(), json!(e)); }
            if let Some(t) = t { c.insert("title".into(), json!(t)); }
            Value::Object(c)
        }).collect();
        if !ch_json.is_empty() { obj.insert("chapters".into(), json!(ch_json)); }

        let v: Video = serde_json::from_value(Value::Object(obj)).expect("never panics");
        prop_assert_eq!(v.duration_ms, dur);
        prop_assert_eq!(v.chapters.len(), chapters.len());
        for (got, (s, e, t)) in v.chapters.iter().zip(chapters.iter()) {
            prop_assert_eq!(got.start_ms, *s);
            prop_assert_eq!(got.end_ms, *e);
            prop_assert_eq!(&got.title, t);
        }
        // Serialize -> deserialize is stable.
        let s = serde_json::to_string(&v).unwrap();
        let back: Video = serde_json::from_str(&s).unwrap();
        prop_assert_eq!(back.duration_ms, v.duration_ms);
        prop_assert_eq!(back.chapters.len(), v.chapters.len());
    }
}
