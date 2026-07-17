//! Conformance + property tests for anti-fraud stream validation.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_ranking::{validate_stream, AntiFraudInput, DropReason, Verdict};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    input: AntiFraudInput,
    expect: Verdict,
}

const SUITE: &str = include_str!("../conformance/antifraud_vectors.json");

#[test]
fn antifraud_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse antifraud suite");
    for case in &suite.cases {
        let got = validate_stream(&case.input);
        assert_eq!(
            got, case.expect,
            "verdict diverged for case '{}'",
            case.name
        );
    }
}

fn input() -> impl Strategy<Value = AntiFraudInput> {
    (
        prop_oneof![
            Just("Movie 2024 1080p BluRay x264-GRP"),
            Just("Movie 2024 2160p WEB-DL x265"),
            Just("Show S01E01 720p HDTV"),
        ],
        prop::collection::vec(
            prop_oneof![
                Just("movie.mkv"),
                Just("movie.mp4"),
                Just("movie-sample.mkv"),
                Just("setup.exe"),
                Just("password.txt"),
                Just("readme.nfo"),
            ],
            0..4,
        ),
        prop::option::of(1_000_000u64..200_000_000_000),
        prop::option::of(1u32..240),
    )
        .prop_map(
            |(name, files, size_bytes, runtime_minutes)| AntiFraudInput {
                name: name.to_string(),
                files: files.iter().map(|s| s.to_string()).collect(),
                size_bytes,
                runtime_minutes,
            },
        )
}

proptest! {
    #[test]
    fn validate_is_total_and_deterministic(i in input()) {
        prop_assert_eq!(validate_stream(&i), validate_stream(&i));
    }

    #[test]
    fn an_executable_is_always_dropped(mut i in input()) {
        // Adding an executable can only move the verdict toward Drop (monotone in evidence).
        i.files.push("trojan.exe".to_string());
        prop_assert!(!validate_stream(&i).is_keep());
    }

    #[test]
    fn absurd_size_is_always_dropped(name in "[A-Za-z ]{3,20}") {
        // 100 GB for a 10-minute runtime: dropped regardless of label.
        let i = AntiFraudInput {
            name,
            files: vec!["v.mkv".into()],
            size_bytes: Some(100_000_000_000),
            runtime_minutes: Some(10),
        };
        prop_assert_eq!(validate_stream(&i), Verdict::Drop { reason: DropReason::SizePerMinuteTooHigh });
    }

    #[test]
    fn a_clean_video_with_sane_size_is_kept(size in 2_000_000_000u64..8_000_000_000, rt in 90u32..150) {
        let i = AntiFraudInput {
            name: "Movie 2024 1080p BluRay x264-GRP".into(),
            files: vec!["movie.mkv".into()],
            size_bytes: Some(size),
            runtime_minutes: Some(rt),
        };
        prop_assert!(validate_stream(&i).is_keep());
    }
}
