//! Add-on resource RESPONSES: catalog, meta, stream, subtitles.
//!
//! These deserialize the JSON bodies add-ons return. Fields are permissive (everything optional
//! beyond the essentials) because real add-ons in the wild omit, add, and bend fields; VortX must
//! consume them all without rejecting a response over a missing optional.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::manifest::Manifest;

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

/// `GET .../addon_catalog/...` -> `{ "addons": [ { transportUrl, transportName, manifest } ] }`
///
/// An add-on that lists OTHER add-ons: community add-on collections, and (the payoff) the VortX
/// "Singularity" source hub, which is served as a standard `addon_catalog` so it routes through the
/// same engine path as any other add-on instead of being a bespoke integration.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AddonCatalogResponse {
    #[serde(default)]
    pub addons: Vec<AddonDescriptor>,
}

/// One discoverable add-on inside an `addon_catalog`: its transport URL plus full manifest.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AddonDescriptor {
    #[serde(rename = "transportUrl")]
    pub transport_url: String,
    #[serde(
        default,
        rename = "transportName",
        skip_serializing_if = "Option::is_none"
    )]
    pub transport_name: Option<String>,
    pub manifest: Manifest,
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
    #[serde(
        default,
        rename = "posterShape",
        skip_serializing_if = "Option::is_none"
    )]
    pub poster_shape: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub logo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(
        default,
        rename = "releaseInfo",
        skip_serializing_if = "Option::is_none"
    )]
    pub release_info: Option<String>,
    #[serde(
        default,
        rename = "imdbRating",
        skip_serializing_if = "Option::is_none"
    )]
    pub imdb_rating: Option<String>,
    /// Content maturity certification as the addon reports it (any scheme: MPAA `R`, US-TV `TV-MA`, BBFC
    /// `15`, a bare age). The engine reconciles it to one age-equivalent via `vortx_state::parse_
    /// certification` for parental-controls enforcement; `None` is treated as unrated (fail-closed for a
    /// kids profile).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub certification: Option<String>,
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
    #[serde(
        default,
        rename = "posterShape",
        skip_serializing_if = "Option::is_none"
    )]
    pub poster_shape: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub logo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(
        default,
        rename = "releaseInfo",
        skip_serializing_if = "Option::is_none"
    )]
    pub release_info: Option<String>,
    #[serde(
        default,
        rename = "imdbRating",
        skip_serializing_if = "Option::is_none"
    )]
    pub imdb_rating: Option<String>,
    /// Content maturity certification (any scheme); reconciled by `vortx_state::parse_certification` for
    /// parental-controls enforcement. See [`MetaPreview::certification`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub certification: Option<String>,
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
    #[serde(
        default,
        rename = "behaviorHints",
        skip_serializing_if = "Option::is_none"
    )]
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
    #[serde(
        default,
        rename = "externalUrl",
        skip_serializing_if = "Option::is_none"
    )]
    pub external_url: Option<String>,

    /// Short label (resolution / source). Newer field; older add-ons use `title`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Long label (the line shown under the name). Older add-ons put the label here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    #[serde(
        default,
        rename = "behaviorHints",
        skip_serializing_if = "Option::is_none"
    )]
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
    Torrent {
        info_hash: String,
        file_idx: Option<u32>,
    },
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
    #[serde(
        default,
        rename = "bingeGroup",
        skip_serializing_if = "Option::is_none"
    )]
    pub binge_group: Option<String>,
    #[serde(
        default,
        rename = "notWebReady",
        skip_serializing_if = "Option::is_none"
    )]
    pub not_web_ready: Option<bool>,
    /// Headers the player must inject when fetching the stream (debrid/private trackers).
    #[serde(
        default,
        rename = "proxyHeaders",
        skip_serializing_if = "Option::is_none"
    )]
    pub proxy_headers: Option<Value>,
    #[serde(
        default,
        rename = "countryWhitelist",
        skip_serializing_if = "Option::is_none"
    )]
    pub country_whitelist: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    #[serde(default, rename = "videoSize", skip_serializing_if = "Option::is_none")]
    pub video_size: Option<i64>,
    #[serde(default, rename = "videoHash", skip_serializing_if = "Option::is_none")]
    pub video_hash: Option<String>,
    /// The typed VortX score-input side-channel carried by a native `vortx-source/1` stream. When present,
    /// the engine ranks from these typed fields INSTEAD of regex-parsing the release title, which is what
    /// makes ranking byte-reproducible across platforms. Absent on plain Stremio streams (they fall back to
    /// the title parser). See [`VortxStreamHints`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vortx: Option<VortxStreamHints>,
}

/// The typed score-input side-channel a native `vortx-source/1` stream carries in `behaviorHints.vortx`.
/// This is the single most important federation-alignment point: the engine reads these typed fields rather
/// than parsing the title string for quality / seeders / pack info, so a stream ranks IDENTICALLY on every
/// platform (Apple, Android, a Cloudflare Worker, wasm) instead of drifting on per-platform title regex.
///
/// Byte-frozen to the Singularity Worker's emitted shape (the `behaviorHints.vortx` object); the engine is
/// the consumer, the Worker is the conformance target. EVERY field is optional so a partial object (an
/// `http` stream has no `seeders`; an `nzb` stream has an `nzbHash` but no `infohash`) and a plain Stremio
/// stream (no object at all) both degrade cleanly to the title-parse fallback rather than erroring.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct VortxStreamHints {
    /// `SourceKind` discriminator (`"torrent" | "http" | "nzb"`); selects the engine resolve path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// Debrid service wire-strings this infohash is cached on (the hive cached-check result). Byte-equal to
    /// the engine `DebridService` enum; the engine treats the infohash as instant-cached on exactly these,
    /// with no token minted (facts-never-tokens; the user's own debrid re-confirms on play).
    #[serde(
        default,
        rename = "cachedServices",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub cached_services: Vec<String>,
    /// Swarm health (torrent only); a ranking score input, NOT parsed from the title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seeders: Option<i64>,
    /// Exact size in bytes; the size tiebreaker, NOT parsed from a `[2.1GB]` token in the title.
    #[serde(default, rename = "sizeBytes", skip_serializing_if = "Option::is_none")]
    pub size_bytes: Option<i64>,
    /// Canonical resolution token (e.g. `"2160p"`); a ranking score input.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    /// Audio languages; feeds language preference + foreign-audio demotion.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub languages: Vec<String>,
    /// Release tags (`hdr`/`dv`/`remux`/`cam`/...); feeds tag filters + fraud penalties + source class.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    /// Distinct-node confidence count (anti-fake-infohash); a ranking input + `minSourceNodes` gate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sources: Option<i64>,
    /// Season-pack indicator.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pack: Option<bool>,
    /// Exact file index inside a pack (or the row's own file index), so no client picker is needed.
    #[serde(default, rename = "fileIdx", skip_serializing_if = "Option::is_none")]
    pub file_idx: Option<u32>,
    /// NZB MD5, for the on-device usenet resolver (`nzb` kind only).
    #[serde(default, rename = "nzbHash", skip_serializing_if = "Option::is_none")]
    pub nzb_hash: Option<String>,
}

/// A subtitle track.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Subtitle {
    pub id: String,
    pub url: String,
    pub lang: String,
}
