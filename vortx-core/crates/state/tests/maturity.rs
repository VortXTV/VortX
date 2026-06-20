//! Cross-language conformance + property tests for the parental-controls maturity gate.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_state::{
    maturity_allows, parse_certification, MaturityRating, ParentalFlags, DEFAULT_KIDS_CEILING,
};

#[derive(Deserialize)]
struct Suite {
    certifications: Vec<CertVec>,
    decisions: Vec<DecisionVec>,
}

#[derive(Deserialize)]
struct CertVec {
    raw: String,
    age: Option<u8>,
}

#[derive(Deserialize)]
struct DecisionVec {
    name: String,
    kids: bool,
    ceiling: Option<u8>,
    rating: Option<u8>,
    allowed: bool,
}

const SUITE: &str = include_str!("../conformance/maturity_vectors.json");

#[test]
fn maturity_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse maturity suite");
    assert!(suite.certifications.len() >= 18 && suite.decisions.len() >= 10);

    for v in &suite.certifications {
        let got = parse_certification(&v.raw).map(|r| r.0);
        assert_eq!(got, v.age, "certification parse drifted for {:?}", v.raw);
    }
    for d in &suite.decisions {
        let flags = ParentalFlags {
            kids: d.kids,
            maturity_ceiling: d.ceiling,
            ..Default::default()
        };
        let got = maturity_allows(&flags, d.rating.map(MaturityRating));
        assert_eq!(got, d.allowed, "decision drifted for {}", d.name);
    }
}

proptest! {
    /// A kids profile NEVER sees content rated above its effective ceiling, and NEVER sees unrated content.
    #[test]
    fn kids_never_exceed_ceiling(ceiling in proptest::option::of(0u8..21), rating in proptest::option::of(0u8..25)) {
        let flags = ParentalFlags { kids: true, maturity_ceiling: ceiling, ..Default::default() };
        let allowed = maturity_allows(&flags, rating.map(MaturityRating));
        let eff = ceiling.unwrap_or(DEFAULT_KIDS_CEILING);
        match rating {
            Some(r) => prop_assert_eq!(allowed, r <= eff),
            None => prop_assert!(!allowed), // fail-closed
        }
    }

    /// A profile with no restriction (not kids, no ceiling) allows every rating, rated or not.
    #[test]
    fn unrestricted_allows_all(rating in proptest::option::of(0u8..25)) {
        let flags = ParentalFlags::default();
        prop_assert!(maturity_allows(&flags, rating.map(MaturityRating)));
    }

    /// Parsing is total and never panics; any parsed age is within the sane range.
    #[test]
    fn parse_is_total_and_bounded(s in ".{0,12}") {
        if let Some(r) = parse_certification(&s) {
            prop_assert!(r.0 <= 21);
        }
    }
}
