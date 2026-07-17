//! Cross-language conformance + property tests for the ContentKind typed axis: the wire `type` string -> a
//! typed ContentKind -> a coarse ContentClass. The mapping is the cross-platform contract that decides which
//! per-kind ranking/parse/finish profile a request rides, so it is pinned by shared vectors.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_protocol::{ContentClass, ContentKind};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    #[serde(rename = "type")]
    type_: String,
    kind: ContentKind,
    class: ContentClass,
}

const SUITE: &str = include_str!("../conformance/content_kind_vectors.json");

#[test]
fn content_kind_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse content kind suite");
    assert!(suite.cases.len() >= 16);
    for case in &suite.cases {
        let kind = ContentKind::from_type(&case.type_);
        assert_eq!(kind, case.kind, "kind drifted for type {:?}", case.type_);
        assert_eq!(
            kind.class(),
            case.class,
            "class drifted for type {:?}",
            case.type_
        );
    }
}

proptest! {
    // from_type is total (never panics) on arbitrary input, an unrecognized type is always Unknown -> Video
    // (the frozen default so nothing regresses), and every ContentKind round-trips through serde.
    #[test]
    fn from_type_is_total_and_unknown_is_video(s in ".*") {
        let kind = ContentKind::from_type(&s);
        // Round-trip the resulting kind through its wire form.
        let wire = serde_json::to_string(&kind).unwrap();
        let back: ContentKind = serde_json::from_str(&wire).unwrap();
        prop_assert_eq!(kind, back);
        // Any kind that is_video() must classify as Video, and Unknown is always video.
        if kind == ContentKind::Unknown {
            prop_assert_eq!(kind.class(), ContentClass::Video);
        }
        prop_assert_eq!(kind.is_video(), kind.class() == ContentClass::Video);
    }
}
