//! Quality-aware early termination for source fan-out. A vanilla aggregator waits for the slowest scraper
//! or a fixed timeout; this is the engine's pure decision that the host has ENOUGH good results to stop
//! scraping now and cancel the rest, cutting perceived latency without sacrificing quality.
//!
//! The 10x over a best-effort timer (Seren's `preem`, NuvioStreamsAddon's 45s race) is that the decision
//! is a pure, deterministic function of the partial results seen so far: given the same arrival order,
//! every device stops at the identical point, so results are reproducible, not race-dependent. The host
//! owns the actual request cancellation; the engine only emits the signal, so it stays I/O-free.

use serde::{Deserialize, Serialize};

/// A minimal view of one result as it streams in (the host reports these as fan-out completes).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PartialResult {
    /// Debrid-cached (instant) — the results that actually matter for a fast start.
    pub cached: bool,
    /// Vertical resolution in pixels (0 = unknown).
    pub height: u16,
}

/// When the host may stop scraping early.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExitConfig {
    /// Stop once at least this many CACHED results at or above `target_height` have arrived.
    pub min_cached_at_target: u32,
    /// The resolution that counts as "good enough" for the cached-count gate.
    pub target_height: u16,
    /// Fallback: stop once this many TOTAL results have arrived (so a no-cache title still terminates).
    pub min_total: u32,
}

impl Default for ExitConfig {
    fn default() -> Self {
        Self {
            min_cached_at_target: 3,
            target_height: 1080,
            min_total: 30,
        }
    }
}

/// Why the fan-out may stop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExitReason {
    /// Enough cached results at the target resolution: an instant play is assured.
    EnoughCached,
    /// Enough total results: diminishing returns even without cache.
    EnoughTotal,
}

/// The decision the host acts on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum ExitDecision {
    /// Keep scraping; not enough yet.
    Continue,
    /// Stop and cancel remaining sources.
    StopNow { reason: ExitReason },
}

/// Decide whether the host can stop scraping, given everything that has arrived so far. Pure and
/// monotone: once it returns `StopNow`, more results never flip it back to `Continue`. The cached gate is
/// checked first (an instant play is the best reason to stop), then the total-count fallback.
pub fn should_stop(partial: &[PartialResult], cfg: &ExitConfig) -> ExitDecision {
    let cached_at_target = partial
        .iter()
        .filter(|r| r.cached && r.height >= cfg.target_height)
        .count() as u32;
    if cfg.min_cached_at_target > 0 && cached_at_target >= cfg.min_cached_at_target {
        return ExitDecision::StopNow {
            reason: ExitReason::EnoughCached,
        };
    }
    if cfg.min_total > 0 && partial.len() as u32 >= cfg.min_total {
        return ExitDecision::StopNow {
            reason: ExitReason::EnoughTotal,
        };
    }
    ExitDecision::Continue
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(cached: bool, height: u16) -> PartialResult {
        PartialResult { cached, height }
    }

    #[test]
    fn stops_on_enough_cached_at_target() {
        let cfg = ExitConfig { min_cached_at_target: 2, target_height: 1080, min_total: 100 };
        let p = vec![r(true, 1080), r(false, 2160), r(true, 1080)];
        assert_eq!(should_stop(&p, &cfg), ExitDecision::StopNow { reason: ExitReason::EnoughCached });
    }

    #[test]
    fn cached_below_target_does_not_count() {
        let cfg = ExitConfig { min_cached_at_target: 2, target_height: 1080, min_total: 100 };
        // Cached but only 720p -> below target, so not enough cached-at-target yet.
        let p = vec![r(true, 720), r(true, 720)];
        assert_eq!(should_stop(&p, &cfg), ExitDecision::Continue);
    }

    #[test]
    fn falls_back_to_total_count() {
        let cfg = ExitConfig { min_cached_at_target: 5, target_height: 2160, min_total: 3 };
        let p = vec![r(false, 1080), r(false, 720), r(false, 480)];
        assert_eq!(should_stop(&p, &cfg), ExitDecision::StopNow { reason: ExitReason::EnoughTotal });
    }

    #[test]
    fn continues_when_nothing_is_satisfied() {
        let cfg = ExitConfig::default();
        assert_eq!(should_stop(&[], &cfg), ExitDecision::Continue);
    }
}
