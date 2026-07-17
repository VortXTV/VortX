//! Cross-language conformance + property tests for the closed-loop ABR selector. The properties pin the
//! guarantees that make it safe: affordability, no-climb-on-low-buffer, the up-switch rate cap, and
//! determinism.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_playback_policy::{choose_variant, AbrConfig, AbrReason, AbrState, AbrVariant};

#[derive(Deserialize)]
struct Suite {
    ladder: Vec<AbrVariant>,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    buffered_ms: u32,
    throughput_bps: u64,
    current_index: usize,
    index: usize,
    reason: AbrReason,
}

const SUITE: &str = include_str!("../conformance/abr_vectors.json");

#[test]
fn abr_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse abr suite");
    let cfg = AbrConfig::default();
    for case in &suite.cases {
        let state = AbrState {
            buffered_ms: case.buffered_ms,
            throughput_bps: case.throughput_bps,
            current_index: case.current_index,
        };
        let d = choose_variant(&suite.ladder, &state, &cfg);
        assert_eq!(d.index, case.index, "index drifted for {}", case.name);
        assert_eq!(d.reason, case.reason, "reason drifted for {}", case.name);
    }
}

/// Build a ladder with distinct indices (0..n) and the given bandwidths.
fn ladder(bws: &[u64]) -> Vec<AbrVariant> {
    bws.iter()
        .enumerate()
        .map(|(i, &b)| AbrVariant { index: i, bandwidth_bps: b, height: 0 })
        .collect()
}

/// The ladder position (ascending by bandwidth, ties by index) of a given variant index.
fn pos_of(variants: &[AbrVariant], index: usize) -> usize {
    let mut sorted: Vec<&AbrVariant> = variants.iter().collect();
    sorted.sort_by(|a, b| a.bandwidth_bps.cmp(&b.bandwidth_bps).then(a.index.cmp(&b.index)));
    sorted.iter().position(|v| v.index == index).unwrap_or(0)
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn abr_invariants_hold(
        bws in prop::collection::vec(1u64..10_000_000, 1..6),
        buffered_ms in 0u32..40_000,
        throughput_bps in 0u64..30_000_000,
        cur_sel in 0usize..6,
    ) {
        let variants = ladder(&bws);
        let n = variants.len();
        let current_index = cur_sel % n;
        let cfg = AbrConfig::default();
        let state = AbrState { buffered_ms, throughput_bps, current_index };

        let d = choose_variant(&variants, &state, &cfg);

        // Determinism.
        prop_assert_eq!(d, choose_variant(&variants, &state, &cfg));

        let chosen = variants.iter().find(|v| v.index == d.index).unwrap();
        let usable = throughput_bps.saturating_mul(cfg.safety_permille as u64) / 1000;
        let min_bw = bws.iter().copied().min().unwrap();

        // Affordability: the pick fits the safety margin, OR it is the lowest rung (cannot do better).
        prop_assert!(chosen.bandwidth_bps <= usable || chosen.bandwidth_bps == min_bw);

        let cur_pos = pos_of(&variants, current_index);
        let new_pos = pos_of(&variants, d.index);

        // Never climb on a low buffer.
        if buffered_ms < cfg.low_buffer_ms {
            prop_assert!(new_pos <= cur_pos);
        }
        // Up-switches are rate-capped and only happen on a full buffer.
        if new_pos > cur_pos {
            prop_assert!(new_pos - cur_pos <= cfg.max_up_step.max(1));
            prop_assert!(buffered_ms >= cfg.high_buffer_ms);
            prop_assert_eq!(d.reason, AbrReason::StepUp);
        }
    }
}
