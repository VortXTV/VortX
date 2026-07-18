//! Live debrid HTTP stores (Phase 2 of the engine cutover): the real [`vortx_debrid::DebridStore`]
//! implementations, host-side. The kernel's debrid crate stays pure (trait + planner + credential
//! format, no HTTP); this module owns the wire clients, behind the SAME sync-boundary discipline as
//! [`crate::NativeFetcher`]: one shared tokio runtime plus one pooled rustls reqwest client,
//! `block_on` from a synchronous host thread, never a runtime per call and never `block_on` from
//! inside another runtime (the documented host shape).
//!
//! Transport seam: every store speaks through [`DebridTransport`], a tiny blocking request /
//! response trait. The live implementation is [`DebridHttp`]; tests replay RECORDED response bodies
//! through the same parsing paths (the proof-CLI fixture discipline), so the wire contracts are
//! pinned offline and CI never touches the network.
//!
//! Secrets: api tokens arrive as constructor arguments, ride in an Authorization header (or, where
//! an API demands it, as a parameter appended at send time), and are never hardcoded, never logged,
//! never Debug-printed (no Debug derives on secret-carrying types), and never included in error
//! strings (transport errors are stripped of their URL before formatting).

mod alldebrid;
mod premiumize;
mod realdebrid;
mod torbox;

use std::sync::Arc;
use std::time::Duration;

use serde::de::DeserializeOwned;
use vortx_debrid::{DebridError, DebridService, DebridStore};

use crate::fetch::FetchInitError;

pub use alldebrid::AllDebridStore;
pub use premiumize::PremiumizeStore;
pub use realdebrid::RealDebridStore;
pub use torbox::TorBoxStore;

/// Default per-request wall budget. Debrid control calls are small JSON exchanges; anything past
/// this is a stuck connection, not a slow answer.
pub const DEFAULT_DEBRID_BUDGET_MS: u64 = 20_000;

/// HTTP method subset the debrid APIs use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
    Delete,
}

/// A request body. `Multipart` is hand-encoded by the live transport (TorBox's create endpoint is
/// documented as multipart/form-data); `Form` is standard urlencoded.
#[derive(Clone, PartialEq, Eq)]
pub enum HttpBody {
    Empty,
    Form(Vec<(String, String)>),
    Multipart(Vec<(String, String)>),
    Json(String),
}

/// One planned call to a debrid API. `url` NEVER carries a secret: the bearer token rides the
/// Authorization header and `query_secret` is appended by the transport at send time, so no error
/// path can echo a credential. Deliberately no `Debug` derive (bearer / query_secret are secrets).
pub struct HttpRequest {
    pub method: HttpMethod,
    pub url: String,
    pub bearer: Option<String>,
    /// A secret the target API insists on receiving as a query parameter (TorBox `requestdl`
    /// rejects header-only auth with a 422; Premiumize keys on `apikey`). Appended at send time.
    pub query_secret: Option<(&'static str, String)>,
    pub body: HttpBody,
}

impl HttpRequest {
    fn with(method: HttpMethod, url: impl Into<String>) -> Self {
        Self {
            method,
            url: url.into(),
            bearer: None,
            query_secret: None,
            body: HttpBody::Empty,
        }
    }

    pub fn get(url: impl Into<String>) -> Self {
        Self::with(HttpMethod::Get, url)
    }

    pub fn post(url: impl Into<String>) -> Self {
        Self::with(HttpMethod::Post, url)
    }

    pub fn delete(url: impl Into<String>) -> Self {
        Self::with(HttpMethod::Delete, url)
    }

    pub fn with_bearer(mut self, token: impl Into<String>) -> Self {
        self.bearer = Some(token.into());
        self
    }

    pub fn with_query_secret(mut self, name: &'static str, value: impl Into<String>) -> Self {
        self.query_secret = Some((name, value.into()));
        self
    }

    pub fn with_form(mut self, fields: Vec<(String, String)>) -> Self {
        self.body = HttpBody::Form(fields);
        self
    }

    pub fn with_multipart(mut self, fields: Vec<(String, String)>) -> Self {
        self.body = HttpBody::Multipart(fields);
        self
    }

    pub fn with_json(mut self, body: impl Into<String>) -> Self {
        self.body = HttpBody::Json(body.into());
        self
    }
}

/// A raw response: status plus body text. Stores parse; the transport never interprets.
#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
}

impl HttpResponse {
    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

/// The blocking transport seam every store drives. Live traffic goes through [`DebridHttp`];
/// tests replay recorded bodies; a platform host with its own HTTP stack can implement this
/// directly and reuse the stores unchanged.
pub trait DebridTransport: Send + Sync {
    fn execute(&self, req: &HttpRequest) -> Result<HttpResponse, DebridError>;
}

/// The live transport: one tokio runtime + one pooled rustls client, shared by all stores via
/// `Arc`. Mirrors [`crate::NativeFetcher`]'s bridge exactly: the store trait is synchronous, so
/// each call is one `block_on` on the OWN runtime from a synchronous host thread. Never call from
/// inside another tokio runtime (same documented constraint as `NativeFetcher`).
pub struct DebridHttp {
    runtime: tokio::runtime::Runtime,
    client: reqwest::Client,
    budget: Duration,
}

impl DebridHttp {
    /// Build with the default per-request budget.
    pub fn new() -> Result<Self, FetchInitError> {
        Self::with_budget_ms(DEFAULT_DEBRID_BUDGET_MS)
    }

    /// Build with an explicit per-request wall budget in milliseconds.
    pub fn with_budget_ms(budget_ms: u64) -> Result<Self, FetchInitError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()?;
        let client = reqwest::Client::builder().build()?;
        Ok(Self {
            runtime,
            client,
            budget: Duration::from_millis(budget_ms),
        })
    }
}

impl DebridTransport for DebridHttp {
    fn execute(&self, req: &HttpRequest) -> Result<HttpResponse, DebridError> {
        self.runtime.block_on(async {
            match tokio::time::timeout(self.budget, send(&self.client, req)).await {
                Err(_elapsed) => Err(DebridError::Other(format!(
                    "debrid http: timed out after {}ms",
                    self.budget.as_millis()
                ))),
                Ok(result) => result,
            }
        })
    }
}

async fn send(client: &reqwest::Client, req: &HttpRequest) -> Result<HttpResponse, DebridError> {
    let mut builder = match req.method {
        HttpMethod::Get => client.get(&req.url),
        HttpMethod::Post => client.post(&req.url),
        HttpMethod::Delete => client.delete(&req.url),
    };
    if let Some(token) = &req.bearer {
        builder = builder.bearer_auth(token);
    }
    if let Some((name, value)) = &req.query_secret {
        builder = builder.query(&[(name, value.as_str())]);
    }
    builder = match &req.body {
        HttpBody::Empty => builder,
        HttpBody::Form(fields) => builder.form(fields),
        HttpBody::Json(json) => builder
            .header("Content-Type", "application/json")
            .body(json.clone()),
        HttpBody::Multipart(fields) => {
            let (content_type, body) = encode_multipart(fields);
            builder.header("Content-Type", content_type).body(body)
        }
    };
    let response = builder.send().await.map_err(net_err)?;
    let status = response.status().as_u16();
    let body = response.text().await.map_err(net_err)?;
    Ok(HttpResponse { status, body })
}

/// Map a transport failure with its URL STRIPPED: the URL may carry a query secret, so it must
/// never reach an error string (which callers may log).
fn net_err(e: reqwest::Error) -> DebridError {
    DebridError::Other(format!("debrid http: {}", e.without_url()))
}

/// The fixed multipart boundary. Only ever wraps magnet URIs and small flags, none of which can
/// contain this token, so a constant boundary keeps the encoding deterministic and testable.
const MULTIPART_BOUNDARY: &str = "vortx-debrid-boundary-9f2c4e7a1b";

/// Hand-encode a text-field-only multipart/form-data body (TorBox's documented create shape)
/// without pulling reqwest's multipart feature and its dependency tree.
fn encode_multipart(fields: &[(String, String)]) -> (String, String) {
    let mut body = String::new();
    for (name, value) in fields {
        body.push_str(&format!(
            "--{MULTIPART_BOUNDARY}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
        ));
    }
    body.push_str(&format!("--{MULTIPART_BOUNDARY}--\r\n"));
    (
        format!("multipart/form-data; boundary={MULTIPART_BOUNDARY}"),
        body,
    )
}

/// Build the live store for one service. `None` for services without an HTTP client yet
/// (DebridLink / EasyDebrid; DmmPublic is an advisory hashlist tier, not an account store).
/// Pairs with the kernel's `parse_credential`, so a host wires a profile token straight in.
pub fn store_for(
    service: DebridService,
    transport: Arc<dyn DebridTransport>,
    api_key: &str,
) -> Option<Box<dyn DebridStore>> {
    match service {
        DebridService::RealDebrid => Some(Box::new(RealDebridStore::new(transport, api_key))),
        DebridService::AllDebrid => Some(Box::new(AllDebridStore::new(transport, api_key))),
        DebridService::TorBox => Some(Box::new(TorBoxStore::new(transport, api_key))),
        DebridService::Premiumize => Some(Box::new(PremiumizeStore::new(transport, api_key))),
        DebridService::DebridLink | DebridService::EasyDebrid | DebridService::DmmPublic => None,
    }
}

/// Map a non-2xx REST status into the normalized error space (the fallback when a service body
/// carries no richer error envelope).
pub(crate) fn error_for_status(service: &str, op: &str, status: u16) -> DebridError {
    match status {
        401 | 403 => DebridError::Unauthorized,
        404 => DebridError::NotFound,
        429 => DebridError::RateLimited,
        s => DebridError::Other(format!("{service} {op}: http status {s}")),
    }
}

/// Parse a JSON body into `T`, mapping failure to a `DebridError` that names the service and
/// operation (serde's error carries line/column, never the body or any credential).
pub(crate) fn parse_json<T: DeserializeOwned>(
    service: &str,
    op: &str,
    body: &str,
) -> Result<T, DebridError> {
    serde_json::from_str(body)
        .map_err(|e| DebridError::Other(format!("{service} {op}: malformed response: {e}")))
}

/// A response that parsed but does not carry what the contract promises.
pub(crate) fn shape_error(service: &str, op: &str, detail: &str) -> DebridError {
    DebridError::Other(format!(
        "{service} {op}: unexpected response shape: {detail}"
    ))
}

/// Lowercase-normalize an infohash for map keys and comparisons (mirrors the hive's canonical
/// 40-hex-lowercase wire form without rejecting unknown shapes at this boundary).
pub(crate) fn normalize_hash(raw: &str) -> String {
    raw.trim().to_ascii_lowercase()
}

/// Rank a status for "best entry wins" when an account holds the same hash more than once:
/// ready beats pending beats anything else.
pub(crate) fn status_rank(status: vortx_debrid::MagnetStatus) -> u8 {
    if status.is_ready() {
        2
    } else if status.is_pending() {
        1
    } else {
        0
    }
}

/// Extract the v1 (btih) infohash from a magnet URI, a bare 40-hex hash, or a bare base32 hash,
/// normalized to 40-hex lowercase. `None` when no well-formed btih is present.
pub(crate) fn magnet_infohash(magnet: &str) -> Option<String> {
    let candidate = match magnet.strip_prefix("magnet:?") {
        Some(rest) => rest
            .split('&')
            .find_map(|kv| kv.strip_prefix("xt=urn:btih:"))?
            .to_string(),
        None => magnet.trim().to_string(),
    };
    let candidate = candidate.trim();
    if candidate.len() == 40 && candidate.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Some(candidate.to_ascii_lowercase());
    }
    if candidate.len() == 32 {
        return base32_to_hex(candidate);
    }
    None
}

/// Decode a 32-char base32 (RFC 4648) infohash to 40-hex lowercase.
fn base32_to_hex(s: &str) -> Option<String> {
    let mut bits: u64 = 0;
    let mut nbits = 0u32;
    let mut out: Vec<u8> = Vec::with_capacity(20);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a',
            b'2'..=b'7' => c - b'2' + 26,
            _ => return None,
        };
        bits = (bits << 5) | u64::from(v);
        nbits += 5;
        if nbits >= 8 {
            nbits -= 8;
            out.push((bits >> nbits) as u8);
        }
    }
    if out.len() != 20 {
        return None;
    }
    Some(out.iter().map(|b| format!("{b:02x}")).collect())
}

/// Parse `YYYY-MM-DD[T ]HH:MM[:SS][.frac][Z|+HH:MM|-HH:MM|+HHMM]` into Unix seconds (UTC).
/// Lenient by design: any shape that does not fit yields `None` (callers surface
/// `expiration: None` rather than failing the whole call over a date format).
pub(crate) fn iso8601_to_unix(s: &str) -> Option<u64> {
    let s = s.trim();
    let (date, rest) = s.split_once(['T', ' '])?;
    let mut date_parts = date.split('-');
    let year: i64 = date_parts.next()?.parse().ok()?;
    let month: u32 = date_parts.next()?.parse().ok()?;
    let day: u32 = date_parts.next()?.parse().ok()?;
    if date_parts.next().is_some() || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let (time, offset_secs) = if let Some(t) = rest.strip_suffix(['Z', 'z']) {
        (t, 0i64)
    } else if let Some(idx) = rest.rfind(['+', '-']) {
        let (t, off) = rest.split_at(idx);
        (t, parse_utc_offset(off)?)
    } else {
        (rest, 0)
    };
    let time = time.split('.').next()?;
    let mut time_parts = time.split(':');
    let hour: i64 = time_parts.next()?.parse().ok()?;
    let minute: i64 = time_parts.next()?.parse().ok()?;
    let second: i64 = match time_parts.next() {
        Some(sec) => sec.parse().ok()?,
        None => 0,
    };
    if !(0..=23).contains(&hour) || !(0..=59).contains(&minute) || !(0..=60).contains(&second) {
        return None;
    }
    let days = days_from_civil(year, month, day);
    let total = days * 86_400 + hour * 3_600 + minute * 60 + second - offset_secs;
    u64::try_from(total).ok()
}

/// Parse `+HH:MM`, `-HH:MM`, `+HHMM`, or `+HH` into signed offset seconds.
fn parse_utc_offset(off: &str) -> Option<i64> {
    let (sign, digits) = match off.split_at_checked(1)? {
        ("+", rest) => (1i64, rest),
        ("-", rest) => (-1i64, rest),
        _ => return None,
    };
    let compact: String = digits.chars().filter(|c| *c != ':').collect();
    let (hours, minutes): (i64, i64) = match compact.len() {
        2 => (compact.parse().ok()?, 0),
        4 => {
            let (h, m) = compact.split_at(2);
            (h.parse().ok()?, m.parse().ok()?)
        }
        _ => return None,
    };
    if !(0..=23).contains(&hours) || !(0..=59).contains(&minutes) {
        return None;
    }
    Some(sign * (hours * 3_600 + minutes * 60))
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's days_from_civil algorithm).
fn days_from_civil(mut year: i64, month: u32, day: u32) -> i64 {
    if month <= 2 {
        year -= 1;
    }
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_prime = (i64::from(month) + 9) % 12;
    let day_of_year = (153 * month_prime + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// Percent-encode a query value (magnet URIs and links carry `&`, `=`, `:`).
pub(crate) fn urlencode(value: &str) -> String {
    percent_encoding::utf8_percent_encode(value, percent_encoding::NON_ALPHANUMERIC).to_string()
}

#[cfg(test)]
pub(crate) mod testutil {
    //! The replay transport: recorded response bodies answered by URL match, with every issued
    //! request captured so tests can assert the exact wire shape (method, auth channel, fields).

    use std::sync::Mutex;

    use super::{DebridError, DebridTransport, HttpBody, HttpMethod, HttpRequest, HttpResponse};

    /// One scripted route: a request matches when the method matches and the URL contains
    /// `url_part`. First match wins, in order.
    pub struct Route {
        pub method: HttpMethod,
        pub url_part: &'static str,
        pub status: u16,
        pub body: String,
    }

    impl Route {
        pub fn new(
            method: HttpMethod,
            url_part: &'static str,
            status: u16,
            body: impl Into<String>,
        ) -> Self {
            Self {
                method,
                url_part,
                status,
                body: body.into(),
            }
        }
    }

    /// One captured request (test-only; carries the fake test credentials for assertions).
    pub struct Seen {
        pub method: HttpMethod,
        pub url: String,
        pub bearer: Option<String>,
        pub query_secret: Option<(String, String)>,
        pub body: HttpBody,
    }

    pub struct ReplayTransport {
        routes: Vec<Route>,
        pub seen: Mutex<Vec<Seen>>,
    }

    impl ReplayTransport {
        pub fn new(routes: Vec<Route>) -> Self {
            Self {
                routes,
                seen: Mutex::new(Vec::new()),
            }
        }

        /// The captured calls, in issue order.
        pub fn calls(&self) -> Vec<Seen> {
            std::mem::take(&mut *self.seen.lock().expect("seen lock"))
        }
    }

    impl DebridTransport for ReplayTransport {
        fn execute(&self, req: &HttpRequest) -> Result<HttpResponse, DebridError> {
            self.seen.lock().expect("seen lock").push(Seen {
                method: req.method,
                url: req.url.clone(),
                bearer: req.bearer.clone(),
                query_secret: req
                    .query_secret
                    .as_ref()
                    .map(|(k, v)| ((*k).to_string(), v.clone())),
                body: req.body.clone(),
            });
            for route in &self.routes {
                if route.method == req.method && req.url.contains(route.url_part) {
                    return Ok(HttpResponse {
                        status: route.status,
                        body: route.body.clone(),
                    });
                }
            }
            Err(DebridError::Other(format!(
                "replay transport: no recorded route for {}",
                req.url
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso8601_parses_utc_offsets_and_fractions() {
        assert_eq!(iso8601_to_unix("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            iso8601_to_unix("2026-08-17T10:00:00.000Z"),
            Some(1_786_960_800)
        );
        // The same instant expressed with a +02:00 offset.
        assert_eq!(
            iso8601_to_unix("2026-08-17T12:00:00+02:00"),
            Some(1_786_960_800)
        );
        assert_eq!(
            iso8601_to_unix("2026-08-17T12:00:00+0200"),
            Some(1_786_960_800)
        );
        assert_eq!(iso8601_to_unix("2005-03-18T01:58:31Z"), Some(1_111_111_111));
        // Space separator, no zone: treated as UTC.
        assert_eq!(iso8601_to_unix("1970-01-01 00:00:01"), Some(1));
        assert_eq!(iso8601_to_unix("not a date"), None);
        assert_eq!(iso8601_to_unix("2026-13-01T00:00:00Z"), None);
        assert_eq!(iso8601_to_unix(""), None);
        // Pre-epoch instants have no u64 representation.
        assert_eq!(iso8601_to_unix("1969-12-31T23:59:59Z"), None);
    }

    #[test]
    fn magnet_infohash_accepts_uri_hex_and_base32() {
        let hex = "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c";
        let uri = format!("magnet:?xt=urn:btih:{hex}&dn=Name&tr=udp%3A%2F%2Ftracker");
        assert_eq!(magnet_infohash(&uri), Some(hex.to_string()));
        assert_eq!(magnet_infohash(hex), Some(hex.to_string()));
        assert_eq!(
            magnet_infohash(&hex.to_ascii_uppercase()),
            Some(hex.to_string())
        );
        // The same hash in base32.
        assert_eq!(
            magnet_infohash("3WBFL3G4PSSV7MF37AJSHWDQMLNR63I4"),
            Some(hex.to_string())
        );
        assert_eq!(
            magnet_infohash("magnet:?dn=First&xt=urn:btih:3WBFL3G4PSSV7MF37AJSHWDQMLNR63I4"),
            Some(hex.to_string())
        );
        assert_eq!(magnet_infohash("magnet:?dn=NoHash"), None);
        assert_eq!(magnet_infohash("nothexatall"), None);
        assert_eq!(magnet_infohash("magnet:?xt=urn:btih:zz!!"), None);
    }

    #[test]
    fn multipart_encoding_is_deterministic_and_well_formed() {
        let (content_type, body) = encode_multipart(&[
            ("magnet".to_string(), "magnet:?xt=urn:btih:abc".to_string()),
            ("seed".to_string(), "1".to_string()),
        ]);
        assert!(content_type.starts_with("multipart/form-data; boundary="));
        assert!(body.contains("name=\"magnet\"\r\n\r\nmagnet:?xt=urn:btih:abc\r\n"));
        assert!(body.contains("name=\"seed\"\r\n\r\n1\r\n"));
        assert!(body.ends_with(&format!("--{MULTIPART_BOUNDARY}--\r\n")));
    }

    #[test]
    fn status_fallback_maps_the_auth_and_rate_families() {
        assert_eq!(
            error_for_status("svc", "op", 401),
            DebridError::Unauthorized
        );
        assert_eq!(
            error_for_status("svc", "op", 403),
            DebridError::Unauthorized
        );
        assert_eq!(error_for_status("svc", "op", 404), DebridError::NotFound);
        assert_eq!(error_for_status("svc", "op", 429), DebridError::RateLimited);
        assert!(matches!(
            error_for_status("svc", "op", 500),
            DebridError::Other(_)
        ));
    }

    #[test]
    fn urlencode_escapes_query_metacharacters() {
        assert_eq!(urlencode("a&b=c:d"), "a%26b%3Dc%3Ad");
    }

    #[test]
    fn store_for_covers_the_four_live_services() {
        let transport: Arc<dyn DebridTransport> =
            Arc::new(testutil::ReplayTransport::new(Vec::new()));
        for (service, expect) in [
            (DebridService::RealDebrid, true),
            (DebridService::AllDebrid, true),
            (DebridService::TorBox, true),
            (DebridService::Premiumize, true),
            (DebridService::DebridLink, false),
            (DebridService::EasyDebrid, false),
            (DebridService::DmmPublic, false),
        ] {
            let store = store_for(service, Arc::clone(&transport), "k");
            assert_eq!(store.is_some(), expect, "{service:?}");
            if let Some(store) = store {
                assert_eq!(store.name(), service);
            }
        }
    }
}
