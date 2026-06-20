//! Conformance + property tests for stream failover + dead-link rot.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_hive::DebridService;
use vortx_playback::{FailureSignal, StreamCandidate, StreamFailover};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    candidates: Vec<StreamCandidate>,
    signals: Vec<FailureSignal>,
    expect_steps: Vec<ExpectStep>,
}

#[derive(Deserialize)]
struct ExpectStep {
    next: Option<usize>,
    rotted: bool,
}

const SUITE: &str = include_str!("../conformance/failover_vectors.json");

#[test]
fn failover_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse failover suite");
    for case in &suite.cases {
        let mut f = StreamFailover::new(case.candidates.clone());
        for (i, signal) in case.signals.iter().enumerate() {
            let step = f.fail(*signal);
            let expect = &case.expect_steps[i];
            assert_eq!(step.next, expect.next, "{} step {i} next", case.name);
            assert_eq!(
                step.rot.is_some(),
                expect.rotted,
                "{} step {i} rotted",
                case.name
            );
        }
    }
}

fn candidate() -> impl Strategy<Value = StreamCandidate> {
    (
        "[a-h]{1,3}",
        prop::option::of(Just("aabbccddeeff00112233445566778899aabbccdd".to_string())),
    )
        .prop_map(|(id, infohash)| StreamCandidate {
            id,
            service: infohash.as_ref().map(|_| DebridService::RealDebrid),
            file_idx: infohash.as_ref().map(|_| 0),
            infohash,
        })
}

fn signal() -> impl Strategy<Value = FailureSignal> {
    prop_oneof![
        Just(FailureSignal::ResolveError),
        Just(FailureSignal::FirstByteTimeout),
    ]
}

proptest! {
    #[test]
    fn walk_terminates_and_never_repeats_a_dead_index(
        candidates in prop::collection::vec(candidate(), 0..12),
        extra_fails in 0usize..4,
    ) {
        let n = candidates.len();
        let mut f = StreamFailover::new(candidates);
        let mut seen = Vec::new();
        if let Some(c) = f.current() {
            seen.push(c);
        }
        // Fail more times than there are candidates: must terminate, never repeat.
        for _ in 0..(n + extra_fails) {
            let step = f.fail(FailureSignal::ResolveError);
            if let Some(idx) = step.next {
                prop_assert!(!seen.contains(&idx), "repeated a dead index: {idx}");
                seen.push(idx);
            }
        }
        prop_assert!(f.is_exhausted(), "walk did not terminate");
    }

    #[test]
    fn rot_only_on_permanent_failure_of_a_debrid_stream(
        candidates in prop::collection::vec(candidate(), 1..12),
        signals in prop::collection::vec(signal(), 1..12),
    ) {
        let mut f = StreamFailover::new(candidates.clone());
        for sig in signals {
            let before = f.current();
            let step = f.fail(sig);
            if let Some(rot) = step.rot {
                // A rot fact is emitted ONLY for a permanent failure of a debrid/torrent candidate.
                prop_assert_eq!(sig, FailureSignal::ResolveError);
                let c = &candidates[before.unwrap()];
                prop_assert!(c.infohash.is_some() && c.service.is_some());
                prop_assert_eq!(&rot.infohash, c.infohash.as_ref().unwrap());
            }
            if f.is_exhausted() {
                break;
            }
        }
    }
}
