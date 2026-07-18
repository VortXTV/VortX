//! Phase 1 acceptance: the native host substrate driven end to end against a DETERMINISTIC local
//! fixture (a real TCP server this test owns, so no network flakiness and no third-party servers).
//!
//! Proves, per the phase spec:
//! 1. the kernel's `run_fanout` through the host [`NativeFetcher`] settles partial results (a good
//!    source's items survive a malformed, an erroring, and a budget-overrunning peer);
//! 2. the parallel realization path resolves a whole plan within the slowest single budget, not the
//!    sum, while honoring per-request budgets;
//! 3. a circuit-breaker transition (Closed -> Open) is observed through the host path, the opened
//!    source is skipped while cooling, and it is re-planned after the cooldown;
//! 4. state emitted by the kernel's `get_state_delta_json` round-trips BYTE-EQUAL through the
//!    file-backed [`Storage`] implementation, across a reopened store.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, Instant};

use vortx_engine::{dispatch_json, get_state_delta_json, init_runtime, InMemoryEnv};
use vortx_host_native::{FileStorage, NativeFetcher, Storage, SystemEnv};
use vortx_source::{
    parse_stream_item, plan_fanout, run_fanout, settle_fanout, BreakerRegistry, BreakerState,
    CircuitConfig, Fetch, FetchOutcome, FetchRequest,
};

/// How long the fixture's `/slow/` route holds a connection open: far past every budget used here,
/// so a settled `Timeout` can only mean the budget fired, never that the server answered late.
const SLOW_HOLD_MS: u64 = 8_000;

const STREAM_BODY: &str = r#"{"streams":[{"name":"Fixture 2160p","url":"https://cdn.example/a.mp4"},{"name":"Fixture 1080p","url":"https://cdn.example/b.mp4"}]}"#;

/// A deterministic single-purpose HTTP fixture: routes are keyed by the first path segment.
struct FixtureServer {
    addr: SocketAddr,
}

impl FixtureServer {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind fixture listener");
        let addr = listener.local_addr().expect("fixture local addr");
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                thread::spawn(move || handle_connection(stream));
            }
        });
        Self { addr }
    }

    /// A stream-resource URL under the given behavior route (`good`, `malformed`, `slow`, `error`).
    fn stream_url(&self, route: &str) -> String {
        format!("http://{}/{}/stream/movie/tt0468569.json", self.addr, route)
    }
}

fn handle_connection(mut stream: TcpStream) {
    // Read until the end of the request head; GET requests carry no body.
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
    let head = String::from_utf8_lossy(&buf);
    let path = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .unwrap_or("/")
        .to_string();
    let route = path.split('/').find(|s| !s.is_empty()).unwrap_or("");
    match route {
        "good" => respond(&mut stream, 200, STREAM_BODY),
        "malformed" => respond(&mut stream, 200, "this is not the json you planned for"),
        "slow" => {
            thread::sleep(Duration::from_millis(SLOW_HOLD_MS));
            respond(&mut stream, 200, STREAM_BODY);
        }
        "error" => respond(&mut stream, 500, r#"{"err":"fixture 500"}"#),
        _ => respond(&mut stream, 404, "not found"),
    }
}

fn respond(stream: &mut TcpStream, status: u16, body: &str) {
    let reason = match status {
        200 => "OK",
        500 => "Internal Server Error",
        _ => "Not Found",
    };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
}

fn candidates(pairs: &[(&str, String)]) -> Vec<(String, String)> {
    pairs
        .iter()
        .map(|(id, url)| (id.to_string(), url.clone()))
        .collect()
}

// ---------------------------------------------------------------------------------------------
// 1. The kernel's own run_fanout, driven through the host Fetch, settles partial results.
// ---------------------------------------------------------------------------------------------

#[test]
fn run_fanout_through_native_fetch_settles_partial_results_within_budget() {
    let server = FixtureServer::start();
    let fetcher = NativeFetcher::new().expect("build native fetcher");
    let mut breakers = BreakerRegistry::new();

    let agg = run_fanout(
        &fetcher,
        &candidates(&[
            ("good", server.stream_url("good")),
            ("malformed", server.stream_url("malformed")),
            ("slow", server.stream_url("slow")),
            ("error", server.stream_url("error")),
        ]),
        &mut breakers,
        &CircuitConfig::default(),
        1_000,
        500, // per-request budget: the slow route (8s) must settle as Timeout
    );

    // Partial settlement: the good source's items survive every kind of failing peer.
    assert_eq!(agg.survivors, vec!["good"]);
    assert_eq!(agg.items.len(), 2);
    for item in &agg.items {
        assert!(
            parse_stream_item(item).is_some(),
            "kernel rejected host item key {item}"
        );
    }
    let failed: Vec<(&str, String)> = agg
        .failed
        .iter()
        .map(|f| (f.addon_id.as_str(), format!("{:?}", f.reason)))
        .collect();
    assert_eq!(
        failed,
        vec![
            ("error", "Error".to_string()),
            ("malformed", "Malformed".to_string()),
            ("slow", "Timeout".to_string()),
        ]
    );
    // Every failure was charged to its breaker; the survivor's stayed clean.
    assert_eq!(breakers.get("slow").unwrap().consecutive_failures, 1);
    assert_eq!(breakers.get("good").unwrap().consecutive_failures, 0);
}

// ---------------------------------------------------------------------------------------------
// 2. Parallel realization: a whole plan resolves within the slowest budget, not the sum.
// ---------------------------------------------------------------------------------------------

#[test]
fn parallel_realization_is_bounded_by_one_budget_not_the_sum() {
    let server = FixtureServer::start();
    let fetcher = NativeFetcher::new().expect("build native fetcher");

    let budget_ms = 1_000;
    let plan: Vec<FetchRequest> = [
        ("slow-1", server.stream_url("slow")),
        ("slow-2", server.stream_url("slow")),
        ("slow-3", server.stream_url("slow")),
        ("slow-4", server.stream_url("slow")),
        ("good", server.stream_url("good")),
    ]
    .into_iter()
    .map(|(id, url)| FetchRequest {
        addon_id: id.to_string(),
        url,
        budget_ms,
    })
    .collect();

    let started = Instant::now();
    let outcomes = fetcher.realize_plan(&plan);
    let elapsed = started.elapsed();

    // Four sequential 1s budgets would take >= 4s; the fixture holds slow connections for 8s.
    // Finishing well under both proves per-request budgets fired AND requests ran concurrently.
    assert!(
        elapsed < Duration::from_millis(3_000),
        "parallel plan took {elapsed:?}; budgets are not being applied concurrently"
    );

    // Outcomes return in plan order with each request classified under its own budget.
    let by_id: Vec<(&str, &FetchOutcome)> =
        outcomes.iter().map(|(id, o)| (id.as_str(), o)).collect();
    assert_eq!(by_id.len(), 5);
    for slow in ["slow-1", "slow-2", "slow-3", "slow-4"] {
        let outcome = &outcomes.iter().find(|(id, _)| id == slow).unwrap().1;
        assert_eq!(
            *outcome,
            FetchOutcome::Timeout,
            "{slow} should overrun its budget"
        );
    }
    let good = &outcomes.iter().find(|(id, _)| id == "good").unwrap().1;
    assert!(matches!(good, FetchOutcome::Ok { items } if items.len() == 2));

    // And the kernel settles those host outcomes exactly as its contract says.
    let mut breakers = BreakerRegistry::new();
    let agg = settle_fanout(
        &plan,
        &outcomes,
        &mut breakers,
        &CircuitConfig::default(),
        1_000,
    );
    assert_eq!(agg.survivors, vec!["good"]);
    assert_eq!(agg.failed.len(), 4);
    assert_eq!(agg.items.len(), 2);
}

// ---------------------------------------------------------------------------------------------
// 3. Breaker lifecycle through the host path: open observed, skipped while cooling, retried after.
// ---------------------------------------------------------------------------------------------

#[test]
fn breaker_transition_is_observed_skipped_then_retried_after_cooldown() {
    let server = FixtureServer::start();
    let fetcher = NativeFetcher::new().expect("build native fetcher");
    let cfg = CircuitConfig {
        failure_threshold: 2,
        cooldown_secs: 300,
    };
    let mut breakers = BreakerRegistry::new();
    let cands = candidates(&[
        ("flaky", server.stream_url("error")),
        ("good", server.stream_url("good")),
    ]);

    // Round 1: first failure, breaker still Closed, no transition.
    let r1 = fetcher.run_fanout_parallel(&cands, &mut breakers, &cfg, 1_000, 500);
    assert_eq!(r1.planned.len(), 2);
    assert!(r1.transitions.is_empty());
    assert_eq!(r1.aggregate.survivors, vec!["good"]);

    // Round 2: second consecutive failure crosses the threshold; the transition is surfaced.
    let r2 = fetcher.run_fanout_parallel(&cands, &mut breakers, &cfg, 1_001, 500);
    assert_eq!(r2.transitions.len(), 1);
    assert_eq!(r2.transitions[0].addon_id, "flaky");
    assert_eq!(r2.transitions[0].from, BreakerState::Closed);
    assert_eq!(r2.transitions[0].to, BreakerState::Open);

    // Round 3: while cooling down, the open source is not even planned (never fetched).
    let r3 = fetcher.run_fanout_parallel(&cands, &mut breakers, &cfg, 1_050, 500);
    assert_eq!(
        r3.planned
            .iter()
            .map(|r| r.addon_id.as_str())
            .collect::<Vec<_>>(),
        vec!["good"]
    );
    assert!(r3.transitions.is_empty());
    assert_eq!(r3.aggregate.survivors, vec!["good"]);

    // Round 4: past the cooldown the kernel allows the one trial, so it is planned again.
    let plan = plan_fanout(&cands, &breakers, &cfg, 1_301, 500);
    assert_eq!(
        plan.iter().map(|r| r.addon_id.as_str()).collect::<Vec<_>>(),
        vec!["flaky", "good"]
    );
}

// ---------------------------------------------------------------------------------------------
// 4. GT3: kernel state deltas persist byte-equal through the file-backed Storage.
// ---------------------------------------------------------------------------------------------

#[test]
fn state_delta_round_trips_byte_equal_through_file_storage() {
    // Drive the kernel to a real dirty state, exactly as a platform host would over the FFI.
    let mut engine = init_runtime("owner", "Owner");
    let result = dispatch_json(
        &mut engine,
        r#"{"type":"add_profile","id":"kid","name":"Kid"}"#,
        &InMemoryEnv::new(1_000),
    );
    assert!(result.contains("\"ok\":true"), "dispatch failed: {result}");

    let delta = get_state_delta_json(&mut engine);
    assert_ne!(delta, "{}", "the dispatch must dirty the delta");
    assert!(delta.contains("kid"));

    // Persist the delta into a file-backed bucket, then read it back through a FRESH handle over
    // the same root: the stored document must be byte-equal to what the kernel emitted.
    let root = std::env::temp_dir().join(format!(
        "vortx-host-native-acceptance-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default()
    ));
    let store = FileStorage::open(&root).expect("open file storage");
    store
        .set("vortx:state:owner", Some(&delta))
        .expect("persist delta");

    let reopened = FileStorage::open(&root).expect("reopen file storage");
    let read_back = reopened
        .get("vortx:state:owner")
        .expect("read persisted delta")
        .expect("bucket must exist");
    assert_eq!(read_back, delta, "persisted delta is not byte-equal");
    assert_eq!(read_back.as_bytes(), delta.as_bytes());

    // The dirty set cleared on take: a second delta is empty and must NOT disturb the stored one.
    let empty = get_state_delta_json(&mut engine);
    assert!(!empty.contains("kid"));
    assert_eq!(
        reopened.get("vortx:state:owner").unwrap().as_deref(),
        Some(delta.as_str())
    );

    std::fs::remove_dir_all(&root).expect("cleanup scratch root");
}

// ---------------------------------------------------------------------------------------------
// Supporting seams: the real clock drives a kernel dispatch; dead endpoints classify as Error.
// ---------------------------------------------------------------------------------------------

#[test]
fn system_env_drives_a_kernel_dispatch() {
    let mut engine = init_runtime("owner", "Owner");
    let result = dispatch_json(
        &mut engine,
        r#"{"type":"add_profile","id":"clock","name":"Clock"}"#,
        &SystemEnv::new(),
    );
    assert!(
        result.contains("\"ok\":true"),
        "dispatch under SystemEnv failed: {result}"
    );
}

#[test]
fn connection_refused_classifies_as_error_not_timeout() {
    // Bind then drop a listener: the port is real but nothing accepts, so connects are refused
    // immediately. That is a transport Error, not a budget Timeout.
    let port = {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind probe listener");
        listener.local_addr().expect("probe addr").port()
    };
    let fetcher = NativeFetcher::new().expect("build native fetcher");
    let outcome = fetcher.fetch(&FetchRequest {
        addon_id: "dead".to_string(),
        url: format!("http://127.0.0.1:{port}/dead/stream/movie/tt1.json"),
        budget_ms: 2_000,
    });
    assert_eq!(outcome, FetchOutcome::Error);
}
