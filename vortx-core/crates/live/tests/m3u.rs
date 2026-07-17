//! Cross-language conformance + property tests for the M3U/M3U8 playlist parser (LT1). The parse must be
//! identical across platforms (it is the live-TV entry point), so a sample playlist text is pinned to the
//! parsed Playlist wire form; the parser must also never panic on arbitrary bytes.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_live::{parse_m3u, Playlist};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    text: String,
    expect: Playlist,
}

const SUITE: &str = include_str!("../conformance/m3u_vectors.json");

#[test]
fn m3u_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse m3u suite");
    assert!(suite.cases.len() >= 3);
    for case in &suite.cases {
        let got = parse_m3u(&case.text);
        assert_eq!(got, case.expect, "m3u parse drifted for {}", case.name);
    }
}

proptest! {
    // The parser never panics on arbitrary input, is deterministic, every emitted entry has a non-empty URL
    // (a pending #EXTINF with no URL is dropped), and parsing is stable through a serialize round-trip.
    #[test]
    fn parse_is_panic_free_and_well_formed(s in ".*") {
        let a = parse_m3u(&s);
        let b = parse_m3u(&s);
        prop_assert_eq!(&a, &b); // deterministic
        for e in &a.entries {
            prop_assert!(!e.url.is_empty());
            prop_assert!(!e.url.starts_with('#')); // a URL line, never a directive
        }
        // Wire round-trip is stable.
        let json = serde_json::to_string(&a).unwrap();
        let back: Playlist = serde_json::from_str(&json).unwrap();
        prop_assert_eq!(a, back);
    }

    // A well-formed single entry round-trips its fields out of a synthesized EXTINF line.
    #[test]
    fn extinf_fields_survive(id in "[a-z]{1,8}", name in "[A-Za-z ]{1,12}", group in "[A-Za-z]{1,8}") {
        let text = format!("#EXTINF:-1 tvg-id=\"{id}\" group-title=\"{group}\",{name}\nhttp://s/{id}\n");
        let p = parse_m3u(&text);
        prop_assert_eq!(p.entries.len(), 1);
        let e = &p.entries[0];
        prop_assert_eq!(e.tvg_id.as_deref(), Some(id.as_str()));
        prop_assert_eq!(e.group_title.as_deref(), Some(group.as_str()));
        prop_assert_eq!(e.display_name.as_str(), name.trim());
        prop_assert_eq!(e.duration_secs, -1);
    }
}
