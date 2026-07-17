//! The planner: a pure, total function from `(StreamKind, ConnectionHints)` to a `PlaybackPlan`. No
//! clock, no RNG, no IO, no floats. The decode and streaming happen in the platform-native players; this
//! decides the policy they execute, deterministically, so the per-stream-type speed wins are reproducible.

use serde::{Deserialize, Serialize};

use crate::kind::{AbrLadderChoice, DeviceClass, HwDecode, PlayerEngine, StreamKind};

/// Bandwidth at or below this (kbps) is "weak"; start conservatively.
pub const WEAK_BANDWIDTH_KBPS: u32 = 2_500;
/// Bandwidth at or above this (kbps) is "strong"; a living-room device may start high.
pub const STRONG_BANDWIDTH_KBPS: u32 = 12_000;

/// Minimal buffer for an instantly-available source (cached debrid, fully-downloaded torrent).
pub const BUFFER_CACHED_MIN: u16 = 2;
/// Buffer for an uncached progressive HTTP source.
pub const BUFFER_HTTP_UNCACHED: u16 = 8;
/// Buffer to start an HLS stream.
pub const BUFFER_HLS_START: u16 = 6;
/// Buffer for a cold torrent (needs swarm warmup).
pub const BUFFER_TORRENT_COLD: u16 = 20;

/// Conservative prefetch window on a metered connection (seconds).
pub const PREFETCH_METERED: u16 = 5;
/// Prefetch window for HTTP / HLS on an unmetered connection (seconds).
pub const PREFETCH_HTTP: u16 = 30;
/// Prefetch window for a torrent on an unmetered connection (seconds).
pub const PREFETCH_TORRENT: u16 = 15;

/// Minimum torrent piece window ahead of the playhead (always positive: a torrent must read ahead).
pub const PIECE_WINDOW_MIN: u16 = 8;
/// Larger torrent piece window for strong-bandwidth / living-room playback.
pub const PIECE_WINDOW_BIG: u16 = 24;

/// What the engine knows about the current connection and content when planning playback.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionHints {
    /// Estimated downstream bandwidth in kbps. `0` means unknown.
    pub bandwidth_kbps: u32,
    /// The connection is metered (cellular / capped); prefetch conservatively.
    pub metered: bool,
    pub device: DeviceClass,
    /// The source plays instantly (debrid-cached, or a fully-downloaded torrent).
    pub is_cached: bool,
    pub is_dolby_vision: bool,
    pub is_hdr: bool,
}

impl ConnectionHints {
    fn is_weak(&self) -> bool {
        self.bandwidth_kbps > 0 && self.bandwidth_kbps <= WEAK_BANDWIDTH_KBPS
    }

    fn is_strong(&self) -> bool {
        self.bandwidth_kbps >= STRONG_BANDWIDTH_KBPS
    }
}

/// The deterministic plan the native player executes. Float-free on purpose: every field is an enum or a
/// small integer, so it is byte-reproducible across Rust / Swift / Kotlin / TS.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaybackPlan {
    /// Seconds of media to buffer before starting playback.
    pub buffer_target_secs: u16,
    /// Seconds of media to keep prefetched ahead of the playhead.
    pub prefetch_window_secs: u16,
    pub abr_ladder_choice: AbrLadderChoice,
    /// Pieces to keep downloaded ahead of the playhead (0 for non-torrent).
    pub torrent_piece_window: u16,
    pub player_engine: PlayerEngine,
    pub hw_decode: HwDecode,
}

/// Decide the hardware-decode strictness. Turning on DV/HDR only ever raises it (monotone).
fn decode_for(hints: &ConnectionHints) -> HwDecode {
    let base = match hints.device {
        DeviceClass::Constrained => HwDecode::Software,
        DeviceClass::Handset | DeviceClass::LivingRoom => HwDecode::HardwarePreferred,
    };
    if hints.is_dolby_vision || hints.is_hdr {
        match hints.device {
            // A living-room device must hardware-decode true DV/HDR; elsewhere prefer hardware (which
            // raises a Constrained device up from Software, and leaves a Handset at HardwarePreferred).
            DeviceClass::LivingRoom => HwDecode::HardwareRequired,
            _ => HwDecode::HardwarePreferred,
        }
    } else {
        base
    }
}

/// The HLS ABR start tier.
fn abr_for(hints: &ConnectionHints) -> AbrLadderChoice {
    if hints.bandwidth_kbps == 0 {
        AbrLadderChoice::Auto
    } else if hints.metered || hints.is_weak() || hints.device == DeviceClass::Constrained {
        AbrLadderChoice::StartLow
    } else if hints.is_strong() && hints.device == DeviceClass::LivingRoom {
        AbrLadderChoice::StartHigh
    } else {
        AbrLadderChoice::StartMedium
    }
}

fn http_prefetch(hints: &ConnectionHints) -> u16 {
    if hints.metered {
        PREFETCH_METERED
    } else {
        PREFETCH_HTTP
    }
}

/// Plan playback for a stream kind and connection.
pub fn plan(kind: StreamKind, hints: ConnectionHints) -> PlaybackPlan {
    let hw_decode = decode_for(&hints);
    match kind {
        StreamKind::HttpDirect | StreamKind::Debrid => PlaybackPlan {
            buffer_target_secs: if hints.is_cached {
                BUFFER_CACHED_MIN
            } else {
                BUFFER_HTTP_UNCACHED
            },
            prefetch_window_secs: http_prefetch(&hints),
            abr_ladder_choice: AbrLadderChoice::NotApplicable,
            torrent_piece_window: 0,
            player_engine: PlayerEngine::Libmpv,
            hw_decode,
        },
        StreamKind::Torrent => PlaybackPlan {
            buffer_target_secs: if hints.is_cached {
                BUFFER_CACHED_MIN
            } else {
                BUFFER_TORRENT_COLD
            },
            prefetch_window_secs: if hints.metered {
                PREFETCH_METERED
            } else {
                PREFETCH_TORRENT
            },
            abr_ladder_choice: AbrLadderChoice::NotApplicable,
            // Always positive: a torrent must read ahead of the playhead. Wider on capable links.
            torrent_piece_window: if hints.device == DeviceClass::LivingRoom || hints.is_strong() {
                PIECE_WINDOW_BIG
            } else {
                PIECE_WINDOW_MIN
            },
            player_engine: PlayerEngine::Libmpv,
            hw_decode,
        },
        StreamKind::Hls => PlaybackPlan {
            buffer_target_secs: BUFFER_HLS_START,
            prefetch_window_secs: http_prefetch(&hints),
            abr_ladder_choice: abr_for(&hints),
            torrent_piece_window: 0,
            player_engine: PlayerEngine::NativeAbr,
            hw_decode,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hints() -> ConnectionHints {
        ConnectionHints {
            bandwidth_kbps: 8_000,
            metered: false,
            device: DeviceClass::Handset,
            is_cached: false,
            is_dolby_vision: false,
            is_hdr: false,
        }
    }

    #[test]
    fn cached_debrid_starts_with_minimal_buffer() {
        let p = plan(
            StreamKind::Debrid,
            ConnectionHints {
                is_cached: true,
                ..hints()
            },
        );
        assert_eq!(p.buffer_target_secs, BUFFER_CACHED_MIN);
        assert_eq!(p.player_engine, PlayerEngine::Libmpv);
        assert_eq!(p.abr_ladder_choice, AbrLadderChoice::NotApplicable);
        assert_eq!(p.torrent_piece_window, 0);
    }

    #[test]
    fn torrent_always_reads_ahead() {
        let p = plan(StreamKind::Torrent, hints());
        assert!(p.torrent_piece_window > 0);
        assert_eq!(p.buffer_target_secs, BUFFER_TORRENT_COLD);
    }

    #[test]
    fn hls_uses_native_abr() {
        let p = plan(StreamKind::Hls, hints());
        assert_eq!(p.player_engine, PlayerEngine::NativeAbr);
        assert_ne!(p.abr_ladder_choice, AbrLadderChoice::NotApplicable);
        assert_eq!(p.torrent_piece_window, 0);
    }

    #[test]
    fn unknown_bandwidth_hls_is_auto() {
        let p = plan(
            StreamKind::Hls,
            ConnectionHints {
                bandwidth_kbps: 0,
                ..hints()
            },
        );
        assert_eq!(p.abr_ladder_choice, AbrLadderChoice::Auto);
    }

    #[test]
    fn dolby_vision_on_living_room_requires_hardware() {
        let p = plan(
            StreamKind::Hls,
            ConnectionHints {
                device: DeviceClass::LivingRoom,
                is_dolby_vision: true,
                ..hints()
            },
        );
        assert_eq!(p.hw_decode, HwDecode::HardwareRequired);
    }

    #[test]
    fn metered_prefetches_conservatively() {
        let p = plan(
            StreamKind::HttpDirect,
            ConnectionHints {
                metered: true,
                ..hints()
            },
        );
        assert_eq!(p.prefetch_window_secs, PREFETCH_METERED);
    }
}
