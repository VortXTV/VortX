//! The subtitle data model: a track, its provenance, and the user's selection preferences. Pure data;
//! serde wire shapes are the cross-language contract.

use serde::{Deserialize, Serialize};

/// A subtitle container format. Text formats can be restyled; image formats (PGS/VobSub) cannot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubtitleFormat {
    Srt,
    Vtt,
    Ass,
    Ssa,
    Pgs,
    Vobsub,
    Unknown,
}

/// Where a track came from, most trusted/instant first. Used as a tiebreak.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SubtitleSourceTier {
    /// Muxed into the container (instant, authored).
    Embedded,
    /// Supplied by a first-party addon/provider.
    Provider,
    /// OpenSubtitles and similar curated databases.
    OpenSubtitles,
    /// Community uploads (less curated).
    Community,
    /// Machine-generated (whisper transcription).
    Generated,
}

impl SubtitleSourceTier {
    /// Preference rank, lower is better.
    pub fn rank(self) -> u8 {
        match self {
            SubtitleSourceTier::Embedded => 0,
            SubtitleSourceTier::Provider => 1,
            SubtitleSourceTier::OpenSubtitles => 2,
            SubtitleSourceTier::Community => 3,
            SubtitleSourceTier::Generated => 4,
        }
    }
}

/// One available subtitle track.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubtitleTrack {
    pub id: String,
    /// BCP-47-ish language tag (`en`, `en-US`, `pt-BR`). Matched on the primary subtag.
    pub lang: String,
    /// Forced tracks caption only foreign-language passages, not full dialogue.
    #[serde(default)]
    pub forced: bool,
    #[serde(default, rename = "hearingImpaired")]
    pub hearing_impaired: bool,
    pub format: SubtitleFormat,
    pub tier: SubtitleSourceTier,
    /// Community rating proxy (e.g. download count bucket), 0..=1000. Higher is better.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rating: Option<u16>,
}

/// The profile's subtitle preferences.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct SubtitlePrefs {
    /// Preferred languages in priority order (`["en", "es"]`). Empty means any language is acceptable.
    #[serde(default)]
    pub languages: Vec<String>,
    /// Prefer a forced track (e.g. for a mostly-native-language film with foreign passages).
    #[serde(default, rename = "wantForced")]
    pub want_forced: bool,
    #[serde(default, rename = "wantHearingImpaired")]
    pub want_hearing_impaired: bool,
    /// Preferred formats in priority order. Empty means no format preference.
    #[serde(default, rename = "formatPriority")]
    pub format_priority: Vec<SubtitleFormat>,
}

/// The primary language subtag, lowercased (`en-US` -> `en`).
pub(crate) fn primary_subtag(lang: &str) -> String {
    lang.split(['-', '_'])
        .next()
        .unwrap_or(lang)
        .to_ascii_lowercase()
}
