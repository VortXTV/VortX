//! The host-fetch boundary plus the deadline-bounded fan-out orchestration over it. This is the engine
//! substrate decision made concrete: the engine owns WHICH sources to query and HOW to settle their
//! outcomes (skip circuit-open sources, isolate failures, settle partial results); the host owns the bytes,
//! the clock, and the parallelism. The kernel never blocks.
//!
//! A real [`Fetch`] (native `tokio`/`reqwest`, or a browser `fetch` backend for wasm) lives HOST-SIDE; this
//! crate depends only on the trait plus a mock in tests, so the fan-out logic is proven with zero I/O and no
//! async runtime in the FFI'd kernel. Two host usage shapes share the same pure core:
//!
//! - **Parallel (the real substrate):** [`plan_fanout`] -> the host runs every planned request CONCURRENTLY
//!   with a deadline, returning whatever finished -> [`settle_fanout`] (a request the host did not return is
//!   settled as `Timeout`, so a slow source never blocks the merge). This is where true deadline-bounded
//!   parallelism lives, entirely host-side.
//! - **End-to-end (the testable convenience):** [`run_fanout`] is generic over a [`Fetch`] and does
//!   plan -> realize each -> settle in one pure call, so a mock proves the orchestration deterministically.
//!
//! Determinism: planning and settlement are processed in sorted-addon-id order, so however the host
//! parallelizes, the merged [`Aggregate`] is identical across platforms.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::fanout::{aggregate, AddonResult, Aggregate, BreakerRegistry, CircuitConfig, Outcome};

/// One planned fetch the host should perform. `budget_ms` is the per-request time budget the host enforces
/// (returning [`FetchOutcome::Timeout`] if exceeded); the engine stamps it, the host honors it. The kernel
/// stays clockless in milliseconds: it carries the budget, never a wall-clock deadline.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FetchRequest {
    pub addon_id: String,
    pub url: String,
    #[serde(rename = "budgetMs")]
    pub budget_ms: u64,
}

/// What the host returns for a planned fetch. The host has already turned a 2xx body into validated item
/// keys (or classified the failure): a schema-invalid body is `Malformed`, a budget overrun is `Timeout`,
/// any transport/HTTP failure is `Error`. Mirrors [`Outcome`] at the host boundary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum FetchOutcome {
    Ok { items: Vec<String> },
    Malformed,
    Timeout,
    Error,
}

/// The host-provided fetch boundary. The engine calls this to realize a [`FetchRequest`]; the real impl
/// (native `tokio`/`reqwest` or a wasm `fetch` backend) lives OUTSIDE the kernel, so the kernel never takes
/// an async runtime dependency. The host MAY run a batch concurrently: the engine settles outcomes
/// order-independently, so concurrency never changes the result.
pub trait Fetch {
    fn fetch(&self, req: &FetchRequest) -> FetchOutcome;
}

/// Pure: which sources to actually query this round, as stamped requests. A circuit-OPEN source still
/// inside its cooldown is SKIPPED (never fetched), so a persistently bad source stops costing a request;
/// once cooled down it gets its one trial. Deterministic (sorted by addon id). `candidates` are
/// `(addon_id, url)` pairs; `budget_ms` is the per-request time budget stamped onto each request.
pub fn plan_fanout(
    candidates: &[(String, String)],
    breakers: &BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
    budget_ms: u64,
) -> Vec<FetchRequest> {
    let mut sorted: Vec<&(String, String)> = candidates.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    sorted
        .into_iter()
        .filter(|(id, _)| {
            breakers
                .get(id)
                .map(|b| b.should_attempt(cfg, now))
                .unwrap_or(true)
        })
        .map(|(id, url)| FetchRequest {
            addon_id: id.clone(),
            url: url.clone(),
            budget_ms,
        })
        .collect()
}

/// Settle the host's outcomes (keyed by addon id) for a plan into a merged [`Aggregate`], isolating failures
/// and updating the breakers. A planned request the host did NOT return an outcome for is settled as
/// `Timeout` (partial-result settlement: a slow source that missed the deadline never blocks or empties the
/// merge). Pure and deterministic; a failing source contributes no items, so it can never empty a non-empty
/// union.
pub fn settle_fanout(
    plan: &[FetchRequest],
    outcomes: &[(String, FetchOutcome)],
    breakers: &mut BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
) -> Aggregate {
    let by_id: BTreeMap<&str, &FetchOutcome> =
        outcomes.iter().map(|(id, o)| (id.as_str(), o)).collect();
    let results: Vec<AddonResult> = plan
        .iter()
        .map(|req| AddonResult {
            addon_id: req.addon_id.clone(),
            // A request with no host outcome by the deadline settles as Timeout: partial settlement.
            outcome: by_id
                .get(req.addon_id.as_str())
                .map(|o| to_outcome(o))
                .unwrap_or(Outcome::Timeout),
        })
        .collect();
    aggregate(&results, breakers, cfg, now)
}

/// The full deadline-bounded fan-out, generic over a host [`Fetch`]: plan which sources to query, realize
/// each through the host boundary, then settle into an [`Aggregate`]. Pure over the injected fetcher, so a
/// mock proves the orchestration with no I/O. For TRUE parallelism the host instead calls [`plan_fanout`],
/// fetches concurrently with a deadline, and [`settle_fanout`]s the result; both paths share this pure core.
pub fn run_fanout<F: Fetch + ?Sized>(
    fetcher: &F,
    candidates: &[(String, String)],
    breakers: &mut BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
    budget_ms: u64,
) -> Aggregate {
    let plan = plan_fanout(candidates, breakers, cfg, now, budget_ms);
    let outcomes: Vec<(String, FetchOutcome)> = plan
        .iter()
        .map(|req| (req.addon_id.clone(), fetcher.fetch(req)))
        .collect();
    settle_fanout(&plan, &outcomes, breakers, cfg, now)
}

fn to_outcome(o: &FetchOutcome) -> Outcome {
    match o {
        FetchOutcome::Ok { items } => Outcome::Ok {
            items: items.clone(),
        },
        FetchOutcome::Malformed => Outcome::Malformed,
        FetchOutcome::Timeout => Outcome::Timeout,
        FetchOutcome::Error => Outcome::Error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fanout::{BreakerState, CircuitBreaker, FailureKind};

    /// A mock host fetcher: returns the mapped outcome for a request, else `Timeout` (a source the host
    /// could not settle by the deadline).
    struct MockFetch {
        map: BTreeMap<String, FetchOutcome>,
    }

    impl Fetch for MockFetch {
        fn fetch(&self, req: &FetchRequest) -> FetchOutcome {
            self.map
                .get(&req.addon_id)
                .cloned()
                .unwrap_or(FetchOutcome::Timeout)
        }
    }

    fn cands(ids: &[(&str, &str)]) -> Vec<(String, String)> {
        ids.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }

    #[test]
    fn plan_skips_a_cooling_open_breaker_but_keeps_others() {
        let cfg = CircuitConfig {
            failure_threshold: 3,
            cooldown_secs: 300,
        };
        let mut breakers = BreakerRegistry::new();
        breakers.insert(
            "bad".into(),
            CircuitBreaker {
                consecutive_failures: 3,
                state: BreakerState::Open,
                opened_at: 1000,
            },
        );
        // now=1100 -> 100s since open < 300 cooldown -> "bad" still open, skipped.
        let plan = plan_fanout(
            &cands(&[("good", "http://good"), ("bad", "http://bad")]),
            &breakers,
            &cfg,
            1100,
            5000,
        );
        assert_eq!(plan.iter().map(|r| r.addon_id.as_str()).collect::<Vec<_>>(), vec!["good"]);
        assert_eq!(plan[0].budget_ms, 5000);

        // Past the cooldown the trial is allowed again.
        let plan2 = plan_fanout(
            &cands(&[("good", "http://good"), ("bad", "http://bad")]),
            &breakers,
            &cfg,
            1300,
            5000,
        );
        assert_eq!(plan2.len(), 2);
    }

    #[test]
    fn run_fanout_isolates_failure_and_keeps_the_good_items() {
        let fetch = MockFetch {
            map: BTreeMap::from([
                ("good".into(), FetchOutcome::Ok { items: vec!["s1".into(), "s2".into()] }),
                ("poison".into(), FetchOutcome::Malformed),
            ]),
        };
        let mut breakers = BreakerRegistry::new();
        let agg = run_fanout(
            &fetch,
            &cands(&[("good", "http://good"), ("poison", "http://poison")]),
            &mut breakers,
            &CircuitConfig::default(),
            1000,
            5000,
        );
        assert_eq!(agg.items, vec!["s1", "s2"]); // the failure removed nothing
        assert_eq!(agg.survivors, vec!["good"]);
        assert_eq!(agg.failed.len(), 1);
        assert_eq!(agg.failed[0].addon_id, "poison");
        assert_eq!(agg.failed[0].reason, FailureKind::Malformed);
        // The failure was recorded against the poison breaker.
        assert_eq!(breakers.get("poison").unwrap().consecutive_failures, 1);
    }

    #[test]
    fn settle_treats_a_missing_outcome_as_timeout() {
        // The plan had two requests; the host only returned one by the deadline.
        let plan = vec![
            FetchRequest { addon_id: "a".into(), url: "http://a".into(), budget_ms: 5000 },
            FetchRequest { addon_id: "slow".into(), url: "http://slow".into(), budget_ms: 5000 },
        ];
        let outcomes = vec![("a".into(), FetchOutcome::Ok { items: vec!["s1".into()] })];
        let mut breakers = BreakerRegistry::new();
        let agg = settle_fanout(&plan, &outcomes, &mut breakers, &CircuitConfig::default(), 1000);
        assert_eq!(agg.items, vec!["s1"]); // the good source still merges
        assert_eq!(agg.failed.len(), 1);
        assert_eq!(agg.failed[0].addon_id, "slow");
        assert_eq!(agg.failed[0].reason, FailureKind::Timeout); // missing -> timeout
    }
}
