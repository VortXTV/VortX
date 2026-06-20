//! The per-profile taste vector: a recency-decayed, implicit-feedback sum of the [`FeatureVector`]s of
//! the titles a profile engaged with. The decisive thing static TMDB/MDBList "similar" cannot do lives
//! here: a *negative* signal. A removed title pushes the taste vector AWAY from its features, so the
//! profile gets that kind of title suppressed instead of resurfaced.
//!
//! Purity: the caller supplies `age_days` per engagement (computed from the profile's stored timestamps
//! against `now` in the engine layer), so this module holds no clock. Same inputs -> same taste, on
//! every platform.

use std::collections::BTreeMap;

use crate::feature::{feature_vector, FeatureKey, FeatureVector, MetaFeatures};

/// The engagement a profile had with one title, mapped to the implicit-feedback weight `ω`. These map
/// 1:1 onto VortX's per-profile `vortx-state` records (resume ratio, watched bits, continue-watching
/// permille, saved items, search history, and a removed/tombstone set).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngagementSignal {
    /// Watched to completion. `times_watched >= 2` is a rewatch, which is a stronger love signal.
    Finished { times_watched: u32 },
    /// 40..85% progress: real engagement, short of the finish.
    Engaged,
    /// 5..40% progress: started and quit. A mild *negative* (the title disappointed).
    Abandoned,
    /// <5% progress, never marked watched: a trailer-bounce. No signal either way.
    TrailerBounce,
    /// Saved to the library, not yet watched: intent.
    Saved,
    /// Appeared in search history: interest.
    Searched,
    /// Explicitly removed / dismissed: the strong negative.
    Removed,
}

impl EngagementSignal {
    /// The implicit-feedback weight. Positive pulls taste toward the title's features; negative pushes
    /// away; zero drops it entirely.
    pub fn omega(self) -> f32 {
        match self {
            EngagementSignal::Finished { times_watched } if times_watched >= 2 => 1.5,
            EngagementSignal::Finished { .. } => 1.0,
            EngagementSignal::Engaged => 0.6,
            EngagementSignal::Abandoned => -0.25,
            EngagementSignal::TrailerBounce => 0.0,
            EngagementSignal::Saved => 0.4,
            EngagementSignal::Searched => 0.3,
            EngagementSignal::Removed => -1.0,
        }
    }
}

/// One title's contribution to taste: its features, the engagement, and how long ago it happened.
#[derive(Debug, Clone)]
pub struct Engagement {
    pub features: MetaFeatures,
    pub signal: EngagementSignal,
    /// Age of the engagement in days (caller computes from stored timestamp vs `now`).
    pub age_days: f32,
}

impl Engagement {
    pub fn new(features: MetaFeatures, signal: EngagementSignal, age_days: f32) -> Self {
        Self {
            features,
            signal,
            age_days,
        }
    }
}

/// Soft recency half-life: a title's weight halves every 120 days. Not a hard window, so an 8-month-old
/// favourite still counts, just less.
pub const HALF_LIFE_DAYS: f32 = 120.0;

fn recency_decay(age_days: f32) -> f32 {
    0.5_f32.powf(age_days.max(0.0) / HALF_LIFE_DAYS)
}

/// A profile's taste. `mass` is the total absolute engagement weight, a single continuous number that
/// drives cold-start blending: near 0 means "thin profile, lean on popularity", and it rises smoothly as
/// the profile watches (no "is-new-user" boolean).
#[derive(Debug, Clone)]
pub struct TasteProfile {
    pub vector: FeatureVector,
    pub mass: f32,
}

impl TasteProfile {
    pub fn is_thin(&self, full_mass: f32) -> bool {
        self.mass < full_mass
    }
}

/// Build the taste vector: `L2norm( Σ ω(item) · decay(age) · feature_vector(item) )`.
pub fn build_taste(engagements: &[Engagement]) -> TasteProfile {
    let mut acc: BTreeMap<FeatureKey, f32> = BTreeMap::new();
    let mut mass = 0.0_f32;

    for e in engagements {
        let w = e.signal.omega() * recency_decay(e.age_days);
        if w == 0.0 {
            continue;
        }
        mass += w.abs();
        for (key, weight) in feature_vector(&e.features).iter() {
            *acc.entry(key.clone()).or_insert(0.0) += w * weight;
        }
    }

    TasteProfile {
        vector: FeatureVector::from_raw(acc),
        mass,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn movie(genre: &str) -> MetaFeatures {
        MetaFeatures {
            type_: "movie".into(),
            genres: vec![genre.into()],
            ..Default::default()
        }
    }

    #[test]
    fn finished_pulls_taste_toward_the_genre() {
        let taste = build_taste(&[Engagement::new(
            movie("Horror"),
            EngagementSignal::Finished { times_watched: 1 },
            0.0,
        )]);
        let horror = feature_vector(&movie("Horror"));
        assert!(taste.vector.cosine(&horror) > 0.99);
    }

    #[test]
    fn removed_pushes_taste_away_from_the_genre() {
        // Love Drama, remove Horror: taste should point at Drama and *against* Horror.
        let taste = build_taste(&[
            Engagement::new(
                movie("Drama"),
                EngagementSignal::Finished { times_watched: 1 },
                0.0,
            ),
            Engagement::new(movie("Horror"), EngagementSignal::Removed, 0.0),
        ]);
        let horror = feature_vector(&movie("Horror"));
        let drama = feature_vector(&movie("Drama"));
        assert!(
            taste.vector.cosine(&drama) > 0.0,
            "should lean toward the loved genre"
        );
        assert!(
            taste.vector.cosine(&horror) < 0.0,
            "a removed genre must score NEGATIVE, the thing static similar cannot do"
        );
    }

    #[test]
    fn recency_halves_contribution_at_one_half_life() {
        assert!((recency_decay(0.0) - 1.0).abs() < 1e-6);
        assert!((recency_decay(HALF_LIFE_DAYS) - 0.5).abs() < 1e-6);
        assert!((recency_decay(2.0 * HALF_LIFE_DAYS) - 0.25).abs() < 1e-6);
    }

    #[test]
    fn rewatch_outweighs_a_single_watch() {
        assert!(
            EngagementSignal::Finished { times_watched: 3 }.omega()
                > EngagementSignal::Finished { times_watched: 1 }.omega()
        );
    }

    #[test]
    fn trailer_bounce_contributes_no_mass() {
        let taste = build_taste(&[Engagement::new(
            movie("Action"),
            EngagementSignal::TrailerBounce,
            0.0,
        )]);
        assert_eq!(taste.mass, 0.0);
        assert!(taste.vector.is_empty());
    }
}
