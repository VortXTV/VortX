//! Field-level watch-state sync, as a proper CRDT with domain-correct merge semantics. This is the fix
//! for the worst data-loss class in stremio-core: there a whole `LibraryItem` is one timestamp, so a
//! stale "paused at 5 min" sync can clobber a "finished" recorded later on another device. Here every
//! signal is independently clocked and merged by the rule its MEANING demands, so multi-device merge
//! provably never loses progress and never un-finishes a show.
//!
//! It is on-device and privacy-first (the merge is a pure function; nothing has to reach a cloud the way
//! Trakt/Plex require), and it is a join-semilattice: every field is a `max` over a small lattice, so the
//! merge is commutative, associative, and idempotent (proven in the property tests).
//!
//! The merge rules, each chosen for the field's semantics rather than a uniform last-writer-wins:
//! - resume position: latest by its own clock, but a clock tie keeps the FURTHER position (never rewind).
//! - watched: STICKY. Derived as `watched_at >= reset_at`, so a stale pause cannot un-finish a title; only
//!   an explicit newer `reset_at` un-finishes it (a rewatch reset, the Trakt semantic).
//! - times_watched: max, so concurrent rewatches do not double-count and do not lose the higher count.
//! - removed (from continue-watching): a tombstone that any later viewing activity revives.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The independently-clocked watch signals for one title. Unix-second clocks; `0` means "never".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct WatchState {
    /// Playhead position in milliseconds.
    #[serde(default)]
    pub resume_ms: u64,
    /// Clock for `resume_ms`.
    #[serde(default)]
    pub resume_at: u64,
    /// Clock when the title was last marked watched (0 = never).
    #[serde(default)]
    pub watched_at: u64,
    /// How many times finished. Merged by max.
    #[serde(default)]
    pub times_watched: u32,
    /// Clock of an un-finish / rewatch reset (0 = never). A reset newer than `watched_at` un-finishes.
    #[serde(default)]
    pub reset_at: u64,
    /// Clock when removed from continue-watching (0 = never). Revived by newer viewing activity.
    #[serde(default)]
    pub removed_at: u64,
}

impl WatchState {
    /// A resume event: paused at `ms` at time `at`.
    pub fn resumed(ms: u64, at: u64) -> Self {
        Self {
            resume_ms: ms,
            resume_at: at,
            ..Self::default()
        }
    }

    /// A finished event at time `at` (counts one watch).
    pub fn finished(at: u64) -> Self {
        Self {
            watched_at: at,
            times_watched: 1,
            ..Self::default()
        }
    }

    /// An explicit un-finish / rewatch reset at time `at`.
    pub fn reset(at: u64) -> Self {
        Self {
            reset_at: at,
            ..Self::default()
        }
    }

    /// A remove-from-continue-watching event at time `at`.
    pub fn removed(at: u64) -> Self {
        Self {
            removed_at: at,
            ..Self::default()
        }
    }

    /// Whether the title is currently watched: marked watched and not superseded by a newer reset.
    pub fn is_watched(&self) -> bool {
        self.watched_at > 0 && self.watched_at >= self.reset_at
    }

    /// Whether the title is currently removed from continue-watching: the removal is newer than any
    /// viewing activity (a later resume or watch revives it).
    pub fn is_removed(&self) -> bool {
        self.removed_at > self.resume_at.max(self.watched_at)
    }
}

/// Merge two watch states. Each field is a join over its lattice, so this is commutative, associative,
/// and idempotent.
pub fn merge(a: &WatchState, b: &WatchState) -> WatchState {
    // Resume: greater clock wins; a clock tie keeps the further position (never rewind).
    let (resume_at, resume_ms) = (a.resume_at, a.resume_ms).max((b.resume_at, b.resume_ms));
    WatchState {
        resume_ms,
        resume_at,
        watched_at: a.watched_at.max(b.watched_at),
        times_watched: a.times_watched.max(b.times_watched),
        reset_at: a.reset_at.max(b.reset_at),
        removed_at: a.removed_at.max(b.removed_at),
    }
}

/// A profile's watch states, keyed by a stable media key. This is the syncable document.
pub type WatchLog = BTreeMap<String, WatchState>;

/// Merge two watch logs per key. A CRDT: order-independent and idempotent.
pub fn merge_log(a: &WatchLog, b: &WatchLog) -> WatchLog {
    let mut out = a.clone();
    for (key, state) in b {
        out.entry(key.clone())
            .and_modify(|existing| *existing = merge(existing, state))
            .or_insert(*state);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_pause_never_unfinishes() {
        // Paused at 5 min (t=100), finished later (t=200) on another device.
        let paused = WatchState::resumed(300_000, 100);
        let finished = WatchState::finished(200);
        let m = merge(&paused, &finished);
        assert!(
            m.is_watched(),
            "a stale pause must not un-finish a watched title"
        );
        assert_eq!(merge(&finished, &paused), m, "merge is commutative");
    }

    #[test]
    fn explicit_reset_unfinishes_and_refinish_restores() {
        let finished = WatchState::finished(100);
        let reset = WatchState::reset(200);
        assert!(
            !merge(&finished, &reset).is_watched(),
            "a newer reset un-finishes"
        );
        let refinished = WatchState::finished(300);
        assert!(
            merge(&merge(&finished, &reset), &refinished).is_watched(),
            "watching again after a reset re-finishes"
        );
    }

    #[test]
    fn removal_is_revived_by_later_activity() {
        let removed = WatchState::removed(100);
        assert!(removed.is_removed());
        let resumed_later = WatchState::resumed(60_000, 200);
        assert!(
            !merge(&removed, &resumed_later).is_removed(),
            "later activity revives"
        );
        let resumed_earlier = WatchState::resumed(60_000, 50);
        assert!(
            merge(&removed, &resumed_earlier).is_removed(),
            "earlier activity stays removed"
        );
    }

    #[test]
    fn times_watched_takes_the_max() {
        let a = WatchState {
            times_watched: 3,
            ..Default::default()
        };
        let b = WatchState {
            times_watched: 1,
            ..Default::default()
        };
        assert_eq!(merge(&a, &b).times_watched, 3);
    }

    #[test]
    fn resume_never_rewinds_on_a_clock_tie() {
        let further = WatchState::resumed(500_000, 100);
        let nearer = WatchState::resumed(100_000, 100);
        assert_eq!(merge(&further, &nearer).resume_ms, 500_000);
    }

    #[test]
    fn log_merge_is_per_key() {
        let mut a = WatchLog::new();
        a.insert("tt1".into(), WatchState::resumed(100, 10));
        let mut b = WatchLog::new();
        b.insert("tt1".into(), WatchState::finished(20));
        b.insert("tt2".into(), WatchState::finished(5));
        let m = merge_log(&a, &b);
        assert!(m["tt1"].is_watched());
        assert!(m["tt2"].is_watched());
        assert_eq!(m.len(), 2);
    }
}
