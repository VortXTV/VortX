//! Cross-language conformance vectors for the release-token parser. The same label must parse to the
//! same tokens on every platform, so ranking is consistent everywhere. The TS/Swift parsers run this same
//! JSON in their own suites.

use serde::Deserialize;
use vortx_ranking::{parse, Audio, Hdr, Resolution, SourceClass};

#[derive(Deserialize)]
struct Vector {
    description: String,
    label: String,
    resolution: Resolution,
    source_class: SourceClass,
    hdr: Hdr,
    audio: Audio,
    #[serde(default)]
    season: Option<u32>,
    #[serde(default)]
    episode: Option<u32>,
    junk: bool,
}

const VECTORS_JSON: &str = include_str!("../conformance/parse_vectors.json");

#[test]
fn parse_vectors_match() {
    let vectors: Vec<Vector> =
        serde_json::from_str(VECTORS_JSON).expect("conformance vectors parse");
    assert!(vectors.len() >= 5, "expected the full vector set");
    for v in &vectors {
        let p = parse(&v.label);
        assert_eq!(p.resolution, v.resolution, "resolution: {}", v.description);
        assert_eq!(
            p.source_class, v.source_class,
            "source_class: {}",
            v.description
        );
        assert_eq!(p.hdr, v.hdr, "hdr: {}", v.description);
        assert_eq!(p.audio, v.audio, "audio: {}", v.description);
        assert_eq!(p.season, v.season, "season: {}", v.description);
        assert_eq!(p.episode, v.episode, "episode: {}", v.description);
        assert_eq!(p.junk, v.junk, "junk: {}", v.description);
    }
}
