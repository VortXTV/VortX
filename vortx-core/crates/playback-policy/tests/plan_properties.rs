//! Property-based invariants for the planner. These turn the policy's guarantees into checked
//! properties: totality, determinism, per-kind shape, and the four monotonicity rules (bandwidth never
//! lowers the ABR tier, DV/HDR never relaxes decode, cached never buffers more, metered never prefetches
//! more).

use proptest::prelude::*;
use vortx_playback_policy::{
    plan, AbrLadderChoice, ConnectionHints, DeviceClass, PlayerEngine, StreamKind,
};

fn stream_kind() -> impl Strategy<Value = StreamKind> {
    prop_oneof![
        Just(StreamKind::Hls),
        Just(StreamKind::HttpDirect),
        Just(StreamKind::Debrid),
        Just(StreamKind::Torrent),
    ]
}

fn device() -> impl Strategy<Value = DeviceClass> {
    prop_oneof![
        Just(DeviceClass::Constrained),
        Just(DeviceClass::Handset),
        Just(DeviceClass::LivingRoom),
    ]
}

fn hints() -> impl Strategy<Value = ConnectionHints> {
    (
        0u32..50_000,
        any::<bool>(),
        device(),
        any::<bool>(),
        any::<bool>(),
        any::<bool>(),
    )
        .prop_map(
            |(bandwidth_kbps, metered, device, is_cached, is_dolby_vision, is_hdr)| {
                ConnectionHints {
                    bandwidth_kbps,
                    metered,
                    device,
                    is_cached,
                    is_dolby_vision,
                    is_hdr,
                }
            },
        )
}

proptest! {
    #[test]
    fn deterministic_and_total(kind in stream_kind(), h in hints()) {
        // Running at all proves totality (no panic); equality proves determinism.
        prop_assert_eq!(plan(kind, h), plan(kind, h));
    }

    #[test]
    fn per_kind_shape_holds(kind in stream_kind(), h in hints()) {
        let p = plan(kind, h);
        match kind {
            StreamKind::Hls => {
                prop_assert_eq!(p.player_engine, PlayerEngine::NativeAbr);
                prop_assert_eq!(p.torrent_piece_window, 0);
                prop_assert_ne!(p.abr_ladder_choice, AbrLadderChoice::NotApplicable);
            }
            StreamKind::Torrent => {
                prop_assert!(p.torrent_piece_window > 0);
                prop_assert_eq!(p.abr_ladder_choice, AbrLadderChoice::NotApplicable);
                prop_assert_eq!(p.player_engine, PlayerEngine::Libmpv);
            }
            StreamKind::HttpDirect | StreamKind::Debrid => {
                prop_assert_eq!(p.torrent_piece_window, 0);
                prop_assert_eq!(p.abr_ladder_choice, AbrLadderChoice::NotApplicable);
                prop_assert_eq!(p.player_engine, PlayerEngine::Libmpv);
            }
        }
    }

    #[test]
    fn cached_never_buffers_more(kind in stream_kind(), h in hints()) {
        let cached = plan(kind, ConnectionHints { is_cached: true, ..h });
        let uncached = plan(kind, ConnectionHints { is_cached: false, ..h });
        prop_assert!(cached.buffer_target_secs <= uncached.buffer_target_secs);
    }

    #[test]
    fn metered_never_prefetches_more(kind in stream_kind(), h in hints()) {
        let metered = plan(kind, ConnectionHints { metered: true, ..h });
        let unmetered = plan(kind, ConnectionHints { metered: false, ..h });
        prop_assert!(metered.prefetch_window_secs <= unmetered.prefetch_window_secs);
    }

    #[test]
    fn hls_abr_tier_is_monotone_in_bandwidth(
        dev in device(),
        metered in any::<bool>(),
        b1 in 0u32..50_000,
        b2 in 0u32..50_000,
    ) {
        let (lo, hi) = (b1.min(b2), b1.max(b2));
        let base = ConnectionHints {
            bandwidth_kbps: 0,
            metered,
            device: dev,
            is_cached: false,
            is_dolby_vision: false,
            is_hdr: false,
        };
        let low = plan(StreamKind::Hls, ConnectionHints { bandwidth_kbps: lo, ..base });
        let high = plan(StreamKind::Hls, ConnectionHints { bandwidth_kbps: hi, ..base });
        // AbrLadderChoice derives Ord (Auto < StartLow < StartMedium < StartHigh).
        prop_assert!(low.abr_ladder_choice <= high.abr_ladder_choice);
    }

    #[test]
    fn dv_or_hdr_never_relaxes_decode(kind in stream_kind(), h in hints()) {
        let plain = plan(kind, ConnectionHints { is_dolby_vision: false, is_hdr: false, ..h });
        let dv = plan(kind, ConnectionHints { is_dolby_vision: true, ..h });
        let hdr = plan(kind, ConnectionHints { is_hdr: true, ..h });
        // HwDecode derives Ord (Software < HardwarePreferred < HardwareRequired).
        prop_assert!(dv.hw_decode >= plain.hw_decode);
        prop_assert!(hdr.hw_decode >= plain.hw_decode);
    }
}
