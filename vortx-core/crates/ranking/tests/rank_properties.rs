//! Property-based proof that the ranker is a deterministic total order: ranking any random set of streams
//! produces a non-increasing score order, and ranking the same input twice yields the identical result.

use proptest::prelude::*;
use vortx_protocol::Stream;
use vortx_ranking::{rank, RankingPrefs};

const LABELS: &[&str] = &[
    "2160p BluRay REMUX Dolby Vision Atmos 7.1 x265",
    "1080p WEB-DL DDP5.1 H.264",
    "720p HDTV x264",
    "480p WEBRip",
    "2160p HDCAM",
    "1080p BluRay x265 HDR10",
    "2160p WEB-DL HDR10 Atmos",
    "Just A Title",
];

fn stream(label: &str) -> Stream {
    Stream {
        name: Some(label.to_string()),
        ..Default::default()
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    #[test]
    fn rank_is_sorted_descending_and_deterministic(
        idxs in prop::collection::vec(0usize..LABELS.len(), 0..20usize),
        cached in prop::collection::vec(any::<bool>(), 0..20usize),
    ) {
        let streams: Vec<Stream> = idxs.iter().map(|&i| stream(LABELS[i])).collect();
        let prefs = RankingPrefs::default();

        let ranked = rank(&streams, &prefs, &cached);

        // Non-increasing by score.
        for window in ranked.windows(2) {
            prop_assert!(window[0].score >= window[1].score);
        }

        // Deterministic: identical input ranks identically.
        let again = rank(&streams, &prefs, &cached);
        prop_assert_eq!(ranked, again);
    }
}
