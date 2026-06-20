//! Cross-language conformance vectors for the parental-PIN preimage.
//!
//! The PIN hash is `SHA-256("<profile_id>:<pin>")`. The SHA-256 step is standard; the cross-platform
//! contract is the PREIMAGE STRING, pinned here so the Swift app, the web client, and the dashboard all
//! build the same bytes before hashing and therefore verify a PIN identically. The same JSON is intended
//! to be consumed verbatim by the TS and Swift test suites.

use serde::Deserialize;
use vortx_state::pin_preimage;

#[derive(Deserialize)]
struct Vector {
    description: String,
    profile_id: String,
    pin: String,
    expected_preimage: String,
}

const VECTORS_JSON: &str = include_str!("../conformance/pin_preimage_vectors.json");

#[test]
fn pin_preimage_vectors_match() {
    let vectors: Vec<Vector> =
        serde_json::from_str(VECTORS_JSON).expect("conformance vectors parse");
    assert!(vectors.len() >= 4, "expected the full vector set");
    for v in &vectors {
        assert_eq!(
            pin_preimage(&v.profile_id, &v.pin),
            v.expected_preimage,
            "pin preimage drifted for vector: {}",
            v.description
        );
    }
}
