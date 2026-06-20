//! Property-based invariants for the recommend pipeline. The NEW BAR for anything with an ordering:
//! the output must be a deterministic total order of the inputs, must never leak a watched title, must
//! respect the rail-length cap, and must not duplicate a candidate.

use std::collections::HashSet;

use proptest::prelude::*;
use vortx_reco::{
    build_taste, recommend, Candidate, Engagement, EngagementSignal, MetaFeatures, RecoPrefs,
    TasteProfile,
};

fn sci_fi_taste() -> TasteProfile {
    build_taste(&[Engagement::new(
        MetaFeatures {
            type_: "movie".into(),
            genres: vec!["Sci-Fi".into()],
            ..Default::default()
        },
        EngagementSignal::Finished { times_watched: 1 },
        0.0,
    )])
}

fn genre() -> impl Strategy<Value = String> {
    prop_oneof![
        Just("Sci-Fi"),
        Just("Drama"),
        Just("Action"),
        Just("Comedy"),
        Just("Horror"),
    ]
    .prop_map(String::from)
}

fn genre_list() -> impl Strategy<Value = Vec<String>> {
    prop::collection::vec(genre(), 1..4)
}

proptest! {
    #[test]
    fn pipeline_invariants_hold(
        genre_lists in prop::collection::vec(genre_list(), 0..25),
        watched_flags in prop::collection::vec(any::<bool>(), 0..25),
        max_per_genre in 1usize..5,
        count in 1usize..30,
    ) {
        let cands: Vec<Candidate> = genre_lists
            .iter()
            .enumerate()
            .map(|(i, gs)| {
                Candidate::new(
                    format!("tt{i}"),
                    MetaFeatures { type_: "movie".into(), genres: gs.clone(), ..Default::default() },
                )
            })
            .collect();

        let mut watched = HashSet::new();
        for (i, &w) in watched_flags.iter().enumerate() {
            if w && i < cands.len() {
                watched.insert(format!("tt{i}"));
            }
        }

        let taste = sci_fi_taste();
        let prefs = RecoPrefs { count, max_per_genre, ..RecoPrefs::default() };
        let recs = recommend(&cands, &taste, &watched, &prefs);

        // A watched/removed title is never recommended.
        for r in &recs {
            prop_assert!(!watched.contains(&r.meta_id));
        }

        // Rail-length cap is respected.
        prop_assert!(recs.len() <= count);

        // No candidate appears twice.
        let unique: HashSet<&String> = recs.iter().map(|r| &r.meta_id).collect();
        prop_assert_eq!(unique.len(), recs.len());

        // Deterministic total order: identical inputs -> identical ordering.
        let again = recommend(&cands, &taste, &watched, &prefs);
        let ids_a: Vec<&str> = recs.iter().map(|r| r.meta_id.as_str()).collect();
        let ids_b: Vec<&str> = again.iter().map(|r| r.meta_id.as_str()).collect();
        prop_assert_eq!(ids_a, ids_b);

        // Every recommendation traces back to a real candidate id.
        let candidate_ids: HashSet<&String> = cands.iter().map(|c| &c.meta_id).collect();
        for r in &recs {
            prop_assert!(candidate_ids.contains(&r.meta_id));
        }
    }
}
