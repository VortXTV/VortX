//! The recommendation pipeline: score candidates by cosine against the taste vector, diversify with
//! MMR + a per-genre calibration cap, attach an honest reason (the argmax of the score decomposition),
//! and drop anything already watched/removed. Pure and deterministic: the same inputs yield the same
//! ordering on every run, on every platform.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use crate::feature::{cosine, feature_vector, FeatureKey, FeatureVector, MetaFeatures};
use crate::taste::TasteProfile;

/// A title eligible to be recommended.
#[derive(Debug, Clone)]
pub struct Candidate {
    pub meta_id: String,
    pub features: MetaFeatures,
}

impl Candidate {
    pub fn new(meta_id: impl Into<String>, features: MetaFeatures) -> Self {
        Self {
            meta_id: meta_id.into(),
            features,
        }
    }
}

/// Why a title was recommended. Built from the score decomposition, so it cannot misattribute: a
/// `BecauseYouLike` reason is literally the feature that contributed most to the score.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reason {
    /// A specific feature (genre/person/decade) dominated the match. Carries the [`FeatureKey::wire`]
    /// string, e.g. `"genre:Sci-Fi"`.
    BecauseYouLike(String),
    /// No taste overlap drove this pick (thin profile / cold start): it is on the rail on popularity.
    Trending,
}

/// One recommendation with its score and honest reasons.
#[derive(Debug, Clone, PartialEq)]
pub struct Recommendation {
    pub meta_id: String,
    pub score: f32,
    pub reasons: Vec<Reason>,
}

/// Tuning for the pipeline.
#[derive(Debug, Clone)]
pub struct RecoPrefs {
    /// Rail length cap.
    pub count: usize,
    /// MMR relevance-vs-diversity tradeoff in `[0,1]`. Higher = more relevance, less spread.
    pub lambda: f32,
    /// Genre calibration: at most this many items whose dominant genre is the same.
    pub max_per_genre: usize,
    /// Drop candidates scoring at or below this.
    pub score_floor: f32,
}

impl Default for RecoPrefs {
    fn default() -> Self {
        Self {
            count: 20,
            lambda: 0.7,
            max_per_genre: 4,
            score_floor: 0.0,
        }
    }
}

/// A scored, vectorized candidate carried through the MMR loop.
struct Scored {
    meta_id: String,
    score: f32,
    vector: FeatureVector,
    reason: Reason,
}

/// Recommend titles for a profile.
///
/// `watched` holds meta ids the profile has already finished/removed; they never appear in the output.
pub fn recommend(
    candidates: &[Candidate],
    taste: &TasteProfile,
    watched: &HashSet<String>,
    prefs: &RecoPrefs,
) -> Vec<Recommendation> {
    // 1. Score + filter (drop watched, drop below floor).
    let mut scored: Vec<Scored> = candidates
        .iter()
        .filter(|c| !watched.contains(&c.meta_id))
        .map(|c| {
            let vector = feature_vector(&c.features);
            let score = cosine(&taste.vector, &vector);
            let reason = vector
                .top_shared(&taste.vector)
                .map(|k| Reason::BecauseYouLike(k.wire()))
                .unwrap_or(Reason::Trending);
            Scored {
                meta_id: c.meta_id.clone(),
                score,
                vector,
                reason,
            }
        })
        .filter(|s| s.score > prefs.score_floor)
        .collect();

    // Stable starting order: score desc, then meta_id asc to break ties deterministically.
    scored.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| a.meta_id.cmp(&b.meta_id))
    });

    // 2. Greedy MMR with a per-genre calibration cap.
    let mut selected: Vec<Recommendation> = Vec::new();
    let mut selected_vectors: Vec<FeatureVector> = Vec::new();
    let mut genre_counts: HashMap<String, usize> = HashMap::new();

    while selected.len() < prefs.count && !scored.is_empty() {
        let mut best: Option<(usize, f32)> = None;

        for (i, cand) in scored.iter().enumerate() {
            // Genre calibration: skip if this candidate's dominant genre is already at cap.
            if let Some(g) = dominant_genre(&cand.vector) {
                if genre_counts.get(&g).copied().unwrap_or(0) >= prefs.max_per_genre {
                    continue;
                }
            }
            let max_sim = selected_vectors
                .iter()
                .map(|sv| cosine(&cand.vector, sv))
                .fold(0.0_f32, f32::max);
            let mmr = prefs.lambda * cand.score - (1.0 - prefs.lambda) * max_sim;
            // Strict `>` keeps the earliest (highest score / lowest id) candidate on ties: deterministic.
            if best.is_none_or(|(_, bv)| mmr > bv) {
                best = Some((i, mmr));
            }
        }

        let Some((idx, _)) = best else {
            break; // every remaining candidate is over its genre cap
        };
        let chosen = scored.remove(idx);
        if let Some(g) = dominant_genre(&chosen.vector) {
            *genre_counts.entry(g).or_insert(0) += 1;
        }
        selected_vectors.push(chosen.vector);
        selected.push(Recommendation {
            meta_id: chosen.meta_id,
            score: chosen.score,
            reasons: vec![chosen.reason],
        });
    }

    selected
}

/// The genre with the largest weight in a candidate's vector (for the calibration cap).
fn dominant_genre(vector: &FeatureVector) -> Option<String> {
    vector
        .iter()
        .filter_map(|(k, w)| match k {
            FeatureKey::Genre(g) => Some((g.clone(), w)),
            _ => None,
        })
        .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap_or(Ordering::Equal))
        .map(|(g, _)| g)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::taste::{build_taste, Engagement, EngagementSignal};

    fn movie(id: &str, genres: &[&str]) -> Candidate {
        Candidate::new(
            id,
            MetaFeatures {
                type_: "movie".into(),
                genres: genres.iter().map(|s| s.to_string()).collect(),
                ..Default::default()
            },
        )
    }

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

    #[test]
    fn watched_titles_are_never_recommended() {
        let taste = sci_fi_taste();
        let cands = vec![movie("tt1", &["Sci-Fi"]), movie("tt2", &["Sci-Fi"])];
        let mut watched = HashSet::new();
        watched.insert("tt1".to_string());
        let recs = recommend(&cands, &taste, &watched, &RecoPrefs::default());
        assert!(recs.iter().all(|r| r.meta_id != "tt1"));
        assert!(recs.iter().any(|r| r.meta_id == "tt2"));
    }

    #[test]
    fn reason_names_the_matched_genre() {
        let taste = sci_fi_taste();
        let cands = vec![movie("tt1", &["Sci-Fi"])];
        let recs = recommend(&cands, &taste, &HashSet::new(), &RecoPrefs::default());
        assert_eq!(
            recs[0].reasons,
            vec![Reason::BecauseYouLike("genre:Sci-Fi".into())]
        );
    }

    #[test]
    fn genre_cap_calibrates_the_rail() {
        let taste = sci_fi_taste();
        let cands: Vec<Candidate> = (0..10)
            .map(|i| movie(&format!("tt{i}"), &["Sci-Fi"]))
            .collect();
        let prefs = RecoPrefs {
            count: 10,
            max_per_genre: 3,
            ..RecoPrefs::default()
        };
        let recs = recommend(&cands, &taste, &HashSet::new(), &prefs);
        assert_eq!(
            recs.len(),
            3,
            "Sci-Fi is capped at 3 even with 10 candidates"
        );
    }

    #[test]
    fn deterministic_total_order() {
        let taste = sci_fi_taste();
        let cands = vec![
            movie("tt1", &["Sci-Fi", "Action"]),
            movie("tt2", &["Sci-Fi"]),
            movie("tt3", &["Drama"]),
            movie("tt4", &["Sci-Fi", "Thriller"]),
        ];
        let a = recommend(&cands, &taste, &HashSet::new(), &RecoPrefs::default());
        let b = recommend(&cands, &taste, &HashSet::new(), &RecoPrefs::default());
        let ids_a: Vec<&str> = a.iter().map(|r| r.meta_id.as_str()).collect();
        let ids_b: Vec<&str> = b.iter().map(|r| r.meta_id.as_str()).collect();
        assert_eq!(ids_a, ids_b);
    }
}
