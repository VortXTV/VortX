//! Cross-language conformance + property tests for the Home feed lane builder.
//!
//! The conformance vectors use an empty candidate pool so every pinned value is integer/string
//! deterministic (no float scoring): lane assignment, eligibility gating, cross-lane dedup, Up Next
//! recency order. The reco-scored lane's float ordering is covered by the reco crate's own invariants, not
//! byte-pinned here. The properties assert the structural guarantees the feed must always hold.

use std::collections::{BTreeMap, HashSet};

use proptest::prelude::*;
use serde::Deserialize;
use vortx_reco::{
    build_home_feed, AllEligible, AllOf, AvailabilitySet, HomeFeedInput, HomeFeedPrefs, LaneKind,
    MaturityGate,
};
use vortx_state::{maturity_allows, MaturityRating, ParentalFlags, WatchLog, WatchState};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    watch: Vec<WatchEntry>,
    library: Vec<String>,
    trending: Vec<String>,
    eligible: Option<Vec<String>>,
    expect_lanes: Vec<ExpectLane>,
}

#[derive(Deserialize)]
struct WatchEntry {
    meta_id: String,
    #[serde(flatten)]
    state: WatchState,
}

#[derive(Deserialize)]
struct ExpectLane {
    kind: String,
    items: Vec<String>,
}

const SUITE: &str = include_str!("../conformance/homefeed_vectors.json");

fn kind_wire(kind: LaneKind) -> &'static str {
    match kind {
        LaneKind::UpNext => "up_next",
        LaneKind::StartWatching => "start_watching",
        LaneKind::BecauseYouWatched => "because_you_watched",
        LaneKind::Trending => "trending",
    }
}

#[test]
fn home_feed_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse homefeed suite");
    assert!(suite.cases.len() >= 5, "expected the full vector set");
    let taste = vortx_reco::build_taste(&[]);
    for case in &suite.cases {
        let log: WatchLog = case
            .watch
            .iter()
            .map(|e| (e.meta_id.clone(), e.state))
            .collect();
        let input = HomeFeedInput {
            watch_log: &log,
            library: &case.library,
            candidates: &[],
            taste: &taste,
            trending: &case.trending,
        };
        let feed = match &case.eligible {
            None => build_home_feed(&input, &AllEligible, &HomeFeedPrefs::default()),
            Some(ids) => build_home_feed(
                &input,
                &AvailabilitySet::new(ids.clone()),
                &HomeFeedPrefs::default(),
            ),
        };
        let got: Vec<(String, Vec<String>)> = feed
            .lanes
            .iter()
            .map(|l| {
                (
                    kind_wire(l.kind).to_string(),
                    l.items.iter().map(|i| i.meta_id.clone()).collect(),
                )
            })
            .collect();
        let want: Vec<(String, Vec<String>)> = case
            .expect_lanes
            .iter()
            .map(|e| (e.kind.clone(), e.items.clone()))
            .collect();
        assert_eq!(got, want, "home feed drifted for {}", case.name);
    }
}

// --- properties ---

fn watch_state() -> impl Strategy<Value = WatchState> {
    (0u64..3000, 0u64..1000, 0u64..1000, 0u64..1000).prop_map(
        |(resume_ms, resume_at, watched_at, removed_at)| WatchState {
            resume_ms,
            resume_at,
            watched_at,
            times_watched: if watched_at > 0 { 1 } else { 0 },
            reset_at: 0,
            removed_at,
        },
    )
}

fn id() -> impl Strategy<Value = String> {
    "[a-e]".prop_map(String::from)
}

proptest! {
    #[test]
    fn invariants_hold(
        watch in prop::collection::vec((id(), watch_state()), 0..8),
        library in prop::collection::vec(id(), 0..8),
        trending in prop::collection::vec(id(), 0..8),
        eligible in prop::collection::hash_set(id(), 0..6),
    ) {
        let log: WatchLog = watch.into_iter().collect::<BTreeMap<_, _>>();
        let taste = vortx_reco::build_taste(&[]);
        let input = HomeFeedInput {
            watch_log: &log,
            library: &library,
            candidates: &[],
            taste: &taste,
            trending: &trending,
        };
        let avail = AvailabilitySet(eligible.clone());
        let feed = build_home_feed(&input, &avail, &HomeFeedPrefs::default());

        let mut seen: HashSet<&str> = HashSet::new();
        for lane in &feed.lanes {
            for item in &lane.items {
                // No item in two lanes.
                prop_assert!(seen.insert(item.meta_id.as_str()), "{} in two lanes", item.meta_id);
                // Every lane item is eligible.
                prop_assert!(eligible.contains(&item.meta_id), "{} ineligible", item.meta_id);
                // A finished title never appears in Up Next.
                if lane.kind == LaneKind::UpNext {
                    let w = log.get(&item.meta_id).unwrap();
                    prop_assert!(!w.is_watched(), "{} finished but in Up Next", item.meta_id);
                    prop_assert!(!w.is_removed(), "{} removed but in Up Next", item.meta_id);
                }
            }
        }
    }

    #[test]
    fn build_is_deterministic(
        watch in prop::collection::vec((id(), watch_state()), 0..6),
        library in prop::collection::vec(id(), 0..6),
        trending in prop::collection::vec(id(), 0..6),
    ) {
        let log: WatchLog = watch.into_iter().collect::<BTreeMap<_, _>>();
        let taste = vortx_reco::build_taste(&[]);
        let input = HomeFeedInput {
            watch_log: &log,
            library: &library,
            candidates: &[],
            taste: &taste,
            trending: &trending,
        };
        let a = build_home_feed(&input, &AllEligible, &HomeFeedPrefs::default());
        let b = build_home_feed(&input, &AllEligible, &HomeFeedPrefs::default());
        prop_assert_eq!(a, b);
    }

    /// A kids profile can NEVER surface a maturity-disallowed title in ANY lane: not over its ceiling, not
    /// unrated. Drives ids through every lane source with random ratings and a random ceiling.
    #[test]
    fn kids_feed_never_shows_blocked_content(
        watch in prop::collection::vec((id(), watch_state()), 0..8),
        library in prop::collection::vec(id(), 0..8),
        trending in prop::collection::vec(id(), 0..8),
        ratings_seed in prop::collection::vec((id(), proptest::option::of(0u8..20)), 0..6),
        ceiling in proptest::option::of(0u8..18),
    ) {
        let log: WatchLog = watch.into_iter().collect::<BTreeMap<_, _>>();
        let ratings: std::collections::HashMap<String, Option<MaturityRating>> = ratings_seed
            .into_iter()
            .map(|(k, v)| (k, v.map(MaturityRating)))
            .collect();
        let flags = ParentalFlags { kids: true, maturity_ceiling: ceiling, ..Default::default() };
        let taste = vortx_reco::build_taste(&[]);
        // Everything is "available"; the maturity gate is the only thing that may exclude.
        let mut all_ids: Vec<String> = library.clone();
        all_ids.extend(trending.clone());
        all_ids.extend(log.keys().cloned());
        let avail = AvailabilitySet::new(all_ids);
        let gate = MaturityGate { flags: &flags, ratings: &ratings };
        let input = HomeFeedInput {
            watch_log: &log,
            library: &library,
            candidates: &[],
            taste: &taste,
            trending: &trending,
        };
        let feed = build_home_feed(&input, &AllOf(&[&avail, &gate]), &HomeFeedPrefs::default());
        for lane in &feed.lanes {
            for item in &lane.items {
                let rating = ratings.get(&item.meta_id).copied().flatten();
                prop_assert!(maturity_allows(&flags, rating), "{} surfaced but blocked", item.meta_id);
            }
        }
    }
}
