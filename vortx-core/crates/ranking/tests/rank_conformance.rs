//! Cross-language conformance for the fixed-point ranker. Now that the score is an integer, both the score
//! and the order are byte-pinnable; this test asserts the engine reproduces them exactly. If this drifts,
//! a stream list ranked on iOS, Android, and a Worker would diverge.

use serde::Deserialize;
use vortx_protocol::{Stream, StreamBehaviorHints, VortxStreamHints};
use vortx_ranking::{rank, RankingPrefs};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    prefs: RankingPrefs,
    streams: Vec<StreamSpec>,
    expect: Vec<Expect>,
}

#[derive(Deserialize)]
struct StreamSpec {
    label: String,
    #[serde(default)]
    cached: bool,
    #[serde(default)]
    video_size: Option<i64>,
    /// The typed behaviorHints.vortx side-channel; when present the ranker reads it instead of the title.
    #[serde(default)]
    vortx: Option<VortxStreamHints>,
}

#[derive(Deserialize)]
struct Expect {
    raw_index: usize,
    score: i64,
}

const SUITE: &str = include_str!("../conformance/rank_vectors.json");

#[test]
fn rank_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse rank suite");
    assert!(suite.cases.len() >= 4, "expected the full vector set");
    for case in &suite.cases {
        let streams: Vec<Stream> = case
            .streams
            .iter()
            .map(|s| {
                let behavior_hints = if s.video_size.is_some() || s.vortx.is_some() {
                    Some(StreamBehaviorHints {
                        video_size: s.video_size,
                        vortx: s.vortx.clone(),
                        ..Default::default()
                    })
                } else {
                    None
                };
                Stream {
                    name: Some(s.label.clone()),
                    behavior_hints,
                    ..Default::default()
                }
            })
            .collect();
        let cached: Vec<bool> = case.streams.iter().map(|s| s.cached).collect();

        let ranked = rank(&streams, &case.prefs, &cached);

        let got: Vec<(usize, i64)> = ranked.iter().map(|r| (r.raw_index, r.score)).collect();
        let want: Vec<(usize, i64)> = case.expect.iter().map(|e| (e.raw_index, e.score)).collect();
        assert_eq!(got, want, "ranking drifted for {}", case.name);
    }
}
