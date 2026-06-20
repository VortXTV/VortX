//! Deterministic, explainable subtitle auto-selection. Picking the right track is a ranked-preference
//! problem: preferred-language rank, then forced / hearing-impaired intent, then format preference, then
//! source trust, then community rating, with the track id as the final tiebreak. That is one `Ord` sort
//! key, so selection is a single `min` over the eligible tracks: pure, total, and ORDER-INDEPENDENT
//! (shuffling the track list cannot change the pick, because the id is in the key).

use serde::{Deserialize, Serialize};

use crate::model::{primary_subtag, SubtitlePrefs, SubtitleSourceTier, SubtitleTrack};

/// Why a track was chosen (the dominant factors of its score).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum Reason {
    /// Matched this preferred language.
    PreferredLanguage(String),
    /// A forced track was wanted and this one is forced.
    Forced,
    /// A hearing-impaired track was wanted and this one is HI.
    HearingImpaired,
    /// The track is in a preferred format.
    PreferredFormat,
    /// The track comes from a trusted, instant source (embedded / first-party).
    TrustedSource,
    /// The track is highly rated by the community.
    HighlyRated,
}

/// The chosen track and the reasons it won.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubtitleSelection {
    pub track_index: usize,
    pub reasons: Vec<Reason>,
}

/// Community rating at or above this is "highly rated" (out of 1000).
const HIGHLY_RATED: u16 = 700;

/// The total-order sort key for one eligible track. Lower is better on every field.
type SortKey = (usize, u8, u8, usize, u8, u16, String);

/// Choose the best subtitle track for the preferences, or `None` if nothing is eligible (no track in a
/// required language, or no tracks at all).
pub fn select(tracks: &[SubtitleTrack], prefs: &SubtitlePrefs) -> Option<SubtitleSelection> {
    let best = tracks
        .iter()
        .enumerate()
        .filter_map(|(i, t)| language_rank(t, prefs).map(|rank| (sort_key(t, prefs, rank), i)))
        .min_by(|a, b| a.0.cmp(&b.0))?;

    let idx = best.1;
    Some(SubtitleSelection {
        track_index: idx,
        reasons: reasons_for(&tracks[idx], prefs),
    })
}

/// The track's preferred-language rank (0 = top choice), or `None` if a language is required and this
/// track does not match. When no language is preferred, every track ranks 0.
fn language_rank(track: &SubtitleTrack, prefs: &SubtitlePrefs) -> Option<usize> {
    if prefs.languages.is_empty() {
        return Some(0);
    }
    let track_primary = primary_subtag(&track.lang);
    prefs
        .languages
        .iter()
        .position(|pref| primary_subtag(pref) == track_primary)
}

fn sort_key(track: &SubtitleTrack, prefs: &SubtitlePrefs, lang_rank: usize) -> SortKey {
    let forced_key = pref_match_key(prefs.want_forced, track.forced);
    let hi_key = pref_match_key(prefs.want_hearing_impaired, track.hearing_impaired);
    let format_rank = prefs
        .format_priority
        .iter()
        .position(|f| *f == track.format)
        .unwrap_or(prefs.format_priority.len());
    let tier_rank = track.tier.rank();
    let rating_key = u16::MAX - track.rating.unwrap_or(0);
    (
        lang_rank,
        forced_key,
        hi_key,
        format_rank,
        tier_rank,
        rating_key,
        track.id.clone(),
    )
}

/// 0 when the track matches the desired flag, 1 otherwise. If the flag is wanted, matching means having
/// it; if not wanted, matching means lacking it (so a default selection avoids forced/HI tracks).
fn pref_match_key(wanted: bool, has: bool) -> u8 {
    if wanted == has {
        0
    } else {
        1
    }
}

fn reasons_for(track: &SubtitleTrack, prefs: &SubtitlePrefs) -> Vec<Reason> {
    let mut reasons = Vec::new();
    if !prefs.languages.is_empty() {
        let track_primary = primary_subtag(&track.lang);
        if let Some(pref) = prefs
            .languages
            .iter()
            .find(|p| primary_subtag(p) == track_primary)
        {
            reasons.push(Reason::PreferredLanguage(pref.clone()));
        }
    }
    if prefs.want_forced && track.forced {
        reasons.push(Reason::Forced);
    }
    if prefs.want_hearing_impaired && track.hearing_impaired {
        reasons.push(Reason::HearingImpaired);
    }
    if prefs.format_priority.contains(&track.format) {
        reasons.push(Reason::PreferredFormat);
    }
    if matches!(
        track.tier,
        SubtitleSourceTier::Embedded | SubtitleSourceTier::Provider
    ) {
        reasons.push(Reason::TrustedSource);
    }
    if track.rating.unwrap_or(0) >= HIGHLY_RATED {
        reasons.push(Reason::HighlyRated);
    }
    reasons
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::SubtitleFormat;

    fn track(id: &str, lang: &str, tier: SubtitleSourceTier) -> SubtitleTrack {
        SubtitleTrack {
            id: id.into(),
            lang: lang.into(),
            forced: false,
            hearing_impaired: false,
            format: SubtitleFormat::Srt,
            tier,
            rating: None,
        }
    }

    #[test]
    fn preferred_language_wins() {
        let tracks = vec![
            track("es1", "es", SubtitleSourceTier::Embedded),
            track("en1", "en", SubtitleSourceTier::OpenSubtitles),
        ];
        let prefs = SubtitlePrefs {
            languages: vec!["en".into()],
            ..Default::default()
        };
        let sel = select(&tracks, &prefs).unwrap();
        assert_eq!(tracks[sel.track_index].id, "en1");
    }

    #[test]
    fn region_subtag_matches_primary() {
        let tracks = vec![track("enus", "en-US", SubtitleSourceTier::Community)];
        let prefs = SubtitlePrefs {
            languages: vec!["en".into()],
            ..Default::default()
        };
        assert!(select(&tracks, &prefs).is_some());
    }

    #[test]
    fn no_match_in_required_language_is_none() {
        let tracks = vec![track("fr1", "fr", SubtitleSourceTier::Embedded)];
        let prefs = SubtitlePrefs {
            languages: vec!["en".into()],
            ..Default::default()
        };
        assert!(select(&tracks, &prefs).is_none());
    }

    #[test]
    fn empty_tracks_is_none() {
        assert!(select(&[], &SubtitlePrefs::default()).is_none());
    }

    #[test]
    fn forced_preference_is_respected() {
        let mut forced = track("enf", "en", SubtitleSourceTier::Embedded);
        forced.forced = true;
        let plain = track("enp", "en", SubtitleSourceTier::Embedded);
        let tracks = vec![plain, forced];
        let prefs = SubtitlePrefs {
            languages: vec!["en".into()],
            want_forced: true,
            ..Default::default()
        };
        let sel = select(&tracks, &prefs).unwrap();
        assert_eq!(tracks[sel.track_index].id, "enf");
        assert!(sel.reasons.contains(&Reason::Forced));
    }

    #[test]
    fn default_selection_avoids_forced() {
        let mut forced = track("enf", "en", SubtitleSourceTier::Embedded);
        forced.forced = true;
        let plain = track("enp", "en", SubtitleSourceTier::Embedded);
        let tracks = vec![forced, plain];
        let prefs = SubtitlePrefs {
            languages: vec!["en".into()],
            ..Default::default()
        };
        let sel = select(&tracks, &prefs).unwrap();
        assert_eq!(tracks[sel.track_index].id, "enp");
    }

    #[test]
    fn tier_breaks_ties() {
        let tracks = vec![
            track("gen", "en", SubtitleSourceTier::Generated),
            track("emb", "en", SubtitleSourceTier::Embedded),
        ];
        let prefs = SubtitlePrefs {
            languages: vec!["en".into()],
            ..Default::default()
        };
        let sel = select(&tracks, &prefs).unwrap();
        assert_eq!(tracks[sel.track_index].id, "emb");
    }
}
