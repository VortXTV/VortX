//! The RECORD capture path: fetch each planned request's RAW body so the round can be replayed
//! byte-identically. The NativeFetcher boundary deliberately returns classified outcomes (never
//! bodies), so capture owns its own minimal GET here; classification then goes through host-native's
//! PUBLIC `body_to_items`, the same validation the live path applies, keeping record and replay on
//! one classification contract. This module exists ONLY for `--record`; plain live resolution goes
//! through `NativeFetcher::realize_plan`.

use std::collections::BTreeMap;
use std::time::Duration;

use vortx_host_native::body_to_items;
use vortx_source::{FetchOutcome, FetchRequest};

use crate::CliError;

/// One captured request: the raw body when the source answered 2xx, plus the classified outcome.
pub struct Capture {
    pub bodies: BTreeMap<String, String>,
    pub outcomes: Vec<(String, FetchOutcome)>,
}

/// Classify a recorded/replayed raw body exactly like the live host classifies a 2xx body: schema
/// validation via `body_to_items` yields `Ok { items }`, anything else is `Malformed`.
pub fn classify_body(url: &str, body: &str) -> FetchOutcome {
    match body_to_items(url, body) {
        Some(items) => FetchOutcome::Ok { items },
        None => FetchOutcome::Malformed,
    }
}

/// Fetch every planned request, capturing raw bodies. Mirrors the host outcome contract: a budget
/// overrun is `Timeout`, a transport failure or non-2xx is `Error`, a 2xx body is recorded and then
/// classified. Sequential on purpose: capture is a dev utility, not the resolve substrate.
pub fn capture_plan(plan: &[FetchRequest]) -> Result<Capture, CliError> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|e| CliError::Runtime(format!("build capture runtime: {e}")))?;
    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| CliError::Runtime(format!("build capture client: {e}")))?;

    let mut bodies = BTreeMap::new();
    let mut outcomes = Vec::with_capacity(plan.len());
    for req in plan {
        let outcome = runtime.block_on(async {
            let budget = Duration::from_millis(req.budget_ms);
            match tokio::time::timeout(budget, fetch_body(&client, &req.url)).await {
                Err(_elapsed) => FetchOutcome::Timeout,
                Ok(Err(())) => FetchOutcome::Error,
                Ok(Ok(body)) => {
                    let outcome = classify_body(&req.url, &body);
                    bodies.insert(req.addon_id.clone(), body);
                    outcome
                }
            }
        });
        outcomes.push((req.addon_id.clone(), outcome));
    }
    Ok(Capture { bodies, outcomes })
}

async fn fetch_body(client: &reqwest::Client, url: &str) -> Result<String, ()> {
    let response = client.get(url).send().await.map_err(|_| ())?;
    if !response.status().is_success() {
        return Err(());
    }
    response.text().await.map_err(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classification_matches_the_host_contract() {
        let url = "https://a.example/stream/movie/tt1.json";
        let good = r#"{"streams":[{"name":"x","url":"https://cdn.example/x.mp4"}]}"#;
        assert!(matches!(
            classify_body(url, good),
            FetchOutcome::Ok { items } if items.len() == 1
        ));
        assert_eq!(classify_body(url, "not json"), FetchOutcome::Malformed);
    }
}
