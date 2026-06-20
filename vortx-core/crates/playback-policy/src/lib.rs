//! # vortx-playback-policy
//!
//! The engine-owned playback-policy planner. Given how a stream is delivered ([`StreamKind`]) and the
//! current [`ConnectionHints`], it deterministically decides a [`PlaybackPlan`]: the buffer target,
//! prefetch window, HLS ABR start tier, torrent piece window, player engine, and hardware-decode
//! strictness.
//!
//! The actual decoding and streaming run in the platform-native players (AVPlayer / libmpv on Apple,
//! ExoPlayer / Media3 on Android, the in-process librqbit server for torrents). What the engine owns,
//! and what this crate is, is the deterministic POLICY those players execute, so the per-stream-type
//! wins (instant cached play, real HLS ABR, torrent read-ahead, hardware decode, true DV routing) are
//! reproducible and testable rather than hand-wavy.
//!
//! [`plan`] is a pure, total function: no clock, no RNG, no IO, no floats. Every output is an enum or a
//! small integer, so a plan is byte-reproducible across platforms and the conformance vectors pin it
//! exactly. The monotonicity guarantees (more bandwidth never lowers the ABR tier, DV/HDR never relaxes
//! decode strictness, cached never buffers more, metered never prefetches more) are enforced by
//! property tests against the `Ord`-ordered enums.

mod abr;
mod kind;
mod plan;

pub use abr::{choose_variant, AbrConfig, AbrDecision, AbrReason, AbrState, AbrVariant};
pub use kind::{AbrLadderChoice, DeviceClass, HwDecode, PlayerEngine, StreamKind};
pub use plan::{
    plan, ConnectionHints, PlaybackPlan, BUFFER_CACHED_MIN, BUFFER_HLS_START, BUFFER_HTTP_UNCACHED,
    BUFFER_TORRENT_COLD, PIECE_WINDOW_BIG, PIECE_WINDOW_MIN, PREFETCH_HTTP, PREFETCH_METERED,
    PREFETCH_TORRENT, STRONG_BANDWIDTH_KBPS, WEAK_BANDWIDTH_KBPS,
};
