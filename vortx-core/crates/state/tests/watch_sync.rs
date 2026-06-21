//! Cross-language conformance + CRDT-law property tests for the per-profile watch-state SYNC document.
//!
//! This is the document that closes engine-needs #1's "+SyncDoc" gap: a field-level, independently-clocked
//! watch record that two devices can merge to the same state. The conformance vectors pin the merge result
//! cross-language; the property tests prove it is a join-semilattice (commutative / associative / idempotent),
//! i.e. a real CRDT, so out-of-order or repeated syncs always converge.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_state::{merge_log, WatchLog, WatchState};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    base: WatchLog,
    incoming: WatchLog,
    expect: WatchLog,
}

const SUITE: &str = include_str!("../conformance/watch_sync_vectors.json");

#[test]
fn watch_sync_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse watch-sync suite");
    assert!(suite.cases.len() >= 4);
    for case in &suite.cases {
        assert_eq!(
            merge_log(&case.base, &case.incoming),
            case.expect,
            "watch-sync merge drifted for {}",
            case.name
        );
        // The same inputs in the other order converge identically (commutative).
        assert_eq!(
            merge_log(&case.incoming, &case.base),
            case.expect,
            "watch-sync merge not commutative for {}",
            case.name
        );
    }
}

fn watch_state() -> impl Strategy<Value = WatchState> {
    // Small clock ranges so random keys collide and the merges genuinely overlap.
    (0u64..3, 0u64..3, 0u64..3, 0u32..3, 0u64..3, 0u64..3).prop_map(
        |(resume_ms, resume_at, watched_at, times_watched, reset_at, removed_at)| WatchState {
            resume_ms,
            resume_at,
            watched_at,
            times_watched,
            reset_at,
            removed_at,
        },
    )
}

fn watch_log() -> impl Strategy<Value = WatchLog> {
    prop::collection::btree_map("[a-c]", watch_state(), 0..4)
}

proptest! {
    // A join-semilattice: commutative + associative + idempotent => a CRDT, so sync always converges.
    #[test]
    fn merge_is_commutative(a in watch_log(), b in watch_log()) {
        prop_assert_eq!(merge_log(&a, &b), merge_log(&b, &a));
    }

    #[test]
    fn merge_is_idempotent(a in watch_log()) {
        prop_assert_eq!(merge_log(&a, &a), a.clone());
    }

    #[test]
    fn merge_is_associative(a in watch_log(), b in watch_log(), c in watch_log()) {
        let left = merge_log(&merge_log(&a, &b), &c);
        let right = merge_log(&a, &merge_log(&b, &c));
        prop_assert_eq!(left, right);
    }
}
