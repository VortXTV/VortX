//! Conformance + property tests for the AU2 LogicalTimeline + ResumeTarget. The half-open chapter bounds, the
//! chapter-snap resume, and the finished->restart reuse of the SH6 contract are the cross-platform guarantees:
//! the same duration + chapters + position must resolve to the same resume target on every device.

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::Value;
use vortx_protocol::Chapter;
use vortx_state::{finished, FinishPolicy, LogicalTimeline};

#[derive(Deserialize)]
struct Suite {
    chapter_at: Vec<ChapterAtCase>,
    resume: Vec<ResumeCase>,
    nav: Vec<NavCase>,
}

#[derive(Deserialize)]
struct ChapterAtCase {
    name: String,
    duration_ms: i64,
    chapters: Vec<Chapter>,
    cases: Vec<ChapterAtPoint>,
}

#[derive(Deserialize)]
struct ChapterAtPoint {
    offset_ms: i64,
    expect: Option<usize>,
}

#[derive(Deserialize)]
struct ResumeCase {
    name: String,
    duration_ms: i64,
    chapters: Vec<Chapter>,
    position_ms: i64,
    policy: FinishPolicy,
    snap_ms: i64,
    expect: Value,
}

#[derive(Deserialize)]
struct NavCase {
    name: String,
    duration_ms: i64,
    chapters: Vec<Chapter>,
    cases: Vec<NavPoint>,
}

#[derive(Deserialize)]
struct NavPoint {
    offset_ms: i64,
    next: Option<usize>,
    prev: Option<usize>,
}

const SUITE: &str = include_str!("../conformance/timeline_vectors.json");

#[test]
fn timeline_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse timeline suite");

    for c in &suite.chapter_at {
        let tl = LogicalTimeline::new(c.duration_ms, &c.chapters);
        for p in &c.cases {
            assert_eq!(
                tl.chapter_at(p.offset_ms),
                p.expect,
                "chapter_at drifted for {} @ {}",
                c.name,
                p.offset_ms
            );
        }
    }

    for c in &suite.resume {
        let tl = LogicalTimeline::new(c.duration_ms, &c.chapters);
        let got = tl.resume_with_snap(c.position_ms, &c.policy, c.snap_ms);
        assert_eq!(
            serde_json::to_value(got).unwrap(),
            c.expect,
            "resume drifted for {}",
            c.name
        );
    }

    for c in &suite.nav {
        let tl = LogicalTimeline::new(c.duration_ms, &c.chapters);
        for p in &c.cases {
            assert_eq!(
                tl.next_chapter(p.offset_ms),
                p.next,
                "next_chapter drifted for {} @ {}",
                c.name,
                p.offset_ms
            );
            assert_eq!(
                tl.prev_chapter(p.offset_ms),
                p.prev,
                "prev_chapter drifted for {} @ {}",
                c.name,
                p.offset_ms
            );
        }
    }
}

/// Ascending-start chapters (a real chapter list) from a deduped sorted set of start offsets.
fn chapters(starts: &[i64]) -> Vec<Chapter> {
    starts
        .iter()
        .map(|&s| Chapter {
            start_ms: s * 1000,
            end_ms: None,
            title: None,
        })
        .collect()
}

proptest! {
    // chapter_at always returns a chapter whose half-open segment actually contains the offset.
    #[test]
    fn chapter_at_offset_is_inside_the_returned_segment(
        starts in prop::collection::btree_set(0i64..120, 0..10).prop_map(|s| s.into_iter().collect::<Vec<_>>()),
        dur in 0i64..150,
        offset in -10i64..150,
    ) {
        let chs = chapters(&starts);
        let tl = LogicalTimeline::new(dur * 1000, &chs);
        let off = offset * 1000;
        if let Some(i) = tl.chapter_at(off) {
            prop_assert!(i < chs.len());
            let seg = tl.segment(i).unwrap();
            prop_assert!(seg.start_ms <= off && off < seg.end_ms);
        }
    }

    // resume is deterministic, stays in [0, duration], honors the SH6 finished->0 contract, and any resolved
    // chapter actually contains the returned position.
    #[test]
    fn resume_is_bounded_finished_aware_and_deterministic(
        starts in prop::collection::btree_set(0i64..120, 0..10).prop_map(|s| s.into_iter().collect::<Vec<_>>()),
        dur in 1i64..150,
        pos in -10i64..400,
    ) {
        let chs = chapters(&starts);
        let duration = dur * 1000;
        let tl = LogicalTimeline::new(duration, &chs);
        let position = pos * 1000;
        let r = tl.resume(position, &FinishPolicy::VIDEO);

        prop_assert_eq!(r, tl.resume(position, &FinishPolicy::VIDEO)); // deterministic
        prop_assert!(r.position_ms >= 0 && r.position_ms <= duration); // bounded

        let clamped = position.clamp(0, duration);
        if finished(clamped as u64, duration as u64, &FinishPolicy::VIDEO) {
            prop_assert_eq!(r.position_ms, 0); // SH6 finished -> restart
        }
        if let Some(i) = r.chapter_index {
            let seg = tl.segment(i).unwrap();
            prop_assert!(seg.start_ms <= r.position_ms && r.position_ms < seg.end_ms);
        }
    }

    // next/prev are strictly on the correct side of the offset and index valid chapters.
    #[test]
    fn next_and_prev_chapter_are_on_the_correct_side(
        starts in prop::collection::btree_set(0i64..120, 0..10).prop_map(|s| s.into_iter().collect::<Vec<_>>()),
        offset in -10i64..150,
    ) {
        let chs = chapters(&starts);
        let tl = LogicalTimeline::new(150_000, &chs);
        let off = offset * 1000;
        if let Some(i) = tl.next_chapter(off) {
            prop_assert!(chs[i].start_ms > off);
        }
        if let Some(i) = tl.prev_chapter(off) {
            prop_assert!(chs[i].start_ms < off);
        }
    }
}
