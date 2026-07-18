//! # Postel lenient decode layer
//!
//! "Be conservative in what you send, be liberal in what you accept." The strict decoders in this crate
//! ([`crate::parse_manifest`], [`crate::parse_stream`], ...) reject any body that is not byte-clean Stremio
//! JSON, which is exactly what other clients do, and exactly why some real add-ons that VortX could otherwise
//! install and serve get hard-rejected over a single dialect quirk. This module is the SECOND, opt-in pass:
//! it runs ONLY after the strict decode has already failed, applies a fixed, closed set of REPAIRS to the raw
//! bytes / parsed value, and hands back the recovered typed value together with a [`DecodeReport`] naming
//! every repair it applied. Nothing is ever guessed silently: an addon whose body needed a BOM strip and a
//! stringified `fileIdx` coerced comes back with those two repairs recorded, so the host can surface, log, or
//! down-rank a source that needed patching.
//!
//! Invariants (HARD):
//! - The strict path is untouched. A body that parses strictly never reaches this module, so every existing
//!   conformance vector is byte-identical: repair only fires on a strict failure.
//! - The repair set is CLOSED. Each repair here is backed by a real broken-addon fixture (see the tests); no
//!   heuristic runs without a fixture proving it. Adding a repair means adding a fixture.
//! - Repair is pure and deterministic: same bytes + same base -> same value + same report, on every platform.
//!
//! The repairs, each proven by a fixture:
//! - **BOM prefix** (`RepairKind::BomPrefix`): a leading UTF-8 BOM (`U+FEFF`) that makes `serde_json` reject
//!   the whole document.
//! - **HTML-served-as-JSON** (`RepairKind::HtmlWrapper`): a JSON body wrapped/served as HTML (a `<pre>...</pre>`
//!   dump, an HTML comment preamble); the JSON object/array is extracted from inside the markup.
//! - **Stringified numbers** (`RepairKind::StringifiedNumber`): a numeric field sent as a JSON string
//!   (`"fileIdx": "0"`, `"seeders": "1234"`) that fails an integer field.
//! - **Legacy `extra` arrays** (`RepairKind::LegacyExtraArray`): an old manifest catalog `extra` given as an
//!   array of bare names (`"extra": ["genre","search"]`) instead of `[{ "name": ... }]`.
//! - **Relative resource URLs** (`RepairKind::RelativeUrl`): a `url`/`poster`/`logo`/... given relative
//!   (`"/dl/x.mkv"`, `"art/p.jpg"`) that is resolved against the source base.
//! - **Malformed magnets** (`RepairKind::MalformedMagnet`): an `infoHash` field carrying a whole magnet URI
//!   (`"magnet:?xt=urn:btih:HASH&dn=..."`) or a URL, from which the bare btih is extracted.

use std::borrow::Cow;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::manifest::Manifest;
use crate::resource::{
    CatalogResponse, MetaDetail, MetaPreview, MetaResponse, Stream, StreamResponse, Subtitle,
    SubtitlesResponse,
};

/// One class of repair applied by [`decode_repair`]. Closed set: every variant is backed by a fixture.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RepairKind {
    /// A numeric field arrived as a JSON string and was coerced to an integer.
    StringifiedNumber,
    /// A legacy catalog `extra` array of bare names was normalized to `[{ "name": ... }]`.
    LegacyExtraArray,
    /// A leading UTF-8 byte-order mark was stripped before parsing.
    BomPrefix,
    /// JSON was extracted from an HTML-wrapped body (served as `text/html`).
    HtmlWrapper,
    /// A relative resource URL was resolved against the source base.
    RelativeUrl,
    /// A bare btih info-hash was extracted from a magnet URI (or URL) in `infoHash`.
    MalformedMagnet,
}

/// One recorded repair: what class, and the wire field it touched (when field-scoped).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Repair {
    pub kind: RepairKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub field: Option<String>,
}

/// The typed record of every repair a lenient decode applied. Empty means "strict decode, nothing repaired"
/// (the common case), so it is skip-serialized wherever it is embedded and the wire stays byte-identical when
/// no repair fired. Never records a silent guess: a value only appears here because it was actively changed.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DecodeReport {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repairs: Vec<Repair>,
}

impl DecodeReport {
    /// A report with no repairs (a strict decode, or an untouched value).
    pub fn is_empty(&self) -> bool {
        self.repairs.is_empty()
    }

    fn record(&mut self, kind: RepairKind, field: Option<&str>) {
        self.repairs.push(Repair {
            kind,
            field: field.map(|f| f.to_string()),
        });
    }

    /// Whether any recorded repair is of `kind`.
    pub fn contains(&self, kind: RepairKind) -> bool {
        self.repairs.iter().any(|r| r.kind == kind)
    }

    /// Fold another report's repairs into this one (used to aggregate a fan-out's per-item repairs).
    pub fn merge(&mut self, other: &DecodeReport) {
        self.repairs.extend(other.repairs.iter().cloned());
    }

    /// The distinct repair classes recorded, in first-seen order.
    pub fn kinds(&self) -> Vec<RepairKind> {
        let mut out: Vec<RepairKind> = Vec::new();
        for r in &self.repairs {
            if !out.contains(&r.kind) {
                out.push(r.kind);
            }
        }
        out
    }
}

// ---- public entrypoints: strict-fail fallbacks, one per decoded shape ----

/// Lenient decode of an add-on `manifest.json` body. Call ONLY after [`crate::parse_manifest`] has failed:
/// sanitizes the bytes (BOM / HTML wrapper), then repairs the parsed value (legacy `extra` arrays, stringified
/// numbers, relative `logo`/`background` URLs) before the typed deserialize. `base` (the manifest URL) resolves
/// relative asset URLs; pass `None` to skip URL resolution. `Err` when the body is unrecoverable.
pub fn decode_repair_manifest(
    body: &str,
    base: Option<&str>,
) -> Result<(Manifest, DecodeReport), crate::ProtocolError> {
    repair_typed::<Manifest>(body, base).map_err(crate::ProtocolError::Manifest)
}

/// Lenient decode of a whole `stream` response body (`{ "streams": [...] }`). Call ONLY after
/// [`crate::parse_stream`] has failed. `base` resolves relative stream/subtitle URLs. `None` when unrecoverable.
pub fn decode_repair_stream(body: &str, base: Option<&str>) -> Option<(StreamResponse, DecodeReport)> {
    repair_typed::<StreamResponse>(body, base).ok()
}

/// Lenient decode of a whole `catalog` response body (`{ "metas": [...] }`). Call ONLY after
/// [`crate::parse_catalog`] has failed. `base` resolves relative poster/logo/... URLs. `None` when unrecoverable.
pub fn decode_repair_catalog(body: &str, base: Option<&str>) -> Option<(CatalogResponse, DecodeReport)> {
    repair_typed::<CatalogResponse>(body, base).ok()
}

/// Lenient decode of a whole `meta` response body (`{ "meta": {...} }`). Call ONLY after
/// [`crate::parse_meta`] has failed. `base` resolves relative asset URLs. `None` when unrecoverable.
pub fn decode_repair_meta(body: &str, base: Option<&str>) -> Option<(MetaResponse, DecodeReport)> {
    repair_typed::<MetaResponse>(body, base).ok()
}

/// Lenient decode of a whole `subtitles` response body (`{ "subtitles": [...] }`). Call ONLY after
/// [`crate::parse_subtitles`] has failed. `base` resolves relative subtitle URLs. `None` when unrecoverable.
pub fn decode_repair_subtitles(
    body: &str,
    base: Option<&str>,
) -> Option<(SubtitlesResponse, DecodeReport)> {
    repair_typed::<SubtitlesResponse>(body, base).ok()
}

/// Lenient decode of ONE stream item key (a bare `Stream` object), for the fan-out settle path. Call ONLY
/// after the strict `Stream` parse has failed. `None` when the item cannot be recovered.
pub fn repair_stream_item(item: &str, base: Option<&str>) -> Option<(Stream, DecodeReport)> {
    repair_typed::<Stream>(item, base).ok()
}

/// Lenient decode of ONE catalog item key (a bare `MetaPreview`). Call ONLY after the strict parse failed.
pub fn repair_catalog_item(item: &str, base: Option<&str>) -> Option<(MetaPreview, DecodeReport)> {
    repair_typed::<MetaPreview>(item, base).ok()
}

/// Lenient decode of ONE meta item key (a bare `MetaDetail`). Call ONLY after the strict parse failed.
pub fn repair_meta_item(item: &str, base: Option<&str>) -> Option<(MetaDetail, DecodeReport)> {
    repair_typed::<MetaDetail>(item, base).ok()
}

/// Lenient decode of ONE subtitle item key (a bare `Subtitle`). Call ONLY after the strict parse failed.
pub fn repair_subtitle_item(item: &str, base: Option<&str>) -> Option<(Subtitle, DecodeReport)> {
    repair_typed::<Subtitle>(item, base).ok()
}

/// The shared pipeline: sanitize the bytes, parse to a `Value`, repair the value in place recording every
/// change, then typed-deserialize. Generic over the target so every shape shares one repair contract.
fn repair_typed<T: DeserializeOwned>(
    raw: &str,
    base: Option<&str>,
) -> Result<(T, DecodeReport), serde_json::Error> {
    let mut report = DecodeReport::default();
    let text = sanitize_text(raw, &mut report);
    let mut value: Value = serde_json::from_str(&text)?;
    repair_value(&mut value, base, &mut report);
    let typed = serde_json::from_value::<T>(value)?;
    Ok((typed, report))
}

// ---- text-level sanitizers (whole-document) ----

/// Strip a leading UTF-8 BOM and, if the body is HTML-wrapped JSON, extract the embedded JSON document.
/// Records `BomPrefix` / `HtmlWrapper` for each transform applied. Returns the cleaned text (borrowed when
/// nothing changed, so the untouched path stays allocation-free).
fn sanitize_text<'a>(raw: &'a str, report: &mut DecodeReport) -> Cow<'a, str> {
    let mut text: Cow<'a, str> = Cow::Borrowed(raw);
    // 1. BOM: a leading U+FEFF makes serde_json reject the whole document.
    if let Some(stripped) = text.strip_prefix('\u{feff}') {
        report.record(RepairKind::BomPrefix, None);
        text = Cow::Owned(stripped.to_string());
    }
    // 2. HTML wrapper: a JSON body served as text/html (a <pre> dump, an HTML/comment preamble). Extract the
    //    outermost JSON object/array from inside the markup.
    if looks_like_html(&text) {
        if let Some(extracted) = extract_json_span(&text) {
            report.record(RepairKind::HtmlWrapper, None);
            text = Cow::Owned(extracted);
        }
    }
    text
}

/// Whether the trimmed text opens with markup rather than JSON (`<!DOCTYPE`, `<html`, `<pre`, an HTML comment).
fn looks_like_html(text: &str) -> bool {
    text.trim_start().starts_with('<')
}

/// Extract the outermost balanced JSON object/array span from an HTML-wrapped body: the substring from the
/// first `{`/`[` to its matching close, honoring string literals + escapes so a brace inside a quoted value
/// never miscounts. `None` when no balanced span is found.
fn extract_json_span(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let start = bytes.iter().position(|&b| b == b'{' || b == b'[')?;
    let open = bytes[start];
    let close = if open == b'{' { b'}' } else { b']' };
    let mut depth = 0i32;
    let mut in_str = false;
    let mut escaped = false;
    for (i, &b) in bytes.iter().enumerate().skip(start) {
        if in_str {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                in_str = false;
            }
            continue;
        }
        match b {
            b'"' => in_str = true,
            x if x == open => depth += 1,
            x if x == close => {
                depth -= 1;
                if depth == 0 {
                    return Some(text[start..=i].to_string());
                }
            }
            _ => {}
        }
    }
    None
}

// ---- value-level repairs (recursive over the parsed JSON) ----

/// Wire keys that name an INTEGER field. A string value on one of these is coerced to a number.
const NUMERIC_KEYS: &[&str] = &[
    "fileIdx",
    "videoSize",
    "seeders",
    "sizeBytes",
    "sources",
    "bitrateKbps",
    "uptimePermille",
    "season",
    "episode",
    "durationMs",
    "optionsLimit",
    "startMs",
    "endMs",
];

/// Wire keys that name a resource URL. A relative value on one of these is resolved against the source base.
const URL_KEYS: &[&str] = &[
    "url",
    "externalUrl",
    "poster",
    "background",
    "logo",
    "thumbnail",
    "icon",
];

/// Repair a parsed value in place, recording each change. Recurses through objects and arrays; the repairs are
/// field-scoped (keyed on the wire name), so a `fileIdx` string is coerced but an `id` string is left alone.
fn repair_value(value: &mut Value, base: Option<&str>, report: &mut DecodeReport) {
    match value {
        Value::Object(map) => {
            // First pass: field-scoped repairs on this object's direct children.
            let keys: Vec<String> = map.keys().cloned().collect();
            for key in keys {
                let Some(child) = map.get_mut(&key) else {
                    continue;
                };
                if key == "extra" {
                    normalize_legacy_extra(child, report);
                } else if key == "infoHash" {
                    fix_malformed_magnet(child, report);
                } else if NUMERIC_KEYS.contains(&key.as_str()) {
                    coerce_stringified_number(child, &key, report);
                } else if URL_KEYS.contains(&key.as_str()) {
                    resolve_relative_url(child, &key, base, report);
                }
            }
            // Second pass: recurse into every child (nested objects/arrays: videos, streams, catalogs, ...).
            for child in map.values_mut() {
                repair_value(child, base, report);
            }
        }
        Value::Array(items) => {
            for item in items {
                repair_value(item, base, report);
            }
        }
        _ => {}
    }
}

/// Coerce a stringified integer to a JSON number. Leaves a non-integer string untouched (it will fail the
/// typed parse and the item is dropped, which is correct: we never invent a value).
fn coerce_stringified_number(value: &mut Value, field: &str, report: &mut DecodeReport) {
    if let Value::String(s) = value {
        let trimmed = s.trim();
        if let Ok(n) = trimmed.parse::<i64>() {
            *value = Value::from(n);
            report.record(RepairKind::StringifiedNumber, Some(field));
        }
    }
}

/// Normalize a legacy catalog `extra` array of bare names into the modern `[{ "name": ... }]` object form.
/// Only fires when at least one element is a bare string; a value already in object form is left untouched.
fn normalize_legacy_extra(value: &mut Value, report: &mut DecodeReport) {
    let Value::Array(items) = value else {
        return;
    };
    if !items.iter().any(Value::is_string) {
        return;
    }
    let mut changed = false;
    for item in items.iter_mut() {
        if let Value::String(name) = item {
            *item = serde_json::json!({ "name": name });
            changed = true;
        }
    }
    if changed {
        report.record(RepairKind::LegacyExtraArray, Some("extra"));
    }
}

/// Resolve a relative resource URL against the source base. An absolute URL (has a scheme, is protocol-relative
/// `//`, or is a `magnet:`/`data:` URI) is left untouched. Needs a base; with `None`, nothing changes.
fn resolve_relative_url(value: &mut Value, field: &str, base: Option<&str>, report: &mut DecodeReport) {
    let Some(base) = base else { return };
    let Value::String(s) = value else { return };
    if s.is_empty() || is_absolute_url(s) {
        return;
    }
    let joined = join_url(base, s);
    *value = Value::from(joined);
    report.record(RepairKind::RelativeUrl, Some(field));
}

/// Extract a bare btih info-hash from a magnet URI or URL in an `infoHash` field. A plain hash (the normal
/// case) is left untouched. Fires only when the value carries `xt=urn:btih:` or a `://`, so a valid hash is
/// never rewritten.
fn fix_malformed_magnet(value: &mut Value, report: &mut DecodeReport) {
    let Value::String(s) = value else { return };
    if let Some(hash) = extract_btih(s) {
        if hash != *s {
            *value = Value::from(hash);
            report.record(RepairKind::MalformedMagnet, Some("infoHash"));
        }
    }
}

/// Pull the btih hash out of a magnet URI (`magnet:?xt=urn:btih:HASH&...`) or a URL path. Returns `None` when
/// the input is not magnet/URL shaped (so a bare hash is not touched).
fn extract_btih(s: &str) -> Option<String> {
    let lower = s.to_ascii_lowercase();
    if let Some(pos) = lower.find("btih:") {
        let after = &s[pos + "btih:".len()..];
        let hash: String = after
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect();
        if !hash.is_empty() {
            return Some(hash);
        }
    }
    // A URL that ends in a hash-looking path segment (e.g. ".../HASH" or ".../HASH.torrent").
    if s.contains("://") {
        let tail = s.rsplit('/').next().unwrap_or("");
        let tail = tail.split('.').next().unwrap_or("");
        if tail.len() >= 32 && tail.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Some(tail.to_string());
        }
    }
    None
}

/// Whether `s` is already an absolute URL (has a `scheme:`, is protocol-relative `//`, or is `magnet:`/`data:`).
fn is_absolute_url(s: &str) -> bool {
    if s.starts_with("//") {
        return true;
    }
    // scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
    let mut chars = s.char_indices();
    match chars.next() {
        Some((_, c)) if c.is_ascii_alphabetic() => {}
        _ => return false,
    }
    for (i, c) in chars {
        if c == ':' {
            return i >= 1;
        }
        if !(c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')) {
            return false;
        }
    }
    false
}

/// Join a relative URL onto a source base. A `/absolute-path` resolves against the base ORIGIN
/// (`scheme://host`); a bare `relative/path` appends to the base directory. Deterministic, no allocation of a
/// URL parser.
fn join_url(base: &str, rel: &str) -> String {
    let base = base.trim_end_matches('/');
    if let Some(path) = rel.strip_prefix('/') {
        format!("{}/{}", origin(base), path)
    } else {
        format!("{base}/{rel}")
    }
}

/// The `scheme://host[:port]` origin of a base URL (everything before the first path `/`). Falls back to the
/// whole input when there is no `://`.
fn origin(base: &str) -> &str {
    let Some(after_scheme) = base.find("://") else {
        return base;
    };
    let host_start = after_scheme + 3;
    match base[host_start..].find('/') {
        Some(i) => &base[..host_start + i],
        None => base,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parse_manifest, parse_stream, StreamSource};

    // Each test harvests a REAL broken-addon shape and proves (a) strict fails, (b) repair recovers it, and
    // (c) the repair is recorded. Fixtures are the closed set of heuristics: no repair without a fixture.

    #[test]
    fn bom_prefixed_stream_body_strict_fails_then_repairs() {
        // A CDN/proxy prepends a UTF-8 BOM; every strict client rejects the document.
        let body = "\u{feff}{\"streams\":[{\"name\":\"A 1080p\",\"url\":\"https://cdn/x.mkv\"}]}";
        assert!(parse_stream(body).is_err(), "strict must reject a BOM body");
        let (resp, report) = decode_repair_stream(body, None).expect("repair recovers");
        assert_eq!(resp.streams.len(), 1);
        assert_eq!(resp.streams[0].url.as_deref(), Some("https://cdn/x.mkv"));
        assert!(report.contains(RepairKind::BomPrefix));
    }

    #[test]
    fn html_wrapped_stream_body_extracts_the_json() {
        // Some hosts serve the JSON with text/html, wrapped in a <pre> dump.
        let body = "<!doctype html><html><body><pre>{\"streams\":[{\"url\":\"https://cdn/a.mp4\"}]}</pre></body></html>";
        assert!(parse_stream(body).is_err());
        let (resp, report) = decode_repair_stream(body, None).expect("repair recovers");
        assert_eq!(resp.streams.len(), 1);
        assert!(report.contains(RepairKind::HtmlWrapper));
    }

    #[test]
    fn stringified_numbers_are_coerced_on_the_item_path() {
        // A scraper emits fileIdx / seeders / videoSize as strings; the typed u32/i64 fields reject them.
        let item = r#"{"name":"Pack","infoHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileIdx":"3",
            "behaviorHints":{"videoSize":"1400000000","vortx":{"seeders":"512"}}}"#;
        assert!(
            serde_json::from_str::<Stream>(item).is_err(),
            "strict must reject stringified numbers"
        );
        let (s, report) = repair_stream_item(item, None).expect("repair recovers");
        assert_eq!(s.file_idx, Some(3));
        let hints = s.behavior_hints.unwrap();
        assert_eq!(hints.video_size, Some(1_400_000_000));
        assert_eq!(hints.vortx.unwrap().seeders, Some(512));
        assert!(report.contains(RepairKind::StringifiedNumber));
    }

    #[test]
    fn legacy_extra_array_manifest_strict_fails_then_repairs() {
        // A pre-2019 manifest lists catalog extra as bare names, not { name } objects.
        let body = r#"{"id":"x","version":"1.0.0","name":"Legacy","resources":["catalog"],
            "types":["movie"],"catalogs":[{"type":"movie","id":"top","extra":["genre","search"]}]}"#;
        assert!(parse_manifest(body).is_err(), "strict must reject a bare-name extra array");
        let (m, report) = decode_repair_manifest(body, None).expect("repair recovers");
        assert_eq!(m.catalogs[0].extra.len(), 2);
        assert_eq!(m.catalogs[0].extra[0].name, "genre");
        assert!(report.contains(RepairKind::LegacyExtraArray));
    }

    #[test]
    fn relative_stream_url_is_resolved_against_the_base() {
        // The stream url is site-relative; without a base every client plays a broken link.
        let item = r#"{"name":"A","url":"/dl/movie/x.mkv","fileIdx":"0"}"#;
        // (fileIdx string also breaks strict, which is what routes this item into repair.)
        assert!(serde_json::from_str::<Stream>(item).is_err());
        let (s, report) =
            repair_stream_item(item, Some("https://iptv.example/path")).expect("repair recovers");
        assert_eq!(s.url.as_deref(), Some("https://iptv.example/dl/movie/x.mkv"));
        assert!(report.contains(RepairKind::RelativeUrl));
        // A bare relative (no leading slash) joins the base directory.
        let item2 = r#"{"name":"A","url":"art/p.jpg","season":"1"}"#;
        let (s2, _) = repair_stream_item(item2, Some("https://h/base")).expect("repair");
        assert_eq!(s2.url.as_deref(), Some("https://h/base/art/p.jpg"));
    }

    #[test]
    fn malformed_magnet_infohash_yields_the_bare_btih() {
        // The addon dumps a whole magnet URI into infoHash; the ranker/resolver needs the bare hash.
        let item = r#"{"name":"T","infoHash":"magnet:?xt=urn:btih:C12FE1C06BBA254A9DC9F519B335AA7C1367A88A&dn=Movie","fileIdx":"0"}"#;
        assert!(serde_json::from_str::<Stream>(item).is_err()); // fileIdx string routes it into repair
        let (s, report) = repair_stream_item(item, None).expect("repair recovers");
        assert_eq!(
            s.info_hash.as_deref(),
            Some("C12FE1C06BBA254A9DC9F519B335AA7C1367A88A")
        );
        assert_eq!(
            s.source(),
            StreamSource::Torrent {
                info_hash: "C12FE1C06BBA254A9DC9F519B335AA7C1367A88A".into(),
                file_idx: Some(0),
            }
        );
        assert!(report.contains(RepairKind::MalformedMagnet));
    }

    #[test]
    fn a_clean_bare_infohash_is_never_rewritten() {
        // Guard: the magnet repair must not touch a valid bare hash (only stringified fileIdx broke strict).
        let item = r#"{"infoHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileIdx":"1"}"#;
        let (s, report) = repair_stream_item(item, None).expect("repair");
        assert_eq!(
            s.info_hash.as_deref(),
            Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        );
        assert!(!report.contains(RepairKind::MalformedMagnet));
    }

    #[test]
    fn a_combined_break_records_every_repair_applied() {
        // A realistically-broken addon: BOM + stringified fileIdx + magnet-in-infoHash + relative url at once.
        let body = "\u{feff}{\"streams\":[{\"name\":\"X\",\"infoHash\":\"magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01\",\"fileIdx\":\"2\",\"url\":\"/x.mkv\"}]}";
        assert!(parse_stream(body).is_err());
        let (resp, report) =
            decode_repair_stream(body, Some("https://h/p")).expect("repair recovers");
        let s = &resp.streams[0];
        assert_eq!(s.file_idx, Some(2));
        assert_eq!(s.info_hash.as_deref(), Some("ABCDEF0123456789ABCDEF0123456789ABCDEF01"));
        assert_eq!(s.url.as_deref(), Some("https://h/x.mkv"));
        let kinds = report.kinds();
        for k in [
            RepairKind::BomPrefix,
            RepairKind::StringifiedNumber,
            RepairKind::MalformedMagnet,
            RepairKind::RelativeUrl,
        ] {
            assert!(kinds.contains(&k), "missing {k:?} in {kinds:?}");
        }
    }

    #[test]
    fn an_unrecoverable_body_yields_none() {
        // Not JSON, not HTML-wrapped JSON: repair cannot invent a body.
        assert!(decode_repair_stream("total garbage, no json here", None).is_none());
        assert!(repair_stream_item("<html>no json</html>", None).is_none());
    }

    #[test]
    fn is_absolute_url_classifies_correctly() {
        assert!(is_absolute_url("https://h/x"));
        assert!(is_absolute_url("magnet:?xt=urn:btih:X"));
        assert!(is_absolute_url("data:text/plain,x"));
        assert!(is_absolute_url("//cdn/x"));
        assert!(!is_absolute_url("/abs/path"));
        assert!(!is_absolute_url("rel/path"));
        assert!(!is_absolute_url("x.mkv"));
    }

    #[test]
    fn report_serializes_only_when_non_empty() {
        let empty = DecodeReport::default();
        assert_eq!(serde_json::to_string(&empty).unwrap(), "{}");
        assert!(empty.is_empty());
        let mut r = DecodeReport::default();
        r.record(RepairKind::BomPrefix, None);
        let wire = serde_json::to_string(&r).unwrap();
        assert!(wire.contains("bom_prefix"));
    }
}
