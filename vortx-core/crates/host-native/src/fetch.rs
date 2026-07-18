//! The native [`Fetch`] host: tokio + reqwest(rustls) behind the kernel's synchronous fetch boundary.
//! The kernel plans (`plan_fanout`), the host realizes, the kernel settles (`settle_fanout`); this
//! module owns the realize step in both of the kernel's documented usage shapes:
//!
//! - **Trait path** ([`Fetch::fetch`]): one blocking, budget-bounded realization per request, which
//!   makes the kernel's own `execute_plan` / `run_fanout` work unchanged over a real network.
//! - **Parallel path** ([`NativeFetcher::realize_plan`]): every planned request in flight
//!   CONCURRENTLY, each under its OWN `budget_ms`, so the whole plan resolves within the slowest
//!   single budget instead of the sum. The outcomes feed straight into `settle_fanout`, and
//!   [`NativeFetcher::run_fanout_parallel`] packages plan -> realize -> settle in one call while
//!   surfacing every circuit-breaker transition the settle produced.
//!
//! Outcome classification at this boundary (mirroring the kernel's [`FetchOutcome`] contract): a
//! budget overrun is `Timeout`; any transport failure or non-2xx status is `Error`; a 2xx body that
//! fails resource-schema validation ([`crate::body_to_items`]) is `Malformed`; a valid body arrives
//! as `Ok { items }` carrying one validated item key per element.

use std::time::Duration;

use vortx_source::{
    plan_fanout, settle_fanout, Aggregate, BreakerRegistry, BreakerState, CircuitConfig, Fetch,
    FetchOutcome, FetchRequest,
};

use crate::body::body_to_items;

/// Failures constructing the native fetch host (the runtime or the HTTP client).
#[derive(Debug, thiserror::Error)]
pub enum FetchInitError {
    #[error("failed to build the tokio runtime: {0}")]
    Runtime(#[from] std::io::Error),
    #[error("failed to build the HTTP client: {0}")]
    Client(#[from] reqwest::Error),
}

/// One observed circuit-breaker state change from a settle: which addon moved, from what, to what.
/// `Closed -> Open` is a source being circuited out; `Open -> Closed` is a cooled-down trial
/// succeeding. Hosts log or surface these; the kernel itself only stores the resulting state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BreakerTransition {
    pub addon_id: String,
    pub from: BreakerState,
    pub to: BreakerState,
}

/// The result of one parallel fan-out round: what the plan was, what settled, and which breakers
/// changed state while settling. `planned` is empty when every candidate was circuit-skipped.
#[derive(Debug, Clone)]
pub struct FanoutReport {
    /// The requests actually issued this round (circuit-open sources are skipped by the kernel plan).
    pub planned: Vec<FetchRequest>,
    /// The settled merge: items from the survivors, failures isolated with reasons.
    pub aggregate: Aggregate,
    /// Every breaker that changed state in this round, in plan order.
    pub transitions: Vec<BreakerTransition>,
}

/// The native fetch host: a tokio runtime plus a rustls-backed reqwest client. Construct once and
/// share; the client pools connections across requests.
///
/// Call sites must be synchronous host threads (the FFI dispatch thread, a CLI, a test): the
/// blocking entry points drive the internal runtime with `block_on`, which panics if invoked from
/// within another tokio runtime. That is the intended shape: the KERNEL is synchronous and the host
/// owns all concurrency internally.
#[derive(Debug)]
pub struct NativeFetcher {
    runtime: tokio::runtime::Runtime,
    client: reqwest::Client,
}

impl NativeFetcher {
    /// Build the host with a multi-thread runtime and a rustls HTTP client.
    pub fn new() -> Result<Self, FetchInitError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()?;
        let client = reqwest::Client::builder().build()?;
        Ok(Self { runtime, client })
    }

    /// Realize every request in `plan` CONCURRENTLY, each bounded by its own `budget_ms`, returning
    /// `(addon_id, outcome)` pairs in plan order (settlement is order-independent, but a
    /// deterministic return order keeps host logs stable). A request that overruns its budget
    /// resolves as `Timeout` without delaying the others: total wall time is bounded by the largest
    /// single budget, not the sum. Feed the result to the kernel's `settle_fanout`.
    pub fn realize_plan(&self, plan: &[FetchRequest]) -> Vec<(String, FetchOutcome)> {
        self.runtime.block_on(async {
            let futures = plan
                .iter()
                .map(|req| async { (req.addon_id.clone(), realize_one(&self.client, req).await) });
            futures::join_all(futures).await
        })
    }

    /// The full parallel fan-out round over live sources: kernel-plan (skipping circuit-open
    /// sources), realize concurrently under per-request budgets, kernel-settle (isolating failures,
    /// updating `breakers` in place), and report every breaker transition the round caused.
    pub fn run_fanout_parallel(
        &self,
        candidates: &[(String, String)],
        breakers: &mut BreakerRegistry,
        cfg: &CircuitConfig,
        now: u64,
        budget_ms: u64,
    ) -> FanoutReport {
        let planned = plan_fanout(candidates, breakers, cfg, now, budget_ms);
        let before: Vec<(String, BreakerState)> = planned
            .iter()
            .map(|req| (req.addon_id.clone(), breaker_state(breakers, &req.addon_id)))
            .collect();
        let outcomes = self.realize_plan(&planned);
        let aggregate = settle_fanout(&planned, &outcomes, breakers, cfg, now);
        let transitions = before
            .into_iter()
            .filter_map(|(addon_id, from)| {
                let to = breaker_state(breakers, &addon_id);
                (from != to).then_some(BreakerTransition { addon_id, from, to })
            })
            .collect();
        FanoutReport {
            planned,
            aggregate,
            transitions,
        }
    }
}

/// The kernel's synchronous fetch boundary: block the calling host thread on one budget-bounded
/// realization. This is what lets the kernel's own `execute_plan` / `run_fanout` run unchanged over
/// the real network; for whole-plan concurrency use [`NativeFetcher::realize_plan`] instead.
impl Fetch for NativeFetcher {
    fn fetch(&self, req: &FetchRequest) -> FetchOutcome {
        self.runtime.block_on(realize_one(&self.client, req))
    }
}

/// An addon's breaker state, `Closed` when it has no registry entry yet (the kernel default).
fn breaker_state(breakers: &BreakerRegistry, addon_id: &str) -> BreakerState {
    breakers.get(addon_id).map(|b| b.state).unwrap_or_default()
}

/// Realize one request under its own budget: GET the URL, then classify per the outcome contract.
async fn realize_one(client: &reqwest::Client, req: &FetchRequest) -> FetchOutcome {
    let budget = Duration::from_millis(req.budget_ms);
    match tokio::time::timeout(budget, fetch_body(client, &req.url)).await {
        // Budget overrun: the whole realization (connect + headers + body) shares the one budget.
        Err(_elapsed) => FetchOutcome::Timeout,
        // Transport failure or non-2xx status.
        Ok(Err(())) => FetchOutcome::Error,
        // A 2xx body: schema-validate into item keys, else the addon answered garbage.
        Ok(Ok(body)) => match body_to_items(&req.url, &body) {
            Some(items) => FetchOutcome::Ok { items },
            None => FetchOutcome::Malformed,
        },
    }
}

/// GET `url` and return its body on a 2xx, `Err(())` on any transport failure or non-2xx status
/// (the caller folds both into `FetchOutcome::Error`; the distinction the kernel cares about is
/// only ok / malformed / timeout / error).
async fn fetch_body(client: &reqwest::Client, url: &str) -> Result<String, ()> {
    let response = client.get(url).send().await.map_err(|_| ())?;
    if !response.status().is_success() {
        return Err(());
    }
    response.text().await.map_err(|_| ())
}

/// A minimal local `join_all` so the host does not pull the `futures` crate for one combinator:
/// polls every future each wake and completes when all are done, preserving input order.
mod futures {
    use std::future::Future;
    use std::pin::Pin;
    use std::task::{Context, Poll};

    pub async fn join_all<F: Future>(iter: impl IntoIterator<Item = F>) -> Vec<F::Output>
    where
        F::Output: Unpin,
    {
        JoinAll {
            slots: iter
                .into_iter()
                .map(|f| Slot::Pending(Box::pin(f)))
                .collect(),
        }
        .await
    }

    enum Slot<F: Future> {
        Pending(Pin<Box<F>>),
        Done(F::Output),
        Taken,
    }

    struct JoinAll<F: Future> {
        slots: Vec<Slot<F>>,
    }

    impl<F: Future> Future for JoinAll<F>
    where
        F::Output: Unpin,
    {
        type Output = Vec<F::Output>;

        fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
            // SAFETY-free: we never move the pinned inner futures; they live in Box::pin.
            let this = self.get_mut();
            let mut all_done = true;
            for slot in &mut this.slots {
                if let Slot::Pending(fut) = slot {
                    match fut.as_mut().poll(cx) {
                        Poll::Ready(out) => *slot = Slot::Done(out),
                        Poll::Pending => all_done = false,
                    }
                }
            }
            if !all_done {
                return Poll::Pending;
            }
            let outputs = this
                .slots
                .iter_mut()
                .map(|slot| match std::mem::replace(slot, Slot::Taken) {
                    Slot::Done(out) => out,
                    _ => unreachable!("all slots are Done when all_done"),
                })
                .collect();
            Poll::Ready(outputs)
        }
    }
}
