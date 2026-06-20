//! Cross-language conformance: feature extraction must yield exactly the pinned namespaced key set for
//! each fixture. Pairs with the invariant tests in `src/feature.rs` (`cosine(v,v)=1`, disjoint=0) that
//! cover the float math the key set deliberately does not.

use std::collections::BTreeSet;

use serde::Deserialize;
use vortx_reco::{feature_vector, MetaFeatures};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    features: MetaFeatures,
    #[serde(rename = "expectedKeys")]
    expected_keys: Vec<String>,
}

const SUITE: &str = include_str!("../conformance/feature_keys.json");

#[test]
fn feature_keys_match_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse conformance suite");
    for case in &suite.cases {
        let got: BTreeSet<String> = feature_vector(&case.features)
            .wire_keys()
            .into_iter()
            .collect();
        let want: BTreeSet<String> = case.expected_keys.iter().cloned().collect();
        assert_eq!(got, want, "feature keys diverged for case '{}'", case.name);
    }
}
