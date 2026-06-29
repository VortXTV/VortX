//! XMLTV EPG parser with the timezone -> UTC integer fence (LT2). Tolerant, dependency-free, panic-free: a
//! lightweight tag scanner (NOT a full XML parser) extracts `<channel>` and `<programme>` blocks the way
//! XMLTV is actually shaped, decoding the five basic entities and degrading field by field on malformed input.
//!
//! The 10x correctness fence: ALL times are normalized to a UTC INTEGER (ms since the Unix epoch) at the
//! parse boundary. The XMLTV `YYYYMMDDHHMMSS +zzzz` grammar (and the `+HHMM`/`-HHMM` offset) is converted to
//! UTC ms with hand-rolled integer civil-date math (Howard Hinnant's days_from_civil) so there is NO float,
//! NO `chrono` dependency, and the SAME boundary on every platform. Off-by-an-hour EPG (the universal IPTV
//! pain) becomes impossible. A bare datetime with no offset is treated as UTC (the deterministic default; the
//! host can correct with a known local zone). The host supplies the clock; this module only parses bytes.

use serde::{Deserialize, Serialize};

/// A parsed XMLTV document: the channels and the programmes, times already normalized to UTC ms.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Epg {
    pub channels: Vec<EpgChannel>,
    pub programs: Vec<Program>,
}

/// One `<channel>` definition.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EpgChannel {
    pub id: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub display_names: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

/// A canonical season/episode, 1-indexed (the xmltv_ns 0-index is normalized by +1).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EpisodeNum {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
}

/// One `<programme>`: its airing window in UTC ms plus the parsed metadata.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Program {
    pub channel_id: String,
    /// Airing start, UTC milliseconds since the Unix epoch (normalized from the XMLTV grammar + offset).
    pub start_utc_ms: i64,
    /// Airing stop, UTC ms; equals `start_utc_ms` when the programme omits a parseable `stop`.
    pub stop_utc_ms: i64,
    #[serde(default)]
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sub_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub desc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode_num: Option<EpisodeNum>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_new: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_premiere: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rating: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

/// Parse an XMLTV document. Tolerant + panic-free; a programme missing a `channel` or an unparseable `start`
/// is skipped (it is unusable), everything else degrades field by field.
pub fn parse_xmltv(text: &str) -> Epg {
    let mut epg = Epg::default();

    for (open, inner) in blocks(text, "channel") {
        let Some(id) = attr(open, "id") else { continue };
        epg.channels.push(EpgChannel {
            id,
            display_names: child_all(inner, "display-name")
                .into_iter()
                .map(|(_, t)| t)
                .filter(|t| !t.is_empty())
                .collect(),
            icon: child_icon(inner),
        });
    }

    for (open, inner) in blocks(text, "programme") {
        let (Some(channel_id), Some(start)) = (attr(open, "channel"), attr(open, "start")) else {
            continue;
        };
        let Some(start_utc_ms) = parse_xmltv_time(&start) else {
            continue;
        };
        let stop_utc_ms = attr(open, "stop")
            .as_deref()
            .and_then(parse_xmltv_time)
            .unwrap_or(start_utc_ms);
        epg.programs.push(Program {
            channel_id,
            start_utc_ms,
            stop_utc_ms,
            title: child_text(inner, "title").unwrap_or_default(),
            sub_title: child_text(inner, "sub-title"),
            desc: child_text(inner, "desc"),
            category: child_text(inner, "category"),
            episode_num: parse_episode_num(inner),
            is_new: has_tag(inner, "new"),
            is_premiere: has_tag(inner, "premiere"),
            rating: child_rating(inner),
            icon: child_icon(inner),
        });
    }

    epg
}

// --- the timezone -> UTC integer fence ---

/// Parse an XMLTV datetime (`YYYYMMDDHHMMSS [+/-HHMM]`, with optional seconds) to UTC ms. Hand-rolled
/// integer math, no float, no chrono. A bare datetime (no offset) is treated as UTC.
pub fn parse_xmltv_time(s: &str) -> Option<i64> {
    let s = s.trim();
    let (dt, off) = match s.split_once(char::is_whitespace) {
        Some((d, o)) => (d, o.trim()),
        None => (s, ""),
    };
    if dt.len() < 8 || !dt.bytes().take(8).all(|b| b.is_ascii_digit()) {
        return None;
    }
    let field = |start: usize, len: usize| -> Option<i64> {
        let sub = dt.get(start..start + len)?;
        if sub.bytes().all(|b| b.is_ascii_digit()) {
            sub.parse::<i64>().ok()
        } else {
            None
        }
    };
    let year = field(0, 4)?;
    let month = field(4, 2)?;
    let day = field(6, 2)?;
    let hour = field(8, 2).unwrap_or(0);
    let min = field(10, 2).unwrap_or(0);
    let sec = field(12, 2).unwrap_or(0);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || min > 59 || sec > 60 {
        return None;
    }
    let days = days_from_civil(year, month, day);
    let local_secs = days * 86_400 + hour * 3_600 + min * 60 + sec;
    // Convert local -> UTC by subtracting the offset (a +0200 local instant is 2h earlier in UTC).
    Some((local_secs - offset_secs(off)) * 1_000)
}

/// Days from the Unix epoch (1970-01-01) for a proleptic-Gregorian civil date. Howard Hinnant's algorithm;
/// pure integer, valid for any year.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = (m + 9) % 12; // march = 0
    let doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
}

/// Parse an `+HHMM` / `-HHMM` (colon-tolerant) timezone offset to signed seconds; empty/garbage -> 0.
fn offset_secs(o: &str) -> i64 {
    let o = o.trim();
    if o.is_empty() {
        return 0;
    }
    let (sign, rest) = match o.as_bytes().first() {
        Some(b'-') => (-1, &o[1..]),
        Some(b'+') => (1, &o[1..]),
        _ => (1, o),
    };
    let digits: String = rest.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.len() < 2 {
        return 0;
    }
    let hh: i64 = digits[0..2].parse().unwrap_or(0);
    let mm: i64 = if digits.len() >= 4 {
        digits[2..4].parse().unwrap_or(0)
    } else {
        0
    };
    sign * (hh * 3_600 + mm * 60)
}

// --- episode-num across the three XMLTV systems ---

/// Canonical season/episode from the `<episode-num>` elements, preferring `xmltv_ns` (0-indexed, normalized
/// +1) then `onscreen` (SxxEyy). `dd_progid` carries no S/E and is ignored here.
fn parse_episode_num(inner: &str) -> Option<EpisodeNum> {
    let mut ns = None;
    let mut onscreen = None;
    for (open, text) in child_all(inner, "episode-num") {
        match attr(open, "system").as_deref() {
            Some("xmltv_ns") => ns = Some(text),
            Some("onscreen") => onscreen = Some(text),
            // A systemless episode-num is conventionally xmltv_ns.
            None if ns.is_none() => ns = Some(text),
            _ => {}
        }
    }
    if let Some(t) = ns {
        if let Some(e) = parse_xmltv_ns(&t) {
            return Some(e);
        }
    }
    onscreen.and_then(|t| parse_onscreen(&t))
}

/// `season.episode.part`, each 0-indexed and optionally `X/Y`; normalized to 1-indexed.
fn parse_xmltv_ns(s: &str) -> Option<EpisodeNum> {
    let mut it = s.split('.');
    let season = num_before_slash(it.next().unwrap_or("")).map(|n| n + 1);
    let episode = num_before_slash(it.next().unwrap_or("")).map(|n| n + 1);
    if season.is_none() && episode.is_none() {
        None
    } else {
        Some(EpisodeNum { season, episode })
    }
}

fn num_before_slash(field: &str) -> Option<u32> {
    let f = field.split('/').next().unwrap_or("").trim();
    (!f.is_empty()).then(|| f.parse::<u32>().ok()).flatten()
}

/// Parse an `onscreen` value like `S01E02` (already 1-indexed). Scans case-insensitively for `s<digits>` and
/// `e<digits>`.
fn parse_onscreen(s: &str) -> Option<EpisodeNum> {
    let lower = s.to_ascii_lowercase();
    let b = lower.as_bytes();
    let read_after = |marker: u8| -> Option<u32> {
        let pos = b.iter().position(|&c| c == marker)?;
        let digits: String = b[pos + 1..]
            .iter()
            .take_while(|c| c.is_ascii_digit())
            .map(|&c| c as char)
            .collect();
        (!digits.is_empty()).then(|| digits.parse::<u32>().ok()).flatten()
    };
    let season = read_after(b's');
    let episode = read_after(b'e');
    if season.is_none() && episode.is_none() {
        None
    } else {
        Some(EpisodeNum { season, episode })
    }
}

// --- the tolerant tag scanner ---

/// All `<tag ...>inner</tag>` blocks (and self-closing `<tag .../>` with empty inner), as
/// `(opening-tag-attrs, inner)`. Boundary-checked so `<tag` does not match `<tagsomething`. Never panics.
fn blocks<'a>(text: &'a str, tag: &str) -> Vec<(&'a str, &'a str)> {
    let open = format!("<{tag}");
    let close = format!("</{tag}>");
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(rel) = text[i..].find(&open) {
        let abs = i + rel;
        let after = text[abs + open.len()..].chars().next();
        if !matches!(after, Some(c) if c.is_whitespace() || c == '>' || c == '/') {
            i = abs + open.len();
            continue;
        }
        let Some(gt_rel) = text[abs..].find('>') else { break };
        let gt = abs + gt_rel;
        let attrs = &text[abs + open.len()..gt];
        if attrs.ends_with('/') {
            out.push((attrs.trim_end_matches('/'), ""));
            i = gt + 1;
            continue;
        }
        match text[gt + 1..].find(&close) {
            Some(crel) => {
                out.push((attrs, &text[gt + 1..gt + 1 + crel]));
                i = gt + 1 + crel + close.len();
            }
            None => {
                out.push((attrs, &text[gt + 1..]));
                break;
            }
        }
    }
    out
}

/// Extract a quoted attribute value (`name="v"` or `name='v'`) from an opening-tag attr string; entities
/// decoded. Boundary-checked so `id` does not match `xid`.
fn attr(open: &str, name: &str) -> Option<String> {
    let mut search = 0;
    while let Some(rel) = open[search..].find(name) {
        let at = search + rel;
        let before_ok = at == 0
            || open[..at]
                .chars()
                .last()
                .is_some_and(|c| c.is_whitespace());
        let rest = open[at + name.len()..].trim_start();
        if before_ok {
            if let Some(after_eq) = rest.strip_prefix('=') {
                let after_eq = after_eq.trim_start();
                for q in ['"', '\''] {
                    if let Some(v) = after_eq.strip_prefix(q) {
                        if let Some(end) = v.find(q) {
                            return Some(decode_entities(&v[..end]));
                        }
                    }
                }
            }
        }
        search = at + name.len();
    }
    None
}

/// First `<tag>text</tag>` inner text (trimmed, entity-decoded).
fn child_text(inner: &str, tag: &str) -> Option<String> {
    blocks(inner, tag)
        .into_iter()
        .next()
        .map(|(_, t)| decode_entities(t.trim()))
        .filter(|t| !t.is_empty())
}

/// All `<tag ...>text</tag>` as `(attrs, decoded-trimmed-text)`.
fn child_all<'a>(inner: &'a str, tag: &str) -> Vec<(&'a str, String)> {
    blocks(inner, tag)
        .into_iter()
        .map(|(a, t)| (a, decode_entities(t.trim())))
        .collect()
}

/// Whether `<tag>`/`<tag/>` is present (for the empty flags `<new/>` / `<premiere/>`).
fn has_tag(inner: &str, tag: &str) -> bool {
    !blocks(inner, tag).is_empty()
}

/// `<icon src="...">` of the first icon child.
fn child_icon(inner: &str) -> Option<String> {
    blocks(inner, "icon")
        .into_iter()
        .next()
        .and_then(|(open, _)| attr(open, "src"))
}

/// `<rating><value>X</value></rating>` of the first rating child.
fn child_rating(inner: &str) -> Option<String> {
    let (_, r) = blocks(inner, "rating").into_iter().next()?;
    child_text(r, "value")
}

/// Decode the five predefined XML entities. (Numeric character references are left as-is; EPG text rarely
/// uses them and a tolerant parser must not panic on a malformed one.)
fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_is_zero_and_a_known_date_is_exact() {
        // 1970-01-01T00:00:00Z = 0 ms.
        assert_eq!(parse_xmltv_time("19700101000000 +0000"), Some(0));
        // 2026-06-29T14:00:00Z (verified epoch).
        assert_eq!(parse_xmltv_time("20260629140000 +0000"), Some(1_782_741_600_000));
    }

    #[test]
    fn offset_is_applied_to_reach_the_same_utc_instant() {
        // 16:00 +0200 == 14:00 UTC == 11:00 -0300.
        let utc = 1_782_741_600_000;
        assert_eq!(parse_xmltv_time("20260629160000 +0200"), Some(utc));
        assert_eq!(parse_xmltv_time("20260629110000 -0300"), Some(utc));
        // Bare (no offset) is treated as UTC.
        assert_eq!(parse_xmltv_time("20260629140000"), Some(utc));
    }

    #[test]
    fn parses_channels_and_a_programme() {
        let xml = r#"<tv>
            <channel id="cnn.us"><display-name>CNN</display-name><icon src="http://l/cnn.png"/></channel>
            <programme start="20260629140000 +0000" stop="20260629150000 +0000" channel="cnn.us">
              <title>World News</title><sub-title>Evening</sub-title><desc>Headlines &amp; analysis</desc>
              <category>News</category><episode-num system="xmltv_ns">0.1.0/1</episode-num>
              <new/><rating><value>TV-14</value></rating><icon src="http://l/ep.png"/>
            </programme>
        </tv>"#;
        let epg = parse_xmltv(xml);
        assert_eq!(epg.channels.len(), 1);
        assert_eq!(epg.channels[0].id, "cnn.us");
        assert_eq!(epg.channels[0].display_names, vec!["CNN"]);
        assert_eq!(epg.channels[0].icon.as_deref(), Some("http://l/cnn.png"));
        assert_eq!(epg.programs.len(), 1);
        let p = &epg.programs[0];
        assert_eq!(p.channel_id, "cnn.us");
        assert_eq!(p.start_utc_ms, 1_782_741_600_000);
        assert_eq!(p.stop_utc_ms, 1_782_745_200_000);
        assert_eq!(p.title, "World News");
        assert_eq!(p.sub_title.as_deref(), Some("Evening"));
        assert_eq!(p.desc.as_deref(), Some("Headlines & analysis")); // entity decoded
        assert_eq!(p.category.as_deref(), Some("News"));
        assert_eq!(p.episode_num, Some(EpisodeNum { season: Some(1), episode: Some(2) })); // 0-indexed +1
        assert!(p.is_new);
        assert!(!p.is_premiere);
        assert_eq!(p.rating.as_deref(), Some("TV-14"));
        assert_eq!(p.icon.as_deref(), Some("http://l/ep.png"));
    }

    #[test]
    fn onscreen_episode_num_when_no_xmltv_ns() {
        let xml = r#"<programme start="20260629140000" channel="c"><title>X</title>
            <episode-num system="onscreen">S03E07</episode-num></programme>"#;
        let p = &parse_xmltv(xml).programs[0];
        assert_eq!(p.episode_num, Some(EpisodeNum { season: Some(3), episode: Some(7) }));
    }

    #[test]
    fn a_programme_missing_channel_or_start_is_skipped() {
        let xml = r#"<programme start="20260629140000"><title>NoChannel</title></programme>
                     <programme channel="c"><title>NoStart</title></programme>"#;
        assert!(parse_xmltv(xml).programs.is_empty());
    }

    #[test]
    fn missing_stop_defaults_to_start() {
        let xml = r#"<programme start="20260629140000 +0000" channel="c"><title>T</title></programme>"#;
        let p = &parse_xmltv(xml).programs[0];
        assert_eq!(p.stop_utc_ms, p.start_utc_ms);
    }
}
