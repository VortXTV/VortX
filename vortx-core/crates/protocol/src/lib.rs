//! # vortx-protocol
//!
//! The Stremio add-on protocol, implemented for VortX core. This crate is intentionally pure: it
//! parses manifests, builds the exact resource URLs add-ons expect, and decodes their responses.
//! It does NO networking (the `env`/transport layer fetches; this crate stays testable and portable
//! across every compile target).
//!
//! Staying byte-compatible with the official clients here is what lets the entire existing add-on
//! ecosystem (Torrentio, Cinemeta, AIOStreams, Comet, MediaFusion, ...) work unchanged on VortX.
//!
//! Nuvio-style add-ons that are NOT Stremio-protocol are handled by a separate adapter layer (added
//! in a later phase) that maps them onto these same types, so the rest of the engine only ever sees
//! one shape.

mod manifest;
mod resource;
mod transport;

pub use manifest::{
    Manifest, ManifestBehaviorHints, ManifestCatalog, ManifestExtra, ManifestResource,
};
pub use resource::{
    AddonCatalogResponse, AddonDescriptor, CatalogResponse, MetaDetail, MetaPreview, MetaResponse,
    Stream, StreamBehaviorHints, StreamResponse, StreamSource, Subtitle, SubtitlesResponse, Video,
};
pub use transport::{base_url, ResourcePath};

/// The four core add-on resources VortX requests by name.
pub mod resources {
    pub const CATALOG: &str = "catalog";
    pub const META: &str = "meta";
    pub const STREAM: &str = "stream";
    pub const SUBTITLES: &str = "subtitles";
    pub const ADDON_CATALOG: &str = "addon_catalog";
}

/// Errors decoding add-on payloads.
#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("invalid manifest: {0}")]
    Manifest(serde_json::Error),
    #[error("invalid {resource} response: {source}")]
    Response {
        resource: &'static str,
        source: serde_json::Error,
    },
}

/// Parse an add-on `manifest.json` body.
pub fn parse_manifest(body: &str) -> Result<Manifest, ProtocolError> {
    serde_json::from_str(body).map_err(ProtocolError::Manifest)
}

/// Decode a `catalog` response body.
pub fn parse_catalog(body: &str) -> Result<CatalogResponse, ProtocolError> {
    serde_json::from_str(body).map_err(|source| ProtocolError::Response {
        resource: resources::CATALOG,
        source,
    })
}

/// Decode a `meta` response body.
pub fn parse_meta(body: &str) -> Result<MetaResponse, ProtocolError> {
    serde_json::from_str(body).map_err(|source| ProtocolError::Response {
        resource: resources::META,
        source,
    })
}

/// Decode a `stream` response body.
pub fn parse_stream(body: &str) -> Result<StreamResponse, ProtocolError> {
    serde_json::from_str(body).map_err(|source| ProtocolError::Response {
        resource: resources::STREAM,
        source,
    })
}

/// Decode a `subtitles` response body.
pub fn parse_subtitles(body: &str) -> Result<SubtitlesResponse, ProtocolError> {
    serde_json::from_str(body).map_err(|source| ProtocolError::Response {
        resource: resources::SUBTITLES,
        source,
    })
}

/// Decode an `addon_catalog` response body (an add-on that lists other add-ons).
pub fn parse_addon_catalog(body: &str) -> Result<AddonCatalogResponse, ProtocolError> {
    serde_json::from_str(body).map_err(|source| ProtocolError::Response {
        resource: resources::ADDON_CATALOG,
        source,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const CINEMETA_MANIFEST: &str = r#"{
        "id": "com.linvo.cinemeta",
        "version": "3.0.13",
        "name": "Cinemeta",
        "description": "The official addon for movie and series catalogs",
        "resources": [
            "catalog",
            { "name": "meta", "types": ["movie", "series"], "idPrefixes": ["tt"] },
            { "name": "addon_catalog", "types": ["all"] }
        ],
        "types": ["movie", "series"],
        "idPrefixes": ["tt"],
        "catalogs": [
            { "type": "movie", "id": "top", "name": "Popular",
              "extra": [ { "name": "genre", "options": ["Action", "Comedy"], "isRequired": false },
                         { "name": "skip" } ] },
            { "type": "series", "id": "top", "name": "Popular" }
        ],
        "behaviorHints": { "configurable": false, "configurationRequired": false }
    }"#;

    #[test]
    fn parses_a_real_manifest() {
        let m = parse_manifest(CINEMETA_MANIFEST).expect("manifest parses");
        assert_eq!(m.id, "com.linvo.cinemeta");
        assert_eq!(m.name, "Cinemeta");
        assert_eq!(m.types, vec!["movie", "series"]);
        assert_eq!(m.catalogs.len(), 2);
        assert_eq!(m.catalogs[0].extra.len(), 2);
        assert_eq!(
            m.id_prefixes.as_deref(),
            Some(["tt".to_string()].as_slice())
        );
        // Short and Full resource forms both parse.
        assert_eq!(m.resources[0].name(), "catalog");
        assert_eq!(m.resources[1].name(), "meta");
    }

    #[test]
    fn supports_matches_resource_type_and_idprefix() {
        let m = parse_manifest(CINEMETA_MANIFEST).unwrap();
        // catalog is short-form -> uses the manifest's types + idPrefixes.
        assert!(m.supports("catalog", "movie", "top"));
        // meta is full-form, narrowed to movie/series + tt ids.
        assert!(m.supports("meta", "movie", "tt0111161"));
        assert!(m.supports("meta", "series", "tt0944947"));
        // wrong id prefix is rejected.
        assert!(!m.supports("meta", "movie", "kitsu:42"));
        // resource the add-on does not serve.
        assert!(!m.supports("stream", "movie", "tt0111161"));
    }

    #[test]
    fn builds_resource_url_without_extra() {
        let base = "https://v3-cinemeta.strem.io/manifest.json";
        let req = ResourcePath::new(resources::META, "movie", "tt0111161");
        assert_eq!(
            req.to_url(base),
            "https://v3-cinemeta.strem.io/meta/movie/tt0111161.json"
        );
    }

    #[test]
    fn builds_catalog_url_with_encoded_extra() {
        let base = "https://v3-cinemeta.strem.io/manifest.json";
        let req = ResourcePath::new(resources::CATALOG, "movie", "top")
            .with_extra("genre", "Sci-Fi & Fantasy")
            .with_extra("skip", "100");
        // Space and '&' inside the value are percent-encoded; the joining '&' stays literal.
        assert_eq!(
            req.to_url(base),
            "https://v3-cinemeta.strem.io/catalog/movie/top/genre=Sci-Fi%20%26%20Fantasy&skip=100.json"
        );
    }

    #[test]
    fn encodes_special_ids() {
        let base = "https://addon.example/manifest.json";
        let req = ResourcePath::new(resources::STREAM, "series", "tt0944947:1:1");
        // The ':' in a series id is encoded (encodeURIComponent leaves it as %3A).
        assert_eq!(
            req.to_url(base),
            "https://addon.example/stream/series/tt0944947%3A1%3A1.json"
        );
    }

    #[test]
    fn base_url_strips_manifest_suffix() {
        assert_eq!(base_url("https://x.io/manifest.json"), "https://x.io");
        assert_eq!(
            base_url("https://x.io/cfg/manifest.json"),
            "https://x.io/cfg"
        );
        // Already a base URL -> trailing slash trimmed, used as-is.
        assert_eq!(base_url("https://x.io/cfg/"), "https://x.io/cfg");
    }

    #[test]
    fn decodes_stream_responses_of_every_source_kind() {
        let body = r#"{ "streams": [
            { "name": "Torrentio 1080p", "title": "The Movie\n1.4GB",
              "infoHash": "a1b2", "fileIdx": 0,
              "behaviorHints": { "bingeGroup": "tt-1080p", "notWebReady": true } },
            { "name": "RealDebrid", "url": "https://rd.example/stream.mkv",
              "behaviorHints": { "proxyHeaders": { "request": { "Authorization": "Bearer x" } } } },
            { "title": "Trailer", "ytId": "dQw4w9WgXcQ" },
            { "title": "Open in browser", "externalUrl": "https://example.com/watch" },
            { "title": "broken" }
        ] }"#;
        let parsed = parse_stream(body).expect("stream response parses");
        assert_eq!(parsed.streams.len(), 5);
        assert_eq!(
            parsed.streams[0].source(),
            StreamSource::Torrent {
                info_hash: "a1b2".into(),
                file_idx: Some(0)
            }
        );
        assert_eq!(
            parsed.streams[1].source(),
            StreamSource::Url("https://rd.example/stream.mkv".into())
        );
        assert_eq!(
            parsed.streams[2].source(),
            StreamSource::YouTube("dQw4w9WgXcQ".into())
        );
        assert_eq!(
            parsed.streams[3].source(),
            StreamSource::External("https://example.com/watch".into())
        );
        assert_eq!(parsed.streams[4].source(), StreamSource::Unknown);
        // behaviorHints decoded.
        let hints = parsed.streams[0].behavior_hints.as_ref().unwrap();
        assert_eq!(hints.binge_group.as_deref(), Some("tt-1080p"));
        assert_eq!(hints.not_web_ready, Some(true));
    }

    #[test]
    fn decodes_meta_with_episodes() {
        let body = r#"{ "meta": {
            "id": "tt0944947", "type": "series", "name": "Game of Thrones",
            "poster": "https://img/p.jpg", "genres": ["Drama", "Fantasy"],
            "videos": [
                { "id": "tt0944947:1:1", "title": "Winter Is Coming", "season": 1, "episode": 1,
                  "released": "2011-04-17T00:00:00.000Z" },
                { "id": "tt0944947:1:2", "season": 1, "episode": 2 }
            ]
        } }"#;
        let parsed = parse_meta(body).expect("meta parses");
        assert_eq!(parsed.meta.name, "Game of Thrones");
        assert_eq!(parsed.meta.videos.len(), 2);
        assert_eq!(parsed.meta.videos[0].season, Some(1));
        assert_eq!(
            parsed.meta.videos[0].title.as_deref(),
            Some("Winter Is Coming")
        );
    }

    #[test]
    fn decodes_catalog_and_tolerates_missing_optionals() {
        let body = r#"{ "metas": [
            { "id": "tt1", "type": "movie", "name": "A" },
            { "id": "tt2", "type": "movie", "name": "B", "poster": "p", "imdbRating": "8.1" }
        ] }"#;
        let parsed = parse_catalog(body).expect("catalog parses");
        assert_eq!(parsed.metas.len(), 2);
        assert!(parsed.metas[0].poster.is_none());
        assert_eq!(parsed.metas[1].imdb_rating.as_deref(), Some("8.1"));
    }

    #[test]
    fn decodes_subtitles() {
        let body =
            r#"{ "subtitles": [ { "id": "1", "url": "https://s/en.srt", "lang": "eng" } ] }"#;
        let parsed = parse_subtitles(body).unwrap();
        assert_eq!(parsed.subtitles.len(), 1);
        assert_eq!(parsed.subtitles[0].lang, "eng");
    }

    #[test]
    fn decodes_addon_catalog_into_descriptors() {
        let body = r#"{ "addons": [
            { "transportUrl": "https://v3-cinemeta.strem.io/manifest.json",
              "transportName": "Cinemeta",
              "manifest": { "id": "com.linvo.cinemeta", "version": "3.0.13", "name": "Cinemeta",
                            "resources": ["catalog", "meta"], "types": ["movie", "series"] } },
            { "transportUrl": "https://torrentio.strem.fun/manifest.json",
              "manifest": { "id": "com.stremio.torrentio", "version": "1.0.0", "name": "Torrentio",
                            "resources": ["stream"], "types": ["movie", "series"],
                            "idPrefixes": ["tt"] } }
        ] }"#;
        let parsed = parse_addon_catalog(body).expect("addon_catalog parses");
        assert_eq!(parsed.addons.len(), 2);
        assert_eq!(parsed.addons[0].transport_name.as_deref(), Some("Cinemeta"));
        assert_eq!(parsed.addons[0].manifest.id, "com.linvo.cinemeta");
        // transportName is optional and absent on the second entry.
        assert!(parsed.addons[1].transport_name.is_none());
        assert_eq!(parsed.addons[1].manifest.name, "Torrentio");
    }
}
