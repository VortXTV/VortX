//! The wire contract the platform bridges speak: a JSON [`Action`] in, a JSON [`DispatchResult`] (with
//! [`EngineEvent`]s) out. These tagged shapes are the FFI seam; their field names are the cross-language
//! contract, pinned by conformance vectors.

use serde::{Deserialize, Serialize};
use vortx_ranking::RankingPrefs;
use vortx_state::WatchLog;

/// An action the host dispatches into the engine. Tagged by `type` (snake_case).
///
/// Not `Eq`: [`Action::SetRankingPrefs`] carries [`RankingPrefs`], whose `max_filesize_gb: Option<f64>`
/// is not `Eq`. `PartialEq` is enough for the round-trip conformance checks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Action {
    /// Re-point the active profile to an existing, live profile (instant, no re-auth).
    SwitchProfile { id: String },
    /// Add (or revive) a viewer profile in the roster.
    AddProfile { id: String, name: String },
    /// Tombstone-delete a profile (never the owner or the last live profile).
    DeleteProfile { id: String },
    /// Set a profile's parental controls: the kids flag and an optional maturity ceiling (age). Bumps the
    /// profile's LWW edit clock so the change wins on multi-device merge.
    SetParental {
        id: String,
        #[serde(default)]
        kids: bool,
        #[serde(
            default,
            rename = "maturityCeiling",
            skip_serializing_if = "Option::is_none"
        )]
        maturity_ceiling: Option<u8>,
    },
    /// Set a profile's stream-ranking preferences (used as the default when a stream resolve omits prefs).
    /// Bumps the profile's LWW edit clock.
    SetRankingPrefs { id: String, prefs: RankingPrefs },
    /// Report playback progress for an item ADDRESSED BY IDENTITY (meta/video), never by a stream object.
    /// The engine writes the resume point and updates Continue Watching per its own rules, so URL
    /// transformations (proxy / DV path / debrid reconstruct) are irrelevant to progress tracking.
    ReportProgress {
        #[serde(rename = "metaId")]
        meta_id: String,
        #[serde(default, rename = "videoId", skip_serializing_if = "Option::is_none")]
        video_id: Option<String>,
        #[serde(default)]
        name: String,
        #[serde(rename = "positionMs")]
        position_ms: u64,
        #[serde(rename = "durationMs")]
        duration_ms: u64,
    },
    /// Mark an item (and optional episode) watched; removes it from Continue Watching.
    MarkWatched {
        #[serde(rename = "metaId")]
        meta_id: String,
        #[serde(default, rename = "videoId", skip_serializing_if = "Option::is_none")]
        video_id: Option<String>,
    },
    /// Remove an item from Continue Watching (the user dismissed it); the resume point is kept.
    RemoveFromContinueWatching {
        #[serde(rename = "metaId")]
        meta_id: String,
    },
    /// Merge an incoming per-profile watch document (the field-level watch-state CRDT) from another device
    /// into the named profile's library. Convergent: repeated or out-of-order merges settle identically.
    MergeWatchState {
        #[serde(rename = "profileId")]
        profile_id: String,
        log: WatchLog,
    },
    /// No state change; a way for the host to request a fresh state snapshot.
    GetState,
}

/// A thing that happened as a result of an action. Tagged by `event` (snake_case).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum EngineEvent {
    ProfileSwitched { id: String },
    ProfileAdded { id: String },
    ProfileDeleted { id: String },
    ParentalSet { id: String },
    RankingPrefsSet { id: String },
    ProgressReported { id: String },
    Watched { id: String },
    RemovedFromCw { id: String },
    WatchStateMerged { id: String },
}

/// The result of a dispatch: success/failure, an optional error message, and the events produced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DispatchResult {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default)]
    pub events: Vec<EngineEvent>,
}

impl DispatchResult {
    pub(crate) fn ok(events: Vec<EngineEvent>) -> Self {
        Self {
            ok: true,
            error: None,
            events,
        }
    }

    pub(crate) fn err(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            error: Some(message.into()),
            events: Vec::new(),
        }
    }
}
