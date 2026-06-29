//! LT4: EPG now/next + windowed grid query views over the LT2 [`Program`] corpus.
//!
//! These are PURE query views: the kernel answers windowed queries over programmes the host already parsed
//! (LT2) and stores; the host owns the index and passes `now` (there is NO clock inside the kernel). Nothing
//! here fetches or allocates a clock, so a guide rendered on Apple, Android, and wasm from the same corpus is
//! byte-identical.
//!
//! Time is UTC milliseconds throughout (the unit LT2 [`Program::start_utc_ms`] emits). [`EpgWindow`] here is
//! the millisecond twin of the source crate's `EpgWindow` (which is Unix SECONDS for the wire request): both
//! are half-open `[start, end)` with the SAME `contains`/`overlaps` truth, so a host converts seconds->ms
//! once at the boundary and the semantics never drift. See `guide.rs` conformance vectors for the unit pin.
//!
//! The 10x is correctness at the boundaries: half-open intervals (a programme ending exactly at `now` is NOT
//! "now"; one starting exactly at `now` IS), explicit gap handling (no programme covering `now` -> `now=None`,
//! `next` is still the upcoming one), and window-clamping so a programme straddling a window edge renders at
//! the edge instead of overflowing the grid.

use serde::Serialize;

use crate::epg::Program;

/// A half-open EPG time window `[start_utc_ms, end_utc_ms)` in UTC milliseconds. Millisecond twin of the
/// source crate's seconds-based `EpgWindow`; identical half-open semantics (see module docs).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct EpgWindow {
    pub start_utc_ms: i64,
    pub end_utc_ms: i64,
}

impl EpgWindow {
    pub fn new(start_utc_ms: i64, end_utc_ms: i64) -> Self {
        Self {
            start_utc_ms,
            end_utc_ms,
        }
    }

    /// Whether `t` falls in the half-open window: `start <= t < end`.
    pub fn contains(&self, t: i64) -> bool {
        t >= self.start_utc_ms && t < self.end_utc_ms
    }

    /// Whether an interval `[start, end)` overlaps this window (standard half-open overlap).
    pub fn overlaps(&self, start: i64, end: i64) -> bool {
        start < self.end_utc_ms && end > self.start_utc_ms
    }
}

/// The now/next answer for one channel at an instant. Either may be absent (gap before/after the schedule).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct NowNext<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub now: Option<&'a Program>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next: Option<&'a Program>,
}

/// A programme placed on the grid, clamped to the queried window for display.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GridProgram<'a> {
    pub program: &'a Program,
    /// `max(program.start_utc_ms, window.start_utc_ms)` so a programme straddling the left edge starts at it.
    pub clamped_start_ms: i64,
    /// `min(program.stop_utc_ms, window.end_utc_ms)` so a programme straddling the right edge ends at it.
    pub clamped_stop_ms: i64,
}

/// One channel's row in the grid: the channel id and its programmes overlapping the window, in time order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ChannelGrid<'a> {
    pub channel_id: String,
    pub programs: Vec<GridProgram<'a>>,
}

/// The programmes on one channel, sorted by `(start, stop)` so picks are deterministic. Stable sort keeps
/// equal-keyed programmes in input order; callers that need full order-independence give distinct starts.
fn channel_sorted<'a>(programs: &'a [Program], channel_id: &str) -> Vec<&'a Program> {
    let mut chan: Vec<&Program> = programs
        .iter()
        .filter(|p| p.channel_id == channel_id)
        .collect();
    chan.sort_by_key(|p| (p.start_utc_ms, p.stop_utc_ms));
    chan
}

/// Now/next for `channel_id` at `now_utc_ms`. `now` is the programme whose half-open `[start, stop)` contains
/// the instant (the most recently started one, if a bad schedule overlaps); `next` is the earliest programme
/// starting at/after the instant that is not the `now` programme itself. A zero-length programme
/// (`stop == start`, e.g. LT2 defaulting a missing stop) has an empty interval, so it is never `now`.
pub fn now_next<'a>(programs: &'a [Program], channel_id: &str, now_utc_ms: i64) -> NowNext<'a> {
    let chan = channel_sorted(programs, channel_id);

    // `now`: among programmes containing the instant, the one with the greatest start (= greatest index,
    // since sorted ascending). Half-open: start <= now < stop, so a programme ending exactly at now is out.
    let now_idx = chan
        .iter()
        .enumerate()
        .filter(|(_, p)| p.start_utc_ms <= now_utc_ms && now_utc_ms < p.stop_utc_ms)
        .map(|(i, _)| i)
        .max();

    // `next`: earliest programme starting at/after the instant, excluding the `now` programme (which can
    // share the instant only when it starts exactly at it).
    let next = chan
        .iter()
        .enumerate()
        .find(|(i, p)| p.start_utc_ms >= now_utc_ms && Some(*i) != now_idx)
        .map(|(_, p)| *p);

    NowNext {
        now: now_idx.map(|i| chan[i]),
        next,
    }
}

/// The grid for `channel_ids` over `window`: one row per requested channel (in the order given, empty rows
/// included), each programme overlapping the window clamped to it for display, in time order.
pub fn grid<'a>(
    programs: &'a [Program],
    channel_ids: &[&str],
    window: &EpgWindow,
) -> Vec<ChannelGrid<'a>> {
    channel_ids
        .iter()
        .map(|&cid| {
            let programs = channel_sorted(programs, cid)
                .into_iter()
                .filter(|p| window.overlaps(p.start_utc_ms, p.stop_utc_ms))
                .map(|p| GridProgram {
                    program: p,
                    clamped_start_ms: p.start_utc_ms.max(window.start_utc_ms),
                    clamped_stop_ms: p.stop_utc_ms.min(window.end_utc_ms),
                })
                .collect();
            ChannelGrid {
                channel_id: cid.to_string(),
                programs,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prog(channel: &str, start: i64, stop: i64, title: &str) -> Program {
        Program {
            channel_id: channel.to_string(),
            start_utc_ms: start,
            stop_utc_ms: stop,
            title: title.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn window_is_half_open() {
        let w = EpgWindow::new(100, 200);
        assert!(!w.contains(99));
        assert!(w.contains(100)); // start is inclusive
        assert!(w.contains(199));
        assert!(!w.contains(200)); // end is exclusive
        assert!(w.overlaps(150, 250));
        assert!(!w.overlaps(200, 300)); // touches the end, no overlap
        assert!(!w.overlaps(0, 100)); // touches the start, no overlap
    }

    #[test]
    fn now_next_picks_the_airing_and_the_upcoming() {
        let progs = vec![
            prog("c", 0, 100, "A"),
            prog("c", 100, 200, "B"),
            prog("c", 200, 300, "C"),
        ];
        let nn = now_next(&progs, "c", 150);
        assert_eq!(nn.now.unwrap().title, "B");
        assert_eq!(nn.next.unwrap().title, "C");
    }

    #[test]
    fn boundary_instant_belongs_to_the_starting_programme_not_the_ending_one() {
        let progs = vec![prog("c", 0, 100, "A"), prog("c", 100, 200, "B")];
        // At exactly 100: A ends (excluded), B starts (included). next is the one after B.
        let nn = now_next(&progs, "c", 100);
        assert_eq!(nn.now.unwrap().title, "B");
        assert!(nn.next.is_none());
    }

    #[test]
    fn a_gap_yields_no_now_but_still_a_next() {
        let progs = vec![prog("c", 0, 100, "A"), prog("c", 200, 300, "C")];
        let nn = now_next(&progs, "c", 150); // in the gap
        assert!(nn.now.is_none());
        assert_eq!(nn.next.unwrap().title, "C");
    }

    #[test]
    fn a_zero_length_programme_is_never_now() {
        let progs = vec![prog("c", 100, 100, "Z")]; // missing-stop default from LT2
        let nn = now_next(&progs, "c", 100);
        assert!(nn.now.is_none());
        assert_eq!(nn.next.unwrap().title, "Z"); // it can still be "next"
    }

    #[test]
    fn grid_clamps_straddling_programmes_to_the_window() {
        let progs = vec![
            prog("c", 0, 150, "left-straddle"),
            prog("c", 150, 250, "inside"),
            prog("c", 250, 400, "right-straddle"),
            prog("c", 400, 500, "after"),
        ];
        let w = EpgWindow::new(100, 300);
        let g = grid(&progs, &["c"], &w);
        assert_eq!(g.len(), 1);
        let row = &g[0];
        assert_eq!(row.programs.len(), 3); // "after" excluded
        assert_eq!(row.programs[0].clamped_start_ms, 100); // clamped to window start
        assert_eq!(row.programs[0].clamped_stop_ms, 150);
        assert_eq!(row.programs[2].clamped_start_ms, 250);
        assert_eq!(row.programs[2].clamped_stop_ms, 300); // clamped to window end
    }

    #[test]
    fn grid_includes_an_empty_row_for_a_channel_with_no_programmes() {
        let progs = vec![prog("a", 0, 100, "A")];
        let w = EpgWindow::new(0, 100);
        let g = grid(&progs, &["a", "b"], &w);
        assert_eq!(g.len(), 2);
        assert_eq!(g[1].channel_id, "b");
        assert!(g[1].programs.is_empty());
    }

    #[test]
    fn overlapping_schedule_picks_the_most_recently_started_as_now() {
        // Bad data: two programmes cover the instant; the one that started later is "now".
        let progs = vec![prog("c", 0, 300, "long"), prog("c", 100, 200, "short")];
        let nn = now_next(&progs, "c", 150);
        assert_eq!(nn.now.unwrap().title, "short");
    }
}
