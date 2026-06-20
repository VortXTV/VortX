//! Cross-language conformance vectors for the Nuvio -> protocol stream mapping. Every platform's adapter
//! must produce the same protocol stream for the same Nuvio result, so a Nuvio provider behaves
//! identically wherever it runs.

use serde::Deserialize;
use vortx_adapters::{nuvio_stream_to_protocol, NuvioStream};

#[derive(Deserialize)]
struct Vector {
    description: String,
    stream: NuvioStream,
    expected_url: String,
    #[serde(default)]
    expected_name: Option<String>,
    expected_has_proxy_headers: bool,
}

const VECTORS_JSON: &str = include_str!("../conformance/nuvio_vectors.json");

#[test]
fn nuvio_mapping_vectors_match() {
    let vectors: Vec<Vector> =
        serde_json::from_str(VECTORS_JSON).expect("conformance vectors parse");
    assert!(vectors.len() >= 4, "expected the full vector set");
    for v in &vectors {
        let stream = nuvio_stream_to_protocol(&v.stream);
        assert_eq!(
            stream.url.as_deref(),
            Some(v.expected_url.as_str()),
            "url: {}",
            v.description
        );
        assert_eq!(stream.name, v.expected_name, "name: {}", v.description);
        let has_proxy = stream
            .behavior_hints
            .and_then(|h| h.proxy_headers)
            .is_some();
        assert_eq!(
            has_proxy, v.expected_has_proxy_headers,
            "proxy: {}",
            v.description
        );
    }
}
