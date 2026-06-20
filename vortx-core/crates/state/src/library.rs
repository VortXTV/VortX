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
