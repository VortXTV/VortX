//! Conformance + property tests for the LT5 LIVE ranking profile (stream health). Two guarantees, both
//! cross-platform: a live channel/stream ranks by health (uptime, then bitrate, with language owned by the
//! shared base and counted once), and the VIDEO profile stays byte-identical to the frozen rank() (the health
//! terms provably never fire off the live path). The health weights are re-derived independently below so the
//! property test is a genuine second implementation, not a mirror of the crate's own arithmetic.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_protocol::{ContentKind, Stream, StreamBehaviorHints, VortxStreamHints};
use vortx_ranking::{rank, rank_for, RankingPrefs};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    #[serde(default)]
    prefs: RankingPrefs,
    streams: Vec<StreamSpec>,
    expect: Vec<Expect>,
}

#[derive(Deserialize, Clone)]
struct StreamSpec {
    label: String,
    #[serde(default)]
    video_size: Option<i64>,
    #[serde(default)]
    vortx: Option<VortxStreamHints>,
}

#[derive(Deserialize)]
struct Expect {
    raw_index: usize,
    score: i64,
}

fn build(spec: &StreamSpec) -> Stream {
    let behavior_hints = if spec.video_size.is_some() || spec.vortx.is_some() {
        Some(StreamBehaviorHints {
            video_size: spec.video_size,
            vortx: spec.vortx.clone(),
            ..Default::default()
        })
    } else {
        None
    };
    Stream {
        name: Some(spec.label.clone()),
        behavior_hints,
        ..Default::default()
    }
}

const SUITE: &str = include_str!("../conformance/live_rank_vectors.json");

#[test]
fn live_rank_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse live rank suite");
    assert!(suite.cases.len() >= 4, "expected the full vector set");
    for case in &suite.cases {
        let streams: Vec<Stream> = case.streams.iter().map(build).collect();
        let cached = vec![false; streams.len()];

        let ranked = rank_for(ContentKind::Channel, &streams, &case.prefs, &cached);
        let got: Vec<(usize, i64)> = ranked.iter().map(|r| (r.raw_index, r.score)).collect();
        let want: Vec<(usize, i64)> = case.expect.iter().map(|e| (e.raw_index, e.score)).collect();
        assert_eq!(got, want, "live ranking drifted for {}", case.name);

        // No-regression: the same streams under the VIDEO profile are byte-identical to the frozen rank().
        assert_eq!(
            rank_for(ContentKind::Movie, &streams, &case.prefs, &cached),
            rank(&streams, &case.prefs, &cached),
            "video profile changed for {}",
            case.name
        );
    }
}

// ---- independent re-derivation of the health weights (a genuine second implementation) ----

const TIER_STEP_MILLI: i64 = 15_000 * 1_000;

fn expected_uptime_points(p: Option<i64>) -> i64 {
    match p {
        Some(p) if p > 0 => (p.min(1000) * 400) / 1000,
        _ => 0,
    }
}

fn expected_bitrate_points(k: Option<i64>) -> i64 {
    match k {
        Some(k) if k > 0 => {
            let log2 = 63 - (k as u64).leading_zeros() as i64;
            ((log2 - 8).max(0) * 50).min(300)
        }
        _ => 0,
    }
}

/// A live stream carrying optional typed bitrate / uptime / languages behind a neutral label.
fn live_stream(bitrate: Option<i64>, uptime: Option<i64>, langs: &[String]) -> Stream {
    build(&StreamSpec {
        label: "Channel".to_string(),
        video_size: None,
        vortx: Some(VortxStreamHints {
            bitrate_kbps: bitrate,
            uptime_permille: uptime,
            languages: langs.to_vec(),
            ..Default::default()
        }),
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    // No-regression: the VIDEO profile equals the frozen rank() for ANY list of live-shaped streams (even ones
    // carrying bitrate / uptime typed fields), so the health terms provably never touch video.
    #[test]
    fn video_profile_equals_base_rank_for_any_live_streams(
        specs in prop::collection::vec(
            (
                prop::option::of(0i64..50_000_000i64),
                prop::option::of(-100i64..2_000i64),
                prop::collection::vec(prop_oneof!["en", "ja", "fr"], 0..3),
            ),
            0..8,
        ),
    ) {
        let streams: Vec<Stream> = specs
            .iter()
            .map(|(b, u, l)| live_stream(*b, *u, l))
            .collect();
        let cached = vec![false; streams.len()];
        let prefs = RankingPrefs { preferred_languages: vec!["en".to_string()], ..Default::default() };
        prop_assert_eq!(
            rank_for(ContentKind::Movie, &streams, &prefs, &cached),
            rank(&streams, &prefs, &cached)
        );
    }

    // The live profile only ADDS bitrate + uptime over the base (never subtracts), is a permutation of the base
    // survivors, is deterministic, and each stream's delta is exactly the re-derived health points AND is
    // bounded strictly below the resolution-tier step (so health can never reorder across tiers).
    #[test]
    fn live_profile_adds_bounded_health_only(
        specs in prop::collection::vec(
            (
                prop::option::of(0i64..50_000_000i64),
                prop::option::of(-100i64..2_000i64),
                prop::collection::vec(prop_oneof!["en", "ja", "fr"], 0..3),
            ),
            0..8,
        ),
    ) {
        let streams: Vec<Stream> = specs
            .iter()
            .map(|(b, u, l)| live_stream(*b, *u, l))
            .collect();
        let cached = vec![false; streams.len()];
        let prefs = RankingPrefs { preferred_languages: vec!["en".to_string()], ..Default::default() };

        let base = rank(&streams, &prefs, &cached);
        let live = rank_for(ContentKind::Channel, &streams, &prefs, &cached);

        // Deterministic.
        prop_assert_eq!(&live, &rank_for(ContentKind::Channel, &streams, &prefs, &cached));

        // Same surviving set (a permutation).
        let mut base_idx: Vec<usize> = base.iter().map(|r| r.raw_index).collect();
        let mut live_idx: Vec<usize> = live.iter().map(|r| r.raw_index).collect();
        base_idx.sort_unstable();
        live_idx.sort_unstable();
        prop_assert_eq!(&base_idx, &live_idx);

        // Non-increasing by score (a valid total order).
        for w in live.windows(2) {
            prop_assert!(w[0].score >= w[1].score);
        }

        // Per stream: live == base + exactly the re-derived health delta, and that delta is bounded below the
        // tier step (so language is not double-counted and health never crosses a resolution tier).
        for b in &base {
            let l = live.iter().find(|r| r.raw_index == b.raw_index).unwrap();
            let (bitrate, uptime, _) = &specs[b.raw_index];
            let delta = (expected_bitrate_points(*bitrate) + expected_uptime_points(*uptime)) * 1_000;
            prop_assert_eq!(l.score, b.score + delta);
            prop_assert!(l.score >= b.score);
            prop_assert!((0..TIER_STEP_MILLI).contains(&delta));
        }
    }
}
