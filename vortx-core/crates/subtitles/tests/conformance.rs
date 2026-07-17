//! Cross-language conformance: subtitle selection must pick the same track index (or none) for each
//! pinned tracks + prefs fixture, on every implementation.

use serde::Deserialize;
use vortx_subtitles::{select, SubtitlePrefs, SubtitleTrack};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    tracks: Vec<SubtitleTrack>,
    prefs: SubtitlePrefs,
    #[serde(rename = "expectIndex")]
    expect_index: Option<usize>,
}

const SUITE: &str = include_str!("../conformance/select_vectors.json");

#[test]
fn selection_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse select suite");
    for case in &suite.cases {
        let got = select(&case.tracks, &case.prefs).map(|s| s.track_index);
        assert_eq!(
            got, case.expect_index,
            "selection diverged for case '{}'",
            case.name
        );
    }
}
