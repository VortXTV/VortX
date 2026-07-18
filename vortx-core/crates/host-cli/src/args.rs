//! Hand-rolled argument parsing for the proof CLI. Deliberately dependency-free (no clap): the
//! binary is a dev-only workspace member and the flag surface is small, so a tiny parser keeps the
//! lockfile untouched and the offline build offline.

use std::path::PathBuf;

use vortx_debrid::DebridService;

/// Default per-request fetch budget (ms) when neither a flag nor a fixture run spec supplies one.
pub const DEFAULT_BUDGET_MS: u64 = 5_000;

/// The parsed command line for `vortx-host-cli resolve`.
#[derive(Debug, Clone, Default)]
pub struct Cli {
    /// The content id to resolve (e.g. `tt0468569`).
    pub meta_id: String,
    /// The content type segment of the resource path (default `movie`).
    pub content_type: String,
    /// A FIXED clock override in Unix seconds. Replay defaults to the fixture's recorded `now`;
    /// live defaults to the real clock through the host Env seam.
    pub now: Option<u64>,
    /// Per-request fetch budget override in milliseconds.
    pub budget_ms: Option<u64>,
    /// The user's enabled debrid services (wire strings), used for cacheStatus + the resolve plan.
    pub services: Vec<DebridService>,
    /// Live sources to fan out over, as `(addon_id, transport_url)` pairs.
    pub addons: Vec<(String, String)>,
    /// Replay a recorded fixture directory instead of fetching.
    pub replay: Option<PathBuf>,
    /// Record the live fan-out (bodies + registry + run spec) into this directory.
    pub record: Option<PathBuf>,
    /// Persist the circuit-breaker snapshot across runs through the host Storage seam.
    pub state_dir: Option<PathBuf>,
    /// Pretty-print the output JSON (the byte-stability contract holds per formatting mode).
    pub pretty: bool,
}

/// A command-line error: the message the user sees above the usage text (exit code 2).
#[derive(Debug)]
pub struct UsageError(pub String);

pub const USAGE: &str = "\
vortx-host-cli: the headless byte-stable resolve proof for the vortx-core engine.

USAGE:
  vortx-host-cli resolve --meta <id> [options]

OPTIONS:
  --meta <id>           Content id to resolve (e.g. tt0468569). REQUIRED.
  --type <type>         Content type (default: movie).
  --now <unix-secs>     Fix the clock. Replay defaults to the fixture's recorded now;
                        live defaults to the system clock.
  --budget-ms <ms>      Per-request fetch budget (default: 5000, or the fixture's).
  --service <wire>      Enable a debrid service (repeatable): realdebrid, alldebrid,
                        premiumize, torbox, debridlink, easydebrid.
  --addon [id=]<url>    LIVE mode: fan out over this source (repeatable). The id
                        defaults to a slug of the URL host.
  --replay <dir>        Replay a recorded fixture directory (registry.json, run.json,
                        bodies/<addon-id>.json) instead of fetching.
  --record <dir>        LIVE mode: record the fetched bodies + run spec into <dir>
                        so the run can be replayed byte-identically.
  --state-dir <dir>     Persist the circuit-breaker snapshot between runs (Storage seam).
  --pretty              Pretty-print the output JSON.

With no --addon and no --replay, the embedded tt0468569 fixture is replayed, so the
command is hermetic and deterministic out of the box.";

/// Parse a debrid service wire string through the SAME serde shape the kernel uses, so the CLI can
/// never drift from the frozen wire tokens.
pub fn parse_service(wire: &str) -> Result<DebridService, UsageError> {
    serde_json::from_value(serde_json::Value::String(wire.to_string()))
        .map_err(|_| UsageError(format!("unknown debrid service wire string: {wire}")))
}

/// Derive a stable addon id from a transport URL: the host part, slugged. `id=url` overrides.
pub fn addon_arg(raw: &str) -> Result<(String, String), UsageError> {
    if let Some((id, url)) = raw.split_once('=') {
        if !id.is_empty() && !id.contains("://") {
            return Ok((id.to_string(), url.to_string()));
        }
    }
    let host = raw
        .split("://")
        .nth(1)
        .unwrap_or(raw)
        .split('/')
        .next()
        .unwrap_or_default();
    if host.is_empty() {
        return Err(UsageError(format!("cannot derive an addon id from: {raw}")));
    }
    let slug: String = host
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    Ok((slug, raw.to_string()))
}

fn parse_u64(flag: &str, value: &str) -> Result<u64, UsageError> {
    value
        .parse()
        .map_err(|_| UsageError(format!("{flag} expects an unsigned integer, got: {value}")))
}

/// Parse `args` (the argv AFTER the program name). The only command is `resolve`.
pub fn parse(args: &[String]) -> Result<Cli, UsageError> {
    let mut it = args.iter();
    match it.next().map(String::as_str) {
        Some("resolve") => {}
        Some(other) => return Err(UsageError(format!("unknown command: {other}"))),
        None => {
            return Err(UsageError(
                "missing command: expected `resolve`".to_string(),
            ))
        }
    }

    let mut cli = Cli {
        content_type: "movie".to_string(),
        ..Cli::default()
    };
    while let Some(flag) = it.next() {
        let mut value = |name: &str| -> Result<&String, UsageError> {
            it.next()
                .ok_or_else(|| UsageError(format!("{name} expects a value")))
        };
        match flag.as_str() {
            "--meta" => cli.meta_id = value("--meta")?.clone(),
            "--type" => cli.content_type = value("--type")?.clone(),
            "--now" => cli.now = Some(parse_u64("--now", value("--now")?)?),
            "--budget-ms" => cli.budget_ms = Some(parse_u64("--budget-ms", value("--budget-ms")?)?),
            "--service" => cli.services.push(parse_service(value("--service")?)?),
            "--addon" => cli.addons.push(addon_arg(value("--addon")?)?),
            "--replay" => cli.replay = Some(PathBuf::from(value("--replay")?)),
            "--record" => cli.record = Some(PathBuf::from(value("--record")?)),
            "--state-dir" => cli.state_dir = Some(PathBuf::from(value("--state-dir")?)),
            "--pretty" => cli.pretty = true,
            other => return Err(UsageError(format!("unknown flag: {other}"))),
        }
    }

    if cli.meta_id.is_empty() {
        return Err(UsageError("--meta <id> is required".to_string()));
    }
    if cli.replay.is_some() && !cli.addons.is_empty() {
        return Err(UsageError(
            "--replay and --addon are mutually exclusive (replay never fetches)".to_string(),
        ));
    }
    if cli.record.is_some() && cli.addons.is_empty() {
        return Err(UsageError(
            "--record needs at least one --addon (recording is a live capture)".to_string(),
        ));
    }
    Ok(cli)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_the_bare_resolve_invocation() {
        let cli = parse(&argv(&["resolve", "--meta", "tt0468569"])).expect("parse");
        assert_eq!(cli.meta_id, "tt0468569");
        assert_eq!(cli.content_type, "movie");
        assert!(cli.addons.is_empty() && cli.replay.is_none());
    }

    #[test]
    fn rejects_a_missing_meta_with_a_usage_error() {
        assert!(parse(&argv(&["resolve"])).is_err());
        assert!(parse(&argv(&[])).is_err());
        assert!(parse(&argv(&["frobnicate"])).is_err());
    }

    #[test]
    fn service_wire_strings_round_trip_the_kernel_enum() {
        assert!(parse_service("realdebrid").is_ok());
        assert!(parse_service("torbox").is_ok());
        assert!(parse_service("RealDebrid").is_err()); // wire strings are frozen lowercase
        assert!(parse_service("notaservice").is_err());
    }

    #[test]
    fn addon_ids_come_from_the_override_or_the_host_slug() {
        let (id, url) = addon_arg("mysrc=https://a.example/manifest.json").expect("explicit id");
        assert_eq!(
            (id.as_str(), url.as_str()),
            ("mysrc", "https://a.example/manifest.json")
        );
        let (id, url) = addon_arg("https://addon.example.com:8080/manifest.json").expect("slug");
        assert_eq!(id, "addon-example-com-8080");
        assert_eq!(url, "https://addon.example.com:8080/manifest.json");
    }

    #[test]
    fn replay_and_addon_are_mutually_exclusive() {
        let err = parse(&argv(&[
            "resolve",
            "--meta",
            "tt1",
            "--replay",
            "/x",
            "--addon",
            "https://a.example/m.json",
        ]));
        assert!(err.is_err());
    }

    #[test]
    fn record_requires_a_live_addon() {
        assert!(parse(&argv(&["resolve", "--meta", "tt1", "--record", "/x"])).is_err());
    }
}
