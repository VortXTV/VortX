//! The /proxy opts parser and the HLS playlist rewriter, transcribed from the
//! server.js proxy module (see contract/GOLDEN.md section 7 for the captured
//! algorithm). Pure functions, unit-tested against crafted playlists.

use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use url::Url;

/// querystring.escape-alike: encode everything but unreserved characters.
const QS_ENCODE: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~');

/// The parsed first path segment of a /proxy request:
/// `d={origin}&h={Name:Value}&h=...&r={Name:Value}...`
#[derive(Debug, Default, Clone)]
pub struct ProxyOpts {
    /// Decoded destination origin (`d=`).
    pub destination: Option<String>,
    /// Decoded request headers (`h=`), each split on the FIRST colon.
    pub headers: Vec<(String, String)>,
    /// Decoded response header overrides (`r=`), each split on the FIRST colon.
    pub response_headers: Vec<(String, String)>,
    /// The RAW (still-encoded) `h=` values in order, reused verbatim when the
    /// rewriter mints a different-origin /proxy URL.
    pub raw_h: Vec<String>,
    /// The raw opts segment as received; `/proxy/{this}` is the virtual root
    /// that relative and same-origin playlist entries resolve through.
    pub raw_segment: String,
}

fn qs_decode(raw: &str) -> String {
    // node querystring.parse: '+' is space, then percent-decode.
    let plus_as_space = raw.replace('+', " ");
    percent_encoding::percent_decode_str(&plus_as_space)
        .decode_utf8_lossy()
        .into_owned()
}

/// Split a decoded `Name:Value` on the FIRST colon (server.js
/// `parseHeaderString`); the value may itself contain colons.
fn split_header(decoded: &str) -> (String, String) {
    match decoded.split_once(':') {
        Some((n, v)) => (n.to_string(), v.to_string()),
        None => (decoded.to_string(), String::new()),
    }
}

/// Parse the raw (percent-encoded) opts segment.
pub fn parse_opts(raw_segment: &str) -> ProxyOpts {
    let mut opts = ProxyOpts { raw_segment: raw_segment.to_string(), ..Default::default() };
    for pair in raw_segment.split('&') {
        let (key, raw_value) = pair.split_once('=').unwrap_or((pair, ""));
        match key {
            "d" => {
                if opts.destination.is_none() {
                    opts.destination = Some(qs_decode(raw_value));
                }
            }
            "h" => {
                opts.raw_h.push(raw_value.to_string());
                opts.headers.push(split_header(&qs_decode(raw_value)));
            }
            "r" => opts.response_headers.push(split_header(&qs_decode(raw_value))),
            _ => {}
        }
    }
    opts
}

/// server.js `urlJoin`: join with '/' and collapse every slash run.
fn url_join(a: &str, b: &str) -> String {
    let joined = format!("{a}/{b}");
    let mut out = String::with_capacity(joined.len());
    let mut prev_slash = false;
    for c in joined.chars() {
        if c == '/' {
            if !prev_slash {
                out.push(c);
            }
            prev_slash = true;
        } else {
            prev_slash = false;
            out.push(c);
        }
    }
    out
}

/// `scheme://host[:port]` with the default port omitted (what
/// `querystring`-era server.js intends; its port-doubling bug is not copied).
fn origin_of(u: &Url) -> String {
    u.origin().ascii_serialization()
}

fn same_origin(a: &Url, b: &Url) -> bool {
    a.scheme() == b.scheme()
        && a.host_str() == b.host_str()
        && a.port_or_known_default() == b.port_or_known_default()
}

/// Rewrite one playlist URI per the captured server.js rules.
fn rewrite_uri(line: &str, virtual_root: &str, dest: &Url, raw_h: &[String]) -> String {
    if line.starts_with("http://") || line.starts_with("https://") {
        let Ok(u) = Url::parse(line) else { return line.to_string() };
        let query = u.query().map(|q| format!("?{q}")).unwrap_or_default();
        if same_origin(&u, dest) {
            // Same origin: back through the SAME opts (virtual root).
            return format!("{}{}", url_join(virtual_root, u.path()), query);
        }
        // Different origin: a fresh /proxy root carrying the same h= headers.
        let mut opts = format!("d={}", utf8_percent_encode(&origin_of(&u), QS_ENCODE));
        for h in raw_h {
            opts.push_str("&h=");
            opts.push_str(h);
        }
        return format!("/proxy/{opts}{}{}", u.path(), query);
    }
    if line.starts_with('/') {
        return url_join(virtual_root, line);
    }
    // Relative: unchanged; it resolves against the proxy URL itself, which
    // keeps every segment flowing through the proxy (captured live).
    line.to_string()
}

/// Rewrite a whole line: non-comment lines are URIs; comment/tag lines get
/// only their `URI="..."` attribute value rewritten.
fn rewrite_line(line: &str, virtual_root: &str, dest: &Url, raw_h: &[String]) -> String {
    if !line.starts_with('#') && !line.is_empty() {
        return rewrite_uri(line, virtual_root, dest, raw_h);
    }
    if let Some(start) = line.find("URI=\"") {
        let value_start = start + "URI=\"".len();
        if let Some(rel_end) = line[value_start..].find('"') {
            let value = &line[value_start..value_start + rel_end];
            let rewritten = rewrite_uri(value, virtual_root, dest, raw_h);
            return format!(
                "{}{}{}",
                &line[..value_start],
                rewritten,
                &line[value_start + rel_end..]
            );
        }
    }
    line.to_string()
}

/// Rewrite an entire playlist body, preserving line terminators.
pub fn rewrite_playlist(body: &str, virtual_root: &str, dest: &Url, raw_h: &[String]) -> String {
    let mut out = String::with_capacity(body.len() + body.len() / 2);
    for piece in body.split_inclusive('\n') {
        let (content, term) = match piece.strip_suffix("\r\n") {
            Some(c) => (c, "\r\n"),
            None => match piece.strip_suffix('\n') {
                Some(c) => (c, "\n"),
                None => (piece, ""),
            },
        };
        out.push_str(&rewrite_line(content, virtual_root, dest, raw_h));
        out.push_str(term);
    }
    out
}

/// Playlist detection: dest path extension `.m3u`/`.m3u8` OR a content-type
/// containing `mpegurl` (case-insensitive), per the server.js source.
pub fn is_playlist(dest_path: &str, content_type: Option<&str>) -> bool {
    let last = dest_path.rsplit('/').next().unwrap_or("");
    let by_ext = matches!(
        last.rfind('.').map(|i| &last[i..]),
        Some(".m3u") | Some(".m3u8")
    );
    let by_type = content_type
        .map(|c| c.to_ascii_lowercase().contains("mpegurl"))
        .unwrap_or(false);
    by_ext || by_type
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts_segment(port: u16) -> String {
        format!(
            "d=http%3A%2F%2F127.0.0.1%3A{port}&h=Referer%3Ahttp%3A%2F%2Fx.example%2Fpage%3Fq%3D1&h=User-Agent%3AVortX%2F1.0"
        )
    }

    #[test]
    fn parse_opts_splits_h_on_first_colon() {
        let o = parse_opts(&opts_segment(8901));
        assert_eq!(o.destination.as_deref(), Some("http://127.0.0.1:8901"));
        assert_eq!(o.headers.len(), 2);
        assert_eq!(o.headers[0].0, "Referer");
        assert_eq!(o.headers[0].1, "http://x.example/page?q=1"); // colons survive in the value
        assert_eq!(o.headers[1], ("User-Agent".into(), "VortX/1.0".into()));
    }

    #[test]
    fn rewrite_covers_all_captured_cases() {
        let seg = opts_segment(8901);
        let vroot = format!("/proxy/{seg}");
        let o = parse_opts(&seg);
        let dest = Url::parse("http://127.0.0.1:8901/hls/master.m3u8").unwrap();
        let body = concat!(
            "#EXTM3U\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=1\n",
            "variant/index.m3u8\n",
            "/root/abs.m3u8\n",
            "http://127.0.0.1:8901/same/origin.m3u8?tok=1\n",
            "https://cdn.example.com/other/low.m3u8?x=2\n",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"/keys/k1.bin\"\n",
            "#EXT-X-MAP:URI=\"init.mp4\"\n",
        );
        let out = rewrite_playlist(body, &vroot, &dest, &o.raw_h);
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines[2], "variant/index.m3u8"); // relative: untouched
        assert_eq!(lines[3], format!("{vroot}/root/abs.m3u8"));
        assert_eq!(lines[4], format!("{vroot}/same/origin.m3u8?tok=1"));
        assert_eq!(
            lines[5],
            format!(
                "/proxy/d=https%3A%2F%2Fcdn.example.com&h={}&h={}/other/low.m3u8?x=2",
                "Referer%3Ahttp%3A%2F%2Fx.example%2Fpage%3Fq%3D1", "User-Agent%3AVortX%2F1.0"
            )
        );
        assert_eq!(lines[6], format!("#EXT-X-KEY:METHOD=AES-128,URI=\"{vroot}/keys/k1.bin\""));
        assert_eq!(lines[7], "#EXT-X-MAP:URI=\"init.mp4\""); // relative URI attr: untouched
    }

    #[test]
    fn playlist_detection() {
        assert!(is_playlist("/a/b/master.m3u8", None));
        assert!(is_playlist("/a/b/master.m3u", None));
        assert!(is_playlist("/x", Some("application/vnd.apple.MPEGURL")));
        assert!(!is_playlist("/a/video.mp4", Some("video/mp4")));
    }
}
