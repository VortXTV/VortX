//! Per-profile library buckets, and the structural fence that keeps VortX-only data out of the Stremio
//! account library.
//!
//! An early build corrupted account-wide library sync in every official Stremio client by smuggling app
//! data through a `libraryItem`. Here that is impossible BY CONSTRUCTION: only [`LibraryItem::Standard`]
//! items project to the account-mirror shape ([`StremioLibraryItem`]), which has no field for
//! VortX-specific data; [`LibraryItem::NativeMagnet`] and [`LibraryItem::TorrentPlaylist`] (the native
//! magnet / #81 cases) are structurally excluded from the projection.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use vortx_protocol::ContentKind;

use crate::finish::{finished, FinishPolicy};
use crate::watch::{merge, merge_log, WatchLog, WatchState};

/// One entry in a profile's library. `Standard` items mirror to the Stremio account; `NativeMagnet` and
/// `TorrentPlaylist` are VortX-only and never touch the account library.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LibraryItem {
    /// A standard catalog title (movie/series/...). The only kind that mirrors to the account library.
    Standard {
        id: String,
        name: String,
        #[serde(rename = "type")]
        type_: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        poster: Option<String>,
    },
    /// A native magnet saved directly to the library (VortX-only; the #81 wrong-meta fix lives here).
    NativeMagnet {
        id: String,
        name: String,
        infohash: String,
        #[serde(default, rename = "fileIdx", skip_serializing_if = "Option::is_none")]
        file_idx: Option<u32>,
        #[serde(default)]
        trackers: Vec<String>,
    },
    /// A user-built playlist of torrent/source entries (VortX-only).
    TorrentPlaylist {
        id: String,
        name: String,
        #[serde(default)]
        entries: Vec<String>,
    },
}

impl LibraryItem {
    /// The item's stable id, regardless of kind.
    pub fn id(&self) -> &str {
        match self {
            LibraryItem::Standard { id, .. } => id,
            LibraryItem::NativeMagnet { id, .. } => id,
            LibraryItem::TorrentPlaylist { id, .. } => id,
        }
    }

    /// The item's display name, regardless of kind.
    pub fn name(&self) -> &str {
        match self {
            LibraryItem::Standard { name, .. } => name,
            LibraryItem::NativeMagnet { name, .. } => name,
            LibraryItem::TorrentPlaylist { name, .. } => name,
        }
    }
}

/// A watch-history entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: String,
    #[serde(default, rename = "videoId", skip_serializing_if = "Option::is_none")]
    pub video_id: Option<String>,
    #[serde(rename = "watchedAt")]
    pub watched_at: u64,
}

/// A Continue Watching rail entry (emitted by the engine for the active profile).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CwItem {
    pub id: String,
    pub name: String,
    /// Playback progress in permille (0..=1000). An integer (not a float) so per-profile sync is
    /// byte-identical across Rust/TS/Swift.
    #[serde(default)]
    pub progress: u32,
}

/// A resume point for a video (offset within its duration).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResumePoint {
    #[serde(rename = "offsetSecs")]
    pub offset_secs: u64,
    #[serde(rename = "durationSecs")]
    pub duration_secs: u64,
    #[serde(rename = "updatedAt")]
    pub updated_at: u64,
}

/// The set of watched video ids for a meta (VortX's own per-profile watched schema).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WatchedBitfield {
    #[serde(default, rename = "videoIds")]
    pub video_ids: Vec<String>,
}

/// A single profile's library bucket. Every profile owns its own, unlike stremio-core's single
/// account-wide `LibraryBucket`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ProfileLibrary {
    #[serde(default)]
    pub items: Vec<LibraryItem>,
    #[serde(default)]
    pub history: Vec<HistoryEntry>,
    #[serde(default, rename = "continueWatching")]
    pub continue_watching: Vec<CwItem>,
    #[serde(default)]
    pub resume: BTreeMap<String, ResumePoint>,
    #[serde(default)]
    pub watched: BTreeMap<String, WatchedBitfield>,
    #[serde(default, rename = "searchHistory")]
    pub search_history: Vec<String>,
    /// The field-level watch-state CRDT for this profile: the cross-device SYNC truth, keyed by the played
    /// unit (episode video id, else meta id). Each entry's signals are independently clocked, so a
    /// multi-device merge resolves each by its own meaning (never rewind a resume, never un-finish a watched
    /// title). The `resume` / `continue_watching` / `watched` fields above are the LOCAL read projections the
    /// app renders; THIS is the document that syncs and merges.
    #[serde(
        default,
        rename = "watchLog",
        skip_serializing_if = "BTreeMap::is_empty"
    )]
    pub watch_log: WatchLog,
}

/// Playback at or past this permille of the runtime counts as FINISHED (cleared from resume + Continue
/// Watching, recorded watched). The engine owns this threshold so every platform agrees.
pub const FINISHED_PERMILLE: u32 = 900;
/// The Continue Watching rail is capped at this many entries, newest first. The engine owns the cap so the
/// app renders the list verbatim instead of re-deriving it.
pub const CW_CAP: usize = 30;

impl ProfileLibrary {
    /// Record playback progress for a VIDEO item (the byte-identical default: the frozen video finish
    /// policy). Audiobooks/podcasts call [`report_progress_kind`](Self::report_progress_kind) so their
    /// tail-aware finish applies.
    pub fn report_progress(
        &mut self,
        meta_id: &str,
        video_id: Option<&str>,
        position_ms: u64,
        duration_ms: u64,
        name: &str,
        now: u64,
    ) {
        self.report_progress_kind(
            ContentKind::Movie,
            meta_id,
            video_id,
            position_ms,
            duration_ms,
            name,
            now,
        );
    }

    /// Record playback progress for an item ADDRESSED BY IDENTITY (`meta_id`, optional `video_id`), never
    /// by a stream object, under the finish policy for `content_kind`. The engine owns the Continue-Watching
    /// rules: an in-progress item is upserted to the FRONT of the rail (newest first, capped at [`CW_CAP`])
    /// with its resume point; once it FINISHES (per [`FinishPolicy::for_kind`]: the frozen `permille >= 900`
    /// for video, tail-aware for audio) it is marked watched and removed from the rail. `now` is supplied by
    /// the host (the kernel has no clock).
    #[allow(clippy::too_many_arguments)]
    pub fn report_progress_kind(
        &mut self,
        content_kind: ContentKind,
        meta_id: &str,
        video_id: Option<&str>,
        position_ms: u64,
        duration_ms: u64,
        name: &str,
        now: u64,
    ) {
        let permille = position_ms
            .saturating_mul(1000)
            .checked_div(duration_ms)
            .map(|p| p.min(1000) as u32)
            .unwrap_or(0);
        // The resume point is keyed by the most specific unit (the episode if present, else the title), so
        // each episode keeps its own position.
        let resume_key = video_id.unwrap_or(meta_id).to_string();
        // The finish decision routes through the pure tail-aware policy for this content kind. For video
        // (the default) the policy is VIDEO (tail_grace 0), which reduces EXACTLY to `permille >= 900`, so a
        // video report is byte-identical to the prior check; an audiobook/podcast gets the tail-aware AUDIO
        // policy and finishes in the outro.
        if finished(position_ms, duration_ms, &FinishPolicy::for_kind(content_kind)) {
            self.resume.remove(&resume_key);
            self.mark_watched(meta_id, video_id, now);
        } else {
            // Record the in-progress signal in the sync document (independently clocked) before the local
            // projection, so a multi-device merge can resolve resume position correctly.
            self.bump_watch(&resume_key, WatchState::resumed(position_ms, now));
            self.resume.insert(
                resume_key,
                ResumePoint {
                    offset_secs: position_ms / 1000,
                    duration_secs: duration_ms / 1000,
                    updated_at: now,
                },
            );
            // Move the title to the front of Continue Watching with its latest progress.
            self.continue_watching.retain(|c| c.id != meta_id);
            self.continue_watching.insert(
                0,
                CwItem {
                    id: meta_id.to_string(),
                    name: name.to_string(),
                    progress: permille,
                },
            );
            self.continue_watching.truncate(CW_CAP);
        }
    }

    /// Mark an item (and optional episode) watched: record the watched video id, drop it from Continue
    /// Watching, append a fresh history entry (replacing any prior one for the same item), and record the
    /// finished signal in the sync document.
    pub fn mark_watched(&mut self, meta_id: &str, video_id: Option<&str>, now: u64) {
        if let Some(vid) = video_id {
            let wb = self.watched.entry(meta_id.to_string()).or_default();
            if !wb.video_ids.iter().any(|v| v == vid) {
                wb.video_ids.push(vid.to_string());
            }
        }
        self.continue_watching.retain(|c| c.id != meta_id);
        self.history
            .retain(|h| !(h.id == meta_id && h.video_id.as_deref() == video_id));
        self.history.push(HistoryEntry {
            id: meta_id.to_string(),
            video_id: video_id.map(str::to_string),
            watched_at: now,
        });
        self.bump_watch(video_id.unwrap_or(meta_id), WatchState::finished(now));
    }

    /// Remove an item from Continue Watching (the user dismissed it). Leaves the resume point intact and
    /// records a tombstone in the sync document so the dismissal propagates across devices (a later resume or
    /// watch revives it).
    pub fn remove_from_continue_watching(&mut self, meta_id: &str, now: u64) {
        self.continue_watching.retain(|c| c.id != meta_id);
        self.bump_watch(meta_id, WatchState::removed(now));
    }

    /// Join a delta into the canonical, independently-clocked watch document for one unit. The host supplies
    /// `now` (the kernel has no clock).
    fn bump_watch(&mut self, key: &str, delta: WatchState) {
        let entry = self.watch_log.entry(key.to_string()).or_default();
        *entry = merge(entry, &delta);
    }

    /// Merge an incoming per-profile watch document (e.g. from another device) into this one, then re-project
    /// the converged result onto the local Continue-Watching rail. A pure CRDT join (commutative /
    /// associative / idempotent), so repeated or out-of-order syncs converge. A unit finished or dismissed on
    /// another device drops out of this device's Continue Watching; a further-along resume elsewhere never
    /// rewinds this device's position.
    pub fn merge_watch_log(&mut self, incoming: &WatchLog) {
        self.watch_log = merge_log(&self.watch_log, incoming);
        let log = &self.watch_log;
        self.continue_watching.retain(|cw| {
            log.get(&cw.id)
                .map(|st| !st.is_watched() && !st.is_removed())
                .unwrap_or(true)
        });
    }
}

/// The account-library shape that mirrors to api.strem.io: ONLY the fields official Stremio clients
/// parse. There is intentionally no field for VortX-specific data, so a projection can never leak it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StremioLibraryItem {
    #[serde(rename = "_id")]
    pub id: String,
    pub name: String,
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
}

impl ProfileLibrary {
    /// Project to the account-library items that may be synced to api.strem.io. ONLY `Standard` items are
    /// included; `NativeMagnet`/`TorrentPlaylist` are structurally excluded, so per-profile / native data
    /// can NEVER corrupt the account library that official Stremio clients also read.
    pub fn account_library_items(&self) -> Vec<StremioLibraryItem> {
        self.items
            .iter()
            .filter_map(|item| match item {
                LibraryItem::Standard {
                    id,
                    name,
                    type_,
                    poster,
                } => Some(StremioLibraryItem {
                    id: id.clone(),
                    name: name.clone(),
                    type_: type_.clone(),
                    poster: poster.clone(),
                }),
                LibraryItem::NativeMagnet { .. } | LibraryItem::TorrentPlaylist { .. } => None,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{WatchLog, WatchState};

    #[test]
    fn progress_upserts_continue_watching_newest_first() {
        let mut lib = ProfileLibrary::default();
        lib.report_progress("a", None, 300_000, 600_000, "A", 100); // 50%
        lib.report_progress("b", None, 60_000, 600_000, "B", 200); // 10%, newer
        assert_eq!(
            lib.continue_watching
                .iter()
                .map(|c| c.id.as_str())
                .collect::<Vec<_>>(),
            vec!["b", "a"]
        );
        assert_eq!(lib.continue_watching[1].progress, 500); // 50% permille
        assert_eq!(lib.resume["a"].offset_secs, 300);
    }

    #[test]
    fn re_reporting_moves_to_front_without_duplicating() {
        let mut lib = ProfileLibrary::default();
        lib.report_progress("a", None, 60_000, 600_000, "A", 100);
        lib.report_progress("b", None, 60_000, 600_000, "B", 200);
        lib.report_progress("a", None, 120_000, 600_000, "A", 300); // bump a
        let ids: Vec<&str> = lib
            .continue_watching
            .iter()
            .map(|c| c.id.as_str())
            .collect();
        assert_eq!(ids, vec!["a", "b"]); // a moved to front, no dupe
        assert_eq!(lib.continue_watching.len(), 2);
    }

    #[test]
    fn finishing_marks_watched_and_drops_from_cw() {
        let mut lib = ProfileLibrary::default();
        lib.report_progress("s", Some("s:1:1"), 60_000, 600_000, "S", 100); // in progress
        assert_eq!(lib.continue_watching.len(), 1);
        lib.report_progress("s", Some("s:1:1"), 595_000, 600_000, "S", 200); // 99% -> finished
        assert!(lib.continue_watching.is_empty());
        assert!(lib.watched["s"].video_ids.contains(&"s:1:1".to_string()));
        assert!(!lib.resume.contains_key("s:1:1")); // resume cleared on finish
        assert_eq!(lib.history.last().unwrap().id, "s");
    }

    #[test]
    fn audiobook_finishes_in_the_tail_grace_where_a_movie_would_not() {
        // A 40-min unit stopped at 35:00 (87.5%, below 90%). As an audiobook it is FINISHED (within the
        // 5-minute tail grace); as a movie it stays in Continue Watching (the frozen video policy).
        let mut audio = ProfileLibrary::default();
        audio.report_progress_kind(ContentKind::Audiobook, "ab", None, 2_100_000, 2_400_000, "AB", 100);
        assert!(audio.continue_watching.is_empty(), "audiobook finished via tail grace");
        assert_eq!(audio.history.last().unwrap().id, "ab"); // finish recorded in history
        assert!(!audio.resume.contains_key("ab")); // resume cleared on finish

        let mut movie = ProfileLibrary::default();
        movie.report_progress_kind(ContentKind::Movie, "mv", None, 2_100_000, 2_400_000, "MV", 100);
        assert_eq!(movie.continue_watching.len(), 1, "movie at 87.5% stays in CW (frozen video policy)");
        assert!(movie.history.is_empty()); // not finished -> no history entry
        // The plain report_progress wrapper is the video policy, byte-identical to report_progress_kind(Movie).
        let mut wrapped = ProfileLibrary::default();
        wrapped.report_progress("mv", None, 2_100_000, 2_400_000, "MV", 100);
        assert_eq!(wrapped.continue_watching.len(), 1);
    }

    #[test]
    fn cw_is_capped_at_cw_cap_keeping_newest() {
        let mut lib = ProfileLibrary::default();
        for i in 0..(CW_CAP + 5) {
            lib.report_progress(&format!("m{i}"), None, 60_000, 600_000, "M", i as u64);
        }
        assert_eq!(lib.continue_watching.len(), CW_CAP);
        assert_eq!(lib.continue_watching[0].id, format!("m{}", CW_CAP + 4)); // newest at front
    }

    #[test]
    fn dismiss_removes_from_cw_but_keeps_resume() {
        let mut lib = ProfileLibrary::default();
        lib.report_progress("a", None, 60_000, 600_000, "A", 100);
        lib.remove_from_continue_watching("a", 200);
        assert!(lib.continue_watching.is_empty());
        assert!(lib.resume.contains_key("a"));
        // The dismissal is recorded as a tombstone in the sync document so it propagates across devices.
        assert!(lib.watch_log["a"].is_removed());
    }

    #[test]
    fn progress_keeps_the_sync_document_in_lockstep() {
        let mut lib = ProfileLibrary::default();
        lib.report_progress("a", None, 60_000, 600_000, "A", 100); // in progress
        assert_eq!(lib.watch_log["a"].resume_ms, 60_000);
        assert!(!lib.watch_log["a"].is_watched());
        lib.report_progress("a", None, 595_000, 600_000, "A", 200); // 99% -> finished
        assert!(
            lib.watch_log["a"].is_watched(),
            "finishing records a watch in the sync document"
        );
    }

    #[test]
    fn merge_drops_a_remotely_finished_title_from_continue_watching() {
        let mut local = ProfileLibrary::default();
        local.report_progress("m", None, 60_000, 600_000, "M", 100); // locally in CW
        assert_eq!(local.continue_watching.len(), 1);

        // Another device finished "m".
        let mut remote = WatchLog::new();
        remote.insert("m".into(), WatchState::finished(200));
        local.merge_watch_log(&remote);

        assert!(
            local.continue_watching.is_empty(),
            "a remotely finished title leaves CW"
        );
        assert!(local.watch_log["m"].is_watched());
    }

    #[test]
    fn merging_own_state_is_a_no_op() {
        let mut local = ProfileLibrary::default();
        local.report_progress("m", None, 60_000, 600_000, "M", 100);
        let before = local.clone();
        let snapshot = local.watch_log.clone();
        local.merge_watch_log(&snapshot); // idempotent at the library level
        assert_eq!(
            local, before,
            "merging an identical document changes nothing"
        );
    }

    fn mixed_library() -> ProfileLibrary {
        ProfileLibrary {
            items: vec![
                LibraryItem::Standard {
                    id: "tt1".into(),
                    name: "A Movie".into(),
                    type_: "movie".into(),
                    poster: Some("https://p/x.jpg".into()),
                },
                LibraryItem::NativeMagnet {
                    id: "mag1".into(),
                    name: "A Magnet".into(),
                    infohash: "aabbcc".into(),
                    file_idx: Some(0),
                    trackers: vec!["udp://t".into()],
                },
                LibraryItem::TorrentPlaylist {
                    id: "pl1".into(),
                    name: "A Playlist".into(),
                    entries: vec!["e1".into()],
                },
            ],
            ..Default::default()
        }
    }

    #[test]
    fn account_mirror_excludes_native_magnet_and_playlist() {
        // THE FENCE: only Standard items reach the account library.
        let mirror = mixed_library().account_library_items();
        assert_eq!(mirror.len(), 1);
        assert_eq!(mirror[0].id, "tt1");
    }

    #[test]
    fn account_item_serializes_only_stremio_standard_keys() {
        let mirror = mixed_library().account_library_items();
        let json = serde_json::to_string(&mirror[0]).unwrap();
        // No VortX-specific or per-profile keys can ride into the account library.
        for forbidden in [
            "infohash", "fileIdx", "trackers", "entries", "kind", "vortx", "profile",
        ] {
            assert!(
                !json.contains(forbidden),
                "account item leaked key: {forbidden}"
            );
        }
        assert!(json.contains("\"_id\""));
        assert!(json.contains("\"type\""));
    }

    #[test]
    fn library_item_accessors_work_across_kinds() {
        let lib = mixed_library();
        assert_eq!(lib.items[0].id(), "tt1");
        assert_eq!(lib.items[1].name(), "A Magnet");
        assert_eq!(lib.items[2].id(), "pl1");
    }

    #[test]
    fn library_serde_round_trip() {
        let lib = mixed_library();
        let json = serde_json::to_string(&lib).unwrap();
        let back: ProfileLibrary = serde_json::from_str(&json).unwrap();
        assert_eq!(lib, back);
    }
}
