//! Cross-language conformance for the release-name parser: each raw name lifts the exact pinned fields.

use serde::Deserialize;
use vortx_ranking::{parse_release, ReleaseMeta};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    input: String,
    expect: ReleaseMeta,
}

const SUITE: &str = include_str!("../conformance/release_vectors.json");

#[test]
fn release_parsing_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse release suite");
    for case in &suite.cases {
        let got = parse_release(&case.input);
        assert_eq!(
            got, case.expect,
            "release parse diverged for case '{}'",
            case.name
        );
    }
}
