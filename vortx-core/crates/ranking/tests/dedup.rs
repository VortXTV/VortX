//! Conformance + property tests for cross-source dedup.

use std::collections::BTreeSet;

use proptest::prelude::*;
use serde::Deserialize;
use vortx_ranking::{dedup, DedupStream};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    streams: Vec<DedupStream>,
    expect_groups: Vec<Vec<usize>>,
}

const SUITE: &str = include_str!("../conformance/dedup_vectors.json");

#[test]
fn dedup_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse dedup suite");
    for case in &suite.cases {
        let groups: Vec<Vec<usize>> = dedup(&case.streams)
            .into_iter()
            .map(|m| m.members)
            .collect();
        assert_eq!(
            groups, case.expect_groups,
            "dedup diverged for case '{}'",
            case.name
        );
    }
}

// A small pool of streams so duplicates actually occur.
fn stream() -> impl Strategy<Value = DedupStream> {
    (
        "[a-c]",
        prop_oneof![
            Just("Movie 2024 1080p WEB-DL x264-GRP"),
            Just("Movie.2024.1080p.WEB-DL.x264-GRP"),
            Just("Movie 2024 2160p BluRay x265-OTH"),
            Just("Other 2020 720p HDTV x264-ZZZ"),
        ],
        prop::option::of(prop_oneof![Just("h1"), Just("h2")]),
        prop::option::of(2_000_000_000u64..2_100_000_000),
    )
        .prop_map(|(source, name, infohash, size)| DedupStream {
            source_id: source.to_string(),
            name: name.to_string(),
            infohash: infohash.map(String::from),
            file_idx: infohash.map(|_| 0),
            size_bytes: size,
        })
}

/// A content key independent of input position, for comparing partitions across orderings.
fn content_key(s: &DedupStream) -> String {
    format!("{}|{}|{:?}", s.source_id, s.name, s.infohash)
}

proptest! {
    #[test]
    fn dedup_is_a_partition(streams in prop::collection::vec(stream(), 0..12)) {
        let groups = dedup(&streams);
        // Every input index appears exactly once across the groups.
        let mut all: Vec<usize> = groups.iter().flat_map(|m| m.members.clone()).collect();
        all.sort_unstable();
        prop_assert_eq!(all, (0..streams.len()).collect::<Vec<_>>());
        // Each group reports its lowest member as primary.
        for m in &groups {
            prop_assert_eq!(m.primary, *m.members.iter().min().unwrap());
        }
    }

    #[test]
    fn dedup_is_commutative(streams in prop::collection::vec(stream(), 0..12)) {
        // Partition by content is the same regardless of input order.
        let partition = |list: &[DedupStream]| -> BTreeSet<BTreeSet<String>> {
            dedup(list)
                .into_iter()
                .map(|m| m.members.iter().map(|&i| content_key(&list[i])).collect())
                .collect()
        };
        let forward = partition(&streams);
        let mut rev = streams.clone();
        rev.reverse();
        let backward = partition(&rev);
        prop_assert_eq!(forward, backward);
    }

    #[test]
    fn exact_infohash_always_merges(name_a in "[A-Za-z ]{3,20}", name_b in "[A-Za-z ]{3,20}") {
        // Two streams with the same infohash + file_idx land in one group, whatever the labels.
        let streams = vec![
            DedupStream { source_id: "a".into(), name: name_a, infohash: Some("deadbeef".into()), file_idx: Some(0), size_bytes: None },
            DedupStream { source_id: "b".into(), name: name_b, infohash: Some("DEADBEEF".into()), file_idx: Some(0), size_bytes: None },
        ];
        let groups = dedup(&streams);
        prop_assert_eq!(groups.len(), 1);
        prop_assert_eq!(groups[0].members.len(), 2);
    }
}
