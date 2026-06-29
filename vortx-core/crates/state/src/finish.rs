//! The per-content-kind FINISH decision, as a pure tail-aware function. The lone library threshold
//! (`FINISHED_PERMILLE = 900`) and the tracker scrobble threshold (`800`) were permille-only comparisons;
//! audiobook/podcast finish is TAIL-AWARE (a long credits / ad-roll / "thanks for listening" outro means the
//! real end is before the literal end), which needs absolute position+duration, not just a permille. So this
//! is a real SIGNATURE change to `(position_ms, duration_ms, policy) -> bool`, with the video policy proven to
//! reduce EXACTLY to `permille >= 900` and the scrobble policy to `800` at `tail_grace_ms = 0`.
//!
//! The result: ONE pinned integer pair per content kind, conformance-vectored, instead of every app's fuzzy
//! 90-95% that drifts between clients.

use serde::{Deserialize, Serialize};
use vortx_protocol::{ContentClass, ContentKind};

use crate::library::FINISHED_PERMILLE;

/// When playback counts as FINISHED: at/past `finished_permille` of the runtime, OR within `tail_grace_ms`
/// of the literal end (whichever comes first). The tail grace is what lets audiobook/podcast finish before a
/// long outro; for video it is 0, so the policy reduces to the pure permille comparison.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct FinishPolicy {
    pub finished_permille: u32,
    #[serde(default)]
    pub tail_grace_ms: u64,
}

impl FinishPolicy {
    /// The FROZEN video policy: at/past 90% of the runtime, no tail grace. Reduces EXACTLY to the prior
    /// `permille >= FINISHED_PERMILLE` library comparison (the single source of the 900 threshold).
    pub const VIDEO: FinishPolicy = FinishPolicy {
        finished_permille: FINISHED_PERMILLE,
        tail_grace_ms: 0,
    };
    /// The tracker scrobble policy: Trakt's long-standing 80% default, no tail grace (reduces EXACTLY to the
    /// prior `progress >= 800`).
    pub const SCROBBLE: FinishPolicy = FinishPolicy {
        finished_permille: 800,
        tail_grace_ms: 0,
    };
    /// Audiobook / podcast: still 90% on percent, but ALSO finished within 5 minutes of the literal end, so a
    /// listener who stops in the outro / ad-roll is correctly marked finished. The tail grace is what the
    /// signature change exists for; SH3 wires this per content kind.
    pub const AUDIO: FinishPolicy = FinishPolicy {
        finished_permille: FINISHED_PERMILLE,
        tail_grace_ms: 300_000,
    };

    /// The library finish policy for a content kind: [`AUDIO`](FinishPolicy::AUDIO) (tail-aware) for the
    /// audio class, [`VIDEO`](FinishPolicy::VIDEO) (the frozen permille-only policy) for video and live. A
    /// video/series/movie/unknown title is byte-identical to the prior behavior; only audio diverges (into
    /// tail-aware finish).
    pub fn for_kind(kind: ContentKind) -> FinishPolicy {
        match kind.class() {
            ContentClass::Audio => FinishPolicy::AUDIO,
            ContentClass::Video | ContentClass::Live => FinishPolicy::VIDEO,
        }
    }
}

/// Whether playback at `position_ms` of `duration_ms` counts as FINISHED under `policy`. PURE + integer:
/// finished iff within the policy's tail grace of the end, OR at/past its permille threshold. An unknown
/// (zero) duration never finishes (matching the prior `checked_div` behavior). The video policy
/// (`tail_grace_ms = 0`) reduces EXACTLY to `permille >= finished_permille`.
pub fn finished(position_ms: u64, duration_ms: u64, policy: &FinishPolicy) -> bool {
    if duration_ms == 0 {
        return false;
    }
    if policy.tail_grace_ms > 0 && position_ms.saturating_add(policy.tail_grace_ms) >= duration_ms {
        return true;
    }
    let permille = (position_ms.saturating_mul(1000) / duration_ms).min(1000) as u32;
    permille >= policy.finished_permille
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The old library comparison, for the byte-identical reduction proof.
    fn old_permille(position_ms: u64, duration_ms: u64) -> u32 {
        position_ms
            .saturating_mul(1000)
            .checked_div(duration_ms)
            .map(|p| p.min(1000) as u32)
            .unwrap_or(0)
    }

    #[test]
    fn video_policy_reduces_exactly_to_the_permille_900_comparison() {
        for &(pos, dur) in &[(0, 600_000), (539_999, 600_000), (540_000, 600_000), (600_000, 600_000), (1, 0)] {
            assert_eq!(
                finished(pos, dur, &FinishPolicy::VIDEO),
                old_permille(pos, dur) >= 900,
                "video drift at pos={pos} dur={dur}"
            );
        }
    }

    #[test]
    fn scrobble_policy_reduces_exactly_to_the_permille_800_comparison() {
        for &(pos, dur) in &[(479_999, 600_000), (480_000, 600_000), (600_000, 600_000)] {
            assert_eq!(
                finished(pos, dur, &FinishPolicy::SCROBBLE),
                old_permille(pos, dur) >= 800,
                "scrobble drift at pos={pos} dur={dur}"
            );
        }
    }

    #[test]
    fn audio_tail_grace_finishes_before_the_percent_threshold() {
        // A 40-minute podcast: stopping at 35 min (87.5%, below 90%) is FINISHED because it is within the
        // 5-minute tail grace; one ms earlier it is not (the boundary is exact).
        let dur = 2_400_000; // 40 min
        assert!(finished(2_100_000, dur, &FinishPolicy::AUDIO)); // 35:00, tail boundary
        assert!(!finished(2_099_999, dur, &FinishPolicy::AUDIO)); // 1ms earlier: 87.49% < 90%, outside tail
        // And the percent path still finishes a long audiobook well before any tail.
        assert!(finished(3_600_000, dur, &FinishPolicy::AUDIO)); // past 90%
    }

    #[test]
    fn zero_duration_never_finishes_under_any_policy() {
        assert!(!finished(1_000, 0, &FinishPolicy::VIDEO));
        assert!(!finished(1_000, 0, &FinishPolicy::AUDIO)); // tail grace must not fire on unknown duration
    }

    #[test]
    fn for_kind_selects_audio_only_for_the_audio_class() {
        assert_eq!(FinishPolicy::for_kind(ContentKind::Movie), FinishPolicy::VIDEO);
        assert_eq!(FinishPolicy::for_kind(ContentKind::Series), FinishPolicy::VIDEO);
        assert_eq!(FinishPolicy::for_kind(ContentKind::Channel), FinishPolicy::VIDEO); // live -> video
        assert_eq!(FinishPolicy::for_kind(ContentKind::Unknown), FinishPolicy::VIDEO);
        assert_eq!(FinishPolicy::for_kind(ContentKind::Audiobook), FinishPolicy::AUDIO);
        assert_eq!(FinishPolicy::for_kind(ContentKind::Podcast), FinishPolicy::AUDIO);
    }
}
