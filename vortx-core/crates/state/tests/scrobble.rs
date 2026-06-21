//! Cross-language conformance + property tests for the tracker scrobble decision.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_state::{scrobble, PlaybackEvent, ScrobbleAction, ScrobbleConfig};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    event: PlaybackEvent,
    position_ms: u64,
    duration_ms: u64,
    watched_at_permille: u32,
    expect: ScrobbleAction,
}

const SUITE: &str = include_str!("../conformance/scrobble_vectors.json");

#[test]
fn scrobble_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse scrobble suite");
    assert!(suite.cases.len() >= 6);
    for case in &suite.cases {
        let cfg = ScrobbleConfig {
            watched_at_permille: case.watched_at_permille,
        };
        assert_eq!(
            scrobble(case.event, case.position_ms, case.duration_ms, &cfg),
            case.expect,
            "scrobble drifted for {}",
            case.name
        );
    }
}

fn event() -> impl Strategy<Value = PlaybackEvent> {
    prop_oneof![
        Just(PlaybackEvent::Start),
        Just(PlaybackEvent::Pause),
        Just(PlaybackEvent::Stop),
    ]
}

proptest! {
    #[test]
    fn watched_iff_stop_past_threshold(
        ev in event(),
        position_ms in 0u64..1_000_000,
        duration_ms in 0u64..1_000_000,
        threshold in 0u32..1001,
    ) {
        let cfg = ScrobbleConfig { watched_at_permille: threshold };
        let action = scrobble(ev, position_ms, duration_ms, &cfg);

        // Determinism.
        prop_assert_eq!(action, scrobble(ev, position_ms, duration_ms, &cfg));

        match action {
            ScrobbleAction::None => prop_assert_eq!(duration_ms, 0),
            ScrobbleAction::Stop { progress_permille, watched } => {
                prop_assert!(progress_permille <= 1000);
                prop_assert_eq!(watched, progress_permille >= threshold);
            }
            ScrobbleAction::Start { progress_permille } | ScrobbleAction::Pause { progress_permille } => {
                prop_assert!(progress_permille <= 1000);
                // watched is only ever decided on a stop.
                prop_assert!(!matches!(ev, PlaybackEvent::Stop));
            }
        }
    }
}
