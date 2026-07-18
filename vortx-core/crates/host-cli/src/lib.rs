//! # vortx-host-cli
//!
//! The Phase 3 PROOF: a dev-only headless host that drives the kernel's resolve surface end to end
//! over the Phase 1 host substrate and prints a BYTE-STABLE ranked stream resolution as JSON.
//!
//! The round is the kernel's own stateless LOAD effect model, driven through the SAME JSON query
//! surface the platform FFI bridges call (`vortx_engine::resolve_json`):
//!
//! 1. **PLAN**: a `stream_load` query routes the request over the source snapshot and returns the
//!    deadline-stamped fetch plan (circuit-open sources skipped, sorted by addon id).
//! 2. **REALIZE**: live mode realizes the plan through [`vortx_host_native::NativeFetcher`] (the
//!    Phase 1 Fetch seam, parallel with per-request budgets); replay mode classifies recorded
//!    bodies through the same public host validation (`body_to_items`), so the network is the ONLY
//!    thing held constant.
//! 3. **SETTLE**: a `settle_streams` query settles the outcomes (failures isolated, missing ->
//!    Timeout), ranks with the fixed-point ranker, and returns the updated breaker snapshot.
//!
//! Determinism claim made executable: with a fixed `now` and identical fetched bodies, two runs
//! emit BYTE-IDENTICAL documents. The integration tests assert `run1_bytes == run2_bytes` over the
//! embedded fixture, an on-disk replay, a real local HTTP server, and a record->replay round trip.
//!
//! The other two Phase 1 seams are wired too: [`vortx_host_native::SystemEnv`] supplies the default
//! live clock, and `--state-dir` persists the circuit-breaker snapshot across runs through
//! [`vortx_host_native::FileStorage`].

pub mod args;
pub mod fixture;
pub mod output;
pub mod record;

use std::collections::BTreeMap;

use serde_json::{json, Value};
use vortx_debrid::{DebridService, ResolveSource, ResolveStep};
use vortx_engine::{init_runtime, resolve_json, Engine};
use vortx_host_native::{FileStorage, NativeFetcher, Storage, SystemEnv};
use vortx_ranking::RankedStream;
use vortx_source::{
    settle_streams, BreakerRegistry, CircuitConfig, FetchOutcome, FetchRequest, ResourceKind,
    SourceEntry, SourceKind,
};

use crate::args::{Cli, DEFAULT_BUDGET_MS};
use crate::fixture::{Fixture, RunSpec};
use crate::output::{ranked_out, ResolveOutput, ResolveSection};

/// The storage bucket the circuit-breaker snapshot persists under with `--state-dir`.
pub const CIRCUIT_BUCKET: &str = "vortx:cli:circuit";

/// A runtime failure (exit code 1). Usage errors are [`args::UsageError`] (exit code 2).
#[derive(Debug)]
pub enum CliError {
    Fixture(String),
    Runtime(String),
    Engine(String),
    Storage(String),
}

impl std::fmt::Display for CliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CliError::Fixture(msg) => write!(f, "fixture: {msg}"),
            CliError::Runtime(msg) => write!(f, "runtime: {msg}"),
            CliError::Engine(msg) => write!(f, "engine: {msg}"),
            CliError::Storage(msg) => write!(f, "storage: {msg}"),
        }
    }
}

impl std::error::Error for CliError {}

/// How the plan gets realized this run.
enum Mode {
    /// Recorded bodies, no network. The hermetic proof path.
    Replay(Fixture),
    /// Real fan-out over the given `(addon_id, url)` sources through the host substrate.
    Live(Vec<(String, String)>),
}

/// Run one resolve round and return the output document as a JSON string (no trailing newline).
pub fn run(cli: &Cli) -> Result<String, CliError> {
    // ---- Resolve the mode and the run parameters (fixed clock, budget, services). -------------
    let mode = if !cli.addons.is_empty() {
        Mode::Live(cli.addons.clone())
    } else if let Some(dir) = &cli.replay {
        Mode::Replay(fixture::load(dir)?)
    } else {
        Mode::Replay(fixture::embedded())
    };

    let (now, budget_ms, services) = match &mode {
        Mode::Replay(f) => {
            let services = if cli.services.is_empty() {
                parse_services(&f.run.services)?
            } else {
                cli.services.clone()
            };
            (
                cli.now.unwrap_or(f.run.now),
                cli.budget_ms.unwrap_or(f.run.budget_ms),
                services,
            )
        }
        // The live clock enters through the host Env seam, never sampled ad hoc.
        Mode::Live(_) => (
            cli.now.unwrap_or_else(SystemEnv::unix_now),
            cli.budget_ms.unwrap_or(DEFAULT_BUDGET_MS),
            cli.services.clone(),
        ),
    };

    let registry: Vec<SourceEntry> = match &mode {
        Mode::Replay(f) => f.registry.clone(),
        Mode::Live(addons) => addons
            .iter()
            .map(|(id, url)| SourceEntry {
                id: id.clone(),
                url: url.clone(),
                kind: SourceKind::StremioAddon,
                capabilities: vec![ResourceKind::Stream],
                types: Vec::new(),
                id_prefixes: Vec::new(),
            })
            .collect(),
    };

    // ---- Circuit snapshot: read through the host Storage seam when a state dir is given. ------
    let circuit_cfg = CircuitConfig::default();
    let (circuit, store) = load_circuit(cli)?;

    // ---- PLAN through the engine's JSON query surface (the FFI shape the bridges call). -------
    let engine = init_runtime("owner", "Owner");
    let plan_response = query(
        &engine,
        &json!({
            "kind": "stream_load",
            "req": { "kind": "stream", "type": cli.content_type, "id": cli.meta_id },
            "registrySnapshot": registry,
            "circuitSnapshot": circuit,
            "circuitCfg": circuit_cfg,
            "now": now,
            "budgetMs": budget_ms,
        }),
        "stream_load_plan",
    )?;
    let plan: Vec<FetchRequest> = field(&plan_response, "requests")?;

    // ---- REALIZE: recorded bodies (replay), captured bodies (record), or the Fetch seam. ------
    let outcomes: Vec<(String, FetchOutcome)> = match &mode {
        Mode::Replay(f) => plan
            .iter()
            .filter_map(|req| {
                f.bodies
                    .get(&req.addon_id)
                    .map(|body| (req.addon_id.clone(), record::classify_body(&req.url, body)))
            })
            .collect(),
        Mode::Live(_) => {
            if let Some(dir) = &cli.record {
                let capture = record::capture_plan(&plan)?;
                fixture::record(
                    dir,
                    &Fixture {
                        registry: registry.clone(),
                        bodies: capture.bodies,
                        run: RunSpec {
                            now,
                            budget_ms,
                            services: services.iter().map(|s| s.as_wire().to_string()).collect(),
                        },
                    },
                )?;
                capture.outcomes
            } else {
                let fetcher = NativeFetcher::new()
                    .map_err(|e| CliError::Runtime(format!("build native fetcher: {e}")))?;
                fetcher.realize_plan(&plan)
            }
        }
    };

    // ---- SETTLE + RANK through the engine's JSON query surface. -------------------------------
    let outcome_map: BTreeMap<&str, &FetchOutcome> =
        outcomes.iter().map(|(id, o)| (id.as_str(), o)).collect();
    let settle_response = query(
        &engine,
        &json!({
            "kind": "settle_streams",
            "plan": plan,
            "outcomes": outcome_map,
            "circuitSnapshot": circuit,
            "circuitCfg": circuit_cfg,
            "now": now,
            "userServices": services,
        }),
        "settled_streams",
    )?;
    let ranked: Vec<RankedStream> = field(&settle_response, "ranked")?;
    let circuit_out: BreakerRegistry = field(&settle_response, "circuitSnapshot")?;

    // The engine's ranked decision indexes into the settled stream list; re-derive that list with
    // the SAME pure kernel settle (on a scratch breaker copy) to join names/urls/cache facts back
    // onto the ranking, exactly as a platform host does.
    let mut scratch = circuit.clone();
    let resolved = settle_streams(&plan, &outcomes, &mut scratch, &circuit_cfg, now);

    let mut streams = Vec::with_capacity(ranked.len());
    for (rank, entry) in ranked.iter().enumerate() {
        let stream = resolved.streams.get(entry.raw_index).ok_or_else(|| {
            CliError::Engine(format!(
                "ranked raw_index {} out of bounds ({} settled streams)",
                entry.raw_index,
                resolved.streams.len()
            ))
        })?;
        streams.push(ranked_out(rank, entry, stream, &services));
    }

    // ---- The kernel's debrid resolve plan over the ranked order. ------------------------------
    let resolve = debrid_section(&engine, &streams, &resolved.streams, &services, now)?;

    // ---- Persist the updated breaker snapshot through the Storage seam. -----------------------
    if let Some(store) = store {
        let snapshot = serde_json::to_string(&circuit_out)
            .map_err(|e| CliError::Storage(format!("serialize circuit snapshot: {e}")))?;
        store
            .set(CIRCUIT_BUCKET, Some(&snapshot))
            .map_err(|e| CliError::Storage(format!("persist circuit snapshot: {e}")))?;
    }

    let output = ResolveOutput {
        schema: "vortx-host-cli/resolve/1",
        meta: cli.meta_id.clone(),
        content_type: cli.content_type.clone(),
        now,
        services: services.iter().map(|s| s.as_wire().to_string()).collect(),
        plan,
        survivors: resolved.survivors,
        failed: resolved.failed,
        streams,
        resolve,
        circuit: circuit_out,
    };
    let rendered = if cli.pretty {
        serde_json::to_string_pretty(&output)
    } else {
        serde_json::to_string(&output)
    };
    rendered.map_err(|e| CliError::Engine(format!("serialize output: {e}")))
}

/// Parse the fixture run spec's service wire strings.
fn parse_services(wires: &[String]) -> Result<Vec<DebridService>, CliError> {
    wires
        .iter()
        .map(|w| {
            args::parse_service(w)
                .map_err(|e| CliError::Fixture(format!("run.json services: {}", e.0)))
        })
        .collect()
}

/// Read the persisted circuit snapshot (Storage seam), or start Closed-everywhere.
fn load_circuit(cli: &Cli) -> Result<(BreakerRegistry, Option<FileStorage>), CliError> {
    let Some(dir) = &cli.state_dir else {
        return Ok((BreakerRegistry::new(), None));
    };
    let store = FileStorage::open(dir)
        .map_err(|e| CliError::Storage(format!("open state dir {}: {e}", dir.display())))?;
    let circuit = match store
        .get(CIRCUIT_BUCKET)
        .map_err(|e| CliError::Storage(format!("read circuit snapshot: {e}")))?
    {
        Some(text) => serde_json::from_str(&text)
            .map_err(|e| CliError::Storage(format!("parse persisted circuit snapshot: {e}")))?,
        None => BreakerRegistry::new(),
    };
    Ok((circuit, Some(store)))
}

/// Drive one engine query through the JSON FFI surface and check the response kind.
fn query(engine: &Engine, request: &Value, expect_kind: &str) -> Result<Value, CliError> {
    let raw = resolve_json(engine, &request.to_string());
    let response: Value = serde_json::from_str(&raw)
        .map_err(|e| CliError::Engine(format!("unparseable engine response: {e}")))?;
    let kind = response["kind"].as_str().unwrap_or_default().to_string();
    if kind == "error" {
        let msg = response["error"].as_str().unwrap_or("unknown");
        return Err(CliError::Engine(format!(
            "engine rejected the query: {msg}"
        )));
    }
    if kind != expect_kind {
        return Err(CliError::Engine(format!(
            "expected a {expect_kind} response, got {kind}"
        )));
    }
    Ok(response)
}

/// Deserialize one field of an engine response.
fn field<T: serde::de::DeserializeOwned>(response: &Value, name: &str) -> Result<T, CliError> {
    serde_json::from_value(response[name].clone())
        .map_err(|e| CliError::Engine(format!("bad `{name}` in engine response: {e}")))
}

/// Build the debrid resolve section: candidate sources in ranked order, the kernel's ordered plan
/// over them (direct first, then debrid-cached, then debrid-uncached, then P2P), and the direct
/// https URL when the plan's first step already is one. Cached facts are the streams' OWN advertised
/// services intersected with the user's (facts, not tokens); a live unrestrict of a debrid-cached
/// step needs the Phase 2 `DebridStore` HTTP implementations.
fn debrid_section(
    engine: &Engine,
    ranked: &[output::RankedStreamOut],
    settled: &[vortx_protocol::Stream],
    services: &[DebridService],
    now: u64,
) -> Result<ResolveSection, CliError> {
    let mut sources: Vec<ResolveSource> = Vec::new();
    let mut cached: Vec<Value> = Vec::new();
    for entry in ranked {
        // The join is index-safe: every entry's raw_index was bounds-checked when it was built.
        let stream = &settled[entry.raw_index];
        if let Some(url) = &stream.url {
            sources.push(ResolveSource::Direct { url: url.clone() });
        } else if let Some(infohash) = &stream.info_hash {
            sources.push(ResolveSource::Magnet {
                infohash: infohash.clone(),
                file_idx: stream.file_idx,
            });
            if let Some(service) = entry.cache_status.services.first() {
                cached.push(json!({ "infohash": infohash, "service": service }));
            }
        }
    }
    if sources.is_empty() {
        return Ok(ResolveSection {
            sources,
            plan: Vec::new(),
            resolved_url: None,
        });
    }
    let response = query(
        engine,
        &json!({
            "kind": "debrid",
            "sources": sources,
            "userServices": services,
            "cached": cached,
            "now": now,
        }),
        "debrid",
    )?;
    let plan: Vec<ResolveStep> = field(&response, "plan")?;
    let resolved_url = plan
        .first()
        .and_then(|step| match sources.get(step.source_index) {
            Some(ResolveSource::Direct { url }) => Some(url.clone()),
            _ => None,
        });
    Ok(ResolveSection {
        sources,
        plan,
        resolved_url,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::output::CacheState;

    fn bare_cli(meta: &str) -> Cli {
        Cli {
            meta_id: meta.to_string(),
            content_type: "movie".to_string(),
            ..Cli::default()
        }
    }

    #[test]
    fn the_embedded_round_ranks_streams_with_cache_status() {
        let json = run(&bare_cli("tt0468569")).expect("embedded run");
        let doc: Value = serde_json::from_str(&json).expect("valid output json");
        let streams = doc["streams"].as_array().expect("streams array");
        assert!(!streams.is_empty(), "at least one ranked stream");
        // Every ranked stream carries the structured cacheStatus.
        for s in streams {
            assert!(
                s["cacheStatus"]["state"].is_string(),
                "structured cacheStatus"
            );
            assert!(s["cacheStatus"]["advertised"].is_array());
            assert!(s["score"].is_i64(), "fixed-point score");
        }
        // The recorded round has realdebrid enabled, so the 2160p remux is cached + ranked first.
        assert_eq!(doc["streams"][0]["cacheStatus"]["state"], "cached");
        assert_eq!(doc["streams"][0]["tier"], "uhd");
        // The direct https stream resolves to a playable URL through the kernel's plan.
        let url = doc["resolve"]["resolvedUrl"]
            .as_str()
            .expect("resolved url");
        assert!(
            url.starts_with("https://"),
            "direct https resolution: {url}"
        );
    }

    #[test]
    fn two_embedded_runs_are_byte_identical() {
        let a = run(&bare_cli("tt0468569")).expect("run 1");
        let b = run(&bare_cli("tt0468569")).expect("run 2");
        assert_eq!(a.as_bytes(), b.as_bytes());
    }

    #[test]
    fn service_flags_flip_cache_status_deterministically() {
        let mut cli = bare_cli("tt0468569");
        cli.services = vec![DebridService::Premiumize]; // overrides the fixture's realdebrid
        let json = run(&cli).expect("run");
        let doc: Value = serde_json::from_str(&json).expect("valid output json");
        for s in doc["streams"].as_array().expect("streams") {
            let state = s["cacheStatus"]["state"].as_str().expect("state");
            // Nothing in the fixture advertises premiumize: cached can never appear.
            assert_ne!(state, "cached");
        }
        assert_eq!(doc["services"][0], "premiumize");
    }

    #[test]
    fn cache_state_serializes_to_the_frozen_wire_tokens() {
        assert_eq!(
            serde_json::to_string(&CacheState::Cached).unwrap(),
            "\"cached\""
        );
        assert_eq!(
            serde_json::to_string(&CacheState::Unknown).unwrap(),
            "\"unknown\""
        );
    }
}
