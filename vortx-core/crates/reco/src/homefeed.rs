//! The Home feed: a multi-lane builder that turns the watch-state CRDT, the saved library, the reco
//! scorer, and a popularity list into the ordered rows a Home screen shows.
//!
//! The 10x over a stock Home screen (Stremio/Plex/Jellyfin) is two structural choices the others skip:
//!
//! 1. **Eligibility BEFORE ranking.** Every candidate is gated by an [`EligibilityFilter`] (is this title
//!    actually playable right now: cached on a debrid, or reachable via a live catalog) BEFORE it can
//!    enter any lane. Competitors rank first and you discover the top card is a dead link only on click;
//!    here an ineligible title can never reach a lane, so every visible card is playable.
//! 2. **Cross-lane dedup in priority order.** A title appears in exactly ONE lane. Up Next wins over Start
//!    Watching wins over Because You Watched wins over Trending, so the same show never double-renders as
//!    "continue" and "recommended for you".
//!
//! The lane semantics are driven by the watch-state CRDT's domain-correct fields rather than a single
//! timestamp, so a finished title can never surface in Up Next and a stale pause can never resurrect a
//! removed one. The reco lanes reuse [`crate::recommend`] unchanged: its honest reason decomposition is
//! what splits "Because You Watched" (a taste match) from the popularity-only Trending fallback.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use vortx_state::{
    maturity_allows, merge_watch, MaturityRating, ParentalFlags, ProfileLibrary, WatchLog,
    WatchState,
};

use crate::recommend::{recommend, Candidate, Reason, RecoPrefs};

/// A resume offset within this fraction (per-mille) of the runtime counts as FINISHED, not in-progress, so
/// a title you watched to the end never reappears in Up Next.
const NEAR_END_PERMILLE: u64 = 900;

/// Derive a [`WatchLog`] from a profile's stored library: each resume point becomes an in-progress watch
/// state (or finished when it is near the end), and each history entry becomes finished. This is how the
/// engine turns the real continue-watching + history state into the Up Next / Start Watching signals,
/// reusing the watch-state CRDT merge so the two sources combine domain-correctly.
pub fn watch_log_from_library(lib: &ProfileLibrary) -> WatchLog {
    let mut log = WatchLog::new();
    for (id, rp) in &lib.resume {
        let near_end = rp.duration_secs > 0
            && rp.offset_secs.saturating_mul(1000)
                >= rp.duration_secs.saturating_mul(NEAR_END_PERMILLE);
        let ws = if near_end {
            WatchState::finished(rp.updated_at)
        } else {
            WatchState::resumed(rp.offset_secs.saturating_mul(1000), rp.updated_at)
        };
        merge_into(&mut log, id, ws);
    }
    for h in &lib.history {
        merge_into(&mut log, &h.id, WatchState::finished(h.watched_at));
    }
    log
}

fn merge_into(log: &mut WatchLog, id: &str, ws: WatchState) {
    log.entry(id.to_string())
        .and_modify(|e| *e = merge_watch(e, &ws))
        .or_insert(ws);
}
use crate::taste::TasteProfile;

/// The availability gate. The engine plugs in a real source (debrid cache vault + live-catalog set); a
/// pure set-backed impl is provided for tests and for the "everything we were handed is eligible" case.
pub trait EligibilityFilter {
    fn is_eligible(&self, meta_id: &str) -> bool;
}

/// A set of currently-playable meta ids. `is_eligible` is membership.
#[derive(Debug, Clone, Default)]
pub struct AvailabilitySet(pub HashSet<String>);

impl AvailabilitySet {
    pub fn new<I, S>(ids: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self(ids.into_iter().map(Into::into).collect())
    }
}

impl EligibilityFilter for AvailabilitySet {
    fn is_eligible(&self, meta_id: &str) -> bool {
        self.0.contains(meta_id)
    }
}

/// Treats every title as eligible (no availability source wired yet).
#[derive(Debug, Clone, Copy, Default)]
pub struct AllEligible;

impl EligibilityFilter for AllEligible {
    fn is_eligible(&self, _meta_id: &str) -> bool {
        true
    }
}

/// Enforces a profile's parental controls as an eligibility gate. A meta is eligible only if its content
/// rating is within the profile's ceiling; a meta with no known rating is treated as unrated, so a kids
/// profile fails closed (never surfaces what we cannot prove is within its ceiling). Because
/// [`build_home_feed`] applies the eligibility filter to EVERY lane before ranking, composing this gate in
/// enforces parental controls across all lanes and the reco candidate pool at once.
pub struct MaturityGate<'a> {
    pub flags: &'a ParentalFlags,
    /// meta id -> reconciled rating (`None` = unrated/unknown). A missing key is also treated as unrated.
    pub ratings: &'a HashMap<String, Option<MaturityRating>>,
}

impl EligibilityFilter for MaturityGate<'_> {
    fn is_eligible(&self, meta_id: &str) -> bool {
        let rating = self.ratings.get(meta_id).copied().flatten();
        maturity_allows(self.flags, rating)
    }
}

/// Compose filters with AND: a meta is eligible only if EVERY filter admits it. Pass `AllOf(&[&availability,
/// &maturity])` to [`build_home_feed`] to enforce availability AND parental controls in one gate.
pub struct AllOf<'a>(pub &'a [&'a dyn EligibilityFilter]);

impl EligibilityFilter for AllOf<'_> {
    fn is_eligible(&self, meta_id: &str) -> bool {
        self.0.iter().all(|f| f.is_eligible(meta_id))
    }
}

/// Which row a [`LaneItem`] belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LaneKind {
    /// In-progress titles, most-recently-active first. Continue where you left off.
    UpNext,
    /// Saved-but-never-started titles, in library order.
    StartWatching,
    /// Taste matches from the reco scorer (a real `BecauseYouLike` reason).
    BecauseYouWatched,
    /// Popularity fallback for cold-start / thin taste.
    Trending,
}

/// One card in a lane.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaneItem {
    pub meta_id: String,
    /// Playhead in ms, set only for Up Next cards.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_ms: Option<u64>,
    /// Why it was picked, set only for reco lanes (e.g. `"genre:Sci-Fi"` or `"trending"`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// One Home row.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Lane {
    pub kind: LaneKind,
    pub items: Vec<LaneItem>,
}

/// The assembled Home feed: lanes in display order, empties dropped.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HomeFeed {
    pub lanes: Vec<Lane>,
}

/// Everything the builder reads. All borrowed and immutable: the build is a pure function.
pub struct HomeFeedInput<'a> {
    /// The merged watch-state CRDT (build it upstream with `vortx_state::merge_log`).
    pub watch_log: &'a WatchLog,
    /// Saved meta ids in the user's own order (for Start Watching).
    pub library: &'a [String],
    /// The reco candidate pool (for Because You Watched).
    pub candidates: &'a [Candidate],
    /// The profile's taste vector.
    pub taste: &'a TasteProfile,
    /// Popularity-ranked meta ids (for the Trending fallback lane).
    pub trending: &'a [String],
}

/// Per-lane caps + the reco tuning.
#[derive(Debug, Clone)]
pub struct HomeFeedPrefs {
    pub up_next_max: usize,
    pub start_watching_max: usize,
    pub trending_max: usize,
    pub reco: RecoPrefs,
}

impl Default for HomeFeedPrefs {
    fn default() -> Self {
        Self {
            up_next_max: 20,
            start_watching_max: 20,
            trending_max: 20,
            reco: RecoPrefs::default(),
        }
    }
}

/// A title is "in progress" (Up Next) when it has a real playhead, is not finished, and is not removed.
fn is_in_progress(w: &WatchState) -> bool {
    w.resume_ms > 0 && !w.is_watched() && !w.is_removed()
}

/// A library title is startable (Start Watching) when nothing in its watch state has begun: no playhead,
/// not finished, not removed. A missing entry counts as startable.
fn is_startable(log: &WatchLog, meta_id: &str) -> bool {
    match log.get(meta_id) {
        None => true,
        Some(w) => w.resume_ms == 0 && !w.is_watched() && !w.is_removed(),
    }
}

fn reason_wire(reason: &Reason) -> String {
    match reason {
        Reason::BecauseYouLike(key) => key.clone(),
        Reason::Trending => "trending".to_string(),
    }
}

/// Build the Home feed. Eligibility gates candidacy in EVERY lane, lanes are filled in priority order, and
/// a title lands in exactly one lane. Deterministic: the same inputs yield the same feed everywhere.
pub fn build_home_feed(
    input: &HomeFeedInput,
    eligible: &dyn EligibilityFilter,
    prefs: &HomeFeedPrefs,
) -> HomeFeed {
    let mut placed: HashSet<String> = HashSet::new();
    let mut lanes: Vec<Lane> = Vec::new();

    // Lane 1 - Up Next: in-progress + eligible, most recently active first.
    let mut up_next: Vec<(&String, &WatchState)> = input
        .watch_log
        .iter()
        .filter(|(id, w)| is_in_progress(w) && eligible.is_eligible(id))
        .collect();
    // Most recent resume first; ties broken by meta_id for a stable cross-platform order.
    up_next.sort_by(|(a_id, a), (b_id, b)| {
        b.resume_at
            .cmp(&a.resume_at)
            .then_with(|| a_id.cmp(b_id))
    });
    let up_next_items: Vec<LaneItem> = up_next
        .into_iter()
        .take(prefs.up_next_max)
        .map(|(id, w)| {
            placed.insert(id.clone());
            LaneItem {
                meta_id: id.clone(),
                resume_ms: Some(w.resume_ms),
                reason: None,
            }
        })
        .collect();
    push_lane(&mut lanes, LaneKind::UpNext, up_next_items);

    // Lane 2 - Start Watching: saved-but-never-started + eligible, in library order. `placed.insert`
    // returns false when the id is already in another lane OR is a duplicate within the library, so it is
    // the single check-and-claim that keeps every title in exactly one lane and a lane free of dupes.
    let mut start_items: Vec<LaneItem> = Vec::new();
    for id in input.library {
        if start_items.len() >= prefs.start_watching_max {
            break;
        }
        if eligible.is_eligible(id)
            && is_startable(input.watch_log, id)
            && placed.insert(id.clone())
        {
            start_items.push(LaneItem {
                meta_id: id.clone(),
                resume_ms: None,
                reason: None,
            });
        }
    }
    push_lane(&mut lanes, LaneKind::StartWatching, start_items);

    // Lane 3 - Because You Watched: reco scorer over ELIGIBLE, not-already-placed candidates. Eligibility
    // applies before ranking by filtering the candidate pool; `placed` is passed as the exclude-set so the
    // scorer never re-surfaces an Up Next / Start Watching title.
    let eligible_candidates: Vec<Candidate> = input
        .candidates
        .iter()
        .filter(|c| eligible.is_eligible(&c.meta_id))
        .cloned()
        .collect();
    let recs = recommend(&eligible_candidates, input.taste, &placed, &prefs.reco);
    let mut reco_items: Vec<LaneItem> = Vec::new();
    for r in recs {
        // Only genuine taste matches land here; pure-popularity picks fall to the Trending lane.
        let reason = r
            .reasons
            .iter()
            .find(|x| matches!(x, Reason::BecauseYouLike(_)))
            .map(reason_wire);
        // `placed.insert` guards against a candidate id that duplicates one already in a lane.
        if reason.is_some() && placed.insert(r.meta_id.clone()) {
            reco_items.push(LaneItem {
                meta_id: r.meta_id,
                resume_ms: None,
                reason,
            });
        }
    }
    push_lane(&mut lanes, LaneKind::BecauseYouWatched, reco_items);

    // Lane 4 - Trending: popularity list, eligible + not placed, in given order.
    let mut trending_items: Vec<LaneItem> = Vec::new();
    for id in input.trending {
        if trending_items.len() >= prefs.trending_max {
            break;
        }
        if eligible.is_eligible(id) && placed.insert(id.clone()) {
            trending_items.push(LaneItem {
                meta_id: id.clone(),
                resume_ms: None,
                reason: Some("trending".to_string()),
            });
        }
    }
    push_lane(&mut lanes, LaneKind::Trending, trending_items);

    HomeFeed { lanes }
}

/// Append a lane only when it has items (empty rows are dropped from the feed).
fn push_lane(lanes: &mut Vec<Lane>, kind: LaneKind, items: Vec<LaneItem>) {
    if !items.is_empty() {
        lanes.push(Lane { kind, items });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn log_of(entries: &[(&str, WatchState)]) -> WatchLog {
        entries.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    #[test]
    fn up_next_orders_by_recency_and_excludes_finished() {
        let log = log_of(&[
            ("a", WatchState::resumed(1000, 100)),
            ("b", WatchState::resumed(2000, 300)), // more recent
            ("c", WatchState::finished(400)),      // watched -> never in Up Next
        ]);
        let input = HomeFeedInput {
            watch_log: &log,
            library: &[],
            candidates: &[],
            taste: &crate::build_taste(&[]),
            trending: &[],
        };
        let feed = build_home_feed(&input, &AllEligible, &HomeFeedPrefs::default());
        let up = &feed.lanes[0];
        assert_eq!(up.kind, LaneKind::UpNext);
        let ids: Vec<&str> = up.items.iter().map(|i| i.meta_id.as_str()).collect();
        assert_eq!(ids, vec!["b", "a"]); // recency desc, finished "c" absent
    }

    #[test]
    fn ineligible_titles_never_reach_a_lane() {
        let log = log_of(&[("a", WatchState::resumed(1000, 100))]);
        let input = HomeFeedInput {
            watch_log: &log,
            library: &["b".to_string()],
            candidates: &[],
            taste: &crate::build_taste(&[]),
            trending: &["c".to_string()],
        };
        // Nothing is eligible.
        let feed = build_home_feed(&input, &AvailabilitySet::default(), &HomeFeedPrefs::default());
        assert!(feed.lanes.is_empty());
    }

    #[test]
    fn a_title_appears_in_only_one_lane() {
        // "a" is in progress AND in the library AND trending: Up Next must win.
        let log = log_of(&[("a", WatchState::resumed(500, 100))]);
        let input = HomeFeedInput {
            watch_log: &log,
            library: &["a".to_string(), "b".to_string()],
            candidates: &[],
            taste: &crate::build_taste(&[]),
            trending: &["a".to_string(), "d".to_string()],
        };
        let feed = build_home_feed(
            &input,
            &AvailabilitySet::new(["a", "b", "d"]),
            &HomeFeedPrefs::default(),
        );
        let mut seen = HashSet::new();
        for lane in &feed.lanes {
            for item in &lane.items {
                assert!(seen.insert(item.meta_id.clone()), "{} in two lanes", item.meta_id);
            }
        }
        // "a" only in Up Next; "b" startable; "d" trending.
        let up: Vec<&str> = feed.lanes[0].items.iter().map(|i| i.meta_id.as_str()).collect();
        assert_eq!(up, vec!["a"]);
    }

    #[test]
    fn watch_log_derivation_marks_in_progress_finished_and_history() {
        use vortx_state::{HistoryEntry, ProfileLibrary, ResumePoint};
        let mut lib = ProfileLibrary::default();
        // In-progress: 10 min into a 60 min title.
        lib.resume.insert(
            "a".into(),
            ResumePoint { offset_secs: 600, duration_secs: 3600, updated_at: 100 },
        );
        // Near the end: 59 of 60 min -> treated as finished.
        lib.resume.insert(
            "b".into(),
            ResumePoint { offset_secs: 3540, duration_secs: 3600, updated_at: 200 },
        );
        // History: explicitly finished.
        lib.history.push(HistoryEntry { id: "c".into(), video_id: None, watched_at: 300 });

        let log = watch_log_from_library(&lib);
        assert_eq!(log["a"].resume_ms, 600_000);
        assert!(!log["a"].is_watched()); // in progress
        assert!(log["b"].is_watched()); // near-end resume counts as finished
        assert!(log["c"].is_watched());
    }

    #[test]
    fn maturity_gate_blocks_over_ceiling_and_unrated_across_lanes() {
        // A kids profile (default ceiling 12). "r" is over-ceiling, "unrated" has no known rating, "g" is
        // fine. They sit across Up Next / library / trending; none of the blocked ones may surface.
        let log = log_of(&[
            ("g", WatchState::resumed(100, 10)),
            ("r", WatchState::resumed(200, 20)),
        ]);
        let mut ratings: HashMap<String, Option<MaturityRating>> = HashMap::new();
        ratings.insert("g".into(), Some(MaturityRating(0)));
        ratings.insert("r".into(), Some(MaturityRating(17)));
        // "unrated" deliberately absent from the map -> treated as unrated -> fail-closed for kids.
        let flags = ParentalFlags {
            kids: true,
            ..Default::default()
        };
        let input = HomeFeedInput {
            watch_log: &log,
            library: &["unrated".to_string()],
            candidates: &[],
            taste: &crate::build_taste(&[]),
            trending: &["g".to_string(), "r".to_string()],
        };
        let avail = AvailabilitySet::new(["g", "r", "unrated"]);
        let gate = MaturityGate {
            flags: &flags,
            ratings: &ratings,
        };
        let feed = build_home_feed(
            &input,
            &AllOf(&[&avail, &gate]),
            &HomeFeedPrefs::default(),
        );
        let shown: HashSet<&str> = feed
            .lanes
            .iter()
            .flat_map(|l| l.items.iter().map(|i| i.meta_id.as_str()))
            .collect();
        assert!(shown.contains("g"), "g is within ceiling and should show");
        assert!(!shown.contains("r"), "R is over the kids ceiling");
        assert!(!shown.contains("unrated"), "unrated is fail-closed for kids");
    }
}
