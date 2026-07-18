//! The host half of the fan-out item-key contract. The kernel's [`vortx_source::FetchOutcome::Ok`]
//! carries "already-validated item keys": the HOST turns a 2xx body into individual validated item
//! JSON strings, and the kernel then parses each key uniformly (`parse_stream_item`,
//! `parse_catalog_item`, ...) regardless of source kind. This module is that turn: infer the resource
//! kind from the planned URL, decode the body through the byte-compatible `vortx-protocol` parsers
//! (the validation step), and re-serialize each element as one compact item key.
//!
//! Validation through the typed protocol structs is deliberate: an item that fails the protocol
//! schema here would also fail the kernel's own item parse, so rejecting it host-side (the whole
//! body settles as `Malformed`) reports the failure against the addon's circuit breaker instead of
//! silently dropping rows later. Re-serialization is `serde_json::to_string` of the typed struct,
//! which is deterministic, so item keys are byte-stable across hosts for identical bodies.

use vortx_protocol::{
    parse_addon_catalog, parse_catalog, parse_meta, parse_stream, parse_subtitles,
};

/// The response-body shapes this host can validate, inferred from the planned resource URL. Mirrors
/// the add-on protocol's resource path segment (`/{resource}/{type}/{id}.json`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BodyKind {
    /// `{ "metas": [...] }`, one item key per catalog row.
    Catalog,
    /// `{ "meta": {...} }`, a single item key (a title has one canonical detail).
    Meta,
    /// `{ "streams": [...] }`, one item key per stream.
    Stream,
    /// `{ "subtitles": [...] }`, one item key per subtitle track.
    Subtitles,
    /// `{ "addons": [...] }`, one item key per discoverable add-on.
    AddonCatalog,
}

/// The URL path segments that name a fan-out resource, paired with their [`BodyKind`].
const KIND_SEGMENTS: &[(&str, BodyKind)] = &[
    ("catalog", BodyKind::Catalog),
    ("meta", BodyKind::Meta),
    ("stream", BodyKind::Stream),
    ("subtitles", BodyKind::Subtitles),
    ("addon_catalog", BodyKind::AddonCatalog),
];

/// Infer the resource kind from a planned fetch URL by scanning its path segments. The protocol URL
/// shape is `{base}/{resource}/{type}/{id}.json` (plus optional extra segments), so the resource is
/// the LAST known segment that still has at least one segment after it; taking the last occurrence
/// keeps a base path that itself contains a resource word (e.g. `https://host/stream/manifest-v2/...`)
/// from shadowing the real resource. `None` when no known resource segment is present.
pub fn infer_kind(url: &str) -> Option<BodyKind> {
    let path = url_path(url);
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    // The resource segment must be followed by at least one more segment (its `{type}`), so the
    // final `.json` filename can never be misread as a resource.
    segments
        .iter()
        .enumerate()
        .rev()
        .filter(|(i, _)| i + 1 < segments.len())
        .find_map(|(_, seg)| {
            KIND_SEGMENTS
                .iter()
                .find(|(name, _)| name == seg)
                .map(|(_, kind)| *kind)
        })
}

/// The path component of `url`: strip the scheme + authority, then any query or fragment.
fn url_path(url: &str) -> &str {
    let after_scheme = match url.find("://") {
        Some(i) => &url[i + 3..],
        None => url,
    };
    let path = match after_scheme.find('/') {
        Some(i) => &after_scheme[i..],
        None => "",
    };
    let end = path.find(['?', '#']).unwrap_or(path.len());
    &path[..end]
}

/// Turn a 2xx response body into the validated item keys the kernel's settle phase consumes.
/// `None` means the body is schema-invalid for the resource the URL names (or the URL names no known
/// resource at all): the caller settles the fetch as `Malformed`, charging the addon's breaker.
pub fn body_to_items(url: &str, body: &str) -> Option<Vec<String>> {
    let kind = infer_kind(url)?;
    match kind {
        BodyKind::Catalog => parse_catalog(body).ok().map(|r| serialize_all(&r.metas)),
        BodyKind::Meta => parse_meta(body)
            .ok()
            .and_then(|r| serde_json::to_string(&r.meta).ok())
            .map(|item| vec![item]),
        BodyKind::Stream => parse_stream(body).ok().map(|r| serialize_all(&r.streams)),
        BodyKind::Subtitles => parse_subtitles(body)
            .ok()
            .map(|r| serialize_all(&r.subtitles)),
        BodyKind::AddonCatalog => parse_addon_catalog(body)
            .ok()
            .map(|r| serialize_all(&r.addons)),
    }
}

/// Serialize each element to one compact JSON item key, dropping any element serde cannot encode
/// (structurally impossible for these derive-serialized protocol types, but never worth a panic).
fn serialize_all<T: serde::Serialize>(items: &[T]) -> Vec<String> {
    items
        .iter()
        .filter_map(|item| serde_json::to_string(item).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use vortx_source::{parse_catalog_item, parse_stream_item};

    #[test]
    fn infers_the_resource_kind_from_real_world_urls() {
        assert_eq!(
            infer_kind("https://torrentio.strem.fun/stream/movie/tt0468569.json"),
            Some(BodyKind::Stream)
        );
        assert_eq!(
            infer_kind("https://v3-cinemeta.strem.io/catalog/movie/top.json"),
            Some(BodyKind::Catalog)
        );
        assert_eq!(
            infer_kind("https://v3-cinemeta.strem.io/catalog/movie/top/skip=100.json"),
            Some(BodyKind::Catalog)
        );
        assert_eq!(
            infer_kind("https://v3-cinemeta.strem.io/meta/series/tt0903747.json?x=1"),
            Some(BodyKind::Meta)
        );
        assert_eq!(
            infer_kind("https://example.com/base/path/addon_catalog/all/main.json"),
            Some(BodyKind::AddonCatalog)
        );
        // A base path containing a resource word must not shadow the real (later) resource.
        assert_eq!(
            infer_kind("https://host/stream/hosted/subtitles/movie/tt1.json"),
            Some(BodyKind::Subtitles)
        );
        // No resource segment at all: not a fan-out resource URL.
        assert_eq!(infer_kind("https://example.com/manifest.json"), None);
        // A trailing resource word with nothing after it is a filename, not a resource.
        assert_eq!(infer_kind("https://example.com/stream"), None);
    }

    #[test]
    fn stream_body_becomes_one_validated_item_key_per_stream() {
        let url = "https://addon.example/stream/movie/tt1.json";
        let body = r#"{"streams":[{"name":"A 2160p","infoHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"B 1080p","url":"https://cdn.example/b.mp4"}]}"#;
        let items = body_to_items(url, body).expect("valid stream body");
        assert_eq!(items.len(), 2);
        // The keys must parse through the kernel's own uniform item parser.
        for item in &items {
            assert!(
                parse_stream_item(item).is_some(),
                "kernel rejected item key {item}"
            );
        }
    }

    #[test]
    fn catalog_body_becomes_item_keys_the_kernel_parses() {
        let url = "https://cinemeta.example/catalog/movie/top.json";
        let body = r#"{"metas":[{"id":"tt1","type":"movie","name":"One"},{"id":"tt2","type":"movie","name":"Two"}]}"#;
        let items = body_to_items(url, body).expect("valid catalog body");
        assert_eq!(items.len(), 2);
        let metas: Vec<_> = items.iter().filter_map(|k| parse_catalog_item(k)).collect();
        assert_eq!(metas.len(), 2);
        assert_eq!(metas[0].id, "tt1");
        assert_eq!(metas[1].id, "tt2");
    }

    #[test]
    fn meta_body_becomes_exactly_one_item_key() {
        let url = "https://cinemeta.example/meta/movie/tt1.json";
        let body = r#"{"meta":{"id":"tt1","type":"movie","name":"One"}}"#;
        let items = body_to_items(url, body).expect("valid meta body");
        assert_eq!(items.len(), 1);
    }

    #[test]
    fn schema_invalid_bodies_are_rejected_not_partially_parsed() {
        let url = "https://addon.example/stream/movie/tt1.json";
        assert_eq!(body_to_items(url, "not json at all"), None);
        assert_eq!(body_to_items(url, r#"{"streams": "not-an-array"}"#), None);
        // A meta response missing its required singular object is malformed.
        assert_eq!(
            body_to_items("https://x.example/meta/movie/tt1.json", r#"{"metas":[]}"#),
            None
        );
        // A URL naming no known resource cannot be validated: malformed by contract.
        assert_eq!(
            body_to_items("https://x.example/manifest.json", r#"{}"#),
            None
        );
    }

    #[test]
    fn item_keys_are_byte_stable_for_identical_bodies() {
        let url = "https://addon.example/stream/movie/tt1.json";
        let body = r#"{"streams":[{"name":"A 2160p","url":"https://cdn.example/a.mp4"}]}"#;
        let a = body_to_items(url, body).unwrap();
        let b = body_to_items(url, body).unwrap();
        assert_eq!(a, b); // deterministic serialization: the cross-platform stability contract
    }
}
