//! M3U / M3U8 IPTV playlist parser. Tolerant, dependency-free, and PANIC-FREE (mirroring the NZB parser):
//! unknown directives are ignored, a bare URL with no preceding #EXTINF still yields an entry, a malformed
//! #EXTINF degrades field by field, and a pending entry with no URL by end of input is dropped. Captures the
//! two directives most parsers drop: #EXTVLCOPT (HTTP headers a gated CDN needs) and #KODIPROP (the
//! inputstream/DRM hints), so the host can actually play header-gated and DRM channels.

use serde::{Deserialize, Serialize};

/// A parsed playlist: the EPG source URLs declared on the #EXTM3U header, plus the channel entries.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Playlist {
    /// XMLTV EPG source URLs from the #EXTM3U header (`url-tvg` / `x-tvg-url`), comma-split.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub epg_urls: Vec<String>,
    pub entries: Vec<M3uEntry>,
}

/// One channel entry: the stream URL plus the #EXTINF metadata and any per-entry VLC/Kodi directives.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct M3uEntry {
    pub url: String,
    /// EXTINF duration in WHOLE seconds; `-1` for a live (unbounded) channel; `0` when no #EXTINF declared
    /// it. Integer (a fractional VOD duration is truncated) so nothing on the identity path is a float.
    pub duration_secs: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tvg_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tvg_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tvg_logo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_title: Option<String>,
    #[serde(default)]
    pub display_name: String,
    /// Every other EXTINF attribute (tvg-chno, tvg-shift, catchup, catchup-source, ...), in source order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attributes: Vec<(String, String)>,
    /// HTTP headers from #EXTVLCOPT (http-user-agent -> User-Agent, http-referrer -> Referer, http-origin ->
    /// Origin; any other key kept verbatim). The host injects these when fetching the stream.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub headers: Vec<(String, String)>,
    /// #KODIPROP directives (inputstream.adaptive.license_type / license_key / manifest_type, ...) kept raw
    /// for the host inputstream/DRM layer; the structured DRM descriptor is a later chunk.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub props: Vec<(String, String)>,
}

/// Parse an M3U/M3U8 IPTV playlist. See the module docs for the tolerance contract; never panics.
pub fn parse_m3u(text: &str) -> Playlist {
    let mut playlist = Playlist::default();
    let mut pending: Option<M3uEntry> = None;

    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXTM3U") {
            for (k, v) in parse_attrs(rest) {
                if k == "url-tvg" || k == "x-tvg-url" {
                    playlist.epg_urls.extend(
                        v.split(',')
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty()),
                    );
                }
            }
        } else if let Some(rest) = line.strip_prefix("#EXTINF:") {
            let mut e = M3uEntry::default();
            apply_extinf(rest, &mut e);
            pending = Some(e);
        } else if let Some(rest) = line.strip_prefix("#EXTVLCOPT:") {
            if let Some((k, v)) = split_kv(rest) {
                pending
                    .get_or_insert_with(M3uEntry::default)
                    .headers
                    .push((vlc_header_name(&k), v));
            }
        } else if let Some(rest) = line.strip_prefix("#KODIPROP:") {
            if let Some((k, v)) = split_kv(rest) {
                pending.get_or_insert_with(M3uEntry::default).props.push((k, v));
            }
        } else if line.starts_with('#') {
            // unknown directive: tolerated and ignored.
        } else {
            // a URL line completes the (possibly default) pending entry.
            let mut e = pending.take().unwrap_or_default();
            e.url = line.to_string();
            playlist.entries.push(e);
        }
    }
    playlist
}

/// `#EXTINF:` payload, e.g. `-1 tvg-id="cnn" group-title="News",CNN HD`. Splits the display name at the first
/// UNQUOTED comma, reads the integer duration (first token), and folds the `key="value"` attributes in.
fn apply_extinf(rest: &str, e: &mut M3uEntry) {
    let (head, name) = split_unquoted_comma(rest);
    e.display_name = name.trim().to_string();
    let head = head.trim();
    let (dur_tok, attr_str) = match head.find(char::is_whitespace) {
        Some(i) => (&head[..i], head[i..].trim_start()),
        None => (head, ""),
    };
    // Integer part only (float-free); a missing/garbage duration is treated as live (-1).
    e.duration_secs = dur_tok
        .split('.')
        .next()
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(-1);
    for (k, v) in parse_attrs(attr_str) {
        match k.as_str() {
            "tvg-id" => e.tvg_id = Some(v),
            "tvg-name" => e.tvg_name = Some(v),
            "tvg-logo" => e.tvg_logo = Some(v),
            "group-title" => e.group_title = Some(v),
            _ => e.attributes.push((k, v)),
        }
    }
}

/// Split at the first comma that is NOT inside a double-quoted value, so a `group-title="News, Sports"` does
/// not get cut at the comma inside the quotes. Returns `(before, after)`; `after` is empty if no such comma.
fn split_unquoted_comma(s: &str) -> (&str, &str) {
    let mut in_q = false;
    for (i, c) in s.char_indices() {
        match c {
            '"' => in_q = !in_q,
            ',' if !in_q => return (&s[..i], &s[i + 1..]),
            _ => {}
        }
    }
    (s, "")
}

/// Parse `key="value"` (or unquoted `key=value`) attribute pairs in source order. Byte-scans but only ever
/// starts/stops at ASCII delimiters (`=`, `"`, whitespace), so UTF-8 values (logos, names) never split a char.
fn parse_attrs(s: &str) -> Vec<(String, String)> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i].is_ascii_whitespace() || b[i] == b',' {
            i += 1;
            continue;
        }
        let ks = i;
        while i < b.len() && b[i] != b'=' && !b[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= b.len() || b[i] != b'=' {
            // a token with no '=': not an attribute, skip it.
            while i < b.len() && !b[i].is_ascii_whitespace() {
                i += 1;
            }
            continue;
        }
        let key = s[ks..i].to_string();
        i += 1; // skip '='
        let val = if i < b.len() && b[i] == b'"' {
            i += 1;
            let vs = i;
            while i < b.len() && b[i] != b'"' {
                i += 1;
            }
            let v = s[vs..i].to_string();
            if i < b.len() {
                i += 1; // skip closing quote
            }
            v
        } else {
            let vs = i;
            while i < b.len() && !b[i].is_ascii_whitespace() {
                i += 1;
            }
            s[vs..i].to_string()
        };
        if !key.is_empty() {
            out.push((key, val));
        }
    }
    out
}

/// Split a `key=value` directive payload (#EXTVLCOPT / #KODIPROP), trimming an optional quoted value.
fn split_kv(s: &str) -> Option<(String, String)> {
    let (k, v) = s.trim().split_once('=')?;
    Some((k.trim().to_string(), v.trim().trim_matches('"').to_string()))
}

/// Map a VLC option key to its HTTP header name; unknown keys pass through verbatim.
fn vlc_header_name(k: &str) -> String {
    match k {
        "http-user-agent" => "User-Agent".to_string(),
        "http-referrer" => "Referer".to_string(),
        "http-origin" => "Origin".to_string(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_full_channel_with_headers_and_props() {
        let text = "#EXTM3U url-tvg=\"http://epg.xml\"\n\
            #EXTINF:-1 tvg-id=\"cnn.us\" tvg-name=\"CNN\" tvg-logo=\"http://l/cnn.png\" group-title=\"News\" tvg-chno=\"5\",CNN HD\n\
            #EXTVLCOPT:http-user-agent=Mozilla/5.0\n\
            #KODIPROP:inputstream.adaptive.license_type=clearkey\n\
            http://stream/cnn.m3u8\n";
        let p = parse_m3u(text);
        assert_eq!(p.epg_urls, vec!["http://epg.xml"]);
        assert_eq!(p.entries.len(), 1);
        let e = &p.entries[0];
        assert_eq!(e.url, "http://stream/cnn.m3u8");
        assert_eq!(e.duration_secs, -1);
        assert_eq!(e.tvg_id.as_deref(), Some("cnn.us"));
        assert_eq!(e.tvg_name.as_deref(), Some("CNN"));
        assert_eq!(e.tvg_logo.as_deref(), Some("http://l/cnn.png"));
        assert_eq!(e.group_title.as_deref(), Some("News"));
        assert_eq!(e.display_name, "CNN HD");
        assert_eq!(e.attributes, vec![("tvg-chno".to_string(), "5".to_string())]);
        assert_eq!(e.headers, vec![("User-Agent".to_string(), "Mozilla/5.0".to_string())]);
        assert_eq!(
            e.props,
            vec![("inputstream.adaptive.license_type".to_string(), "clearkey".to_string())]
        );
    }

    #[test]
    fn a_comma_inside_a_quoted_attribute_does_not_cut_the_name() {
        let p = parse_m3u("#EXTINF:-1 group-title=\"News, Sports\",My Channel\nhttp://x\n");
        let e = &p.entries[0];
        assert_eq!(e.group_title.as_deref(), Some("News, Sports"));
        assert_eq!(e.display_name, "My Channel");
    }

    #[test]
    fn a_bare_url_with_no_extinf_still_yields_an_entry() {
        let p = parse_m3u("#EXTM3U\nhttp://a\nhttp://b\n");
        assert_eq!(p.entries.len(), 2);
        assert_eq!(p.entries[0].url, "http://a");
        assert_eq!(p.entries[1].url, "http://b");
    }

    #[test]
    fn fractional_vod_duration_is_truncated_to_an_integer() {
        let p = parse_m3u("#EXTINF:7200.500 tvg-id=\"m\",Movie\nhttp://m\n");
        assert_eq!(p.entries[0].duration_secs, 7200);
    }

    #[test]
    fn utf8_attribute_values_do_not_panic_or_split() {
        let p = parse_m3u("#EXTINF:-1 tvg-name=\"Café Noir\",Café\nhttp://c\n");
        assert_eq!(p.entries[0].tvg_name.as_deref(), Some("Café Noir"));
        assert_eq!(p.entries[0].display_name, "Café");
    }

    #[test]
    fn a_pending_extinf_with_no_url_is_dropped() {
        let p = parse_m3u("#EXTINF:-1,Orphan\n");
        assert!(p.entries.is_empty());
    }
}
