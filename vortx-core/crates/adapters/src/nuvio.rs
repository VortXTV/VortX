//! Nuvio provider adapter. Nuvio's strength is hot-loaded JS provider plugins; each provider's
//! `getStreams()` returns plain stream objects. We map those onto protocol streams so they flow through
//! the same ranking/dedup/resolve path as a Stremio addon's streams.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use vortx_protocol::{Stream, StreamBehaviorHints};

/// One provider's metadata in the Nuvio providers repo manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScraperInfo {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, rename = "supportedTypes")]
    pub supported_types: Vec<String>,
    #[serde(default)]
    pub enabled: bool,
}

/// The Nuvio providers repo `manifest.json`: the base URL to fetch provider JS from + the provider list.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NuvioRepoManifest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, rename = "baseUrl", skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    #[serde(default)]
    pub scrapers: Vec<ScraperInfo>,
}

/// One stream a Nuvio provider's `getStreams()` returns. `headers` (Referer / User-Agent / ...) must be
/// carried to the player; providers rely on it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NuvioStream {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quality: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub headers: Option<BTreeMap<String, String>>,
}

/// Map one Nuvio stream to a protocol [`Stream`]. The label falls back to `quality` when `name` is
/// absent; the provider's headers become `behaviorHints.proxyHeaders.request` so the player injects them.
pub fn nuvio_stream_to_protocol(raw: &NuvioStream) -> Stream {
    let behavior_hints = raw.headers.as_ref().map(|headers| {
        let request = serde_json::to_value(headers).unwrap_or(serde_json::Value::Null);
        StreamBehaviorHints {
            proxy_headers: Some(serde_json::json!({ "request": request })),
            ..Default::default()
        }
    });
    Stream {
        url: Some(raw.url.clone()),
        name: raw.name.clone().or_else(|| raw.quality.clone()),
        title: raw.title.clone(),
        behavior_hints,
        ..Default::default()
    }
}

/// Map a provider's whole result set to protocol streams.
pub fn scraper_streams_to_protocol(raw: &[NuvioStream]) -> Vec<Stream> {
    raw.iter().map(nuvio_stream_to_protocol).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_url_and_label() {
        let n = NuvioStream {
            name: Some("VidRock 1080p".into()),
            title: Some("The Movie".into()),
            url: "https://vid/x.mkv".into(),
            quality: Some("1080p".into()),
            size: Some("1.4 GB".into()),
            headers: None,
        };
        let s = nuvio_stream_to_protocol(&n);
        assert_eq!(s.url.as_deref(), Some("https://vid/x.mkv"));
        assert_eq!(s.name.as_deref(), Some("VidRock 1080p"));
        assert_eq!(s.title.as_deref(), Some("The Movie"));
        assert!(s.behavior_hints.is_none());
    }

    #[test]
    fn name_falls_back_to_quality() {
        let n = NuvioStream {
            name: None,
            title: None,
            url: "https://x".into(),
            quality: Some("2160p".into()),
            size: None,
            headers: None,
        };
        assert_eq!(nuvio_stream_to_protocol(&n).name.as_deref(), Some("2160p"));
    }

    #[test]
    fn headers_become_proxy_headers() {
        let mut headers = BTreeMap::new();
        headers.insert("Referer".to_string(), "https://ref".to_string());
        let n = NuvioStream {
            name: Some("src".into()),
            title: None,
            url: "https://x".into(),
            quality: None,
            size: None,
            headers: Some(headers),
        };
        let s = nuvio_stream_to_protocol(&n);
        let hints = s.behavior_hints.expect("hints present");
        let proxy = hints.proxy_headers.expect("proxy headers present");
        assert_eq!(proxy["request"]["Referer"], "https://ref");
    }

    #[test]
    fn repo_manifest_decodes() {
        let body = r#"{ "version": "1.2.0", "baseUrl": "https://cdn/providers",
            "scrapers": [ { "id": "vidrock", "name": "VidRock", "supportedTypes": ["movie", "series"], "enabled": true } ] }"#;
        let m: NuvioRepoManifest = serde_json::from_str(body).unwrap();
        assert_eq!(m.base_url.as_deref(), Some("https://cdn/providers"));
        assert_eq!(m.scrapers.len(), 1);
        assert_eq!(m.scrapers[0].id, "vidrock");
        assert!(m.scrapers[0].enabled);
    }

    #[test]
    fn whole_result_set_maps_lossless_count() {
        let raw = vec![
            NuvioStream {
                name: None,
                title: None,
                url: "a".into(),
                quality: None,
                size: None,
                headers: None,
            },
            NuvioStream {
                name: None,
                title: None,
                url: "b".into(),
                quality: None,
                size: None,
                headers: None,
            },
        ];
        let out = scraper_streams_to_protocol(&raw);
        assert_eq!(out.len(), 2);
        assert_eq!(out[1].url.as_deref(), Some("b"));
    }
}
