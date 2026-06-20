//! Cross-language conformance for the native `vortx-source/1` addon manifest. Every VortX implementation
//! must parse and round-trip this manifest identically, and lift an existing Stremio addon to it
//! losslessly, so a native addon behaves the same wherever it runs.

use vortx_addons::InstalledAddon;
use vortx_protocol::parse_manifest;
use vortx_source::{ResourceKind, SourceKind, VortxAddonManifest, VortxTransport};

const NATIVE: &str = include_str!("../conformance/native_manifest.json");

#[test]
fn native_manifest_parses_and_round_trips() {
    let m: VortxAddonManifest = serde_json::from_str(NATIVE).expect("parse native manifest");
    assert_eq!(m.schema, "vortx-source/1");
    assert_eq!(m.kind, SourceKind::NativeVortx);
    assert!(m.streaming);
    assert!(m.capabilities.contains(&ResourceKind::Ratings));
    assert!(matches!(m.transport, VortxTransport::StremioHttp { .. }));
    assert!(m.debrid.as_ref().unwrap().yields_infohash);
    assert_eq!(m.hive.as_ref().unwrap().fact_ttl_sec, Some(86_400));
    assert_eq!(m.config.as_ref().unwrap().scope, "per-profile");
    assert!(m.signature.is_some());

    // Semantic round-trip: parse -> serialize -> parse equals the original.
    let json = serde_json::to_string(&m).unwrap();
    let back: VortxAddonManifest = serde_json::from_str(&json).unwrap();
    assert_eq!(m, back);
}

#[test]
fn stremio_addon_lifts_to_native_losslessly() {
    let addon = InstalledAddon::new(
        "https://torrentio.strem.fun/manifest.json",
        parse_manifest(
            r#"{ "id": "com.stremio.torrentio", "version": "1.0.0", "name": "Torrentio",
                 "resources": ["stream"], "types": ["movie", "series"], "idPrefixes": ["tt"] }"#,
        )
        .unwrap(),
    );
    let m = VortxAddonManifest::from(&addon);
    assert_eq!(m.kind, SourceKind::StremioAddon);
    assert_eq!(m.id, "com.stremio.torrentio");
    assert_eq!(m.version, "1.0.0");
    assert_eq!(m.types, vec!["movie", "series"]);
    assert_eq!(m.id_prefixes, vec!["tt"]);
    assert!(m.capabilities.contains(&ResourceKind::Stream));
    match &m.transport {
        VortxTransport::StremioHttp { manifest_url } => {
            assert_eq!(
                manifest_url.as_str(),
                "https://torrentio.strem.fun/manifest.json"
            )
        }
        _ => panic!("expected StremioHttp transport"),
    }
}
