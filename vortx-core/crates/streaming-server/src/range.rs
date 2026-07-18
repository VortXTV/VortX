//! HTTP Range parsing for the file endpoint. First range only (server.js's
//! range-parser behaviour); suffix and open-ended forms supported.

#[derive(Debug, PartialEq, Eq)]
pub enum RangeOutcome {
    /// No Range header: serve the whole file with 200.
    Full,
    /// 206 with the inclusive byte window.
    Window { start: u64, end: u64 },
    /// 416 with `Content-Range: bytes */{total}`.
    Unsatisfiable,
}

/// Parse a `Range` header value against `total` file bytes.
pub fn parse_range(header: Option<&str>, total: u64) -> RangeOutcome {
    let Some(raw) = header else { return RangeOutcome::Full };
    let Some(spec) = raw.trim().strip_prefix("bytes=") else {
        // Unknown unit: ignore the header (serve full), per RFC 9110.
        return RangeOutcome::Full;
    };
    let first = spec.split(',').next().unwrap_or("").trim();
    let Some((start_s, end_s)) = first.split_once('-') else {
        return RangeOutcome::Unsatisfiable;
    };
    if total == 0 {
        return RangeOutcome::Unsatisfiable;
    }
    match (start_s.trim(), end_s.trim()) {
        ("", "") => RangeOutcome::Unsatisfiable,
        // suffix: last N bytes
        ("", n) => match n.parse::<u64>() {
            Ok(0) | Err(_) => RangeOutcome::Unsatisfiable,
            Ok(n) => {
                let n = n.min(total);
                RangeOutcome::Window { start: total - n, end: total - 1 }
            }
        },
        (s, "") => match s.parse::<u64>() {
            Ok(start) if start < total => RangeOutcome::Window { start, end: total - 1 },
            _ => RangeOutcome::Unsatisfiable,
        },
        (s, e) => match (s.parse::<u64>(), e.parse::<u64>()) {
            (Ok(start), Ok(end)) if start <= end && start < total => {
                RangeOutcome::Window { start, end: end.min(total - 1) }
            }
            _ => RangeOutcome::Unsatisfiable,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_forms() {
        assert_eq!(parse_range(None, 100), RangeOutcome::Full);
        assert_eq!(parse_range(Some("bytes=0-9"), 100), RangeOutcome::Window { start: 0, end: 9 });
        assert_eq!(parse_range(Some("bytes=90-"), 100), RangeOutcome::Window { start: 90, end: 99 });
        assert_eq!(parse_range(Some("bytes=-10"), 100), RangeOutcome::Window { start: 90, end: 99 });
        // end clamped to the file
        assert_eq!(parse_range(Some("bytes=50-1000"), 100), RangeOutcome::Window { start: 50, end: 99 });
        // first range of a multi-range
        assert_eq!(parse_range(Some("bytes=1-2,5-6"), 100), RangeOutcome::Window { start: 1, end: 2 });
        assert_eq!(parse_range(Some("bytes=100-"), 100), RangeOutcome::Unsatisfiable);
        assert_eq!(parse_range(Some("bytes=5-2"), 100), RangeOutcome::Unsatisfiable);
        assert_eq!(parse_range(Some("items=0-1"), 100), RangeOutcome::Full);
    }
}
