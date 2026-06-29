//! Cross-language conformance + property tests for the hive cached-availability check. The wire-string match
//! between a stream's behaviorHints.vortx.cachedServices and the user's enabled debrid services must be
//! identical on every platform (it feeds cached-aware ranking), so it is pinned by shared vectors.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_hive::DebridService;
use vortx_protocol::{Stream, StreamBehaviorHints, VortxStreamHints};
use vortx_source::{cached_on, cached_vector};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    user_services: Vec<DebridService>,
    streams: Vec<StreamSpec>,
}

#[derive(Deserialize)]
struct StreamSpec {
    #[serde(default)]
    cached_services: Vec<String>,
    #[serde(default)]
    plain: bool,
    expect: bool,
}

const SUITE: &str = include_str!("../conformance/cached_vectors.json");

fn build(spec: &StreamSpec) -> Stream {
    if spec.plain {
        return Stream::default();
    }
    Stream {
        behavior_hints: Some(StreamBehaviorHints {
            vortx: Some(VortxStreamHints {
                cached_services: spec.cached_services.clone(),
                ..Default::default()
            }),
            ..Default::default()
        }),
        ..Default::default()
    }
}

#[test]
fn cached_check_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse cached suite");
    assert!(suite.cases.len() >= 3);
    for case in &suite.cases {
        let streams: Vec<Stream> = case.streams.iter().map(build).collect();
        let got = cached_vector(&streams, &case.user_services);
        let want: Vec<bool> = case.streams.iter().map(|s| s.expect).collect();
        assert_eq!(got, want, "cached check drifted for {}", case.name);
    }
}

proptest! {
    // cached_on is exactly "some stream service case-insensitively equals some user service"; it is symmetric
    // under case folding and false when either side is empty.
    #[test]
    fn cached_on_is_case_insensitive_any_match(
        stream in prop::collection::vec(prop_oneof!["realdebrid", "torbox", "alldebrid"], 0..3usize),
        user in prop::collection::vec(prop_oneof!["realdebrid", "torbox"], 0..3usize),
    ) {
        let user_refs: Vec<&str> = user.iter().map(|s| s.as_str()).collect();
        let expected = stream.iter().any(|s| user.iter().any(|u| s.eq_ignore_ascii_case(u)));
        prop_assert_eq!(cached_on(&stream, &user_refs), expected);

        // Upper-casing the stream side never changes the verdict (case-insensitive).
        let upper: Vec<String> = stream.iter().map(|s| s.to_uppercase()).collect();
        prop_assert_eq!(cached_on(&upper, &user_refs), expected);

        // Empty user services -> never cached.
        prop_assert!(!cached_on(&stream, &[]));
    }
}
