//! Cross-language conformance vectors for the per-profile debrid credential format. Every platform must
//! split a `store:apikey` token the same way (first colon only), so a credential saved on one device
//! resolves identically everywhere.

use serde::Deserialize;
use vortx_debrid::{parse_credential, DebridService};

#[derive(Deserialize)]
struct Vector {
    description: String,
    token: String,
    service: DebridService,
    apikey: String,
}

const VECTORS_JSON: &str = include_str!("../conformance/credential_vectors.json");

#[test]
fn credential_vectors_match() {
    let vectors: Vec<Vector> =
        serde_json::from_str(VECTORS_JSON).expect("conformance vectors parse");
    assert!(vectors.len() >= 4, "expected the full vector set");
    for v in &vectors {
        assert_eq!(
            parse_credential(&v.token),
            Some((v.service, v.apikey.clone())),
            "credential parse drifted for vector: {}",
            v.description
        );
    }
}
