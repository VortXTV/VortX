//! The feature-extraction atom. A title becomes a sparse, L2-normalized [`FeatureVector`] over a
//! namespaced [`FeatureKey`] space. This is a *total function*: no clock, no RNG, no IO, byte-identical
//! keys for identical input. Everything else in the crate reduces to vectors built here: taste is a
//! weighted sum of them, scoring is their cosine, diversity is their cosine, reasons are decompositions
//! of their cosine.
//!
//! Grounded in our own `vortx_protocol::{MetaDetail, MetaPreview}` (which carry `genres` / `cast` /
//! `director` as direct fields), not stremio-core's `links`-bucketed `MetaItem`. The two converge on the
//! same [`MetaFeatures`] shape so a candidate sourced from a light catalog preview and one sourced from a
//! full detail both produce a vector.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use vortx_protocol::{MetaDetail, MetaPreview};

/// Coarse runtime class. A bucket, not the raw minutes, because "a ~2h film" is the taste signal, not
/// "exactly 127 minutes".
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum RuntimeBucket {
    Short,
    Medium,
    Long,
    Epic,
}

impl RuntimeBucket {
    /// Stable wire token (part of the cross-language conformance contract).
    pub fn wire(self) -> &'static str {
        match self {
            RuntimeBucket::Short => "short",
            RuntimeBucket::Medium => "medium",
            RuntimeBucket::Long => "long",
            RuntimeBucket::Epic => "epic",
        }
    }

    /// `None` when the runtime string carries no parseable leading minute count (so it contributes no
    /// feature rather than a bogus one).
    fn classify(runtime: Option<&str>) -> Option<RuntimeBucket> {
        let mins = runtime.and_then(parse_leading_u32)?;
        Some(match mins {
            m if m < 60 => RuntimeBucket::Short,
            m if m < 105 => RuntimeBucket::Medium,
            m if m < 150 => RuntimeBucket::Long,
            _ => RuntimeBucket::Epic,
        })
    }
}

/// A single dimension of the feature space. The variant *is* the namespace, so "the genre Drive" and
/// "the actor Drive" can never collide.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum FeatureKey {
    Genre(String),
    Cast(String),
    Director(String),
    Decade(i16),
    Runtime(RuntimeBucket),
    Type(String),
}

impl FeatureKey {
    /// Stable, human-legible wire string. This is what the conformance vectors pin: identical across
    /// Rust / TS / Swift, independent of the `f32` weight attached to the key.
    pub fn wire(&self) -> String {
        match self {
            FeatureKey::Genre(g) => format!("genre:{g}"),
            FeatureKey::Cast(c) => format!("cast:{c}"),
            FeatureKey::Director(d) => format!("director:{d}"),
            FeatureKey::Decade(y) => format!("decade:{y}"),
            FeatureKey::Runtime(b) => format!("runtime:{}", b.wire()),
            FeatureKey::Type(t) => format!("type:{t}"),
        }
    }
}

/// The features lifted off a meta item, decoupled from whether it came from a preview or a full detail.
/// `cast` / `director` / `runtime` are simply empty/absent for a catalog preview.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MetaFeatures {
    #[serde(rename = "type", default)]
    pub type_: String,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub cast: Vec<String>,
    #[serde(default)]
    pub director: Vec<String>,
    #[serde(
        default,
        rename = "releaseInfo",
        skip_serializing_if = "Option::is_none"
    )]
    pub release_info: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<String>,
}

impl From<&MetaDetail> for MetaFeatures {
    fn from(m: &MetaDetail) -> Self {
        Self {
            type_: m.type_.clone(),
            genres: m.genres.clone().unwrap_or_default(),
            cast: m.cast.clone().unwrap_or_default(),
            director: m.director.clone().unwrap_or_default(),
            release_info: m.release_info.clone(),
            runtime: m.runtime.clone(),
        }
    }
}

impl From<&MetaPreview> for MetaFeatures {
    fn from(m: &MetaPreview) -> Self {
        Self {
            type_: m.type_.clone(),
            genres: m.genres.clone().unwrap_or_default(),
            cast: Vec::new(),
            director: Vec::new(),
            release_info: m.release_info.clone(),
            runtime: None,
        }
    }
}

/// Top-5 cast, rank-decayed: the lead matters more than the fifth-billed.
const CAST_WEIGHTS: [f32; 5] = [0.9, 0.72, 0.58, 0.46, 0.37];
const GENRE_WEIGHT: f32 = 1.0;
const DIRECTOR_WEIGHT: f32 = 1.1;
const DECADE_WEIGHT: f32 = 0.6;
const RUNTIME_WEIGHT: f32 = 0.4;
const TYPE_WEIGHT: f32 = 0.5;

/// A sparse, L2-normalized vector in the [`FeatureKey`] space. Stored in a `BTreeMap` so iteration is
/// deterministic (which keeps `top_shared` reasons stable); cosine itself is order-independent.
#[derive(Debug, Clone, PartialEq)]
pub struct FeatureVector {
    weights: BTreeMap<FeatureKey, f32>,
}

impl FeatureVector {
    /// Normalize a raw (un-normalized) weight map into a unit vector. A zero/empty vector stays empty
    /// (cosine against it is 0, which is the correct "no signal" answer).
    pub(crate) fn from_raw(mut weights: BTreeMap<FeatureKey, f32>) -> Self {
        let norm = weights.values().map(|v| v * v).sum::<f32>().sqrt();
        if norm > 0.0 {
            for v in weights.values_mut() {
                *v /= norm;
            }
        }
        Self { weights }
    }

    pub fn is_empty(&self) -> bool {
        self.weights.is_empty()
    }

    /// This vector's weight on `key` (0.0 if absent).
    pub fn get(&self, key: &FeatureKey) -> f32 {
        self.weights.get(key).copied().unwrap_or(0.0)
    }

    /// The feature keys present, in deterministic (sorted) order.
    pub fn wire_keys(&self) -> Vec<String> {
        self.weights.keys().map(FeatureKey::wire).collect()
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = (&FeatureKey, f32)> {
        self.weights.iter().map(|(k, v)| (k, *v))
    }

    /// Cosine similarity. Both vectors are unit-normalized, so this is their sparse dot product:
    /// iterate the smaller, look up the larger.
    pub fn cosine(&self, other: &FeatureVector) -> f32 {
        let (small, big) = if self.weights.len() <= other.weights.len() {
            (self, other)
        } else {
            (other, self)
        };
        small.weights.iter().map(|(k, v)| v * big.get(k)).sum()
    }

    /// The single feature contributing most to `cosine(self, other)` (used for honest reasons). `None`
    /// when the vectors share nothing.
    pub(crate) fn top_shared(&self, other: &FeatureVector) -> Option<FeatureKey> {
        self.weights
            .iter()
            .map(|(k, v)| (k, v * other.get(k)))
            .filter(|(_, c)| *c > 0.0)
            .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
            .map(|(k, _)| k.clone())
    }
}

/// Free-function cosine, for call sites that read better that way.
pub fn cosine(a: &FeatureVector, b: &FeatureVector) -> f32 {
    a.cosine(b)
}

/// Build the L2-normalized feature vector for a title. Pure and total.
pub fn feature_vector(f: &MetaFeatures) -> FeatureVector {
    let mut raw: BTreeMap<FeatureKey, f32> = BTreeMap::new();

    for g in &f.genres {
        if !g.is_empty() {
            *raw.entry(FeatureKey::Genre(g.clone())).or_insert(0.0) += GENRE_WEIGHT;
        }
    }
    for (i, name) in f.cast.iter().filter(|c| !c.is_empty()).take(5).enumerate() {
        *raw.entry(FeatureKey::Cast(name.clone())).or_insert(0.0) += CAST_WEIGHTS[i];
    }
    for d in &f.director {
        if !d.is_empty() {
            *raw.entry(FeatureKey::Director(d.clone())).or_insert(0.0) += DIRECTOR_WEIGHT;
        }
    }
    if let Some(decade) = decade_of(f.release_info.as_deref()) {
        *raw.entry(FeatureKey::Decade(decade)).or_insert(0.0) += DECADE_WEIGHT;
    }
    if let Some(bucket) = RuntimeBucket::classify(f.runtime.as_deref()) {
        *raw.entry(FeatureKey::Runtime(bucket)).or_insert(0.0) += RUNTIME_WEIGHT;
    }
    if !f.type_.is_empty() {
        *raw.entry(FeatureKey::Type(f.type_.clone())).or_insert(0.0) += TYPE_WEIGHT;
    }

    FeatureVector::from_raw(raw)
}

/// Parse a leading unsigned integer off a string like `"148 min"` -> `148`.
fn parse_leading_u32(s: &str) -> Option<u32> {
    let digits: String = s.trim().chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

/// The decade of the first 4-digit year found in a `releaseInfo` string (`"2010"`, `"2010-2015"`,
/// `"Released 1999"` all work). `1994` -> `1990`.
fn decade_of(release_info: Option<&str>) -> Option<i16> {
    let s = release_info?;
    let bytes = s.as_bytes();
    let mut i = 0;
    while i + 4 <= bytes.len() {
        if bytes[i..i + 4].iter().all(u8::is_ascii_digit) {
            let year: i16 = s[i..i + 4].parse().ok()?;
            return Some((year / 10) * 10);
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inception() -> MetaFeatures {
        MetaFeatures {
            type_: "movie".into(),
            genres: vec!["Action".into(), "Sci-Fi".into(), "Thriller".into()],
            cast: vec![
                "Leonardo DiCaprio".into(),
                "Joseph Gordon-Levitt".into(),
                "Elliot Page".into(),
            ],
            director: vec!["Christopher Nolan".into()],
            release_info: Some("2010".into()),
            runtime: Some("148 min".into()),
        }
    }

    #[test]
    fn extracts_expected_namespaced_keys() {
        let v = feature_vector(&inception());
        let keys = v.wire_keys();
        for expected in [
            "genre:Action",
            "genre:Sci-Fi",
            "genre:Thriller",
            "cast:Leonardo DiCaprio",
            "director:Christopher Nolan",
            "decade:2010",
            "runtime:long",
            "type:movie",
        ] {
            assert!(keys.contains(&expected.to_string()), "missing {expected}");
        }
    }

    #[test]
    fn cast_is_capped_at_five() {
        let mut f = inception();
        f.cast = (0..9).map(|i| format!("Actor {i}")).collect();
        let keys = feature_vector(&f).wire_keys();
        let cast_keys = keys.iter().filter(|k| k.starts_with("cast:")).count();
        assert_eq!(cast_keys, 5);
    }

    #[test]
    fn self_cosine_is_one_disjoint_is_zero() {
        let a = feature_vector(&inception());
        assert!((a.cosine(&a) - 1.0).abs() < 1e-5);

        let other = MetaFeatures {
            type_: "series".into(),
            genres: vec!["Comedy".into()],
            cast: vec!["Steve Carell".into()],
            director: vec!["Greg Daniels".into()],
            release_info: Some("2005".into()),
            runtime: Some("22 min".into()),
        };
        let b = feature_vector(&other);
        assert!(
            a.cosine(&b).abs() < 1e-6,
            "fully disjoint vectors must be orthogonal"
        );
    }

    #[test]
    fn normalization_makes_genre_count_not_dominate() {
        // A 12-genre title and a 2-genre title both become unit vectors; neither wins purely on
        // dimension count.
        let many = MetaFeatures {
            type_: "movie".into(),
            genres: (0..12).map(|i| format!("G{i}")).collect(),
            ..Default::default()
        };
        let few = MetaFeatures {
            type_: "movie".into(),
            genres: vec!["G0".into(), "G1".into()],
            ..Default::default()
        };
        let vm = feature_vector(&many);
        let vf = feature_vector(&few);
        assert!((vm.cosine(&vm) - 1.0).abs() < 1e-5);
        assert!((vf.cosine(&vf) - 1.0).abs() < 1e-5);
    }

    #[test]
    fn runtime_buckets_partition_correctly() {
        assert_eq!(
            RuntimeBucket::classify(Some("40 min")),
            Some(RuntimeBucket::Short)
        );
        assert_eq!(
            RuntimeBucket::classify(Some("90 min")),
            Some(RuntimeBucket::Medium)
        );
        assert_eq!(
            RuntimeBucket::classify(Some("148 min")),
            Some(RuntimeBucket::Long)
        );
        assert_eq!(
            RuntimeBucket::classify(Some("181 min")),
            Some(RuntimeBucket::Epic)
        );
        assert_eq!(RuntimeBucket::classify(Some("unknown")), None);
        assert_eq!(RuntimeBucket::classify(None), None);
    }

    #[test]
    fn decade_parsing() {
        assert_eq!(decade_of(Some("2010")), Some(2010));
        assert_eq!(decade_of(Some("1994")), Some(1990));
        assert_eq!(decade_of(Some("2010-2015")), Some(2010));
        assert_eq!(decade_of(Some("Released 1999")), Some(1990));
        assert_eq!(decade_of(Some("n/a")), None);
        assert_eq!(decade_of(None), None);
    }
}
