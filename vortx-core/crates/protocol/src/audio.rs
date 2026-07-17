//! AU1: the audio metadata model (music tracks/albums/artists, audiobooks, podcasts).
//!
//! Audio is a content CLASS ([`crate::ContentClass::Audio`]) added to the engine by GENERALIZING, not
//! siloing: a track reuses the same [`Chapter`] type as a video unit (so audiobook/podcast chapter resume
//! rides the shared SH5 timeline), and every field is `skip_serializing_if`-default so introducing this model
//! leaves all existing wire vectors byte-identical (a plain track serializes to just its `id` + `title`).
//!
//! Pure schema: no float on any identity or ordering path (durations and track/disc numbers are integers), so
//! the canonical multi-disc ordering key and the codec classification are byte-reproducible on every target.

use serde::{Deserialize, Serialize};

use crate::resource::Chapter;

/// An audio codec. Snake_case on the wire; [`AudioCodec::from_wire`] is tolerant of common container/alias
/// spellings; [`AudioCodec::is_lossless`] lets later audio ranking prefer lossless without re-parsing strings.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize,
)]
#[serde(rename_all = "snake_case")]
pub enum AudioCodec {
    Flac,
    Alac,
    Wav,
    Aiff,
    Dsd,
    Aac,
    Mp3,
    Opus,
    Vorbis,
    Ogg,
    /// Unrecognized or unspecified. The default, and skip-serialized so a track without a known codec emits
    /// no `codec` key (no-regression).
    #[default]
    Unknown,
}

impl AudioCodec {
    /// Parse a wire/codec/container token tolerantly. An AMBIGUOUS container (`m4a`) maps to the LOSSY `Aac`
    /// on purpose: when we cannot prove lossless, default to lossy so lossless-preference ranking never
    /// falsely promotes it. Unknown tokens become [`AudioCodec::Unknown`]. Never panics.
    pub fn from_wire(s: &str) -> AudioCodec {
        match s.trim().to_ascii_lowercase().as_str() {
            "flac" => AudioCodec::Flac,
            "alac" | "apple lossless" | "apple_lossless" => AudioCodec::Alac,
            "wav" | "wave" | "pcm" | "lpcm" => AudioCodec::Wav,
            "aiff" | "aif" => AudioCodec::Aiff,
            "dsd" | "dsf" | "dff" | "dsd64" | "dsd128" => AudioCodec::Dsd,
            "aac" | "mp4a" | "m4a" => AudioCodec::Aac,
            "mp3" | "mpga" | "mpeg3" => AudioCodec::Mp3,
            "opus" => AudioCodec::Opus,
            "vorbis" => AudioCodec::Vorbis,
            "ogg" | "oga" => AudioCodec::Ogg,
            _ => AudioCodec::Unknown,
        }
    }

    /// The canonical wire token (equals the serde representation), for explicit round-trips.
    pub fn wire(self) -> &'static str {
        match self {
            AudioCodec::Flac => "flac",
            AudioCodec::Alac => "alac",
            AudioCodec::Wav => "wav",
            AudioCodec::Aiff => "aiff",
            AudioCodec::Dsd => "dsd",
            AudioCodec::Aac => "aac",
            AudioCodec::Mp3 => "mp3",
            AudioCodec::Opus => "opus",
            AudioCodec::Vorbis => "vorbis",
            AudioCodec::Ogg => "ogg",
            AudioCodec::Unknown => "unknown",
        }
    }

    /// Whether this codec is mathematically lossless (so ranking can prefer it). FLAC/ALAC/WAV/AIFF/DSD.
    pub fn is_lossless(self) -> bool {
        matches!(
            self,
            AudioCodec::Flac
                | AudioCodec::Alac
                | AudioCodec::Wav
                | AudioCodec::Aiff
                | AudioCodec::Dsd
        )
    }

    fn is_unknown(&self) -> bool {
        matches!(self, AudioCodec::Unknown)
    }
}

/// One audio track: a music song, an audiobook chapter-file, or a podcast episode. Reuses the SH5 [`Chapter`]
/// for in-track marks so resume/timeline are shared with video. Every optional is skip-default.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AudioTrack {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    #[serde(default, rename = "trackNo", skip_serializing_if = "Option::is_none")]
    pub track_no: Option<u32>,
    #[serde(default, rename = "discNo", skip_serializing_if = "Option::is_none")]
    pub disc_no: Option<u32>,
    #[serde(
        default,
        rename = "durationMs",
        skip_serializing_if = "Option::is_none"
    )]
    pub duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "AudioCodec::is_unknown")]
    pub codec: AudioCodec,
    /// In-track chapter / segment marks (audiobook chapters, podcast segments), reusing the SH5 [`Chapter`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub chapters: Vec<Chapter>,
}

impl AudioTrack {
    /// The canonical, deterministic ordering key for placing this track within an album: by disc, then track
    /// number, then title. Integer-only (float-free). A missing disc is treated as disc 1 (the common
    /// single-disc case); a missing track number sorts AFTER numbered tracks (so numbered tracks lead and
    /// loose tracks trail); title is the final stable tiebreak. Total order, byte-reproducible.
    pub fn order_key(&self) -> (i64, i64, &str) {
        (
            self.disc_no.map(i64::from).unwrap_or(1),
            self.track_no.map(i64::from).unwrap_or(i64::MAX),
            self.title.as_str(),
        )
    }
}

/// An audio album / audiobook / podcast feed: the ordered list of its track ids plus shared metadata.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AudioAlbum {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub year: Option<u32>,
    /// Track ids in playback order. Empty (and absent on the wire) when not yet populated.
    #[serde(default, rename = "trackIds", skip_serializing_if = "Vec::is_empty")]
    pub track_ids: Vec<String>,
}

/// An artist / author / podcast publisher.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Artist {
    pub id: String,
    pub name: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_track_serializes_to_just_id_and_title() {
        let t = AudioTrack {
            id: "t1".into(),
            title: "Song".into(),
            ..Default::default()
        };
        let v = serde_json::to_value(&t).unwrap();
        assert_eq!(v, serde_json::json!({ "id": "t1", "title": "Song" }));
    }

    #[test]
    fn from_wire_handles_aliases_and_unknown() {
        assert_eq!(AudioCodec::from_wire("FLAC"), AudioCodec::Flac);
        assert_eq!(AudioCodec::from_wire("apple lossless"), AudioCodec::Alac);
        assert_eq!(AudioCodec::from_wire("m4a"), AudioCodec::Aac); // ambiguous container -> lossy
        assert_eq!(AudioCodec::from_wire("pcm"), AudioCodec::Wav);
        assert_eq!(AudioCodec::from_wire("weirdcodec"), AudioCodec::Unknown);
    }

    #[test]
    fn lossless_classification_is_correct() {
        for c in [
            AudioCodec::Flac,
            AudioCodec::Alac,
            AudioCodec::Wav,
            AudioCodec::Aiff,
            AudioCodec::Dsd,
        ] {
            assert!(c.is_lossless(), "{c:?} should be lossless");
        }
        for c in [
            AudioCodec::Aac,
            AudioCodec::Mp3,
            AudioCodec::Opus,
            AudioCodec::Vorbis,
            AudioCodec::Ogg,
            AudioCodec::Unknown,
        ] {
            assert!(!c.is_lossless(), "{c:?} should be lossy");
        }
    }

    #[test]
    fn wire_token_matches_serde_and_round_trips() {
        for c in [
            AudioCodec::Flac,
            AudioCodec::Alac,
            AudioCodec::Wav,
            AudioCodec::Aiff,
            AudioCodec::Dsd,
            AudioCodec::Aac,
            AudioCodec::Mp3,
            AudioCodec::Opus,
            AudioCodec::Vorbis,
            AudioCodec::Ogg,
            AudioCodec::Unknown,
        ] {
            let json = serde_json::to_value(c).unwrap();
            assert_eq!(json, serde_json::Value::String(c.wire().to_string()));
            assert_eq!(AudioCodec::from_wire(c.wire()), c); // round-trips through the canonical token
        }
    }

    #[test]
    fn multi_disc_ordering_is_disc_then_track_then_title() {
        let mut tracks = [
            AudioTrack {
                id: "d2t1".into(),
                title: "B".into(),
                disc_no: Some(2),
                track_no: Some(1),
                ..Default::default()
            },
            AudioTrack {
                id: "d1t2".into(),
                title: "A".into(),
                disc_no: Some(1),
                track_no: Some(2),
                ..Default::default()
            },
            AudioTrack {
                id: "d1t1".into(),
                title: "Z".into(),
                disc_no: Some(1),
                track_no: Some(1),
                ..Default::default()
            },
            AudioTrack {
                id: "loose".into(),
                title: "loose".into(),
                disc_no: Some(1),
                ..Default::default()
            }, // no track_no -> trails disc 1
        ];
        tracks.sort_by(|a, b| a.order_key().cmp(&b.order_key()));
        let ids: Vec<&str> = tracks.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, vec!["d1t1", "d1t2", "loose", "d2t1"]);
    }

    #[test]
    fn missing_disc_is_treated_as_disc_one() {
        let with = AudioTrack {
            id: "a".into(),
            title: "x".into(),
            disc_no: Some(1),
            track_no: Some(5),
            ..Default::default()
        };
        let without = AudioTrack {
            id: "b".into(),
            title: "x".into(),
            track_no: Some(5),
            ..Default::default()
        };
        assert_eq!(with.order_key().0, without.order_key().0); // both disc 1
    }

    #[test]
    fn a_track_with_chapters_and_codec_round_trips() {
        let t = AudioTrack {
            id: "ab1".into(),
            title: "Chapter 1".into(),
            artist: Some("Author".into()),
            album: Some("The Book".into()),
            track_no: Some(1),
            duration_ms: Some(3_600_000),
            codec: AudioCodec::Flac,
            chapters: vec![Chapter {
                start_ms: 0,
                end_ms: Some(60_000),
                title: Some("Intro".into()),
            }],
            ..Default::default()
        };
        let json = serde_json::to_string(&t).unwrap();
        let back: AudioTrack = serde_json::from_str(&json).unwrap();
        assert_eq!(
            serde_json::to_value(&back).unwrap(),
            serde_json::to_value(&t).unwrap()
        );
        assert!(json.contains("\"codec\":\"flac\""));
        assert!(json.contains("\"startMs\":0"));
    }
}
