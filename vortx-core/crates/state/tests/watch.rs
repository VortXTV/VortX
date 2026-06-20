//! Conformance + CRDT property tests for the field-level watch-state sync.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_state::{merge_log, merge_watch, WatchLog, WatchState};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    a: WatchState,
    b: WatchState,
    expect: WatchState,
    is_watched: bool,
    is_removed: bool,
}

const SUITE: &str = include_str!("../conformance/watch_vectors.json");

#[test]
fn watch_merge_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse watch suite");
    for case in &suite.cases {
        let m = merge_watch(&case.a, &case.b);
        assert_eq!(m, case.expect, "merge diverged for case '{}'", case.name);
        assert_eq!(
            merge_watch(&case.b, &case.a),
            m,
            "merge must be commutative ({})",
            case.name
        );
        assert_eq!(
            m.is_watched(),
            case.is_watched,
            "is_watched for '{}'",
            case.name
        );
        assert_eq!(
            m.is_removed(),
            case.is_removed,
            "is_removed for '{}'",
            case.name
        );
    }
}

fn state() -> impl Strategy<Value = WatchState> {
    (
        0u64..1_000_000,
        0u64..1000,
        0u64..1000,
        0u32..10,
        0u64..1000,
        0u64..1000,
    )
        .prop_map(
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

proptest! {
    #[test]
    fn merge_is_commutative(a in state(), b in state()) {
        prop_assert_eq!(merge_watch(&a, &b), merge_watch(&b, &a));
    }

    #[test]
    fn merge_is_associative(a in state(), b in state(), c in state()) {
        let left = merge_watch(&merge_watch(&a, &b), &c);
        let right = merge_watch(&a, &merge_watch(&b, &c));
        prop_assert_eq!(left, right);
    }

    #[test]
    fn merge_is_idempotent_and_absorbing(a in state(), b in state()) {
        // Self-merge is a no-op, and re-applying either operand to the result changes nothing.
        prop_assert_eq!(merge_watch(&a, &a), a);
        let m = merge_watch(&a, &b);
        prop_assert_eq!(merge_watch(&m, &a), m);
        prop_assert_eq!(merge_watch(&m, &b), m);
    }

    #[test]
    fn watched_is_monotone_under_merge(a in state(), b in state()) {
        // Once a title is watched in either operand, the merge stays watched unless a newer reset wins.
        let m = merge_watch(&a, &b);
        if (a.is_watched() && a.watched_at >= b.reset_at) || (b.is_watched() && b.watched_at >= a.reset_at) {
            prop_assert!(m.is_watched());
        }
    }

    #[test]
    fn log_merge_is_commutative_and_idempotent(
        keys in prop::collection::vec(("[a-c]", state()), 0..8),
        keys2 in prop::collection::vec(("[a-c]", state()), 0..8),
    ) {
        let a: WatchLog = keys.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        let b: WatchLog = keys2.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        prop_assert_eq!(merge_log(&a, &b), merge_log(&b, &a));
        let m = merge_log(&a, &b);
        prop_assert_eq!(merge_log(&m, &a), m.clone());
    }
}
