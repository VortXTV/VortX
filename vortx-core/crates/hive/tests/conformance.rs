//! Cross-language conformance vectors for the CacheFact canonical signing payload.
//!
//! These vectors are the single source of truth for the bytes a CacheFact signature covers. EVERY VortX
//! implementation, the Rust kernel here, the TypeScript engine-core, the Swift/Apple app, and the
//! Cloudflare Worker that verifies submitted facts, must reproduce `expected` exactly for each input, or
//! signatures will not interoperate across the federation. The same `conformance/` JSON is intended to be
//! consumed verbatim by the TS (`vitest`), Swift (`XCTest`), and Worker test suites, so the wire contract
//! can never silently drift between platforms.

use serde::Deserialize;
use vortx_hive::{signing_bytes_for, DebridService};

#[derive(Deserialize)]
struct Vector {
    description: String,
    infohash: String,
    service: DebridService,
    cached: bool,
    file_idx: Option<u32>,
    size: Option<u64>,
    quality: Option<String>,
    verified_at: u64,
    ttl: u64,
    signer_pubkey: String,
    expected: String,
}

const VECTORS_JSON: &str = include_str!("../conformance/cachefact_signing_vectors.json");

#[test]
fn cachefact_canonical_signing_vectors_match() {
    let vectors: Vec<Vector> =
        serde_json::from_str(VECTORS_JSON).expect("conformance vectors parse");
    assert!(
        vectors.len() >= 5,
        "expected the full vector set, got {}",
        vectors.len()
    );
    for v in &vectors {
        let bytes = signing_bytes_for(
            &v.infohash,
            v.service,
            v.cached,
            v.file_idx,
            v.size,
            v.quality.as_deref(),
            v.verified_at,
            v.ttl,
            &v.signer_pubkey,
        );
        assert_eq!(
            bytes.as_slice(),
            v.expected.as_bytes(),
            "canonical signing bytes drifted for vector: {}",
            v.description
        );
    }
}
