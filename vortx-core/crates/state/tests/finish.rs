//! Conformance + property tests for the per-content-kind FINISH decision. The key invariant: the video
//! policy at tail_grace 0 reduces EXACTLY to the prior `permille >= 900` comparison, and the scrobble policy
//! to `800`, so re-pinning the library + scrobble call sites onto finished() changes no decision (their
//! existing conformance vectors stay green). The audiobook tail grace is the new tail-aware behavior.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_state::{finished, FinishPolicy};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    position_ms: u64,
    duration_ms: u64,
    finished_permille: u32,
    tail_grace_ms: u64,
    expect: bool,
}

const SUITE: &str = include_str!("../conformance/finish_vectors.json");

#[test]
fn finish_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse finish suite");
    for case in &suite.cases {
        let policy = FinishPolicy {
            finished_permille: case.finished_permille,
            tail_grace_ms: case.tail_grace_ms,
        };
        assert_eq!(
            finished(case.position_ms, case.duration_ms, &policy),
            case.expect,
            "finish drifted for {}",
            case.name
        );
    }
}

/// The prior permille comparison, for the byte-identical reduction proof.
fn old_permille(position_ms: u64, duration_ms: u64) -> u32 {
    position_ms
        .saturating_mul(1000)
        .checked_div(duration_ms)
        .map(|p| p.min(1000) as u32)
        .unwrap_or(0)
}

proptest! {
    // The video policy (tail_grace 0) is EXACTLY `permille >= 900`, and the scrobble policy EXACTLY
    // `permille >= 800`, for every position/duration. This is what makes re-pinning the call sites a no-op.
    #[test]
    fn zero_tail_grace_reduces_to_the_permille_comparison(position_ms in 0u64..100_000_000, duration_ms in 0u64..100_000_000) {
        prop_assert_eq!(
            finished(position_ms, duration_ms, &FinishPolicy::VIDEO),
            old_permille(position_ms, duration_ms) >= 900
        );
        prop_assert_eq!(
            finished(position_ms, duration_ms, &FinishPolicy::SCROBBLE),
            old_permille(position_ms, duration_ms) >= 800
        );
    }

    // The tail grace only ever makes a finish EARLIER (monotone): adding tail grace never un-finishes a
    // title that the permille path already finished.
    #[test]
    fn tail_grace_is_monotone(position_ms in 0u64..100_000_000, duration_ms in 1u64..100_000_000, tail in 0u64..600_000) {
        let base = finished(position_ms, duration_ms, &FinishPolicy { finished_permille: 900, tail_grace_ms: 0 });
        let with_tail = finished(position_ms, duration_ms, &FinishPolicy { finished_permille: 900, tail_grace_ms: tail });
        if base {
            prop_assert!(with_tail, "tail grace must not un-finish");
        }
    }

    // The min-duration guard: the tail branch fires ONLY when the unit is longer than the grace. For a unit
    // at/below the grace length the result is the pure permille comparison (no early "finished at 0"); for a
    // longer unit it is the original tail-OR-permille behavior (byte-identical to before the guard).
    #[test]
    fn tail_grace_guard_only_changes_units_at_or_below_the_grace(
        position_ms in 0u64..10_000_000,
        duration_ms in 1u64..10_000_000,
        tail in 1u64..600_000,
    ) {
        let got = finished(position_ms, duration_ms, &FinishPolicy { finished_permille: 900, tail_grace_ms: tail });
        let permille = old_permille(position_ms, duration_ms) >= 900;
        if duration_ms <= tail {
            prop_assert_eq!(got, permille); // tail disabled -> pure permille
        } else {
            let old_tail = position_ms.saturating_add(tail) >= duration_ms;
            prop_assert_eq!(got, old_tail || permille); // long unit -> unchanged tail-OR-permille
        }
    }
}
