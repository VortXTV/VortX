//! The debrid cache flywheel: every cache probe becomes a signed contribution to the hive, plus the
//! per-token rate budget that keeps the probing from tripping a debrid provider's rate limit.
//!
//! The 10x over DebridMediaManager (a centralized cache list): here a probe result, cached or not, is
//! minted as a signed, trust-gated [`vortx_hive::CacheFact`] and gossiped, so the federation's cache map
//! gets denser every time anyone plays anything, with no central authority and Sybil resistance from the
//! existing trust model. [`should_probe`] composes the two guards that protect the user's token: never
//! re-probe a hash the hive already knows fresh, and otherwise only probe within a [`RateBudget`].

use serde::{Deserialize, Serialize};
use vortx_hive::{CacheFact, DebridService, HiveError, NodeIdentity};

const SECS_PER_MIN: u64 = 60;
const SECS_PER_HOUR: u64 = 3600;

/// Per-token rate budget for debrid calls. Cached-availability checks are cheap and frequent (per
/// minute); uncached adds are expensive and rarer (per hour).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateBudget {
    pub cached_per_min: u32,
    pub uncached_per_hour: u32,
}

impl Default for RateBudget {
    fn default() -> Self {
        Self {
            cached_per_min: 200,
            uncached_per_hour: 60,
        }
    }
}

/// A fixed-window rate meter for one token. `try_*` is check-and-consume: it returns whether the call is
/// within budget and records it if so.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RateMeter {
    cached_window_start: u64,
    cached_count: u32,
    uncached_window_start: u64,
    uncached_count: u32,
}

impl RateMeter {
    /// Try to spend one cached-availability check at `now`. Returns false (and records nothing) if the
    /// minute budget is exhausted.
    pub fn try_cached(&mut self, budget: &RateBudget, now: u64) -> bool {
        if now.saturating_sub(self.cached_window_start) >= SECS_PER_MIN {
            self.cached_window_start = now;
            self.cached_count = 0;
        }
        if self.cached_count < budget.cached_per_min {
            self.cached_count += 1;
            true
        } else {
            false
        }
    }

    /// Try to spend one uncached add at `now`. Returns false if the hour budget is exhausted.
    pub fn try_uncached(&mut self, budget: &RateBudget, now: u64) -> bool {
        if now.saturating_sub(self.uncached_window_start) >= SECS_PER_HOUR {
            self.uncached_window_start = now;
            self.uncached_count = 0;
        }
        if self.uncached_count < budget.uncached_per_hour {
            self.uncached_count += 1;
            true
        } else {
            false
        }
    }
}

/// Whether to spend a cached-availability probe: never re-probe a hash the hive already knows fresh, and
/// otherwise only probe within budget (consuming one unit when it returns true).
pub fn should_probe(
    meter: &mut RateMeter,
    budget: &RateBudget,
    already_known_fresh: bool,
    now: u64,
) -> bool {
    if already_known_fresh {
        return false;
    }
    meter.try_cached(budget, now)
}

/// The result of a debrid cache probe: a hash, the service, the file, and whether it was cached.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProbeResult {
    pub infohash: String,
    pub service: DebridService,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_idx: Option<u32>,
    pub cached: bool,
}

/// Mint the signed `CacheFact` that turns a probe into a federation contribution. Cached and uncached
/// results both produce a fact (a signed negative is as valuable as a signed positive).
pub fn writeback_fact(
    identity: &NodeIdentity,
    probe: &ProbeResult,
    verified_at: u64,
    ttl: u64,
) -> Result<CacheFact, HiveError> {
    CacheFact::create(
        identity,
        &probe.infohash,
        probe.service,
        probe.cached,
        probe.file_idx,
        None,
        None,
        verified_at,
        ttl,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const IH: &str = "aabbccddeeff00112233445566778899aabbccdd";

    #[test]
    fn cached_budget_caps_per_minute_and_resets() {
        let budget = RateBudget {
            cached_per_min: 3,
            uncached_per_hour: 100,
        };
        let mut m = RateMeter::default();
        assert!(m.try_cached(&budget, 0));
        assert!(m.try_cached(&budget, 0));
        assert!(m.try_cached(&budget, 0));
        assert!(!m.try_cached(&budget, 0)); // 4th over budget
        assert!(m.try_cached(&budget, 60)); // new window
    }

    #[test]
    fn should_probe_skips_a_known_fresh_hash() {
        let budget = RateBudget::default();
        let mut m = RateMeter::default();
        assert!(!should_probe(&mut m, &budget, true, 0), "do not re-probe a known hash");
        assert!(should_probe(&mut m, &budget, false, 0), "probe an unknown hash within budget");
    }

    #[test]
    fn writeback_signs_a_fact_for_both_outcomes() {
        let id = NodeIdentity::generate().unwrap();
        for cached in [true, false] {
            let probe = ProbeResult {
                infohash: IH.into(),
                service: DebridService::RealDebrid,
                file_idx: Some(0),
                cached,
            };
            let fact = writeback_fact(&id, &probe, 1000, 86_400).unwrap();
            assert_eq!(fact.cached, cached);
            assert!(fact.verify_signed().is_ok());
        }
    }
}
