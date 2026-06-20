//! Eclipse music adapter. A music addon is still the Stremio shape (manifest + resource URLs), but search
//! answers with typed arrays per kind instead of one `metas[]`, and a track may embed an inline
//! `streamURL` that short-circuits the `/stream` call. We map both onto protocol streams.

use serde::{Deserialize, Serialize};
use vortx_protocol::Stream;

/// A music item (track / album / artist / playlist).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MusicItem {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    /// Some addons embed the playable URL directly on the track, short-circuiting `/stream`.
    #[serde(default, rename = "streamURL", skip_serializing_if = "Option::is_none")]
    pub stream_url: Option<String>,
}

/// An Eclipse `/search?q=` response: typed arrays per kind (not a single `metas[]`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EclipseSearchResponse {
    #[serde(default)]
    pub tracks: Vec<MusicItem>,
    #[serde(default)]
    pub albums: Vec<MusicItem>,
    #[serde(default)]
    pub artists: Vec<MusicItem>,
    #[serde(default)]
    pub playlists: Vec<MusicItem>,
}

/// An Eclipse `/stream/{id}` response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MusicStream {
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quality: Option<String>,
}

/// If a track carries an inline `streamURL`, short-circuit to a playable protocol [`Stream`] (no
/// `/stream` round-trip). Returns `None` when the track has no inline URL.
pub fn track_to_stream(track: &MusicItem) -> Option<Stream> {
    track.stream_url.as_ref().map(|url| Stream {
        url: Some(url.clone()),
        name: Some(track.name.clone()),
        ..Default::default()
    })
}

/// Map an Eclipse `/stream` response to a protocol [`Stream`].
pub fn music_stream_to_protocol(music: &MusicStream) -> Stream {
    Stream {
        url: Some(music.url.clone()),
        name: music.quality.clone().or_else(|| music.format.clone()),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_response_decodes_typed_arrays() {
        let body = r#"{
            "tracks": [ { "id": "t1", "name": "Song", "artist": "Band", "streamURL": "https://a/s.mp3" } ],
            "albums": [ { "id": "al1", "name": "Album" } ],
            "artists": [],
            "playlists": [ { "id": "p1", "name": "Mix" } ]
        }"#;
        let r: EclipseSearchResponse = serde_json::from_str(body).unwrap();
        assert_eq!(r.tracks.len(), 1);
        assert_eq!(r.albums.len(), 1);
        assert!(r.artists.is_empty());
        assert_eq!(r.playlists.len(), 1);
        assert_eq!(r.tracks[0].artist.as_deref(), Some("Band"));
    }

    #[test]
    fn inline_stream_url_short_circuits() {
        let track = MusicItem {
            id: "t1".into(),
            name: "Song".into(),
            artist: Some("Band".into()),
            poster: None,
            stream_url: Some("https://a/s.mp3".into()),
        };
        let s = track_to_stream(&track).expect("short-circuits");
        assert_eq!(s.url.as_deref(), Some("https://a/s.mp3"));
        assert_eq!(s.name.as_deref(), Some("Song"));
    }

    #[test]
    fn track_without_inline_url_needs_stream_call() {
        let track = MusicItem {
            id: "t1".into(),
            name: "Song".into(),
            artist: None,
            poster: None,
            stream_url: None,
        };
        assert!(track_to_stream(&track).is_none());
    }

    #[test]
    fn music_stream_maps_to_protocol() {
        let music = MusicStream {
            url: "https://a/hq.flac".into(),
            format: Some("flac".into()),
            quality: Some("lossless".into()),
        };
        let s = music_stream_to_protocol(&music);
        assert_eq!(s.url.as_deref(), Some("https://a/hq.flac"));
        assert_eq!(s.name.as_deref(), Some("lossless"));
    }
}
