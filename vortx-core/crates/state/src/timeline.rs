//! AU2: the shared audio/video LogicalTimeline + ResumeTarget.
//!
//! ONE timeline model serves audiobook chapters, podcast segments, AND video skip-intro/credits ranges: a
//! pure view over a unit's `duration_ms` + its SH5 [`Chapter`] list (reused, not duplicated), plus a
//! [`ResumeTarget`] the host persists. Resume is chapter-aware (it snaps a near-boundary position back to the
//! chapter start so playback resumes cleanly, not mid-syllable) and reuses the SH6 [`finished`] contract so a
//! finished unit restarts at 0, with the SAME finish definition the library and scrobbler use.
//!
//! Pure + integer only (no float on any boundary or identity path) + deterministic + panic-free. A chapter is
//! identified by its stable integer INDEX in the list (SH5 [`Chapter`] has no id), so nothing is added to the
//! schema. Chapter effective ends are derived order-independently (next-greater start, else duration), so the
//! index identity holds and gaps between explicit-end chapters are preserved.

use serde::{Deserialize, Serialize};
use vortx_protocol::Chapter;

use crate::finish::{finished, FinishPolicy};

/// Default resume snap grace: a resume position within this many ms AFTER a chapter start snaps back to the
/// start, so playback resumes at a clean chapter boundary instead of a few seconds in.
pub const RESUME_SNAP_MS: i64 = 5_000;

/// A resolved segment of the timeline: a chapter index and its half-open `[start_ms, end_ms)` bounds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Segment {
    pub index: usize,
    pub start_ms: i64,
    pub end_ms: i64,
}

/// Where to resume a unit: the playhead position and the chapter index it resolved to (if any).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ResumeTarget {
    pub position_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapter_index: Option<usize>,
}

/// A pure timeline view over a unit's duration and chapters. Borrows the chapters (no clone, no allocation on
/// the query path). Chapters are expected in ascending `start_ms` order (a real chapter list is); effective
/// ends are derived order-independently so the chapter index identity is stable regardless.
#[derive(Debug, Clone, Copy)]
pub struct LogicalTimeline<'a> {
    duration_ms: i64,
    chapters: &'a [Chapter],
}

impl<'a> LogicalTimeline<'a> {
    pub fn new(duration_ms: i64, chapters: &'a [Chapter]) -> Self {
        Self {
            duration_ms,
            chapters,
        }
    }

    /// The number of segments: the chapter count, or 1 when there are no chapters (the whole unit is one
    /// implicit segment `[0, duration)`).
    pub fn segment_count(&self) -> usize {
        if self.chapters.is_empty() {
            1
        } else {
            self.chapters.len()
        }
    }

    /// The half-open `[start, end)` bounds of chapter `i`: `start_ms` clamped to >= 0, and `end_ms` if
    /// explicit else the next-greater chapter start else `duration_ms`, never less than the start.
    fn effective_bounds(&self, i: usize) -> (i64, i64) {
        let raw_start = self.chapters[i].start_ms;
        let start = raw_start.max(0);
        let end = match self.chapters[i].end_ms {
            Some(e) => e,
            None => self
                .chapters
                .iter()
                .map(|c| c.start_ms)
                .filter(|&s| s > raw_start)
                .min()
                .unwrap_or(self.duration_ms),
        };
        (start, start.max(end))
    }

    /// The segment at index `i` (chapter `i`, or the single implicit segment when there are no chapters).
    pub fn segment(&self, i: usize) -> Option<Segment> {
        if self.chapters.is_empty() {
            return (i == 0).then_some(Segment {
                index: 0,
                start_ms: 0,
                end_ms: self.duration_ms.max(0),
            });
        }
        if i >= self.chapters.len() {
            return None;
        }
        let (start_ms, end_ms) = self.effective_bounds(i);
        Some(Segment {
            index: i,
            start_ms,
            end_ms,
        })
    }

    /// The chapter whose half-open `[start, end)` contains `offset_ms` (a chapter ending exactly at the offset
    /// is not it; one starting exactly at it is). `None` when there are no chapters or the offset is in a gap
    /// / outside every chapter. First match by index (segments tile without overlap for a sorted list).
    pub fn chapter_at(&self, offset_ms: i64) -> Option<usize> {
        (0..self.chapters.len()).find(|&i| {
            let (s, e) = self.effective_bounds(i);
            s <= offset_ms && offset_ms < e
        })
    }

    /// Distinct chapter start offsets, ascending. Empty when there are no chapters.
    pub fn boundaries(&self) -> Vec<i64> {
        let mut starts: Vec<i64> = self.chapters.iter().map(|c| c.start_ms.max(0)).collect();
        starts.sort_unstable();
        starts.dedup();
        starts
    }

    /// The chapter to skip FORWARD to: the one whose start is the smallest value strictly greater than
    /// `offset_ms`. `None` if none lies ahead.
    pub fn next_chapter(&self, offset_ms: i64) -> Option<usize> {
        (0..self.chapters.len())
            .filter(|&i| self.chapters[i].start_ms > offset_ms)
            .min_by_key(|&i| (self.chapters[i].start_ms, i))
    }

    /// The chapter to skip BACK to: the one whose start is the largest value strictly less than `offset_ms`.
    /// `None` if none lies behind. (Pure boundary navigation; a host wanting "restart current chapter" uses
    /// [`chapter_at`](Self::chapter_at).)
    pub fn prev_chapter(&self, offset_ms: i64) -> Option<usize> {
        (0..self.chapters.len())
            .filter(|&i| self.chapters[i].start_ms < offset_ms)
            .max_by_key(|&i| (self.chapters[i].start_ms, i))
    }

    /// The start of the segment containing `pos` (or the nearest chapter start at/below it, else 0).
    fn segment_start_at(&self, pos: i64) -> i64 {
        if let Some(i) = self.chapter_at(pos) {
            return self.effective_bounds(i).0;
        }
        self.chapters
            .iter()
            .map(|c| c.start_ms.max(0))
            .filter(|&s| s <= pos)
            .max()
            .unwrap_or(0)
    }

    /// Resume with the default [`RESUME_SNAP_MS`] grace.
    pub fn resume(&self, position_ms: i64, policy: &FinishPolicy) -> ResumeTarget {
        self.resume_with_snap(position_ms, policy, RESUME_SNAP_MS)
    }

    /// Resolve where to resume from `position_ms` under `policy`: if the unit is FINISHED (SH6 [`finished`],
    /// the same contract the library uses), restart at 0; otherwise clamp into `[0, duration]` and snap back
    /// to the current chapter start when within `snap_ms` of it. Carries the resolved chapter index.
    pub fn resume_with_snap(
        &self,
        position_ms: i64,
        policy: &FinishPolicy,
        snap_ms: i64,
    ) -> ResumeTarget {
        let dur = self.duration_ms.max(0);
        let upper = if dur > 0 { dur } else { position_ms.max(0) };
        let pos = position_ms.clamp(0, upper);

        if finished(pos as u64, dur as u64, policy) {
            return ResumeTarget {
                position_ms: 0,
                chapter_index: self.chapter_at(0),
            };
        }

        let seg_start = self.segment_start_at(pos);
        let snapped = if snap_ms >= 0 && pos - seg_start <= snap_ms {
            seg_start
        } else {
            pos
        };
        ResumeTarget {
            position_ms: snapped,
            chapter_index: self.chapter_at(snapped),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chap(start: i64, end: Option<i64>) -> Chapter {
        Chapter {
            start_ms: start,
            end_ms: end,
            title: None,
        }
    }

    #[test]
    fn chapter_at_uses_half_open_bounds_with_derived_ends() {
        let chapters = [chap(0, None), chap(60_000, None), chap(120_000, None)];
        let tl = LogicalTimeline::new(180_000, &chapters);
        assert_eq!(tl.chapter_at(0), Some(0)); // start inclusive
        assert_eq!(tl.chapter_at(59_999), Some(0));
        assert_eq!(tl.chapter_at(60_000), Some(1)); // boundary belongs to the starting chapter
        assert_eq!(tl.chapter_at(179_999), Some(2));
        assert_eq!(tl.chapter_at(180_000), None); // end exclusive (== duration)
        assert_eq!(tl.chapter_at(-1), None);
    }

    #[test]
    fn explicit_ends_create_gaps_that_belong_to_no_chapter() {
        let chapters = [chap(0, Some(10_000)), chap(20_000, Some(30_000))];
        let tl = LogicalTimeline::new(30_000, &chapters);
        assert_eq!(tl.chapter_at(5_000), Some(0));
        assert_eq!(tl.chapter_at(15_000), None); // in the [10s,20s) gap
        assert_eq!(tl.chapter_at(25_000), Some(1));
    }

    #[test]
    fn empty_chapters_is_one_implicit_segment() {
        let tl = LogicalTimeline::new(120_000, &[]);
        assert_eq!(tl.segment_count(), 1);
        assert_eq!(
            tl.segment(0),
            Some(Segment {
                index: 0,
                start_ms: 0,
                end_ms: 120_000
            })
        );
        assert_eq!(tl.chapter_at(60_000), None); // no real chapter
    }

    #[test]
    fn next_and_prev_chapter_navigate_boundaries() {
        let chapters = [chap(0, None), chap(60_000, None), chap(120_000, None)];
        let tl = LogicalTimeline::new(180_000, &chapters);
        assert_eq!(tl.next_chapter(30_000), Some(1));
        assert_eq!(tl.next_chapter(120_000), None); // nothing starts after the last
        assert_eq!(tl.prev_chapter(130_000), Some(2));
        assert_eq!(tl.prev_chapter(0), None); // nothing starts before 0
    }

    #[test]
    fn resume_snaps_back_to_the_chapter_start_within_grace() {
        let chapters = [chap(0, None), chap(60_000, None)];
        let tl = LogicalTimeline::new(120_000, &chapters);
        // VIDEO policy (no tail grace): 63s of 120s is 52.5%, not finished.
        // 3s into chapter 2 (within the 5s snap) -> snaps to the chapter 2 start.
        let r = tl.resume(63_000, &FinishPolicy::VIDEO);
        assert_eq!(r.position_ms, 60_000);
        assert_eq!(r.chapter_index, Some(1));
        // 10s in (outside the snap) -> stays.
        let r2 = tl.resume(70_000, &FinishPolicy::VIDEO);
        assert_eq!(r2.position_ms, 70_000);
        assert_eq!(r2.chapter_index, Some(1));
    }

    #[test]
    fn resume_restarts_a_finished_unit_at_zero() {
        // A 60-minute audiobook with chapters; stopping at 57:00 is within the AUDIO 5-min tail grace -> the
        // SH6 finished() contract says finished -> restart at 0.
        let chapters = [chap(0, None), chap(1_800_000, None)];
        let tl = LogicalTimeline::new(3_600_000, &chapters);
        let r = tl.resume(3_420_000, &FinishPolicy::AUDIO);
        assert_eq!(r.position_ms, 0);
        assert_eq!(r.chapter_index, Some(0));
        // Mid-book (30:00, 50%) is not finished -> resume there (chapter 2 just started, snaps to it).
        let mid = tl.resume(1_800_000, &FinishPolicy::AUDIO);
        assert_eq!(mid.position_ms, 1_800_000);
        assert_eq!(mid.chapter_index, Some(1));
    }

    #[test]
    fn resume_clamps_into_the_duration() {
        let tl = LogicalTimeline::new(120_000, &[]);
        let r = tl.resume(999_999, &FinishPolicy::VIDEO);
        // 999999 of 120000 is finished -> restart at 0.
        assert_eq!(r.position_ms, 0);
    }

    #[test]
    fn unknown_duration_never_finishes_and_resume_keeps_position() {
        let tl = LogicalTimeline::new(0, &[]);
        let r = tl.resume(50_000, &FinishPolicy::AUDIO);
        assert_eq!(r.position_ms, 50_000); // no snap boundary but 0; 50s outside snap of 0
        assert_eq!(r.chapter_index, None);
    }
}
