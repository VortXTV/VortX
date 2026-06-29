//! Property-based proof that the ranker is a deterministic total order: ranking any random set of streams
//! produces a non-increasing score order, and ranking the same input twice yields the identical result.

use proptest::prelude::*;
use vortx_protocol::{Stream, StreamBehaviorHints, VortxStreamHints};
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

    // The determinism win: a stream whose ranking inputs come from the typed vortx side-channel ranks by
    // those typed fields ALONE, independent of whatever arbitrary title it also carries. Any two titles on
    // the same typed object produce the identical score, so the engine never drifts on title text.
    #[test]
    fn typed_vortx_ranking_is_title_independent(
        title_a in ".*",
        title_b in ".*",
        res_idx in 0usize..4,
        tag_idxs in prop::collection::vec(0usize..6usize, 0..4),
    ) {
        const RES: &[&str] = &["2160p", "1080p", "720p", "480p"];
        const TAGS: &[&str] = &["remux", "bluray", "web-dl", "dv", "hdr10", "atmos"];
        let tags: Vec<String> = tag_idxs.iter().map(|&i| TAGS[i].to_string()).collect();
        let make = |title: &str| Stream {
            name: Some(title.to_string()),
            behavior_hints: Some(StreamBehaviorHints {
                vortx: Some(VortxStreamHints {
                    resolution: Some(RES[res_idx].to_string()),
                    tags: tags.clone(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        };
        let prefs = RankingPrefs::default();
        let a = rank(&[make(&title_a)], &prefs, &[false]);
        let b = rank(&[make(&title_b)], &prefs, &[false]);
        prop_assert_eq!(a[0].score, b[0].score);
        prop_assert_eq!(a[0].tier, b[0].tier);
    }
}
