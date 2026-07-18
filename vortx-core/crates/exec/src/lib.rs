//! # vortx-exec
//!
//! The JS-execution seam: the pure contract that lets the kernel ORCHESTRATE JavaScript providers
//! (Nuvio `getStreams()` scrapers) exactly like it orchestrates HTTP addons, while the kernel itself
//! executes ZERO JavaScript. This is the Fetch seam pattern applied to script execution:
//!
//! - The kernel PLANS: an [`ExecRequest`] names the provider, pins the exact script by sha256, fixes
//!   the entrypoint + argument JSON, stamps the time budget, and attaches the [`NetPolicy`] derived
//!   purely from the pack's declared manifest permissions. Shaped deliberately like the Fetch seam's
//!   `FetchRequest` so the plan/settle machinery treats both identically.
//! - The HOST EXECUTES: a real executor (rquickjs in `vortx-host-native`, JavaScriptCore on Apple
//!   later) implements [`JsExec`] and realizes each request into an [`ExecOutcome`], enforcing the
//!   budget (`Timeout`), the memory cap (`Oom`), and the net allowlist (`Denied`).
//! - The kernel SETTLES: `Ok { json }` routes through the existing Nuvio adapter mapping into the
//!   same settle -> rank -> dedup path as HTTP streams; every failure feeds the same circuit
//!   breakers, so a misbehaving provider trips out exactly like a dead HTTP addon.
//!
//! Pure invariant: this crate has no I/O, no JS runtime, and no clock. Only host crates may depend
//! on an actual JS engine.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The entrypoint a Nuvio provider exports for stream resolution.
pub const ENTRYPOINT_GET_STREAMS: &str = "getStreams";

/// The manifest permission prefix that grants a provider network access to one host:
/// `net:<host>` (exact) or `net:*.<domain>` (any subdomain of `<domain>`).
pub const NET_PERMISSION_PREFIX: &str = "net:";

/// Default cap on the number of network requests one exec may issue. A scraper resolves a handful of
/// hoster endpoints; a provider fanning out past this is misbehaving (enumeration / beaconing).
pub const DEFAULT_MAX_REQUESTS: u32 = 32;

/// Default cap on the total response bytes one exec may consume (8 MiB). Scrapers read small JSON /
/// HTML documents; a provider pulling more is exfiltrating bandwidth, not resolving streams.
pub const DEFAULT_MAX_TOTAL_BYTES: u64 = 8 * 1024 * 1024;

/// The network policy one exec runs under, derived PURELY from the pack's declared manifest
/// permissions ([`VortxAddonManifest::permissions`]-style strings). Deny-by-default: an empty
/// allowlist means the script gets NO network at all. The host's net shim enforces this; a
/// violation surfaces as [`ExecOutcome::Denied`] and feeds the provider's circuit breaker.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetPolicy {
    /// Hosts the script may reach: exact hosts (`api.example.com`) or subdomain wildcards
    /// (`*.example.com`). Lower-cased, sorted, deduped, so the planned request is deterministic.
    pub host_allowlist: Vec<String>,
    /// Maximum network requests per exec.
    pub max_requests: u32,
    /// Maximum total response bytes per exec.
    pub max_total_bytes: u64,
}

impl Default for NetPolicy {
    fn default() -> Self {
        Self {
            host_allowlist: Vec::new(),
            max_requests: DEFAULT_MAX_REQUESTS,
            max_total_bytes: DEFAULT_MAX_TOTAL_BYTES,
        }
    }
}

impl NetPolicy {
    /// Derive the policy from a pack's declared permission strings. Only `net:<host>` entries feed
    /// the allowlist; every other permission string is ignored here (it names a different
    /// capability). Pure and deterministic: hosts are lower-cased, sorted, and deduped.
    pub fn from_permissions(permissions: &[String]) -> Self {
        let mut hosts: Vec<String> = permissions
            .iter()
            .filter_map(|p| p.strip_prefix(NET_PERMISSION_PREFIX))
            .filter(|h| !h.is_empty())
            .map(|h| h.to_ascii_lowercase())
            .collect();
        hosts.sort();
        hosts.dedup();
        Self {
            host_allowlist: hosts,
            ..Self::default()
        }
    }

    /// Whether `host` is inside the allowlist: an exact entry matches itself; a `*.domain` entry
    /// matches any host that ENDS with `.domain` (subdomains only, never the bare domain, so a pack
    /// granted `*.cdn.example` cannot reach `cdn.example` itself unless it declares it too).
    pub fn allows(&self, host: &str) -> bool {
        let host = host.to_ascii_lowercase();
        self.host_allowlist.iter().any(|entry| {
            if let Some(suffix) = entry.strip_prefix("*.") {
                host.len() > suffix.len() + 1 && host.ends_with(suffix)
                    && host.as_bytes()[host.len() - suffix.len() - 1] == b'.'
            } else {
                entry == &host
            }
        })
    }
}

/// One planned script execution the host should perform: the exec twin of the Fetch seam's
/// `FetchRequest`. The kernel stamps everything; the host executes exactly this and nothing more.
/// `script_hash` pins the provider source by sha256 (hex), so the host can only run the bytes the
/// pack was installed with; `budget_ms` is the wall-time budget the host enforces (overrun ->
/// [`ExecOutcome::Timeout`]); `net_policy` is the manifest-derived allowlist the host's net shim
/// enforces. The kernel stays clockless: it carries the budget, never a deadline.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecRequest {
    pub provider_id: String,
    /// sha256 (lowercase hex) of the exact provider script source to run.
    pub script_hash: String,
    /// The exported function to call (`getStreams` for the stream resource).
    pub entrypoint: String,
    /// The call arguments as a JSON ARRAY string (deterministic; built by [`stream_args_json`]).
    pub args_json: String,
    #[serde(rename = "budgetMs")]
    pub budget_ms: u64,
    pub net_policy: NetPolicy,
}

/// What the host returns for a planned exec. Mirrors the Fetch seam's `FetchOutcome` at the host
/// boundary so settlement, breaker feeding, and partial-result semantics are identical: `Ok` carries
/// the entrypoint's JSON return value (for `getStreams`, the raw Nuvio stream array) which the
/// kernel routes through the existing adapter mapping; every other variant is a classified failure.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ExecOutcome {
    /// The script ran to completion; `json` is `JSON.stringify` of the entrypoint's return value.
    Ok { json: String },
    /// The script threw (or returned a rejected promise). The provider misbehaved; breaker-visible.
    Threw { message: String },
    /// The script overran its `budget_ms` wall-time budget.
    Timeout,
    /// The script attempted something its policy does not grant (e.g. a host outside the
    /// allowlist); `capability` names the missing grant (`net:<host>`, `net:max-requests`, ...).
    Denied { capability: String },
    /// The script exceeded the executor's memory cap.
    Oom,
}

/// One network request the host's net shim performed on behalf of a script.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetTraceEntry {
    pub url: String,
    pub status: u16,
    pub bytes: u64,
}

/// The audit trail of one exec's network activity: every request the shim allowed, in issue order,
/// plus the total bytes consumed. Hosts log or surface this; the kernel never needs it to settle.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetTrace {
    pub requests: Vec<NetTraceEntry>,
    pub total_bytes: u64,
}

/// The host-provided JS execution boundary: the exec twin of the Fetch seam's `Fetch` trait.
/// SYNCHRONOUS by design, like the Fetch host contract: the kernel is synchronous and the host owns
/// all concurrency internally (it MAY run a batch of requests concurrently; settlement is
/// order-independent, so concurrency never changes the result). The real implementations live
/// OUTSIDE the kernel: rquickjs in `vortx-host-native`, JavaScriptCore in the Apple host later.
/// The kernel itself never executes a byte of JavaScript.
pub trait JsExec {
    fn exec(&self, req: &ExecRequest) -> ExecOutcome;
}

/// Realize an exec `plan` into the `(provider_id, outcome)` pairs the settle phase consumes: the
/// exec twin of the Fetch seam's `execute_plan`. A synchronous host (or a test) drives the
/// round-trip with this; a host with real concurrency executes the same requests in parallel and
/// returns the same `Vec` (settlement is order-independent).
pub fn execute_exec_plan<E: JsExec + ?Sized>(
    plan: &[ExecRequest],
    executor: &E,
) -> Vec<(String, ExecOutcome)> {
    plan.iter()
        .map(|req| (req.provider_id.clone(), executor.exec(req)))
        .collect()
}

/// Build the deterministic `getStreams` argument JSON for a stream request. Nuvio providers take
/// `(id, type, season?, episode?)`; the Stremio series id grammar (`tt123:1:2`) carries the season
/// and episode, so a series id splits into `[base, type, season, episode]` (numbers) while every
/// other id stays `[id, type]`. Pure string work; byte-stable for the same request.
pub fn stream_args_json(type_: &str, id: &str) -> String {
    let parts: Vec<&str> = id.split(':').collect();
    let args = if parts.len() == 3 {
        match (parts[1].parse::<u64>(), parts[2].parse::<u64>()) {
            (Ok(season), Ok(episode)) => serde_json::json!([parts[0], type_, season, episode]),
            _ => serde_json::json!([id, type_]),
        }
    } else {
        serde_json::json!([id, type_])
    };
    args.to_string()
}

/// The host component of `url`, lower-cased: `scheme://[user@]host[:port]/...` -> `host`. `None`
/// when the URL has no `://` scheme separator (the net shim rejects such URLs outright). Pure, so
/// hosts and tests share one URL-host reading and the policy gate cannot drift per platform.
pub fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let authority = rest.split(['/', '?', '#']).next()?;
    let host_port = authority.rsplit_once('@').map(|(_, h)| h).unwrap_or(authority);
    // IPv6 literal: [::1]:8080 -> ::1
    let host = if let Some(stripped) = host_port.strip_prefix('[') {
        stripped.split(']').next()?
    } else {
        host_port.split(':').next()?
    };
    if host.is_empty() {
        return None;
    }
    Some(host.to_ascii_lowercase())
}

/// Convenience for a host: the `(headers)` object of an exec net-shim `fetch` options JSON, as a
/// deterministic sorted map. Tolerant: absent/malformed options mean "no headers", never an error
/// (the policy gate, not the header parse, is the security boundary).
pub fn fetch_options_headers(options_json: &str) -> BTreeMap<String, String> {
    serde_json::from_str::<serde_json::Value>(options_json)
        .ok()
        .and_then(|v| {
            v.get("headers").and_then(|h| {
                serde_json::from_value::<BTreeMap<String, String>>(h.clone()).ok()
            })
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn perms(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn net_policy_derives_only_from_net_permissions_sorted_and_deduped() {
        let policy = NetPolicy::from_permissions(&perms(&[
            "net:Zeta.example",
            "hive:contribute",
            "net:api.example.com",
            "net:api.example.com",
            "config:per-profile",
            "net:*.cdn.example",
        ]));
        assert_eq!(
            policy.host_allowlist,
            vec!["*.cdn.example", "api.example.com", "zeta.example"]
        );
        assert_eq!(policy.max_requests, DEFAULT_MAX_REQUESTS);
        assert_eq!(policy.max_total_bytes, DEFAULT_MAX_TOTAL_BYTES);
    }

    #[test]
    fn empty_permissions_deny_all_network() {
        let policy = NetPolicy::from_permissions(&perms(&["hive:contribute"]));
        assert!(policy.host_allowlist.is_empty());
        assert!(!policy.allows("api.example.com"));
    }

    #[test]
    fn allows_matches_exact_and_subdomain_wildcard_case_insensitively() {
        let policy = NetPolicy::from_permissions(&perms(&["net:api.example.com", "net:*.cdn.example"]));
        assert!(policy.allows("api.example.com"));
        assert!(policy.allows("API.Example.COM"));
        assert!(policy.allows("edge1.cdn.example"));
        assert!(policy.allows("a.b.cdn.example"));
        // The wildcard grants SUBDOMAINS only, never the bare domain.
        assert!(!policy.allows("cdn.example"));
        // A suffix that is not a label boundary must not match.
        assert!(!policy.allows("evilcdn.example"));
        assert!(!policy.allows("evil.example.net"));
    }

    #[test]
    fn url_host_reads_the_authority_host_only() {
        assert_eq!(url_host("https://api.example.com/streams?id=1"), Some("api.example.com".into()));
        assert_eq!(url_host("http://API.Example.com:8080/x"), Some("api.example.com".into()));
        assert_eq!(url_host("https://user:pw@host.example/x"), Some("host.example".into()));
        assert_eq!(url_host("https://[::1]:8080/x"), Some("::1".into()));
        assert_eq!(url_host("no-scheme.example/x"), None);
        assert_eq!(url_host("https:///path-only"), None);
    }

    #[test]
    fn stream_args_json_is_deterministic_and_splits_series_ids() {
        assert_eq!(stream_args_json("movie", "tt0111161"), r#"["tt0111161","movie"]"#);
        assert_eq!(stream_args_json("series", "tt0944947:3:9"), r#"["tt0944947","series",3,9]"#);
        // A colon id whose tail is not numeric stays whole (kitsu:42 style namespaces).
        assert_eq!(stream_args_json("movie", "kitsu:42"), r#"["kitsu:42","movie"]"#);
        assert_eq!(stream_args_json("series", "tt1:a:b"), r#"["tt1:a:b","series"]"#);
    }

    #[test]
    fn exec_request_wire_shape_mirrors_the_fetch_seam() {
        let req = ExecRequest {
            provider_id: "vidfast".into(),
            script_hash: "ab".repeat(32),
            entrypoint: ENTRYPOINT_GET_STREAMS.into(),
            args_json: stream_args_json("movie", "tt1"),
            budget_ms: 5000,
            net_policy: NetPolicy::from_permissions(&perms(&["net:api.example.com"])),
        };
        let wire = serde_json::to_string(&req).unwrap();
        // budget_ms is camelCase like FetchRequest's; the id stays snake like addon_id.
        assert!(wire.contains("\"budgetMs\":5000"), "{wire}");
        assert!(wire.contains("\"provider_id\":\"vidfast\""), "{wire}");
        assert!(wire.contains("\"script_hash\""), "{wire}");
        let back: ExecRequest = serde_json::from_str(&wire).unwrap();
        assert_eq!(back, req);
    }

    #[test]
    fn exec_outcome_status_tags_round_trip() {
        let cases = vec![
            (ExecOutcome::Ok { json: "[]".into() }, r#"{"status":"ok","json":"[]"}"#),
            (
                ExecOutcome::Threw { message: "boom".into() },
                r#"{"status":"threw","message":"boom"}"#,
            ),
            (ExecOutcome::Timeout, r#"{"status":"timeout"}"#),
            (
                ExecOutcome::Denied { capability: "net:evil.example".into() },
                r#"{"status":"denied","capability":"net:evil.example"}"#,
            ),
            (ExecOutcome::Oom, r#"{"status":"oom"}"#),
        ];
        for (outcome, wire) in cases {
            assert_eq!(serde_json::to_string(&outcome).unwrap(), wire);
            assert_eq!(serde_json::from_str::<ExecOutcome>(wire).unwrap(), outcome);
        }
    }

    #[test]
    fn fetch_options_headers_is_tolerant() {
        let h = fetch_options_headers(r#"{"headers":{"Referer":"https://r/","User-Agent":"N"}}"#);
        assert_eq!(h.get("Referer").map(String::as_str), Some("https://r/"));
        assert!(fetch_options_headers("{}").is_empty());
        assert!(fetch_options_headers("not json").is_empty());
        assert!(fetch_options_headers(r#"{"headers":"nope"}"#).is_empty());
    }

    /// A mock executor keyed by provider id, mirroring the Fetch seam's MockFetch.
    struct MockExec {
        map: BTreeMap<String, ExecOutcome>,
    }

    impl JsExec for MockExec {
        fn exec(&self, req: &ExecRequest) -> ExecOutcome {
            self.map
                .get(&req.provider_id)
                .cloned()
                .unwrap_or(ExecOutcome::Timeout)
        }
    }

    fn exec_req(id: &str) -> ExecRequest {
        ExecRequest {
            provider_id: id.into(),
            script_hash: "00".repeat(32),
            entrypoint: ENTRYPOINT_GET_STREAMS.into(),
            args_json: stream_args_json("movie", "tt1"),
            budget_ms: 5000,
            net_policy: NetPolicy::default(),
        }
    }

    #[test]
    fn execute_exec_plan_realizes_each_request_in_plan_order() {
        let exec = MockExec {
            map: BTreeMap::from([("a".to_string(), ExecOutcome::Ok { json: "[]".into() })]),
        };
        let plan = vec![exec_req("a"), exec_req("b")];
        let outcomes = execute_exec_plan(&plan, &exec);
        assert_eq!(outcomes.len(), 2);
        assert_eq!(outcomes[0].0, "a");
        assert_eq!(outcomes[0].1, ExecOutcome::Ok { json: "[]".into() });
        assert_eq!(outcomes[1].0, "b");
        assert_eq!(outcomes[1].1, ExecOutcome::Timeout); // unmapped -> mock default
    }
}
