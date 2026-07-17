//! # vortx-playback
//!
//! VortX's engine-owned playback-assets layer: trickplay scrubbing previews, skip-intro/outro markers,
//! and chapters, made reliable the way the debrid layer made links reliable.
//!
//! Today every playback asset is sourced from exactly one provider, at the client, with no fallback: one
//! dead AniSkip endpoint removes the skip button, remote files without embedded chapters get none, and
//! trickplay does not exist. This crate fixes that structurally:
//!
//! - [`MediaKey`] + [`AssetKind`] + the payloads ([`TrickplaySprite`], [`SkipMarker`], [`Chapter`]).
//! - [`sprite`]: frozen integer seek-to-tile math (+ WebVTT `#xywh` cues) for scrubbing previews.
//! - [`AssetResolvePlanner`]: a deterministic source ladder (embedded -> provider -> hive -> on-device
//!   floor that never misses), a near-line-for-line port of the debrid resolve planner.
//! - [`AssetFact`] + [`merge_asset_fact`]: signed, privacy-safe availability facts that reuse the
//!   `vortx-hive` ed25519 identity, LWW+TTL CRDT, and `TrustStore` gate, so one device's generation
//!   becomes every trusted node's instant load, and a stranger's claim never drives playback.
//!
//! Pure: no HTTP, no async, no FFI. The ffmpeg keyframe sprite generation and the in-process axum serving
//! route are a later phase that builds on these frozen, tested types.

mod fact;
mod failover;
mod model;
mod resolve;
mod sprite;

pub use fact::{asset_signing_bytes_for, merge_asset_fact, AssetFact, AssetKey, HiveAssetMap};
pub use failover::{
    rot_cache_fact, FailoverStep, FailureSignal, RotFact, StreamCandidate, StreamFailover,
};
pub use model::{
    AssetKind, AssetLocator, Chapter, MediaKey, PlaybackAsset, SkipKind, SkipMarker,
    TrickplaySprite,
};
pub use resolve::{
    AssetResolvePlanner, AssetSource, AssetStep, AssetTier, AssetView, StaticAssetView,
    VaultAssetView,
};
pub use sprite::{parse_webvtt_cue, TileLocation};

/// Errors from playback-asset construction. Signature/verification errors surface the underlying
/// [`vortx_hive::HiveError`].
#[derive(Debug, thiserror::Error)]
pub enum PlaybackError {
    #[error("malformed media id (non-empty, no '|' or control chars)")]
    MalformedMediaId,
    #[error("malformed digest (no '|' or control chars, max 128 chars)")]
    MalformedDigest,
    #[error(transparent)]
    Hive(#[from] vortx_hive::HiveError),
}
