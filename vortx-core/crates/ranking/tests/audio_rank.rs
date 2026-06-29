//! Conformance + property tests for the AUDIO ranking profile (lossless preference). The two guarantees are
//! cross-platform: a lossless audio stream outranks a lossy one of equal everything else (byte-pinned score),
//! and the VIDEO profile is byte-identical to the frozen rank() (the lossless term never fires off-audio).

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

const SUITE: &str = include_str!("../conformance/audio_rank_vectors.json");

#[test]
fn audio_rank_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse audio rank suite");
    let prefs = RankingPrefs::default();
    for case in &suite.cases {
        let streams: Vec<Stream> = case.streams.iter().map(build).collect();
        let cached = vec![false; streams.len()];

        let ranked = rank_for(ContentKind::MusicTrack, &streams, &prefs, &cached);
        let got: Vec<(usize, i64)> = ranked.iter().map(|r| (r.raw_index, r.score)).collect();
        let want: Vec<(usize, i64)> = case.expect.iter().map(|e| (e.raw_index, e.score)).collect();
        assert_eq!(got, want, "audio ranking drifted for {}", case.name);

        // The same streams under the VIDEO profile are byte-identical to the frozen rank() (no-regression).
        assert_eq!(
            rank_for(ContentKind::Movie, &streams, &prefs, &cached),
            rank(&streams, &prefs, &cached),
            "video profile changed for {}",
            case.name
        );
    }
}

/// A stream from a label plus an optional codec tag on the typed channel.
fn stream(label: &str, codec_tag: Option<&str>) -> Stream {
    let vortx = codec_tag.map(|t| VortxStreamHints {
        tags: vec![t.to_string()],
        ..Default::default()
    });
    build(&StreamSpec {
        label: label.to_string(),
        video_size: None,
        vortx,
    })
}

proptest! {
    // No-regression: the VIDEO profile equals the frozen rank() for ANY stream list (even ones with codec
    // tokens in the label), so the lossless term provably never touches video.
    #[test]
    fn video_profile_equals_base_rank_for_any_streams(
        labels in prop::collection::vec("[A-Za-z0-9 ]{0,24}", 0..8),
    ) {
        let streams: Vec<Stream> = labels.iter().map(|l| stream(l, None)).collect();
        let cached = vec![false; streams.len()];
        let prefs = RankingPrefs::default();
        prop_assert_eq!(
            rank_for(ContentKind::Movie, &streams, &prefs, &cached),
            rank(&streams, &prefs, &cached)
        );
    }

    // The audio profile only ADDS to base scores (never subtracts), is a permutation of the base result, and
    // is deterministic. A lossless-tagged stream gains exactly the bonus over its base score.
    #[test]
    fn audio_profile_adds_lossless_bonus_only(
        specs in prop::collection::vec(
            ("[A-Za-z0-9 ]{0,16}", prop_oneof![Just(None), Just(Some("flac")), Just(Some("mp3")), Just(Some("opus"))]),
            0..8,
        ),
    ) {
        let streams: Vec<Stream> = specs.iter().map(|(l, t)| stream(l, *t)).collect();
        let cached = vec![false; streams.len()];
        let prefs = RankingPrefs::default();

        let base = rank(&streams, &prefs, &cached);
        let audio = rank_for(ContentKind::MusicTrack, &streams, &prefs, &cached);

        prop_assert_eq!(&audio, &rank_for(ContentKind::MusicTrack, &streams, &prefs, &cached)); // deterministic

        // Same set of surviving raw indices (a permutation).
        let mut base_idx: Vec<usize> = base.iter().map(|r| r.raw_index).collect();
        let mut audio_idx: Vec<usize> = audio.iter().map(|r| r.raw_index).collect();
        base_idx.sort_unstable();
        audio_idx.sort_unstable();
        prop_assert_eq!(&base_idx, &audio_idx);

        // Per stream: audio score >= base score, and a flac-tagged stream gains exactly 100*1000.
        for b in &base {
            let a = audio.iter().find(|r| r.raw_index == b.raw_index).unwrap();
            prop_assert!(a.score >= b.score);
            let is_flac = specs[b.raw_index].1 == Some("flac");
            let expected = if is_flac { b.score + 100_000 } else { b.score };
            prop_assert_eq!(a.score, expected);
        }
    }
}
