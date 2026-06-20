//! The classification enums. Every one is declared weakest-to-strongest and derives `Ord`, so the
//! planner's monotonicity guarantees are checkable as `<=` comparisons rather than prose. All serialize
//! as snake_case wire tokens (the cross-language contract); none carries a float.

use serde::{Deserialize, Serialize};

/// How a playable stream is delivered. `External` (a stream that leaves the engine player) is
/// intentionally excluded: the policy layer only plans for streams the engine drives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamKind {
    /// Adaptive HLS (an .m3u8 with multiple renditions).
    Hls,
    /// A single progressive HTTP(S) file.
    HttpDirect,
    /// A debrid-unrestricted direct link.
    Debrid,
    /// A torrent streamed in-process over the P2P engine.
    Torrent,
}

/// The device's playback capability class, weakest to strongest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceClass {
    /// Low-power / memory-constrained (older phones, low-end TV sticks).
    Constrained,
    /// A modern handset or tablet.
    Handset,
    /// A living-room device on mains power (Apple TV, desktop, console).
    LivingRoom,
}

/// Hardware-decode strictness, least to most strict. Turning on Dolby Vision / HDR may only raise this.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HwDecode {
    /// Software decode is acceptable.
    Software,
    /// Prefer hardware decode, fall back to software.
    HardwarePreferred,
    /// Hardware decode is required (do not fall back; the content demands it).
    HardwareRequired,
}

/// Which player engine drives the stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlayerEngine {
    /// The platform-native adaptive engine (AVPlayer / ExoPlayer) for real HLS ABR.
    NativeAbr,
    /// libmpv for progressive / debrid / torrent playback.
    Libmpv,
}

/// The ABR start tier for an adaptive stream, lowest commitment to highest. Declared so
/// `Auto < StartLow < StartMedium < StartHigh`, which makes bandwidth-monotonicity a `<=` check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AbrLadderChoice {
    /// Not an adaptive stream (non-HLS).
    NotApplicable,
    /// Let the player auto-select (unknown bandwidth).
    Auto,
    StartLow,
    StartMedium,
    StartHigh,
}
