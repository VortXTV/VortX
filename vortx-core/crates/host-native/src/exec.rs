//! The native [`JsExec`] host: a QuickJS (rquickjs / QuickJS-NG, no JIT) sandbox behind the kernel's
//! synchronous exec boundary. The kernel PLANS (`plan_exec` -> `ExecRequest`s), this module EXECUTES,
//! the kernel SETTLES (`settle_streams` over the bridged outcomes): the exact shape of the Fetch seam,
//! applied to Nuvio provider scripts.
//!
//! Sandbox contract, per execution (one fresh `Runtime` + `Context` per exec, so nothing leaks between
//! providers and two identical runs see identical worlds):
//!
//! - **Script pinning**: only sources registered through [`QuickJsExec::register_script`] can run, keyed
//!   by their sha256; the request's `script_hash` must name one, so the host can never be steered into
//!   executing bytes the pack was not installed with.
//! - **Budget** (`budget_ms`): a QuickJS interrupt handler enforces the wall-time deadline (compute), and
//!   the net shim clamps every request to the remaining budget (I/O) -> [`ExecOutcome::Timeout`].
//! - **Memory**: a per-runtime cap -> [`ExecOutcome::Oom`] (QuickJS surfaces the failed allocation as a
//!   null throw, which cannot be forged into anything else useful by the script).
//! - **Network**: the `fetch` shim funnels EVERY request through the kernel-stamped [`NetPolicy`]
//!   (host allowlist + request count + byte caps) before the [`ExecNet`] transport sees it. A violation
//!   is STICKY: it denies the rest of the exec and classifies the whole run [`ExecOutcome::Denied`],
//!   even if the script swallows the thrown error, so a provider cannot probe-and-continue.
//! - **Shims**: `fetch` (Response-like: ok/status/text()/json()/headers.get), `console.*` (no-op),
//!   `atob`/`btoa`, and a CommonJS-style `module.exports` so providers can export `getStreams` either
//!   way. Deliberately minimal; a scraper needing more declares it and the shim grows deliberately.
//!
//! The Apple JavaScriptCore implementation is a later host-specific piece; it slots in behind the same
//! [`JsExec`] trait without kernel changes.

use std::collections::BTreeMap;
use std::time::Duration;

// The QuickJS executor and its digest/JS-runtime deps are feature-gated so an Apple (JavaScriptCore)
// host can build this crate with `--no-default-features` and link neither rquickjs nor sha2. Only the
// transports below (ExecNet / RecordedNet / HttpNet), which use tokio + reqwest + std, stay
// unconditional, so a JavaScriptCore host still gets a real ExecNet to drive its own JsExec.
#[cfg(feature = "quickjs")]
use std::cell::RefCell;
#[cfg(feature = "quickjs")]
use std::rc::Rc;
#[cfg(feature = "quickjs")]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(feature = "quickjs")]
use std::sync::Arc;
#[cfg(feature = "quickjs")]
use std::time::Instant;

#[cfg(feature = "quickjs")]
use rquickjs::{CatchResultExt, CaughtError, Context, Exception, Function, Promise, Runtime};
#[cfg(feature = "quickjs")]
use sha2::{Digest, Sha256};
#[cfg(feature = "quickjs")]
use vortx_exec::{
    fetch_options_headers, url_host, ExecOutcome, ExecRequest, JsExec, NetPolicy, NetTrace,
    NetTraceEntry,
};

/// Default per-exec memory cap (32 MiB): a scraper parses small documents; far more is a leak or abuse.
#[cfg(feature = "quickjs")]
pub const DEFAULT_MEMORY_LIMIT_BYTES: usize = 32 * 1024 * 1024;

/// One network response at the exec net boundary. `headers` keys are expected lower-cased (the shim's
/// `headers.get` lower-cases lookups).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetResponse {
    pub status: u16,
    pub body: String,
    pub headers: BTreeMap<String, String>,
}

/// A transport failure at the exec net boundary. `Timeout` means the request could not complete inside
/// the remaining exec budget (classified as the whole exec timing out); `Transport` is any other
/// network failure (thrown into the script as a catchable error, like a failed `fetch` in a browser).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NetError {
    Timeout,
    Transport(String),
}

/// The transport the exec net shim drives AFTER policy has allowed a request. Implementations do the
/// bytes only; ALL policy (allowlist, counts, caps, budget clamping) is enforced in the shim before
/// this is called, so a transport can never widen the sandbox.
pub trait ExecNet {
    fn get(
        &self,
        url: &str,
        headers: &BTreeMap<String, String>,
        timeout_ms: u64,
    ) -> Result<NetResponse, NetError>;
}

/// A recorded transport: exact-URL -> response, no network. The hermetic proof path (tests, replay);
/// an unrecorded URL is a transport error, so a drifting provider fails loudly instead of silently.
#[derive(Debug, Clone, Default)]
pub struct RecordedNet {
    map: BTreeMap<String, NetResponse>,
}

impl RecordedNet {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a 200 text/JSON body for `url`.
    pub fn with_body(mut self, url: impl Into<String>, body: impl Into<String>) -> Self {
        self.map.insert(
            url.into(),
            NetResponse {
                status: 200,
                body: body.into(),
                headers: BTreeMap::new(),
            },
        );
        self
    }

    /// Record a full response for `url`.
    pub fn with_response(mut self, url: impl Into<String>, response: NetResponse) -> Self {
        self.map.insert(url.into(), response);
        self
    }
}

impl ExecNet for RecordedNet {
    fn get(
        &self,
        url: &str,
        _headers: &BTreeMap<String, String>,
        _timeout_ms: u64,
    ) -> Result<NetResponse, NetError> {
        self.map
            .get(url)
            .cloned()
            .ok_or_else(|| NetError::Transport(format!("unrecorded url: {url}")))
    }
}

/// The live transport: tokio + reqwest(rustls) behind the synchronous exec boundary, the same
/// one-runtime `block_on` bridge as [`crate::NativeFetcher`]. Requests carry the script's headers
/// (Referer / User-Agent, which hosters require) and are clamped to the remaining exec budget.
#[derive(Debug)]
pub struct HttpNet {
    runtime: tokio::runtime::Runtime,
    client: reqwest::Client,
}

impl HttpNet {
    pub fn new() -> Result<Self, crate::FetchInitError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()?;
        let client = reqwest::Client::builder().build()?;
        Ok(Self { runtime, client })
    }
}

impl ExecNet for HttpNet {
    fn get(
        &self,
        url: &str,
        headers: &BTreeMap<String, String>,
        timeout_ms: u64,
    ) -> Result<NetResponse, NetError> {
        self.runtime.block_on(async {
            let mut request = self.client.get(url);
            for (name, value) in headers {
                request = request.header(name.as_str(), value.as_str());
            }
            let send = async {
                let response = request
                    .send()
                    .await
                    .map_err(|e| NetError::Transport(e.to_string()))?;
                let status = response.status().as_u16();
                let headers = response
                    .headers()
                    .iter()
                    .filter_map(|(k, v)| {
                        v.to_str()
                            .ok()
                            .map(|value| (k.as_str().to_ascii_lowercase(), value.to_string()))
                    })
                    .collect();
                let body = response
                    .text()
                    .await
                    .map_err(|e| NetError::Transport(e.to_string()))?;
                Ok(NetResponse {
                    status,
                    body,
                    headers,
                })
            };
            match tokio::time::timeout(Duration::from_millis(timeout_ms), send).await {
                Err(_elapsed) => Err(NetError::Timeout),
                Ok(result) => result,
            }
        })
    }
}

/// Per-exec shim bookkeeping: what the script consumed and whether it violated policy. `denied` is
/// sticky: once set, every further net call refuses and the final classification is `Denied`
/// regardless of what the script did with the thrown error.
#[cfg(feature = "quickjs")]
#[derive(Debug, Default)]
struct ShimState {
    requests_issued: u32,
    total_bytes: u64,
    denied: Option<String>,
    trace: Vec<NetTraceEntry>,
}

/// How a JS evaluation failed, before the flag-based classification is applied.
#[cfg(feature = "quickjs")]
enum JsFailure {
    /// QuickJS threw a NULL value: the signature of an allocation failure under a memory cap.
    NullException,
    /// A real thrown error (or engine error) with a printable message.
    Message(String),
}

/// The QuickJS implementation of the kernel's [`JsExec`] boundary.
#[cfg(feature = "quickjs")]
pub struct QuickJsExec {
    scripts: BTreeMap<String, String>,
    net: Arc<dyn ExecNet>,
    memory_limit_bytes: usize,
}

#[cfg(feature = "quickjs")]
impl QuickJsExec {
    /// Build an executor over a net transport with the default memory cap.
    pub fn new(net: Arc<dyn ExecNet>) -> Self {
        Self {
            scripts: BTreeMap::new(),
            net,
            memory_limit_bytes: DEFAULT_MEMORY_LIMIT_BYTES,
        }
    }

    /// Override the per-exec memory cap (tests use a tiny cap to prove the Oom classification).
    pub fn with_memory_limit(mut self, bytes: usize) -> Self {
        self.memory_limit_bytes = bytes;
        self
    }

    /// Pin a provider script: the source is stored keyed by ITS OWN sha256 (lowercase hex), which is
    /// returned. Because the executor computes the digest itself, an [`ExecRequest::script_hash`] can
    /// only ever name bytes that were actually registered; there is no way to alias a hash onto
    /// different source.
    pub fn register_script(&mut self, source: &str) -> String {
        let digest = Sha256::digest(source.as_bytes());
        let hash: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        self.scripts.insert(hash.clone(), source.to_string());
        hash
    }

    /// Execute one planned request and return the outcome plus the net-shim audit trail.
    pub fn exec_traced(&self, req: &ExecRequest) -> (ExecOutcome, NetTrace) {
        let Some(source) = self.scripts.get(&req.script_hash) else {
            return (
                ExecOutcome::Threw {
                    message: format!("no registered script for hash {}", req.script_hash),
                },
                NetTrace::default(),
            );
        };

        let runtime = match Runtime::new() {
            Ok(rt) => rt,
            Err(e) => {
                return (
                    ExecOutcome::Threw {
                        message: format!("quickjs runtime init failed: {e}"),
                    },
                    NetTrace::default(),
                )
            }
        };
        runtime.set_memory_limit(self.memory_limit_bytes);

        // The wall-time budget: QuickJS polls the interrupt handler during execution; past the
        // deadline it raises an uncatchable interrupt and we classify Timeout via the flag (the
        // interrupt itself is not distinguishable from other errors by message alone).
        let deadline = Instant::now() + Duration::from_millis(req.budget_ms);
        let timed_out = Arc::new(AtomicBool::new(false));
        let interrupt_flag = timed_out.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            if Instant::now() >= deadline {
                interrupt_flag.store(true, Ordering::SeqCst);
                true
            } else {
                false
            }
        })));

        let context = match Context::full(&runtime) {
            Ok(ctx) => ctx,
            Err(e) => {
                return (
                    ExecOutcome::Threw {
                        message: format!("quickjs context init failed: {e}"),
                    },
                    NetTrace::default(),
                )
            }
        };

        let state = Rc::new(RefCell::new(ShimState::default()));
        let result: Result<String, JsFailure> = context.with(|ctx| {
            install_net_shim(
                &ctx,
                self.net.clone(),
                req.net_policy.clone(),
                state.clone(),
                deadline,
                timed_out.clone(),
            )
            .map_err(|e| JsFailure::Message(format!("net shim install failed: {e}")))?;
            ctx.eval::<(), _>(PRELUDE)
                .catch(&ctx)
                .map_err(caught_to_failure)?;
            ctx.eval::<(), _>(source.as_bytes())
                .catch(&ctx)
                .map_err(caught_to_failure)?;
            let promise: Promise = ctx
                .eval(harness(&req.entrypoint, &req.args_json).as_bytes())
                .catch(&ctx)
                .map_err(caught_to_failure)?;
            promise.finish::<String>().catch(&ctx).map_err(caught_to_failure)
        });

        // Classification precedence: the budget and the policy are the HOST's verdicts and outrank
        // whatever the script did with the thrown errors (a script that catches the deny and returns
        // [] is still Denied; one that catches and stalls is still Timeout).
        let state = state.borrow();
        let trace = NetTrace {
            requests: state.trace.clone(),
            total_bytes: state.total_bytes,
        };
        let outcome = if timed_out.load(Ordering::SeqCst) {
            ExecOutcome::Timeout
        } else if let Some(capability) = state.denied.clone() {
            ExecOutcome::Denied { capability }
        } else {
            match result {
                Ok(json) => ExecOutcome::Ok { json },
                Err(JsFailure::NullException) => ExecOutcome::Oom,
                Err(JsFailure::Message(message)) => ExecOutcome::Threw { message },
            }
        };
        (outcome, trace)
    }
}

#[cfg(feature = "quickjs")]
impl JsExec for QuickJsExec {
    fn exec(&self, req: &ExecRequest) -> ExecOutcome {
        self.exec_traced(req).0
    }
}

/// Map a caught JS error onto [`JsFailure`]. A thrown NULL is the memory-cap signature (QuickJS throws
/// null on failed allocation); everything else keeps its printable message for `Threw`.
#[cfg(feature = "quickjs")]
fn caught_to_failure(err: CaughtError<'_>) -> JsFailure {
    match &err {
        CaughtError::Value(value) if value.is_null() => JsFailure::NullException,
        other => JsFailure::Message(format!("{other}").trim_end().to_string()),
    }
}

/// Install `__vx_fetch`, the ONLY door out of the sandbox: policy first (sticky deny), budget clamp,
/// then the transport; every allowed request lands in the audit trace.
#[cfg(feature = "quickjs")]
fn install_net_shim(
    ctx: &rquickjs::Ctx<'_>,
    net: Arc<dyn ExecNet>,
    policy: NetPolicy,
    state: Rc<RefCell<ShimState>>,
    deadline: Instant,
    timed_out: Arc<AtomicBool>,
) -> Result<(), rquickjs::Error> {
    let shim = Function::new(
        ctx.clone(),
        move |fctx: rquickjs::Ctx<'_>, url: String, opts_json: String| -> rquickjs::Result<String> {
            // Sticky deny: after one violation the exec has no network at all.
            if let Some(capability) = state.borrow().denied.clone() {
                return Err(Exception::throw_message(
                    &fctx,
                    &format!("VortxNetDenied: {capability}"),
                ));
            }
            // Budget: no time left means no more I/O.
            if Instant::now() >= deadline {
                timed_out.store(true, Ordering::SeqCst);
                return Err(Exception::throw_message(&fctx, "VortxNetBudget: budget exhausted"));
            }
            // Policy: the host must be readable and inside the manifest-derived allowlist.
            let Some(host) = url_host(&url) else {
                state.borrow_mut().denied = Some("net:invalid-url".to_string());
                return Err(Exception::throw_message(
                    &fctx,
                    &format!("VortxNetDenied: unreadable url {url}"),
                ));
            };
            if !policy.allows(&host) {
                let capability = format!("net:{host}");
                state.borrow_mut().denied = Some(capability.clone());
                return Err(Exception::throw_message(
                    &fctx,
                    &format!("VortxNetDenied: {capability} is not granted"),
                ));
            }
            // Quota: request count.
            {
                let mut st = state.borrow_mut();
                if st.requests_issued >= policy.max_requests {
                    st.denied = Some("net:max-requests".to_string());
                    return Err(Exception::throw_message(
                        &fctx,
                        "VortxNetDenied: net:max-requests exceeded",
                    ));
                }
                st.requests_issued += 1;
            }
            let headers = fetch_options_headers(&opts_json);
            let remaining_ms = deadline
                .saturating_duration_since(Instant::now())
                .as_millis() as u64;
            match net.get(&url, &headers, remaining_ms) {
                Ok(response) => {
                    let bytes = response.body.len() as u64;
                    let mut st = state.borrow_mut();
                    st.total_bytes += bytes;
                    // Quota: total bytes.
                    if st.total_bytes > policy.max_total_bytes {
                        st.denied = Some("net:max-bytes".to_string());
                        return Err(Exception::throw_message(
                            &fctx,
                            "VortxNetDenied: net:max-bytes exceeded",
                        ));
                    }
                    st.trace.push(NetTraceEntry {
                        url: url.clone(),
                        status: response.status,
                        bytes,
                    });
                    drop(st);
                    let payload = serde_json::json!({
                        "status": response.status,
                        "body": response.body,
                        "headers": response.headers,
                    });
                    Ok(payload.to_string())
                }
                Err(NetError::Timeout) => {
                    timed_out.store(true, Ordering::SeqCst);
                    Err(Exception::throw_message(
                        &fctx,
                        "VortxNetBudget: request overran the budget",
                    ))
                }
                // A plain transport failure is catchable by the script (a hoster being down is a
                // scraper-visible condition, not a sandbox verdict).
                Err(NetError::Transport(message)) => Err(Exception::throw_message(
                    &fctx,
                    &format!("VortxNet: {message}"),
                )),
            }
        },
    )?;
    ctx.globals().set("__vx_fetch", shim)
}

/// The JS prelude every exec gets: the `fetch` Response shim over `__vx_fetch`, silent `console`,
/// `atob`/`btoa`, and a CommonJS-style `module.exports` so providers can export either way.
#[cfg(feature = "quickjs")]
const PRELUDE: &str = r#"
globalThis.module = { exports: {} };
globalThis.exports = globalThis.module.exports;
globalThis.console = {
    log: function () {}, warn: function () {}, error: function () {},
    info: function () {}, debug: function () {}
};
globalThis.fetch = function (url, opts) {
    opts = opts || {};
    var raw = __vx_fetch(String(url), JSON.stringify({ headers: opts.headers || {} }));
    var r = JSON.parse(raw);
    var headers = r.headers || {};
    return Promise.resolve({
        ok: r.status >= 200 && r.status < 300,
        status: r.status,
        url: String(url),
        headers: {
            get: function (k) {
                var v = headers[String(k).toLowerCase()];
                return v === undefined ? null : v;
            }
        },
        text: function () { return Promise.resolve(r.body); },
        json: function () { return Promise.resolve(JSON.parse(r.body)); }
    });
};
(function () {
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    globalThis.btoa = function (input) {
        var str = String(input), out = "";
        for (var i = 0; i < str.length; i += 3) {
            var c1 = str.charCodeAt(i), c2 = str.charCodeAt(i + 1), c3 = str.charCodeAt(i + 2);
            if (c1 > 255 || c2 > 255 || c3 > 255) throw new Error("btoa: character out of range");
            var e1 = c1 >> 2, e2 = ((c1 & 3) << 4) | (c2 >> 4), e3 = ((c2 & 15) << 2) | (c3 >> 6), e4 = c3 & 63;
            if (isNaN(c2)) { e3 = 64; e4 = 64; } else if (isNaN(c3)) { e4 = 64; }
            out += chars.charAt(e1) + chars.charAt(e2)
                + (e3 === 64 ? "=" : chars.charAt(e3))
                + (e4 === 64 ? "=" : chars.charAt(e4));
        }
        return out;
    };
    globalThis.atob = function (input) {
        var str = String(input).replace(/=+$/, ""), out = "";
        if (str.length % 4 === 1) throw new Error("atob: invalid input");
        for (var bc = 0, bs, buffer, idx = 0; (buffer = str.charAt(idx++)); ) {
            buffer = chars.indexOf(buffer);
            if (buffer === -1) continue;
            bs = bc % 4 ? bs * 64 + buffer : buffer;
            if (bc++ % 4) out += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6)));
        }
        return out;
    };
})();
"#;

/// Build the harness expression: resolve the entrypoint (global or `module.exports`), apply the
/// kernel-stamped argument array, and stringify the (awaited) result. Both the entrypoint name and the
/// args JSON are embedded as JS STRING LITERALS (via JSON encoding), so request data can never splice
/// code into the harness.
#[cfg(feature = "quickjs")]
fn harness(entrypoint: &str, args_json: &str) -> String {
    let entry_lit = serde_json::to_string(entrypoint).unwrap_or_else(|_| "\"getStreams\"".into());
    let args_lit =
        serde_json::to_string(args_json).unwrap_or_else(|_| "\"[]\"".into());
    format!(
        r#"Promise.resolve().then(function () {{
    var __entry = {entry_lit};
    var __fn = globalThis[__entry];
    if (typeof __fn !== "function" && globalThis.module && globalThis.module.exports) {{
        __fn = globalThis.module.exports[__entry];
    }}
    if (typeof __fn !== "function") {{
        throw new Error("entrypoint not found: " + __entry);
    }}
    var __args = JSON.parse({args_lit});
    if (!Array.isArray(__args)) {{ throw new Error("args_json must be a JSON array"); }}
    return __fn.apply(null, __args);
}}).then(function (__r) {{ return JSON.stringify(__r === undefined ? null : __r); }})"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "quickjs")]
    #[test]
    fn register_script_pins_by_real_sha256() {
        let mut exec = QuickJsExec::new(Arc::new(RecordedNet::new()));
        // sha256("abc") is the classic test vector.
        let hash = exec.register_script("abc");
        assert_eq!(
            hash,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn an_unknown_hash_never_executes() {
        let exec = QuickJsExec::new(Arc::new(RecordedNet::new()));
        let req = ExecRequest {
            provider_id: "p".into(),
            script_hash: "00".repeat(32),
            entrypoint: "getStreams".into(),
            args_json: "[]".into(),
            budget_ms: 1000,
            net_policy: NetPolicy::default(),
        };
        let (outcome, trace) = exec.exec_traced(&req);
        assert!(matches!(outcome, ExecOutcome::Threw { ref message } if message.contains("no registered script")));
        assert!(trace.requests.is_empty());
    }

    #[test]
    fn recorded_net_misses_are_transport_errors() {
        let net = RecordedNet::new().with_body("https://a.example/x", "{}");
        assert!(net
            .get("https://a.example/x", &BTreeMap::new(), 1000)
            .is_ok());
        assert!(matches!(
            net.get("https://b.example/y", &BTreeMap::new(), 1000),
            Err(NetError::Transport(_))
        ));
    }
}
