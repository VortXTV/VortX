//! The typed content-class axis. Live TV and music/audiobooks/podcasts are added to the engine by
//! GENERALIZING the video pipeline rather than bolting on silos: one [`ContentKind`] axis that the wire
//! `type` string maps into, plus per-kind ranking / parse / finish profiles selected on it. The string stays
//! on the wire for Stremio byte-compatibility; the kernel branches on the typed view.
//!
//! The default is video: `Movie`/`Series` (and anything unrecognized) map to [`ContentClass::Video`], whose
//! ranking/parse/finish tables are frozen byte-identical, so every existing conformance vector (which carries
//! `type` `movie`/`series`) parses and ranks exactly as before. Live and audio only diverge when a request
//! explicitly carries a live/audio type.

use serde::{Deserialize, Serialize};

/// The typed content class a `type` string resolves to. `Ord` so it can key per-kind profile tables
/// deterministically. Snake_case on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContentKind {
    Movie,
    Series,
    Channel,
    LiveEvent,
    MusicTrack,
    MusicAlbum,
    Artist,
    Audiobook,
    Podcast,
    PodcastEpisode,
    /// An unrecognized type: treated as video (the frozen default) so nothing regresses.
    Unknown,
}

/// The coarse profile family a [`ContentKind`] belongs to. Per-kind ranking / parse / finish profiles select
/// on this: `Video` reuses the frozen video tables; `Live` and `Audio` get their own. `Unknown` is `Video`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContentClass {
    Video,
    Live,
    Audio,
}

impl ContentKind {
    /// Map a wire `type` string into the typed axis. Accepts the legacy Stremio tokens (`movie`, `series`,
    /// `channel`/`tv`) plus the canonical snake_case kind names; anything else is [`ContentKind::Unknown`]
    /// (which classifies as video, the frozen default). Total: never panics.
    pub fn from_type(type_: &str) -> ContentKind {
        match type_ {
            "movie" => ContentKind::Movie,
            "series" => ContentKind::Series,
            "channel" | "tv" => ContentKind::Channel,
            "live_event" | "event" => ContentKind::LiveEvent,
            "music_track" | "music" | "track" => ContentKind::MusicTrack,
            "music_album" | "album" => ContentKind::MusicAlbum,
            "artist" => ContentKind::Artist,
            "audiobook" => ContentKind::Audiobook,
            "podcast" => ContentKind::Podcast,
            "podcast_episode" => ContentKind::PodcastEpisode,
            _ => ContentKind::Unknown,
        }
    }

    /// The coarse profile family. `Movie`/`Series`/`Unknown` are video (the frozen default); `Channel`/
    /// `LiveEvent` are live; the rest are audio.
    pub fn class(self) -> ContentClass {
        match self {
            ContentKind::Movie | ContentKind::Series | ContentKind::Unknown => ContentClass::Video,
            ContentKind::Channel | ContentKind::LiveEvent => ContentClass::Live,
            ContentKind::MusicTrack
            | ContentKind::MusicAlbum
            | ContentKind::Artist
            | ContentKind::Audiobook
            | ContentKind::Podcast
            | ContentKind::PodcastEpisode => ContentClass::Audio,
        }
    }

    /// Convenience: is this the frozen video default class?
    pub fn is_video(self) -> bool {
        self.class() == ContentClass::Video
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_legacy_stremio_types_to_video_and_live() {
        assert_eq!(ContentKind::from_type("movie"), ContentKind::Movie);
        assert_eq!(ContentKind::from_type("series"), ContentKind::Series);
        assert_eq!(ContentKind::from_type("channel"), ContentKind::Channel);
        assert_eq!(ContentKind::from_type("tv"), ContentKind::Channel);
        assert_eq!(ContentKind::Movie.class(), ContentClass::Video);
        assert_eq!(ContentKind::Series.class(), ContentClass::Video);
        assert_eq!(ContentKind::Channel.class(), ContentClass::Live);
    }

    #[test]
    fn maps_audio_types() {
        assert_eq!(ContentKind::from_type("audiobook"), ContentKind::Audiobook);
        assert_eq!(ContentKind::from_type("podcast"), ContentKind::Podcast);
        assert_eq!(ContentKind::from_type("music"), ContentKind::MusicTrack);
        assert_eq!(ContentKind::Audiobook.class(), ContentClass::Audio);
        assert_eq!(ContentKind::Podcast.class(), ContentClass::Audio);
    }

    #[test]
    fn unknown_type_is_video_so_nothing_regresses() {
        assert_eq!(ContentKind::from_type("widget"), ContentKind::Unknown);
        assert_eq!(ContentKind::from_type(""), ContentKind::Unknown);
        assert_eq!(ContentKind::Unknown.class(), ContentClass::Video);
        assert!(ContentKind::Unknown.is_video());
    }

    #[test]
    fn wire_names_are_snake_case() {
        assert_eq!(
            serde_json::to_string(&ContentKind::LiveEvent).unwrap(),
            "\"live_event\""
        );
        assert_eq!(
            serde_json::to_string(&ContentKind::PodcastEpisode).unwrap(),
            "\"podcast_episode\""
        );
        assert_eq!(
            serde_json::to_string(&ContentClass::Audio).unwrap(),
            "\"audio\""
        );
    }
}
