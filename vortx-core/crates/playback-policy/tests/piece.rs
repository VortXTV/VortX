//! Cross-language conformance + property tests for the streaming torrent piece-selection policy.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_playback_policy::{piece_plan, PieceRequest, PiecePriorityConfig};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    have: Vec<bool>,
    playhead: u32,
    critical_window: u32,
    readahead_window: u32,
    footer_pieces: u32,
    order: Vec<PieceRequest>,
}

const SUITE: &str = include_str!("../conformance/piece_vectors.json");

#[test]
fn piece_plan_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse piece suite");
    for case in &suite.cases {
        let cfg = PiecePriorityConfig {
            critical_window: case.critical_window,
            readahead_window: case.readahead_window,
            footer_pieces: case.footer_pieces,
        };
        let got = piece_plan(&case.have, case.playhead, &cfg);
        assert_eq!(got, case.order, "piece plan drifted for {}", case.name);
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn piece_plan_invariants_hold(
        have in prop::collection::vec(any::<bool>(), 0..30),
        playhead in 0u32..30,
        critical_window in 0u32..8,
        readahead_window in 0u32..16,
        footer_pieces in 0u32..4,
    ) {
        let cfg = PiecePriorityConfig { critical_window, readahead_window, footer_pieces };
        let plan = piece_plan(&have, playhead, &cfg);

        // Determinism.
        prop_assert_eq!(&plan, &piece_plan(&have, playhead, &cfg));

        let mut seen = std::collections::HashSet::new();
        let mut prev_priority = None;
        for req in &plan {
            // Every requested piece is in range and MISSING.
            prop_assert!((req.piece as usize) < have.len());
            prop_assert!(!have[req.piece as usize]);
            // No piece requested twice.
            prop_assert!(seen.insert(req.piece));
            // Priorities are non-decreasing (all Critical, then High, then Normal).
            if let Some(p) = prev_priority {
                prop_assert!(p <= req.priority);
            }
            prev_priority = Some(req.priority);
        }
    }
}
