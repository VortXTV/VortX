//! # vortx-adapters
//!
//! Foreign source formats, normalized onto the one [`vortx_protocol::Stream`] shape so the engine's
//! routing, ranking, dedup, and resolve layers never know the difference. This is what lets non-Stremio
//! sources run on VortX:
//!
//! - **Nuvio** providers return JS-scraper results (`{name, title, url, quality, size, headers}`).
//!   [`scraper_streams_to_protocol`] maps them to protocol streams, carrying the provider's headers as
//!   `proxyHeaders` so the player injects them. (The JS runtime that executes a provider is a later
//!   phase; this is the pure data mapping it feeds into.)
//! - **Eclipse** music addons answer search with typed arrays (`{tracks, albums, artists, playlists}`)
//!   instead of a single `metas[]`, and a track may carry an inline `streamURL` that short-circuits the
//!   `/stream` call. [`track_to_stream`] / [`music_stream_to_protocol`] map these onto protocol streams.

mod eclipse;
mod nuvio;

pub use eclipse::{
    music_stream_to_protocol, track_to_stream, EclipseSearchResponse, MusicItem, MusicStream,
};
pub use nuvio::{
    nuvio_stream_to_protocol, scraper_streams_to_protocol, NuvioRepoManifest, NuvioStream,
    ScraperInfo,
};
