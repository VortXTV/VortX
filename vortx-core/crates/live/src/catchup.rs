//! LT-CATCHUP: a pure, deterministic IPTV catchup / timeshift URL template engine.
//!
//! Catchup lets a viewer play a PAST programme by rewriting the live URL through a `catchup-source` template
//! whose placeholders carry the programme window. The catchup ecosystem is a mess of incompatible dialects
//! (Kodi `{utc}`/`{lutc}`, the `${start}`/`${end}` simple-client form, broken-out `{Y}-{m}-{d}:{H}-{M}`
//! Xtream timeshift, offset/duration variants), so every client re-implements fragile string mangling. This
//! is ONE engine: every placeholder is derived from a single integer instant (the LT2 UTC-ms window), so the
//! unix and broken-out fields are guaranteed to agree. No fetch, no clock (the host passes `now`), no float,
//! no `chrono` (the civil breakdown is the exact inverse of LT2's `days_from_civil`).
//!
//! Supported placeholders (both `{name}` and `${name}` forms): `utc`/`start`/`timestamp` (programme start,
//! unix seconds), `utcend`/`end` (stop, unix seconds), `lutc`/`now` (the supplied now, unix seconds),
//! `duration`/`dur` (seconds), `offset` (now - start, seconds), `Y`/`m`/`d`/`H`/`M`/`S` (the start broken out
//! to UTC fields, zero-padded), and `user`/`pass` (credentials, supplied via a redaction-only [`Secret`] so
//! they never leak anywhere but the final fetch URL). An unknown placeholder is left INTACT (so a host can
//! see what was not substituted rather than get a silently corrupted URL).

use crate::m3u::M3uEntry;
use crate::secret::Secret;

/// A civil UTC date-time broken out to integer fields (the inverse of LT2's `days_from_civil`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CivilTime {
    pub year: i64,
    pub month: i64,
    pub day: i64,
    pub hour: i64,
    pub min: i64,
    pub sec: i64,
}

/// The integer substitution context for one catchup window. Build with [`CatchupCtx::from_window`]; add
/// credentials (for the Xtream `/timeshift/{user}/{pass}/...` shape) with [`CatchupCtx::with_creds`].
#[derive(Debug, Clone, Copy)]
pub struct CatchupCtx<'a> {
    pub start_unix: i64,
    pub end_unix: i64,
    pub now_unix: i64,
    pub duration_secs: i64,
    pub offset_secs: i64,
    pub start: CivilTime,
    user: Option<&'a str>,
    pass: Option<&'a Secret>,
}

impl<'a> CatchupCtx<'a> {
    /// Derive every placeholder value from the programme window (LT2 UTC ms) and the supplied `now`. All
    /// integer: seconds via `div_euclid` (negative-safe), duration clamped non-negative.
    pub fn from_window(start_utc_ms: i64, stop_utc_ms: i64, now_ms: i64) -> Self {
        Self {
            start_unix: start_utc_ms.div_euclid(1000),
            end_unix: stop_utc_ms.div_euclid(1000),
            now_unix: now_ms.div_euclid(1000),
            duration_secs: (stop_utc_ms - start_utc_ms).max(0).div_euclid(1000),
            offset_secs: (now_ms - start_utc_ms).div_euclid(1000),
            start: civil_time(start_utc_ms),
            user: None,
            pass: None,
        }
    }

    /// Attach credentials for `{user}` / `{pass}` substitution. The password stays a [`Secret`]; it is read
    /// only at substitution time into the final fetch URL, never logged or serialized.
    pub fn with_creds(mut self, user: &'a str, pass: &'a Secret) -> Self {
        self.user = Some(user);
        self.pass = Some(pass);
        self
    }

    /// The substitution for a placeholder name, or `None` if the name is unknown (left intact).
    fn lookup(&self, name: &str) -> Option<String> {
        Some(match name {
            "utc" | "start" | "timestamp" => self.start_unix.to_string(),
            "utcend" | "end" => self.end_unix.to_string(),
            "lutc" | "now" => self.now_unix.to_string(),
            "duration" | "dur" => self.duration_secs.to_string(),
            "offset" => self.offset_secs.to_string(),
            "Y" => format!("{:04}", self.start.year),
            "m" => format!("{:02}", self.start.month),
            "d" => format!("{:02}", self.start.day),
            "H" => format!("{:02}", self.start.hour),
            "M" => format!("{:02}", self.start.min),
            "S" => format!("{:02}", self.start.sec),
            "user" => self.user?.to_string(),
            "pass" => self.pass?.reveal().to_string(),
            _ => return None,
        })
    }
}

/// Render a catchup template by substituting every recognized `{name}` / `${name}` placeholder. Unknown
/// placeholders are left intact; a `{` with no closing `}` is copied literally. Pure + deterministic +
/// panic-free; ASCII delimiters only, so UTF-8 in the template is preserved.
pub fn render_catchup(template: &str, ctx: &CatchupCtx) -> String {
    let bytes = template.as_bytes();
    let mut out = String::with_capacity(template.len());
    let mut i = 0;
    while i < bytes.len() {
        // A token is `${name}` (when '$' precedes '{') or `{name}`.
        let dollar = bytes[i] == b'$' && i + 1 < bytes.len() && bytes[i + 1] == b'{';
        if dollar || bytes[i] == b'{' {
            let open = if dollar { i + 1 } else { i }; // index of '{'
            if let Some(rel) = template[open + 1..].find('}') {
                let close = open + 1 + rel;
                let name = &template[open + 1..close];
                match ctx.lookup(name) {
                    Some(val) => out.push_str(&val),
                    None => out.push_str(&template[i..close + 1]), // unknown: keep the literal token
                }
                i = close + 1;
                continue;
            }
        }
        // Not a token: copy this byte's char through verbatim (find the next char boundary).
        let mut j = i + 1;
        while j < bytes.len() && (bytes[j] & 0xC0) == 0x80 {
            j += 1; // continuation byte
        }
        out.push_str(&template[i..j]);
        i = j;
    }
    out
}

/// Build the catchup URL for `entry` for the programme window `[start_utc_ms, stop_utc_ms)` at `now_ms`, or
/// `None` when the entry advertises no catchup. If the entry has a `catchup-source` template it is rendered;
/// otherwise, when it has a `catchup` type, a standard `utc/lutc` query is appended to the stream URL.
pub fn catchup_url_for(
    entry: &M3uEntry,
    start_utc_ms: i64,
    stop_utc_ms: i64,
    now_ms: i64,
) -> Option<String> {
    let ctx = CatchupCtx::from_window(start_utc_ms, stop_utc_ms, now_ms);

    if let Some(src) = attr(entry, "catchup-source").filter(|s| !s.is_empty()) {
        return Some(render_catchup(src, &ctx));
    }

    // A catchup TYPE with no explicit source: the standard Kodi "default"/"append"/"shift" append. A type of
    // "0"/"false"/"none" means no catchup.
    let kind = attr(entry, "catchup")
        .map(str::trim)
        .filter(|s| !s.is_empty())?;
    if matches!(kind.to_ascii_lowercase().as_str(), "0" | "false" | "none") {
        return None;
    }
    let sep = if entry.url.contains('?') { '&' } else { '?' };
    let template = format!("{}{sep}utc={{utc}}&lutc={{lutc}}", entry.url);
    Some(render_catchup(&template, &ctx))
}

/// Look up an EXTINF attribute case-insensitively.
fn attr<'a>(e: &'a M3uEntry, key: &str) -> Option<&'a str> {
    e.attributes
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
        .map(|(_, v)| v.as_str())
}

/// UTC ms -> broken-out civil fields. Seconds via `div_euclid`/`rem_euclid` (negative-safe), date via the
/// Hinnant inverse of LT2's `days_from_civil` (same 1970-01-01 epoch), so it is float-free and agrees with
/// the LT2 fence exactly.
fn civil_time(utc_ms: i64) -> CivilTime {
    let total_secs = utc_ms.div_euclid(1000);
    let days = total_secs.div_euclid(86_400);
    let sod = total_secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    CivilTime {
        year,
        month,
        day,
        hour: sod / 3600,
        min: (sod % 3600) / 60,
        sec: sod % 60,
    }
}

/// Civil date from days-since-epoch: Howard Hinnant's `civil_from_days`, the exact inverse of LT2's
/// `days_from_civil`. Pure integer, valid for any day.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-06-29 14:00:00 UTC = 1782741600 unix (the LT2 known-instant vector).
    const START_MS: i64 = 1_782_741_600_000;
    const STOP_MS: i64 = 1_782_745_200_000; // +1h
    const NOW_MS: i64 = 1_782_745_800_000; // +1h10m

    fn entry_with(attrs: &[(&str, &str)], url: &str) -> M3uEntry {
        M3uEntry {
            url: url.to_string(),
            duration_secs: -1,
            attributes: attrs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            ..Default::default()
        }
    }

    #[test]
    fn unix_seconds_placeholders_substitute() {
        let ctx = CatchupCtx::from_window(START_MS, STOP_MS, NOW_MS);
        assert_eq!(
            render_catchup("u={utc}&e={utcend}&now={lutc}", &ctx),
            "u=1782741600&e=1782745200&now=1782745800"
        );
        assert_eq!(
            render_catchup("s=${start}&end=${end}", &ctx),
            "s=1782741600&end=1782745200"
        );
        assert_eq!(
            render_catchup("d={duration}&o={offset}", &ctx),
            "d=3600&o=4200"
        ); // 1h dur, 70m offset
    }

    #[test]
    fn broken_out_civil_fields_match_the_utc_instant() {
        let ctx = CatchupCtx::from_window(START_MS, STOP_MS, NOW_MS);
        assert_eq!(
            render_catchup("{Y}-{m}-{d}:{H}-{M}-{S}", &ctx),
            "2026-06-29:14-00-00"
        );
    }

    #[test]
    fn creds_substitute_via_secret_only_into_the_url() {
        let pass = Secret::new("p4ss");
        let ctx = CatchupCtx::from_window(START_MS, STOP_MS, NOW_MS).with_creds("alice", &pass);
        let url = render_catchup(
            "/timeshift/{user}/{pass}/{duration}/{Y}-{m}-{d}:{H}-{M}/123.ts",
            &ctx,
        );
        assert_eq!(url, "/timeshift/alice/p4ss/3600/2026-06-29:14-00/123.ts");
        // The Secret never leaks via Debug.
        assert!(!format!("{ctx:?}").contains("p4ss"));
    }

    #[test]
    fn unknown_placeholder_is_left_intact() {
        let ctx = CatchupCtx::from_window(START_MS, STOP_MS, NOW_MS);
        assert_eq!(
            render_catchup("a={utc}&b={mystery}", &ctx),
            "a=1782741600&b={mystery}"
        );
        assert_eq!(
            render_catchup("unterminated {utc", &ctx),
            "unterminated {utc"
        ); // no closing brace
    }

    #[test]
    fn catchup_source_template_is_rendered() {
        let e = entry_with(
            &[
                ("catchup", "default"),
                ("catchup-source", "http://h/play?utc={utc}&dur={duration}"),
            ],
            "http://h/live.ts",
        );
        assert_eq!(
            catchup_url_for(&e, START_MS, STOP_MS, NOW_MS),
            Some("http://h/play?utc=1782741600&dur=3600".to_string())
        );
    }

    #[test]
    fn catchup_type_without_source_appends_the_standard_query() {
        let e = entry_with(&[("catchup", "default")], "http://h/live.ts");
        assert_eq!(
            catchup_url_for(&e, START_MS, STOP_MS, NOW_MS),
            Some("http://h/live.ts?utc=1782741600&lutc=1782745800".to_string())
        );
        // Existing query string -> '&' join.
        let e2 = entry_with(&[("catchup", "append")], "http://h/live.ts?token=x");
        assert_eq!(
            catchup_url_for(&e2, START_MS, STOP_MS, NOW_MS),
            Some("http://h/live.ts?token=x&utc=1782741600&lutc=1782745800".to_string())
        );
    }

    #[test]
    fn no_catchup_attribute_is_none() {
        let e = entry_with(&[("tvg-id", "cnn")], "http://h/live.ts");
        assert_eq!(catchup_url_for(&e, START_MS, STOP_MS, NOW_MS), None);
        // An explicit disable is also None.
        let off = entry_with(&[("catchup", "none")], "http://h/live.ts");
        assert_eq!(catchup_url_for(&off, START_MS, STOP_MS, NOW_MS), None);
    }

    use proptest::prelude::*;

    proptest! {
        // The civil breakdown is the EXACT inverse of LT2's days_from_civil: for any valid civil date, the
        // broken-out fields recovered from the corresponding instant match the original (same epoch, no drift).
        #[test]
        fn civil_breakdown_inverts_lt2_days_from_civil(
            y in 1971i64..2100, m in 1i64..=12, d in 1i64..=28, h in 0i64..24, mi in 0i64..60, s in 0i64..60,
        ) {
            let days = crate::epg::days_from_civil(y, m, d);
            let utc_ms = (days * 86_400 + h * 3_600 + mi * 60 + s) * 1_000;
            let ct = civil_time(utc_ms);
            prop_assert_eq!((ct.year, ct.month, ct.day, ct.hour, ct.min, ct.sec), (y, m, d, h, mi, s));
        }

        // Substitution never panics on arbitrary input and is deterministic.
        #[test]
        fn render_is_panic_free_and_deterministic(t in ".*", start in 0i64..4_000_000_000_000, dur in 0i64..86_400_000) {
            let ctx = CatchupCtx::from_window(start, start + dur, start + 1000);
            let a = render_catchup(&t, &ctx);
            prop_assert_eq!(&a, &render_catchup(&t, &ctx));
        }

        // duration is exactly (stop - start) in seconds (clamped non-negative) and offset is monotonic in now.
        #[test]
        fn duration_and_offset_are_integer_and_correct(start in 0i64..2_000_000_000_000, dur in 0i64..86_400_000, now_delta in -100_000i64..100_000) {
            let stop = start + dur;
            let now = start + now_delta * 1000;
            let ctx = CatchupCtx::from_window(start, stop, now);
            prop_assert_eq!(ctx.duration_secs, dur / 1000);
            prop_assert_eq!(ctx.offset_secs, (now - start).div_euclid(1000));
        }
    }
}
