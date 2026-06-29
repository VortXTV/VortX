//! Cross-language conformance + property tests for the XMLTV EPG parser (LT2). The timezone->UTC integer
//! fence is the cross-platform contract (off-by-an-hour EPG is the universal IPTV bug), so datetime->UTC ms
//! is pinned exactly; the parser must also never panic on arbitrary bytes.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_live::{parse_xmltv, parse_xmltv_time, Epg};

#[derive(Deserialize)]
struct Suite {
    times: Vec<TimeCase>,
    docs: Vec<DocCase>,
}

#[derive(Deserialize)]
struct TimeCase {
    name: String,
    s: String,
    ms: Option<i64>,
}

#[derive(Deserialize)]
struct DocCase {
    name: String,
    xml: String,
    expect: Epg,
}

const SUITE: &str = include_str!("../conformance/xmltv_vectors.json");

#[test]
fn xmltv_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse xmltv suite");
    for c in &suite.times {
        assert_eq!(parse_xmltv_time(&c.s), c.ms, "time drifted for {}", c.name);
    }
    for d in &suite.docs {
        assert_eq!(parse_xmltv(&d.xml), d.expect, "doc parse drifted for {}", d.name);
    }
}

/// A known UTC instant, recomputed independently from the days-since-epoch the parser must agree with.
fn ymd_hms_to_ms(days_from_epoch: i64, h: i64, m: i64, s: i64) -> i64 {
    (days_from_epoch * 86_400 + h * 3_600 + m * 60 + s) * 1_000
}

proptest! {
    // The offset is a pure shift: the same wall-clock with a +HHMM offset is exactly HH:MM*60 seconds
    // earlier in UTC than the same wall-clock read as UTC. (Tests the offset math is the inverse it claims.)
    #[test]
    fn offset_shifts_utc_by_exactly_the_offset(off_h in 0i64..15, off_m in prop_oneof![Just(0i64), Just(30), Just(45)]) {
        let bare = parse_xmltv_time("20260629120000").unwrap(); // noon UTC
        let plus = parse_xmltv_time(&format!("20260629120000 +{off_h:02}{off_m:02}")).unwrap();
        let minus = parse_xmltv_time(&format!("20260629120000 -{off_h:02}{off_m:02}")).unwrap();
        let shift_ms = (off_h * 3_600 + off_m * 60) * 1_000;
        prop_assert_eq!(bare - plus, shift_ms);   // +offset is earlier in UTC
        prop_assert_eq!(minus - bare, shift_ms);  // -offset is later in UTC
    }

    // Parsing arbitrary bytes never panics; every emitted programme has start <= stop and a non-empty
    // channel id (a malformed one is skipped, not emitted with garbage).
    #[test]
    fn parse_is_panic_free_and_well_formed(s in ".*") {
        let epg = parse_xmltv(&s);
        for p in &epg.programs {
            prop_assert!(!p.channel_id.is_empty());
            prop_assert!(p.stop_utc_ms >= p.start_utc_ms);
        }
        // Deterministic.
        prop_assert_eq!(parse_xmltv(&s), epg);
    }

    // A synthesized programme round-trips its UTC instant: the parsed start equals an independently computed
    // ms for the same Y-M-D h:m:s at +0000.
    #[test]
    fn synthesized_programme_start_is_the_expected_utc(h in 0i64..24, m in 0i64..60) {
        // 2026-06-29 is 20633 days from the epoch (verified).
        let xml = format!(
            "<programme start=\"20260629{h:02}{m:02}00 +0000\" channel=\"c\"><title>T</title></programme>"
        );
        let p = &parse_xmltv(&xml).programs[0];
        prop_assert_eq!(p.start_utc_ms, ymd_hms_to_ms(20633, h, m, 0));
    }
}
