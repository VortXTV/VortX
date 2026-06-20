//! The playback-asset data model: the identity anchor ([`MediaKey`]), the asset kinds, and the three
//! asset payloads (trickplay sprite track, skip markers, chapters). All pure data; serde wire shapes are
//! frozen by round-trip conformance tests.

use serde::{Deserialize, Serialize};

/// Identity anchor for a title's playback assets: a meta id plus optional season/episode. The per-title
/// analogue of an infohash. It survives different filenames/sources of the same release, and it flattens
/// to the `(media_id, season, episode)` triple an [`crate::AssetFact`] signs over.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MediaKey {
    pub meta_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
}

impl MediaKey {
    pub fn movie(meta_id: impl Into<String>) -> Self {
        Self {
            meta_id: meta_id.into(),
            season: None,
            episode: None,
        }
    }

    pub fn episode(meta_id: impl Into<String>, season: u32, episode: u32) -> Self {
        Self {
            meta_id: meta_id.into(),
            season: Some(season),
            episode: Some(episode),
        }
    }
}

/// Which kind of playback asset a fact/source/payload is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssetKind {
    Trickplay,
    SkipMarkers,
    Chapters,
}

impl AssetKind {
    /// The canonical wire token used in the signing payload (frozen).
    pub fn as_wire(self) -> &'static str {
        match self {
            AssetKind::Trickplay => "trickplay",
            AssetKind::SkipMarkers => "skip_markers",
            AssetKind::Chapters => "chapters",
        }
    }
}

/// How a sprite sheet is addressed: a direct URL (addon/provider-supplied) or a content digest (fetched
/// from the hive/cache by hash).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AssetLocator {
    Url { url: String },
    Digest { digest: String },
}

/// A Jellyfin-shaped sprite-tile trickplay track. One sheet is a `cols x rows` grid of `tile_w x tile_h`
/// thumbnails, one thumbnail every `interval_ms`. Seek-to-tile math is frozen in [`crate::sprite`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrickplaySprite {
    pub interval_ms: u64,
    pub tile_w: u32,
    pub tile_h: u32,
    pub cols: u32,
    pub rows: u32,
    pub locator: AssetLocator,
}

/// The kind of skip marker. `Outro` is the end credits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipKind {
    Intro,
    Outro,
    Recap,
    Preview,
}

/// A "skip this segment" marker (intro/outro/recap/preview), in milliseconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkipMarker {
    pub kind: SkipKind,
    pub start_ms: u64,
    pub end_ms: u64,
}

/// A named chapter marker, in milliseconds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chapter {
    pub title: String,
    pub start_ms: u64,
}

/// Exactly one resolved payload per `(MediaKey, AssetKind)`, the way a stream resolves to one source.
/// Adjacently tagged (`asset` + `data`) so the sequence-bearing variants serialize cleanly.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "asset", content = "data", rename_all = "snake_case")]
pub enum PlaybackAsset {
    Trickplay(TrickplaySprite),
    SkipMarkers(Vec<SkipMarker>),
    Chapters(Vec<Chapter>),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_kind_wire_tokens_are_frozen() {
        assert_eq!(AssetKind::Trickplay.as_wire(), "trickplay");
        assert_eq!(AssetKind::SkipMarkers.as_wire(), "skip_markers");
        assert_eq!(AssetKind::Chapters.as_wire(), "chapters");
    }

    #[test]
    fn trickplay_sprite_json_roundtrips() {
        let s = TrickplaySprite {
            interval_ms: 5000,
            tile_w: 320,
            tile_h: 180,
            cols: 10,
            rows: 10,
            locator: AssetLocator::Digest {
                digest: "abc123".into(),
            },
        };
        let json = serde_json::to_string(&s).unwrap();
        let back: TrickplaySprite = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }

    #[test]
    fn skip_markers_json_roundtrips() {
        let markers = vec![
            SkipMarker {
                kind: SkipKind::Intro,
                start_ms: 0,
                end_ms: 90_000,
            },
            SkipMarker {
                kind: SkipKind::Outro,
                start_ms: 2_580_000,
                end_ms: 2_640_000,
            },
        ];
        let json = serde_json::to_string(&markers).unwrap();
        let back: Vec<SkipMarker> = serde_json::from_str(&json).unwrap();
        assert_eq!(markers, back);
    }

    #[test]
    fn playback_asset_is_tagged() {
        let asset = PlaybackAsset::Chapters(vec![Chapter {
            title: "Cold Open".into(),
            start_ms: 0,
        }]);
        let json = serde_json::to_string(&asset).unwrap();
        assert!(json.contains("\"asset\":\"chapters\""));
        let back: PlaybackAsset = serde_json::from_str(&json).unwrap();
        assert_eq!(asset, back);
    }
}
