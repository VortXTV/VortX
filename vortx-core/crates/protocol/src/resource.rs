//! Add-on resource RESPONSES: catalog, meta, stream, subtitles.
//!
//! These deserialize the JSON bodies add-ons return. Fields are permissive (everything optional
//! beyond the essentials) because real add-ons in the wild omit, add, and bend fields; VortX must
//! consume them all without rejecting a response over a missing optional.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `GET .../catalog/...` -> `{ "metas": [ ... ] }`
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CatalogResponse {
    #[serde(default)]
    pub metas: Vec<MetaPreview>,
}

/// `GET .../meta/...` -> `{ "meta": { ... } }`
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetaResponse {
    pub meta: MetaDetail,
}

/// `GET .../stream/...` -> `{ "streams": [ ... ] }`
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StreamResponse {
    #[serde(default)]
    pub streams: Vec<Stream>,
}

/// `GET .../subtitles/...` -> `{ "subtitles": [ ... ] }`
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SubtitlesResponse {
    #[serde(default)]
    pub subtitles: Vec<Subtitle>,
}

/// The lightweight item shown in catalog rows.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetaPreview {
    pub id: String,
    #[serde(rename = "type")]
    pub type_: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    #[serde(default, rename = "posterShape", skip_serializing_if = "Option::is_none")]
    pub poster_shape: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub logo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, rename = "releaseInfo", skip_serializing_if = "Option::is_none")]
    pub release_info: Option<String>,
    #[serde(default, rename = "imdbRating", skip_serializing_if = "Option::is_none")]
    pub imdb_rating: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genres: Option<Vec<String>>,
}

/// The full meta detail (catalog preview fields plus episodes/cast/etc.).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetaDetail {
    pub id: String,
    #[serde(rename = "type")]
    pub type_: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    #[serde(default, rename = "posterShape", skip_serializing_if = "Option::is_none")]
    pub poster_shape: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub logo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, rename = "releaseInfo", skip_serializing_if = "Option::is_none")]
    pub release_info: Option<String>,
    #[serde(default, rename = "imdbRating", skip_serializing_if = "Option::is_none")]
    pub imdb_rating: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genres: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cast: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub director: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub country: Option<String>,
    /// Episodes for a series (and chapters/streams for channels).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub videos: Vec<Video>,
    #[serde(default, rename = "behaviorHints", skip_serializing_if = "Option::is_none")]
    pub behavior_hints: Option<Value>,
}

/// One episode / chapter inside a meta detail.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Video {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub released: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub season: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumbnail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub overview: Option<String>,
    /// Some add-ons embed the playable streams directly on the episode.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub streams: Vec<Stream>,
}

/// A playable stream. The SOURCE is one of: a direct `url`, a YouTube `ytId`, a torrent
/// `infoHash` (+ optional `fileIdx`), or an `externalUrl` to open elsewhere. Real add-ons send
/// exactly one; we keep them as separate optionals and expose [`Stream::source`] for logic.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Stream {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, rename = "ytId", skip_serializing_if = "Option::is_none")]
    pub yt_id: Option<String>,
    #[serde(default, rename = "infoHash", skip_serializing_if = "Option::is_none")]
    pub info_hash: Option<String>,
    #[serde(default, rename = "fileIdx", skip_serializing_if = "Option::is_none")]
    pub file_idx: Option<u32>,
    #[serde(default, rename = "externalUrl", skip_serializing_if = "Option::is_none")]
    pub external_url: Option<String>,

    /// Short label (resolution / source). Newer field; older add-ons use `title`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Long label (the line shown under the name). Older add-ons put the label here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    #[serde(default, rename = "behaviorHints", skip_serializing_if = "Option::is_none")]
    pub behavior_hints: Option<StreamBehaviorHints>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub subtitles: Vec<Subtitle>,
}

/// What kind of source a [`Stream`] carries, resolved from its fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamSource {
    /// A direct/debrid HTTP(S) URL.
    Url(String),
    /// A YouTube video id.
    YouTube(String),
    /// A torrent, by info-hash, optionally selecting a file index.
    Torrent { info_hash: String, file_idx: Option<u32> },
    /// A link to open in another app/browser.
    External(String),
    /// No recognised source (malformed / placeholder stream).
    Unknown,
}

impl Stream {
    /// Resolve the playable source from whichever field the add-on populated.
    pub fn source(&self) -> StreamSource {
        if let Some(url) = &self.url {
            StreamSource::Url(url.clone())
        } else if let Some(info_hash) = &self.info_hash {
            StreamSource::Torrent {
                info_hash: info_hash.clone(),
                file_idx: self.file_idx,
            }
        } else if let Some(yt) = &self.yt_id {
            StreamSource::YouTube(yt.clone())
        } else if let Some(ext) = &self.external_url {
            StreamSource::External(ext.clone())
        } else {
            StreamSource::Unknown
        }
    }
}

/// `behaviorHints` on a stream: binge grouping, web-readiness, proxy headers, geo-gating.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StreamBehaviorHints {
    #[serde(default, rename = "bingeGroup", skip_serializing_if = "Option::is_none")]
    pub binge_group: Option<String>,
    #[serde(default, rename = "notWebReady", skip_serializing_if = "Option::is_none")]
    pub not_web_ready: Option<bool>,
    /// Headers the player must inject when fetching the stream (debrid/private trackers).
    #[serde(default, rename = "proxyHeaders", skip_serializing_if = "Option::is_none")]
    pub proxy_headers: Option<Value>,
    #[serde(default, rename = "countryWhitelist", skip_serializing_if = "Option::is_none")]
    pub country_whitelist: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    #[serde(default, rename = "videoSize", skip_serializing_if = "Option::is_none")]
    pub video_size: Option<i64>,
    #[serde(default, rename = "videoHash", skip_serializing_if = "Option::is_none")]
    pub video_hash: Option<String>,
}

/// A subtitle track.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Subtitle {
    pub id: String,
    pub url: String,
    pub lang: String,
}
