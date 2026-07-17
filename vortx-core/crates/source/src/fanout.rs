//! Defensive addon fan-out. The engine queries dozens of untrusted addons for a resource; this is the
//! pure POLICY that turns their per-addon outcomes into one merged result without letting a slow, broken,
//! or hostile addon poison the batch. Two separable concerns:
//!
//! - a per-addon [`CircuitBreaker`] (Closed/Open with cooldown-as-half-open: open after N consecutive
//!   failures, allow one trial after the cooldown) so a persistently bad addon stops being queried;
//! - [`aggregate`], which merges only the items from successful outcomes, so a failure contributes
//!   nothing rather than corrupting the union. Partial-failure isolation is structural, not a check.
//!
//! Pure: the network calls happen platform-side; this decides what to keep and which addons to circuit
//! out. Deterministic (results are processed in sorted addon-id order).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Circuit-breaker tuning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CircuitConfig {
    /// Consecutive failures before the breaker opens.
    pub failure_threshold: u32,
    /// Seconds the breaker stays open before allowing one trial.
    pub cooldown_secs: u64,
}

impl Default for CircuitConfig {
    fn default() -> Self {
        Self {
            failure_threshold: 3,
            cooldown_secs: 300,
        }
    }
}

/// Breaker state. Open uses the cooldown as an implicit half-open (a trial is allowed once cooled down).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BreakerState {
    #[default]
    Closed,
    Open,
}

/// A per-addon circuit breaker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct CircuitBreaker {
    pub consecutive_failures: u32,
    pub state: BreakerState,
    /// Unix seconds the breaker last opened.
    #[serde(default)]
    pub opened_at: u64,
}

impl CircuitBreaker {
    /// A success closes the breaker and clears the failure count.
    pub fn record_success(&mut self) {
        self.consecutive_failures = 0;
        self.state = BreakerState::Closed;
    }

    /// A failure increments the count and opens the breaker at the threshold (re-arming the cooldown).
    pub fn record_failure(&mut self, cfg: &CircuitConfig, now: u64) {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        if self.consecutive_failures >= cfg.failure_threshold {
            self.state = BreakerState::Open;
            self.opened_at = now;
        }
    }

    /// Whether the caller should query this addon now: always when Closed; when Open, only after the
    /// cooldown has elapsed (the one trial that can re-close it).
    pub fn should_attempt(&self, cfg: &CircuitConfig, now: u64) -> bool {
        match self.state {
            BreakerState::Closed => true,
            BreakerState::Open => now.saturating_sub(self.opened_at) >= cfg.cooldown_secs,
        }
    }
}

/// The per-addon breaker registry.
pub type BreakerRegistry = BTreeMap<String, CircuitBreaker>;

/// One addon's outcome for a fan-out. `Ok` carries its already-validated item keys (the platform layer
/// did the fetch + schema-validation; a schema-invalid response arrives here as `Malformed`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Outcome {
    Ok { items: Vec<String> },
    Malformed,
    Timeout,
    Error,
}

/// Why an addon was excluded from the merge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureKind {
    Malformed,
    Timeout,
    Error,
}

/// One addon's result in a fan-out.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddonResult {
    pub addon_id: String,
    #[serde(flatten)]
    pub outcome: Outcome,
}

/// An addon that failed and was isolated.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FailedAddon {
    pub addon_id: String,
    pub reason: FailureKind,
}

/// The merged fan-out result.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Aggregate {
    /// Items from the successful addons, in sorted-addon-id order (dedup across addons is a later stage).
    pub items: Vec<String>,
    /// Addon ids that succeeded, sorted.
    pub survivors: Vec<String>,
    /// Addon ids that failed (isolated), sorted, with the reason.
    pub failed: Vec<FailedAddon>,
}

/// Merge the fan-out, isolating failures and updating the circuit breakers. Deterministic: results are
/// processed in sorted addon-id order. A failing addon contributes NO items, so a single failure can
/// never empty a non-empty union.
pub fn aggregate(
    results: &[AddonResult],
    breakers: &mut BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
) -> Aggregate {
    let mut sorted: Vec<&AddonResult> = results.iter().collect();
    sorted.sort_by(|a, b| a.addon_id.cmp(&b.addon_id));

    let mut out = Aggregate::default();
    for result in sorted {
        let breaker = breakers.entry(result.addon_id.clone()).or_default();
        match &result.outcome {
            Outcome::Ok { items } => {
                breaker.record_success();
                out.items.extend(items.iter().cloned());
                out.survivors.push(result.addon_id.clone());
            }
            failure => {
                breaker.record_failure(cfg, now);
                out.failed.push(FailedAddon {
                    addon_id: result.addon_id.clone(),
                    reason: failure_kind(failure),
                });
            }
        }
    }
    out
}

fn failure_kind(outcome: &Outcome) -> FailureKind {
    match outcome {
        Outcome::Malformed => FailureKind::Malformed,
        Outcome::Timeout => FailureKind::Timeout,
        Outcome::Error | Outcome::Ok { .. } => FailureKind::Error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(id: &str, items: &[&str]) -> AddonResult {
        AddonResult {
            addon_id: id.into(),
            outcome: Outcome::Ok {
                items: items.iter().map(|s| s.to_string()).collect(),
            },
        }
    }

    fn fail(id: &str, outcome: Outcome) -> AddonResult {
        AddonResult {
            addon_id: id.into(),
            outcome,
        }
    }

    #[test]
    fn one_poison_addon_never_aborts_the_batch() {
        let results = vec![
            ok("good", &["s1", "s2"]),
            fail("poison", Outcome::Malformed),
            ok("alsogood", &["s3"]),
        ];
        let mut breakers = BreakerRegistry::new();
        let agg = aggregate(&results, &mut breakers, &CircuitConfig::default(), 1000);
        assert_eq!(agg.items, vec!["s3", "s1", "s2"]); // alsogood < good by addon_id
        assert_eq!(agg.survivors, vec!["alsogood", "good"]);
        assert_eq!(agg.failed.len(), 1);
        assert_eq!(agg.failed[0].addon_id, "poison");
        assert_eq!(agg.failed[0].reason, FailureKind::Malformed);
    }

    #[test]
    fn breaker_opens_after_threshold_failures() {
        let cfg = CircuitConfig {
            failure_threshold: 3,
            cooldown_secs: 100,
        };
        let mut breakers = BreakerRegistry::new();
        for _ in 0..3 {
            aggregate(&[fail("bad", Outcome::Timeout)], &mut breakers, &cfg, 1000);
        }
        let b = breakers.get("bad").unwrap();
        assert_eq!(b.state, BreakerState::Open);
        assert!(!b.should_attempt(&cfg, 1050)); // still cooling down
        assert!(b.should_attempt(&cfg, 1100)); // cooldown elapsed: one trial allowed
    }

    #[test]
    fn success_resets_the_breaker() {
        let cfg = CircuitConfig::default();
        let mut breakers = BreakerRegistry::new();
        aggregate(&[fail("flaky", Outcome::Error)], &mut breakers, &cfg, 1);
        aggregate(&[fail("flaky", Outcome::Error)], &mut breakers, &cfg, 2);
        aggregate(&[ok("flaky", &["s1"])], &mut breakers, &cfg, 3);
        assert_eq!(breakers.get("flaky").unwrap().consecutive_failures, 0);
        assert_eq!(breakers.get("flaky").unwrap().state, BreakerState::Closed);
    }
}
