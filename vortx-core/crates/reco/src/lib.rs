//! # vortx-reco
//!
//! VortX's in-engine recommendation system: pure, deterministic, per-profile, explainable,
//! privacy-first. It replaces the static, identical-for-everyone TMDB/MDBList "similar" list with a rail
//! that is `cosine(YOUR recency-decayed taste, candidate)`, re-ranked for diversity and genre
//! calibration, every item carrying an honest reason.
//!
//! ## The pipeline
//!
//! 1. [`feature_vector`] (the atom): a title -> a sparse, L2-normalized vector over a namespaced
//!    [`FeatureKey`] space. Total function, no clock/RNG/IO.
//! 2. [`build_taste`]: a profile's engagements -> a recency-decayed taste vector with a real *negative*
//!    signal (a removed title pushes taste away from its features).
//! 3. [`recommend`]: candidates -> scored, MMR-diversified, genre-calibrated [`Recommendation`]s with
//!    [`Reason`]s, dropping anything already watched.
//!
//! Nothing here transmits the profile: the taste vector, the engagements, and the recommender all run
//! in the engine, on-device. The cross-user collaborative ("others also watched") layer is a later
//! phase built on the hive's anonymous item-item co-occurrence facts.
//!
//! ## Determinism contract
//!
//! The feature *keys* a meta yields are pinned by cross-language conformance vectors
//! (`conformance/feature_keys.json`). The `f32` weights are validated by invariants
//! (`cosine(v,v) ≈ 1`, `cosine(disjoint) = 0`) rather than golden floats, because IEEE-754 results are
//! not guaranteed byte-identical across platforms.

mod feature;
mod homefeed;
mod recommend;
mod taste;

pub use feature::{cosine, feature_vector, FeatureKey, FeatureVector, MetaFeatures, RuntimeBucket};
pub use homefeed::{
    build_home_feed, AllEligible, AllOf, AvailabilitySet, EligibilityFilter, HomeFeed,
    HomeFeedInput, HomeFeedPrefs, Lane, LaneItem, LaneKind, MaturityGate,
};
pub use recommend::{recommend, Candidate, Reason, RecoPrefs, Recommendation};
pub use taste::{build_taste, Engagement, EngagementSignal, TasteProfile, HALF_LIFE_DAYS};
