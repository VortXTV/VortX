//! The closed-loop adaptive-bitrate (ABR) selector: the runtime decision that makes HLS playback smooth.
//! [`crate::plan`] picks a START tier from connection hints; this picks the NEXT variant every few seconds
//! from the live buffer + throughput, the loop that actually keeps a stream from rebuffering or sitting at
//! a needlessly low quality.
//!
//! It is 10x over a stock player's ABR on three axes the engine cares about:
//!
//! - **Deterministic.** Pure integer math (the throughput safety margin is per-mille, not a float), so the
//!   SAME buffer + throughput yields the SAME variant on iOS, Android, and the web, and the decision is
//!   conformance-pinned. Stock ABR is float and platform-specific.
//! - **Buffer-aware, not throughput-only.** A low buffer can only step DOWN; a step UP is allowed only
//!   when the buffer is comfortably full, so a brief bandwidth spike does not trigger a quality jump that
//!   then rebuffers.
//! - **Anti-oscillation.** Up-switches are rate-limited (at most `max_up_step` ladder rungs at once) while
//!   down-switches are immediate, the asymmetry that stops the visible quality flapping.

use serde::{Deserialize, Serialize};

/// One rendition in the HLS variant ladder.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AbrVariant {
    /// The variant's own index (its position in the master playlist); returned as the decision.
    pub index: usize,
    /// Declared peak bandwidth in bits per second.
    pub bandwidth_bps: u64,
    /// Rendition height in pixels (advisory; not used in the decision).
    #[serde(default)]
    pub height: u16,
}

/// The live signals the selector reads each cycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AbrState {
    /// Media buffered ahead of the playhead, milliseconds.
    pub buffered_ms: u32,
    /// Recently measured download throughput, bits per second.
    pub throughput_bps: u64,
    /// The variant index currently playing.
    pub current_index: usize,
}

/// Tuning. Integer-only so the decision is byte-reproducible.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AbrConfig {
    /// Usable fraction of measured throughput, per-mille (700 = use 70% as the affordable ceiling).
    pub safety_permille: u32,
    /// Below this buffer, never step up (only hold or drop).
    pub low_buffer_ms: u32,
    /// At or above this buffer, a step up is allowed.
    pub high_buffer_ms: u32,
    /// Max ladder rungs to climb in one decision (anti-oscillation). Down-switches are never capped.
    pub max_up_step: usize,
}

impl Default for AbrConfig {
    fn default() -> Self {
        Self {
            safety_permille: 700,
            low_buffer_ms: 8_000,
            high_buffer_ms: 20_000,
            max_up_step: 1,
        }
    }
}

/// Why the selector moved (or held).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AbrReason {
    /// No ladder to choose from; the current index is kept.
    EmptyLadder,
    /// Stayed on the current variant.
    Hold,
    /// Climbed (buffer is full and a higher variant is affordable).
    StepUp,
    /// Dropped because the measured throughput cannot sustain the current variant.
    StepDownThroughput,
    /// Dropped because the buffer is low and a rebuffer is imminent.
    StepDownRebufferRisk,
}

/// The selector's decision: the variant index to switch to and why.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AbrDecision {
    pub index: usize,
    pub reason: AbrReason,
}

/// Choose the next variant. Pure and total. The affordable ceiling is the highest ladder rung whose
/// bandwidth fits the throughput safety margin; the buffer decides whether we may climb toward it, must
/// hold, or must drop. A step up is rate-limited and gated on a full buffer; a step down is immediate.
pub fn choose_variant(
    variants: &[AbrVariant],
    state: &AbrState,
    cfg: &AbrConfig,
) -> AbrDecision {
    if variants.is_empty() {
        return AbrDecision {
            index: state.current_index,
            reason: AbrReason::EmptyLadder,
        };
    }

    // Ladder ascending by bandwidth, ties broken by index for a total order.
    let mut ladder: Vec<&AbrVariant> = variants.iter().collect();
    ladder.sort_by(|a, b| {
        a.bandwidth_bps
            .cmp(&b.bandwidth_bps)
            .then(a.index.cmp(&b.index))
    });

    let cur = ladder
        .iter()
        .position(|v| v.index == state.current_index)
        .unwrap_or(0);

    // Affordable ceiling: highest rung whose bandwidth fits the safety margin, else the lowest rung.
    let usable = state
        .throughput_bps
        .saturating_mul(cfg.safety_permille as u64)
        / 1000;
    let ceiling = ladder
        .iter()
        .rposition(|v| v.bandwidth_bps <= usable)
        .unwrap_or(0);

    let target = if state.buffered_ms < cfg.low_buffer_ms {
        // Low buffer: never climb. Drop to the ceiling if it is below us.
        cur.min(ceiling)
    } else if state.buffered_ms >= cfg.high_buffer_ms && ceiling > cur {
        // Full buffer and headroom: climb, but at most max_up_step rungs at once.
        ceiling.min(cur + cfg.max_up_step.max(1))
    } else {
        // Mid buffer (or no headroom): hold, or drop to the ceiling if throughput fell.
        cur.min(ceiling)
    };

    let reason = if target > cur {
        AbrReason::StepUp
    } else if target < cur {
        if state.buffered_ms < cfg.low_buffer_ms {
            AbrReason::StepDownRebufferRisk
        } else {
            AbrReason::StepDownThroughput
        }
    } else {
        AbrReason::Hold
    };

    AbrDecision {
        index: ladder[target].index,
        reason,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ladder() -> Vec<AbrVariant> {
        vec![
            AbrVariant { index: 0, bandwidth_bps: 1_000_000, height: 360 },
            AbrVariant { index: 1, bandwidth_bps: 3_000_000, height: 720 },
            AbrVariant { index: 2, bandwidth_bps: 6_000_000, height: 1080 },
        ]
    }

    #[test]
    fn full_buffer_climbs_one_rung_at_a_time() {
        // Plenty of throughput for 1080p, full buffer, currently on 360p -> climbs to 720p (one rung).
        let d = choose_variant(
            &ladder(),
            &AbrState { buffered_ms: 25_000, throughput_bps: 20_000_000, current_index: 0 },
            &AbrConfig::default(),
        );
        assert_eq!(d.index, 1);
        assert_eq!(d.reason, AbrReason::StepUp);
    }

    #[test]
    fn low_buffer_never_climbs() {
        let d = choose_variant(
            &ladder(),
            &AbrState { buffered_ms: 3_000, throughput_bps: 20_000_000, current_index: 0 },
            &AbrConfig::default(),
        );
        assert_eq!(d.index, 0);
        assert_eq!(d.reason, AbrReason::Hold);
    }

    #[test]
    fn throughput_drop_steps_down_immediately() {
        // On 1080p but throughput only sustains 360p; mid buffer -> drop straight to the ceiling.
        let d = choose_variant(
            &ladder(),
            &AbrState { buffered_ms: 12_000, throughput_bps: 1_300_000, current_index: 2 },
            &AbrConfig::default(),
        );
        assert_eq!(d.index, 0);
        assert_eq!(d.reason, AbrReason::StepDownThroughput);
    }

    #[test]
    fn low_buffer_drop_is_rebuffer_risk() {
        let d = choose_variant(
            &ladder(),
            &AbrState { buffered_ms: 2_000, throughput_bps: 1_300_000, current_index: 2 },
            &AbrConfig::default(),
        );
        assert_eq!(d.index, 0);
        assert_eq!(d.reason, AbrReason::StepDownRebufferRisk);
    }

    #[test]
    fn empty_ladder_holds_current() {
        let d = choose_variant(
            &[],
            &AbrState { buffered_ms: 1, throughput_bps: 1, current_index: 5 },
            &AbrConfig::default(),
        );
        assert_eq!(d.index, 5);
        assert_eq!(d.reason, AbrReason::EmptyLadder);
    }
}
