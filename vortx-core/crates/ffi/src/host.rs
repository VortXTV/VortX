//! The host seam entry: `vortx_host_resolve_json`, the one extern C function that initializes the
//! Phase 1 host substrate (Fetch / Env / Storage) and runs a full resolve round through it.
//!
//! The kernel handle stays pure, so the seams enter HERE, per call:
//!
//! - **Fetch**: `vortx_host_native::NativeFetcher` realizes the kernel's fetch plan (parallel,
//!   per-request budgets) when live `addons` are given.
//! - **Env**: `vortx_host_native::SystemEnv` supplies the wall clock when `now` is not fixed.
//! - **Storage**: `vortx_host_native::FileStorage` persists the circuit-breaker snapshot across
//!   rounds when `stateDir` is given.
//!
//! The round itself is `vortx_host_cli::run`, the Phase 3 proof loop (plan through the engine's
//! `stream_load` query, realize through the Fetch seam or a recorded fixture, settle + rank through
//! `settle_streams`, then the kernel's debrid resolve plan). This module is a thin C shell over
//! that tested loop: it marshals one JSON request in and the proof's byte-stable resolve document
//! out, and adds NO resolve logic of its own.
//!
//! Request shape (all fields except `meta` optional):
//!
//! ```json
//! {
//!   "meta": "tt0468569",
//!   "type": "movie",
//!   "addons": [["cinemeta", "https://addon.example/manifest.json"]],
//!   "services": ["realdebrid"],
//!   "now": 1770000000,
//!   "budgetMs": 5000,
//!   "stateDir": "/path/for/circuit-snapshot",
//!   "replayDir": "/path/to/recorded/fixture"
//! }
//! ```
//!
//! With no `addons` and no `replayDir` the embedded fixture is replayed, so the call is hermetic
//! and deterministic (the smoke test pins two calls byte-identical). Errors come back as
//! `{"kind":"error","error":"..."}`, the same error envelope as `vortx_resolve_json`.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;

use serde::Deserialize;
use vortx_host_cli::args::{parse_service, Cli};

/// One host resolve request, deserialized from the C caller's JSON.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HostResolveRequest {
    /// The content id to resolve (e.g. `tt0468569`). Required.
    meta: String,
    /// The content type segment of the resource path. Defaults to `movie`.
    #[serde(rename = "type", default = "default_content_type")]
    content_type: String,
    /// Live sources to fan out over, as `[addonId, transportUrl]` pairs. Empty = replay mode.
    #[serde(default)]
    addons: Vec<(String, String)>,
    /// Enabled debrid services as the frozen wire strings (`realdebrid`, `torbox`, ...).
    #[serde(default)]
    services: Vec<String>,
    /// A fixed clock in Unix seconds. Omitted = the fixture's recorded clock (replay) or the
    /// SystemEnv wall clock (live).
    #[serde(default)]
    now: Option<u64>,
    /// Per-request fetch budget override in milliseconds.
    #[serde(default)]
    budget_ms: Option<u64>,
    /// Persist the circuit-breaker snapshot across rounds through the FileStorage seam.
    #[serde(default)]
    state_dir: Option<PathBuf>,
    /// Replay a recorded fixture directory instead of fetching.
    #[serde(default)]
    replay_dir: Option<PathBuf>,
}

fn default_content_type() -> String {
    "movie".to_string()
}

/// Build the `{"kind":"error","error":...}` envelope (the same shape `vortx_resolve_json` uses).
fn error_json(message: &str) -> String {
    serde_json::json!({ "kind": "error", "error": message }).to_string()
}

/// Move a Rust string into a heap C string the caller frees with `vortx_string_free`. The JSON we
/// emit never contains an interior NUL; if one somehow appears, a valid error string goes out
/// instead of a panic.
fn to_c(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| {
            CString::new(r#"{"kind":"error","error":"nul in output"}"#).expect("static cstr")
        })
        .into_raw()
}

/// The checked body of [`vortx_host_resolve_json`]: marshal the request, run the proof loop,
/// marshal the document (or the error envelope) back.
///
/// # Safety
/// `request_json` must be null or a valid NUL-terminated C string.
unsafe fn host_resolve(request_json: *const c_char) -> String {
    if request_json.is_null() {
        return error_json("null request");
    }
    // SAFETY: non-null per the check; the caller guarantees a valid NUL-terminated string.
    let Ok(raw) = CStr::from_ptr(request_json).to_str() else {
        return error_json("non-utf8 request");
    };
    let request: HostResolveRequest = match serde_json::from_str(raw) {
        Ok(request) => request,
        Err(e) => return error_json(&format!("bad request json: {e}")),
    };
    if request.meta.is_empty() {
        return error_json("`meta` is required");
    }
    if request.replay_dir.is_some() && !request.addons.is_empty() {
        return error_json(
            "`replayDir` and `addons` are mutually exclusive (replay never fetches)",
        );
    }
    let mut services = Vec::with_capacity(request.services.len());
    for wire in &request.services {
        match parse_service(wire) {
            Ok(service) => services.push(service),
            Err(e) => return error_json(&e.0),
        }
    }
    let cli = Cli {
        meta_id: request.meta,
        content_type: request.content_type,
        now: request.now,
        budget_ms: request.budget_ms,
        services,
        addons: request.addons,
        replay: request.replay_dir,
        record: None,
        state_dir: request.state_dir,
        pretty: false,
    };
    match vortx_host_cli::run(&cli) {
        Ok(document) => document,
        Err(e) => error_json(&e.to_string()),
    }
}

/// Run one full resolve round through the host seams and return the byte-stable resolve document
/// as an owned JSON string (schema `vortx-host-cli/resolve/1`), or `{"kind":"error",...}`.
///
/// This call does real I/O (network fan-out in live mode, disk when `stateDir` is set), so unlike
/// the pure kernel symbols it wraps everything in `catch_unwind`: a panic surfaces as an error
/// envelope and never unwinds across the C boundary.
///
/// # Safety
/// `request_json` must be null or a valid NUL-terminated C string that outlives the call. The
/// returned pointer must be freed exactly once with `vortx_string_free`.
#[no_mangle]
pub unsafe extern "C" fn vortx_host_resolve_json(request_json: *const c_char) -> *mut c_char {
    let outcome = catch_unwind(AssertUnwindSafe(|| host_resolve(request_json)));
    to_c(outcome.unwrap_or_else(|_| error_json("panic in host resolve")))
}
