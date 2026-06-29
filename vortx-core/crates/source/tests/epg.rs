//! Cross-language conformance + property tests for the SH4 live/audio source additions: the Epg ResourceKind,
//! the Iptv SourceKind, and the typed EpgWindow [startUnix, endUnix) request shape. The wire names + the
//! half-open contains/overlaps semantics are the cross-platform contract for live-TV programme listings.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_source::{EpgWindow, ResourceKind, ResourceRequest, SourceKind};

#[derive(Deserialize)]
struct Suite {
    kinds: Kinds,
    windows: Vec<WindowCase>,
}

#[derive(Deserialize)]
struct Kinds {
    resource_epg_wire: String,
    source_iptv_wire: String,
}

#[derive(Deserialize)]
struct WindowCase {
    name: String,
    window: EpgWindow,
    contains: Vec<ContainsCase>,
    overlaps: Vec<OverlapsCase>,
}

#[derive(Deserialize)]
struct ContainsCase {
    unix: i64,
    expect: bool,
}

#[derive(Deserialize)]
struct OverlapsCase {
    start: i64,
    end: i64,
    expect: bool,
}

const SUITE: &str = include_str!("../conformance/epg_vectors.json");

#[test]
fn epg_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse epg suite");

    // Kind wire names.
    assert_eq!(ResourceKind::Epg.wire(), suite.kinds.resource_epg_wire);
    assert_eq!(
        serde_json::to_string(&ResourceKind::Epg).unwrap(),
        format!("\"{}\"", suite.kinds.resource_epg_wire)
    );
    assert_eq!(
        serde_json::to_string(&SourceKind::Iptv).unwrap(),
        format!("\"{}\"", suite.kinds.source_iptv_wire)
    );

    for case in &suite.windows {
        for c in &case.contains {
            assert_eq!(case.window.contains(c.unix), c.expect, "contains {} in {}", c.unix, case.name);
        }
        for o in &case.overlaps {
            assert_eq!(
                case.window.overlaps(o.start, o.end),
                o.expect,
                "overlaps [{}, {}) in {}",
                o.start,
                o.end,
                case.name
            );
        }
    }
}

#[test]
fn a_non_epg_request_serializes_without_the_window_key() {
    // No-regression: a request without an EPG window emits no epgWindow key.
    let req = ResourceRequest::new(ResourceKind::Stream, "movie", "tt1");
    let s = serde_json::to_string(&req).unwrap();
    assert!(!s.contains("epgWindow"), "plain request must not emit epgWindow: {s}");

    // An EPG request with a window round-trips through the typed field.
    let epg = ResourceRequest::new(ResourceKind::Epg, "channel", "ch1").with_epg_window(1000, 2000);
    let s2 = serde_json::to_string(&epg).unwrap();
    assert!(s2.contains("epgWindow"));
    let back: ResourceRequest = serde_json::from_str(&s2).unwrap();
    assert_eq!(back.epg_window, Some(EpgWindow::new(1000, 2000)));
}

proptest! {
    // contains is the half-open membership [start, end); overlaps is symmetric half-open interval overlap.
    // Both are total and consistent: a window contains x iff it overlaps the instant [x, x+1).
    #[test]
    fn window_predicates_are_consistent(start in -1_000_000i64..1_000_000, len in 0i64..1_000_000, x in -2_000_000i64..2_000_000) {
        let w = EpgWindow::new(start, start + len);
        prop_assert_eq!(w.contains(x), x >= start && x < start + len);
        // contains(x) implies overlaps([x, x+1)) when the window is non-empty.
        if w.contains(x) {
            prop_assert!(w.overlaps(x, x + 1));
        }
        // An empty window (len 0) contains nothing and overlaps nothing.
        if len == 0 {
            prop_assert!(!w.contains(x));
            prop_assert!(!w.overlaps(x, x + 10));
        }
    }
}
