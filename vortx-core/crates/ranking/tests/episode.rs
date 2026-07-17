//! Conformance + property tests for season-pack / anime episode mapping.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_ranking::{map_episode, EpisodeRequest, PackFile};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    files: Vec<PackFile>,
    request: EpisodeRequest,
    expect_index: Option<u32>,
}

const SUITE: &str = include_str!("../conformance/episode_vectors.json");

#[test]
fn episode_mapping_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse episode suite");
    for case in &suite.cases {
        let got = map_episode(&case.files, &case.request).map(|m| m.index);
        assert_eq!(
            got, case.expect_index,
            "mapping diverged for case '{}'",
            case.name
        );
    }
}

fn pack_file() -> impl Strategy<Value = PackFile> {
    (
        0u32..20,
        prop_oneof![
            Just("Show.S01E01.1080p.mkv"),
            Just("Show.S01E02.1080p.mkv"),
            Just("Show - 1 (1080p).mkv"),
            Just("Show.S01E01.sample.mkv"),
            Just("sample.mkv"),
            Just("readme.nfo"),
            Just("setup.exe"),
        ],
        prop::option::of(1_000_000u64..10_000_000_000),
    )
        .prop_map(|(index, name, size_bytes)| PackFile {
            index,
            name: name.to_string(),
            size_bytes,
        })
}

fn request() -> impl Strategy<Value = EpisodeRequest> {
    (
        prop::option::of(1u32..3),
        prop::option::of(1u32..3),
        prop::option::of(1u32..3),
    )
        .prop_map(|(season, episode, absolute)| EpisodeRequest {
            season,
            episode,
            absolute,
        })
}

proptest! {
    #[test]
    fn map_episode_is_total_and_deterministic(
        files in prop::collection::vec(pack_file(), 0..12),
        req in request(),
    ) {
        prop_assert_eq!(map_episode(&files, &req), map_episode(&files, &req));
    }

    #[test]
    fn never_returns_a_sample_or_non_video(
        files in prop::collection::vec(pack_file(), 0..12),
        req in request(),
    ) {
        if let Some(m) = map_episode(&files, &req) {
            let lower = m.name.to_ascii_lowercase();
            prop_assert!(!lower.contains("sample"), "chose a sample: {}", m.name);
            prop_assert!(lower.ends_with(".mkv") || lower.ends_with(".mp4"), "chose a non-video: {}", m.name);
        }
    }

    #[test]
    fn chosen_index_is_a_real_input_file(
        files in prop::collection::vec(pack_file(), 1..12),
        req in request(),
    ) {
        if let Some(m) = map_episode(&files, &req) {
            prop_assert!(files.iter().any(|f| f.index == m.index && f.name == m.name));
        }
    }
}
