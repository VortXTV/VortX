//! Cross-language conformance: the planner must map each pinned `(kind, hints)` to the exact pinned
//! `PlaybackPlan`. All enum/int, so this is a hard byte-for-byte contract every implementation shares.

use serde::Deserialize;
use vortx_playback_policy::{plan, ConnectionHints, PlaybackPlan, StreamKind};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    kind: StreamKind,
    hints: ConnectionHints,
    expect: PlaybackPlan,
}

const SUITE: &str = include_str!("../conformance/plan_vectors.json");

#[test]
fn planner_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse plan conformance suite");
    for case in &suite.cases {
        let got = plan(case.kind, case.hints);
        assert_eq!(got, case.expect, "plan diverged for case '{}'", case.name);
    }
}
