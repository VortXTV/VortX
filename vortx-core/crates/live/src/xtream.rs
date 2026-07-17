//! LT-XTREAM: pure URL templating for the Xtream Codes (`player_api`) IPTV portal, the most common paid-IPTV
//! backend. No fetch, no clock (the host passes `now` for timeshift), no float. The portal owns the
//! credentials with the password as a redaction-only [`Secret`]; every builder `reveal()`s the creds ONLY
//! into the returned URL (the actual fetch URL) and nowhere else. `Debug`/`Display` never print the creds,
//! and [`XtreamPortal::cache_key`] derives a stable one-way handle so a portal can be keyed in cache/hive
//! without leaking. The timeshift datetime reuses the LT-CATCHUP [`render_catchup`] engine, so there is ONE
//! civil-date implementation in the crate.

use core::fmt;

use crate::catchup::{render_catchup, CatchupCtx};
use crate::hash::fnv1a64;
use crate::secret::Secret;

/// The three Xtream stream kinds and their URL path segment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamKind {
    Live,
    Vod,
    Series,
}

impl StreamKind {
    fn path(self) -> &'static str {
        match self {
            StreamKind::Live => "live",
            StreamKind::Vod => "movie",
            StreamKind::Series => "series",
        }
    }
}

/// An Xtream Codes portal: base URL + credentials (password redaction-only). Build URLs with the methods;
/// the creds appear only in the returned URLs, never in `Debug`/`Display`/`cache_key`.
#[derive(Clone)]
pub struct XtreamPortal {
    base_url: String,
    username: String,
    password: Secret,
}

impl XtreamPortal {
    /// Wrap a portal. The base URL's trailing slash is trimmed so path joins are exact.
    pub fn new(base_url: impl Into<String>, username: impl Into<String>, password: Secret) -> Self {
        let mut base_url = base_url.into();
        while base_url.ends_with('/') {
            base_url.pop();
        }
        Self {
            base_url,
            username: username.into(),
            password,
        }
    }

    /// A stable, one-way cache/identity key for this portal (base + user + the password hash). Safe to key in
    /// cache or a hive fact: it is the same for the same portal on every device and contains no credential.
    pub fn cache_key(&self) -> String {
        let material = format!(
            "{}\u{0}{}\u{0}{}",
            self.base_url,
            self.username,
            self.password.key()
        );
        format!("xt:{:016x}", fnv1a64(material.as_bytes()))
    }

    /// The `player_api.php` URL for an optional `action` plus query `params` (keys are literal, values are
    /// encodeURIComponent-encoded). The credentials are always included, encoded, in the query.
    pub fn player_api(&self, action: Option<&str>, params: &[(&str, &str)]) -> String {
        let mut url = format!(
            "{}/player_api.php?username={}&password={}",
            self.base_url,
            enc(&self.username),
            enc(self.password.reveal()),
        );
        if let Some(a) = action {
            url.push_str("&action=");
            url.push_str(&enc(a));
        }
        for (k, v) in params {
            url.push('&');
            url.push_str(k);
            url.push('=');
            url.push_str(&enc(v));
        }
        url
    }

    /// `player_api.php` with no action: the account/auth info endpoint.
    pub fn auth_url(&self) -> String {
        self.player_api(None, &[])
    }

    pub fn live_categories(&self) -> String {
        self.player_api(Some("get_live_categories"), &[])
    }

    pub fn live_streams(&self, category_id: Option<&str>) -> String {
        self.player_api(Some("get_live_streams"), &opt("category_id", category_id))
    }

    pub fn vod_categories(&self) -> String {
        self.player_api(Some("get_vod_categories"), &[])
    }

    pub fn vod_streams(&self, category_id: Option<&str>) -> String {
        self.player_api(Some("get_vod_streams"), &opt("category_id", category_id))
    }

    pub fn series_categories(&self) -> String {
        self.player_api(Some("get_series_categories"), &[])
    }

    pub fn series(&self, category_id: Option<&str>) -> String {
        self.player_api(Some("get_series"), &opt("category_id", category_id))
    }

    pub fn series_info(&self, series_id: &str) -> String {
        self.player_api(Some("get_series_info"), &[("series_id", series_id)])
    }

    pub fn vod_info(&self, vod_id: &str) -> String {
        self.player_api(Some("get_vod_info"), &[("vod_id", vod_id)])
    }

    /// The short EPG for a live stream (the next few programmes), optionally limited.
    pub fn short_epg(&self, stream_id: &str, limit: Option<&str>) -> String {
        let mut params = vec![("stream_id", stream_id)];
        if let Some(l) = limit {
            params.push(("limit", l));
        }
        self.player_api(Some("get_short_epg"), &params)
    }

    /// The full EPG table for a live stream.
    pub fn simple_data_table(&self, stream_id: &str) -> String {
        self.player_api(Some("get_simple_data_table"), &[("stream_id", stream_id)])
    }

    /// The playable stream URL: `{base}/{kind}/{user}/{pass}/{stream_id}.{ext}` with the creds encoded as
    /// path segments.
    pub fn stream_url(&self, kind: StreamKind, stream_id: &str, ext: &str) -> String {
        format!(
            "{}/{}/{}/{}/{}.{}",
            self.base_url,
            kind.path(),
            enc(&self.username),
            enc(self.password.reveal()),
            enc(stream_id),
            enc(ext),
        )
    }

    pub fn live_url(&self, stream_id: &str, ext: &str) -> String {
        self.stream_url(StreamKind::Live, stream_id, ext)
    }

    pub fn vod_url(&self, stream_id: &str, ext: &str) -> String {
        self.stream_url(StreamKind::Vod, stream_id, ext)
    }

    pub fn series_url(&self, stream_id: &str, ext: &str) -> String {
        self.stream_url(StreamKind::Series, stream_id, ext)
    }

    /// The timeshift/catchup URL: `{base}/timeshift/{user}/{pass}/{duration_min}/{Y-m-d:H-M}/{stream_id}.ts`.
    /// The datetime is rendered by the shared LT-CATCHUP engine (one civil-date implementation); the duration
    /// is the programme length in WHOLE MINUTES (Xtream's unit), derived from the same window.
    pub fn timeshift_url(
        &self,
        stream_id: &str,
        start_utc_ms: i64,
        stop_utc_ms: i64,
        now_ms: i64,
    ) -> String {
        let ctx = CatchupCtx::from_window(start_utc_ms, stop_utc_ms, now_ms);
        let datetime = render_catchup("{Y}-{m}-{d}:{H}-{M}", &ctx);
        let duration_min = ctx.duration_secs / 60;
        format!(
            "{}/timeshift/{}/{}/{}/{}/{}.ts",
            self.base_url,
            enc(&self.username),
            enc(self.password.reveal()),
            duration_min,
            datetime,
            enc(stream_id),
        )
    }
}

impl fmt::Debug for XtreamPortal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Never print the username or password; the cache key is correlatable but leak-free.
        f.debug_struct("XtreamPortal")
            .field("base_url", &self.base_url)
            .field("key", &self.cache_key())
            .finish()
    }
}

impl fmt::Display for XtreamPortal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} (xtream, redacted creds)", self.base_url)
    }
}

/// A 0-or-1 query param helper.
fn opt<'a>(key: &'a str, value: Option<&'a str>) -> Vec<(&'a str, &'a str)> {
    value.map(|v| vec![(key, v)]).unwrap_or_default()
}

/// encodeURIComponent-style percent encoding: keep the RFC 3986 unreserved set (`A-Za-z0-9 - . _ ~`),
/// percent-encode every other byte as uppercase `%XX`. Hand-rolled (no dependency), byte-reproducible.
fn enc(s: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push('%');
            out.push(HEX[(b >> 4) as usize] as char);
            out.push(HEX[(b & 0x0f) as usize] as char);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn portal() -> XtreamPortal {
        XtreamPortal::new("http://host:8080/", "alice", Secret::new("p@ss/word"))
    }

    #[test]
    fn base_url_trailing_slash_is_trimmed() {
        let p = XtreamPortal::new("http://host:8080///", "u", Secret::new("x"));
        assert_eq!(
            p.auth_url(),
            "http://host:8080/player_api.php?username=u&password=x"
        );
    }

    #[test]
    fn player_api_encodes_credentials_in_the_query() {
        let p = portal();
        assert_eq!(
            p.auth_url(),
            "http://host:8080/player_api.php?username=alice&password=p%40ss%2Fword"
        );
        assert_eq!(
            p.live_categories(),
            "http://host:8080/player_api.php?username=alice&password=p%40ss%2Fword&action=get_live_categories"
        );
        assert_eq!(
            p.live_streams(Some("5")),
            "http://host:8080/player_api.php?username=alice&password=p%40ss%2Fword&action=get_live_streams&category_id=5"
        );
        assert_eq!(
            p.short_epg("123", Some("10")),
            "http://host:8080/player_api.php?username=alice&password=p%40ss%2Fword&action=get_short_epg&stream_id=123&limit=10"
        );
    }

    #[test]
    fn stream_urls_encode_creds_as_path_segments() {
        let p = portal();
        assert_eq!(
            p.live_url("123", "ts"),
            "http://host:8080/live/alice/p%40ss%2Fword/123.ts"
        );
        assert_eq!(
            p.vod_url("99", "mkv"),
            "http://host:8080/movie/alice/p%40ss%2Fword/99.mkv"
        );
        assert_eq!(
            p.series_url("7", "mp4"),
            "http://host:8080/series/alice/p%40ss%2Fword/7.mp4"
        );
    }

    #[test]
    fn timeshift_reuses_the_catchup_datetime_and_minutes() {
        let p = portal();
        // 2026-06-29 14:00:00 UTC, 1h programme.
        let url = p.timeshift_url(
            "123",
            1_782_741_600_000,
            1_782_745_200_000,
            1_782_745_800_000,
        );
        assert_eq!(
            url,
            "http://host:8080/timeshift/alice/p%40ss%2Fword/60/2026-06-29:14-00/123.ts"
        );
        // The datetime matches the shared LT-CATCHUP render exactly.
        let ctx = CatchupCtx::from_window(1_782_741_600_000, 1_782_745_200_000, 1_782_745_800_000);
        assert!(url.contains(&render_catchup("{Y}-{m}-{d}:{H}-{M}", &ctx)));
    }

    #[test]
    fn debug_and_display_never_leak_credentials() {
        let p = portal();
        let dbg = format!("{p:?}");
        let disp = format!("{p}");
        assert!(!dbg.contains("p@ss") && !dbg.contains("alice"));
        assert!(!disp.contains("p@ss") && !disp.contains("alice"));
        assert!(dbg.contains("http://host:8080")); // base is fine to show
    }

    #[test]
    fn cache_key_is_stable_and_credential_free() {
        let a = portal().cache_key();
        let b = portal().cache_key();
        assert_eq!(a, b); // deterministic
        assert!(!a.contains("p@ss") && !a.contains("alice"));
        // A different password -> a different key.
        let other =
            XtreamPortal::new("http://host:8080", "alice", Secret::new("different")).cache_key();
        assert_ne!(a, other);
    }
}
