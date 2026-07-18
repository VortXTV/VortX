//! Phase 3 acceptance: the byte-stable resolve proof, asserted over the REAL binary.
//!
//! The determinism claim under test: two runs with an identical FIXED `now` and identical fetched
//! bodies produce BYTE-IDENTICAL ranked output. It is proven four ways, strongest last:
//!
//! 1. the bare hermetic command (embedded fixture) is byte-stable and satisfies the acceptance
//!    shape (exit 0, >= 1 ranked stream with structured cacheStatus);
//! 2. an on-disk `--replay` of the same recorded round is byte-identical to the embedded run;
//! 3. a LIVE fan-out over a real local HTTP server (through the NativeFetcher substrate) is
//!    byte-stable across two full network round trips;
//! 4. a `--record`ed live round `--replay`s to the EXACT bytes the live run printed.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::thread;

use serde_json::Value;

const BIN: &str = env!("CARGO_BIN_EXE_vortx-host-cli");
const FIXED_NOW: &str = "1752600000";

fn run_cli(args: &[&str]) -> Output {
    Command::new(BIN)
        .args(args)
        .output()
        .expect("spawn vortx-host-cli")
}

fn stdout_of(out: &Output) -> &[u8] {
    assert!(
        out.status.success(),
        "cli failed (status {:?}): {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr)
    );
    &out.stdout
}

fn parse(bytes: &[u8]) -> Value {
    serde_json::from_slice(bytes).expect("stdout is one valid JSON document")
}

fn scratch_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "vortx-host-cli-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default()
    ));
    std::fs::create_dir_all(&dir).expect("create scratch dir");
    dir
}

/// The acceptance shape: at least one ranked stream, each carrying a structured cacheStatus.
fn assert_acceptance_shape(doc: &Value) {
    let streams = doc["streams"].as_array().expect("streams array");
    assert!(!streams.is_empty(), "at least one ranked stream");
    for stream in streams {
        let status = &stream["cacheStatus"];
        assert!(status.is_object(), "structured cacheStatus on every stream");
        assert!(status["state"].is_string());
        assert!(status["services"].is_array());
        assert!(status["advertised"].is_array());
        assert!(stream["score"].is_i64(), "fixed-point integer score");
    }
}

// -------------------------------------------------------------------------------------------
// 1. The bare hermetic command: exit 0, acceptance shape, byte-stable.
// -------------------------------------------------------------------------------------------

#[test]
fn bare_resolve_exits_zero_with_ranked_cache_status_streams_and_is_byte_stable() {
    let first = run_cli(&["resolve", "--meta", "tt0468569"]);
    let second = run_cli(&["resolve", "--meta", "tt0468569"]);
    let a = stdout_of(&first);
    let b = stdout_of(&second);
    assert_eq!(a, b, "two identical runs must be BYTE-IDENTICAL");

    let doc = parse(a);
    assert_acceptance_shape(&doc);
    // The recorded round has realdebrid active: the top stream is debrid-cached, and the kernel's
    // resolve plan lands on a direct https URL.
    assert_eq!(doc["streams"][0]["cacheStatus"]["state"], "cached");
    assert!(doc["resolve"]["resolvedUrl"]
        .as_str()
        .expect("a resolved url")
        .starts_with("https://"));
}

// -------------------------------------------------------------------------------------------
// 2. An on-disk replay of the same recorded round matches the embedded run byte for byte.
// -------------------------------------------------------------------------------------------

#[test]
fn on_disk_replay_is_byte_identical_to_the_embedded_round() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/tt0468569");
    let dir = scratch_dir("replay");
    std::fs::create_dir_all(dir.join("bodies")).expect("bodies dir");
    for file in ["registry.json", "run.json"] {
        std::fs::copy(src.join(file), dir.join(file)).expect("copy fixture file");
    }
    for body in ["fixture-direct.json", "fixture-hive.json"] {
        std::fs::copy(src.join("bodies").join(body), dir.join("bodies").join(body))
            .expect("copy body");
    }

    let dir_arg = dir.to_str().expect("utf8 scratch path");
    let embedded = run_cli(&["resolve", "--meta", "tt0468569"]);
    let replay_1 = run_cli(&["resolve", "--meta", "tt0468569", "--replay", dir_arg]);
    let replay_2 = run_cli(&["resolve", "--meta", "tt0468569", "--replay", dir_arg]);
    assert_eq!(
        stdout_of(&replay_1),
        stdout_of(&replay_2),
        "replay is byte-stable"
    );
    assert_eq!(
        stdout_of(&replay_1),
        stdout_of(&embedded),
        "the on-disk round and the embedded round are the same recorded inputs"
    );
    std::fs::remove_dir_all(&dir).expect("cleanup");
}

// -------------------------------------------------------------------------------------------
// A deterministic local HTTP fixture for the LIVE-path proofs: routes by first path segment.
// -------------------------------------------------------------------------------------------

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

    fn addon_arg(&self, id: &str, route: &str) -> String {
        format!("{id}=http://{}/{route}/manifest.json", self.addr)
    }
}

fn fixture_body(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("fixtures/tt0468569/bodies")
        .join(name);
    std::fs::read_to_string(path).expect("read fixture body")
}

fn handle_connection(mut stream: TcpStream) {
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
        "hive" => respond(&mut stream, 200, &fixture_body("fixture-hive.json")),
        "direct" => respond(&mut stream, 200, &fixture_body("fixture-direct.json")),
        _ => respond(&mut stream, 404, "not found"),
    }
}

fn respond(stream: &mut TcpStream, status: u16, body: &str) {
    let reason = if status == 200 { "OK" } else { "Not Found" };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
}

// -------------------------------------------------------------------------------------------
// 3. LIVE: two full fan-outs over a real server, through the NativeFetcher substrate, with a
//    fixed now, are byte-identical.
// -------------------------------------------------------------------------------------------

#[test]
fn live_fanout_over_a_real_server_is_byte_stable() {
    let server = FixtureServer::start();
    let hive = server.addon_arg("fixture-hive", "hive");
    let direct = server.addon_arg("fixture-direct", "direct");
    let args = [
        "resolve",
        "--meta",
        "tt0468569",
        "--now",
        FIXED_NOW,
        "--service",
        "realdebrid",
        "--addon",
        hive.as_str(),
        "--addon",
        direct.as_str(),
    ];
    let first = run_cli(&args);
    let second = run_cli(&args);
    assert_eq!(
        stdout_of(&first),
        stdout_of(&second),
        "identical fixed now + identical fetched bodies must be BYTE-IDENTICAL"
    );

    let doc = parse(stdout_of(&first));
    assert_acceptance_shape(&doc);
    assert_eq!(doc["survivors"].as_array().expect("survivors").len(), 2);
    assert_eq!(doc["streams"][0]["cacheStatus"]["state"], "cached");
}

// -------------------------------------------------------------------------------------------
// 4. RECORD -> REPLAY: a recorded live round replays to the exact bytes the live run printed.
// -------------------------------------------------------------------------------------------

#[test]
fn a_recorded_live_round_replays_byte_identically() {
    let server = FixtureServer::start();
    let hive = server.addon_arg("fixture-hive", "hive");
    let direct = server.addon_arg("fixture-direct", "direct");
    let dir = scratch_dir("record");
    let dir_arg = dir.to_str().expect("utf8 scratch path").to_string();

    let recorded = run_cli(&[
        "resolve",
        "--meta",
        "tt0468569",
        "--now",
        FIXED_NOW,
        "--service",
        "realdebrid",
        "--addon",
        hive.as_str(),
        "--addon",
        direct.as_str(),
        "--record",
        dir_arg.as_str(),
    ]);
    // The replay reads now / budget / services back from the recorded run.json: no network, no
    // flags to repeat, and the SAME bytes out.
    let replayed = run_cli(&[
        "resolve",
        "--meta",
        "tt0468569",
        "--replay",
        dir_arg.as_str(),
    ]);
    assert_eq!(
        stdout_of(&recorded),
        stdout_of(&replayed),
        "the record->replay round trip must reproduce the live bytes exactly"
    );
    std::fs::remove_dir_all(&dir).expect("cleanup");
}

// -------------------------------------------------------------------------------------------
// Supporting seams: the Storage-backed circuit snapshot persists, and usage errors exit 2.
// -------------------------------------------------------------------------------------------

#[test]
fn the_circuit_snapshot_persists_across_runs_through_the_storage_seam() {
    let dir = scratch_dir("state");
    let dir_arg = dir.to_str().expect("utf8 scratch path");
    let out = run_cli(&["resolve", "--meta", "tt0468569", "--state-dir", dir_arg]);
    stdout_of(&out);
    // The bucket exists and parses as a breaker registry document.
    let entries: Vec<_> = std::fs::read_dir(&dir)
        .expect("state dir")
        .filter_map(Result::ok)
        .collect();
    assert!(!entries.is_empty(), "the storage seam wrote a bucket");
    let stored = std::fs::read_to_string(entries[0].path()).expect("read bucket");
    let registry: Value = serde_json::from_str(&stored).expect("bucket is JSON");
    assert!(registry.is_object());
    // A second run over the persisted snapshot still succeeds and stays byte-stable.
    let again = run_cli(&["resolve", "--meta", "tt0468569", "--state-dir", dir_arg]);
    assert_eq!(stdout_of(&out), stdout_of(&again));
    std::fs::remove_dir_all(&dir).expect("cleanup");
}

#[test]
fn usage_errors_exit_2_and_print_usage() {
    let out = run_cli(&["resolve"]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("--meta"),
        "stderr explains the missing flag"
    );
    assert!(stderr.contains("USAGE"), "stderr carries the usage text");
    assert!(
        out.stdout.is_empty(),
        "stdout stays reserved for the document"
    );
}
