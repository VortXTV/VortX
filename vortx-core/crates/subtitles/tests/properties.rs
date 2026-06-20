//! Property-based invariants for subtitle selection: totality, determinism, order-independence, validity
//! of the chosen index, and the language contract (a required language is honored, or the result is None).

use proptest::prelude::*;
use vortx_subtitles::{select, SubtitleFormat, SubtitlePrefs, SubtitleSourceTier, SubtitleTrack};

fn format() -> impl Strategy<Value = SubtitleFormat> {
    prop_oneof![
        Just(SubtitleFormat::Srt),
        Just(SubtitleFormat::Vtt),
        Just(SubtitleFormat::Ass),
        Just(SubtitleFormat::Pgs),
    ]
}

fn tier() -> impl Strategy<Value = SubtitleSourceTier> {
    prop_oneof![
        Just(SubtitleSourceTier::Embedded),
        Just(SubtitleSourceTier::Provider),
        Just(SubtitleSourceTier::OpenSubtitles),
        Just(SubtitleSourceTier::Community),
        Just(SubtitleSourceTier::Generated),
    ]
}

fn lang() -> impl Strategy<Value = String> {
    prop_oneof![
        Just("en"),
        Just("en-US"),
        Just("es"),
        Just("fr"),
        Just("ja"),
        Just("pt-BR"),
    ]
    .prop_map(String::from)
}

fn track() -> impl Strategy<Value = SubtitleTrack> {
    (
        "[a-z0-9]{1,8}",
        lang(),
        any::<bool>(),
        any::<bool>(),
        format(),
        tier(),
        prop::option::of(0u16..=1000),
    )
        .prop_map(
            |(id, lang, forced, hearing_impaired, format, tier, rating)| SubtitleTrack {
                id,
                lang,
                forced,
                hearing_impaired,
                format,
                tier,
                rating,
            },
        )
}

fn prefs() -> impl Strategy<Value = SubtitlePrefs> {
    (
        prop::collection::vec(lang(), 0..3),
        any::<bool>(),
        any::<bool>(),
        prop::collection::vec(format(), 0..3),
    )
        .prop_map(
            |(languages, want_forced, want_hearing_impaired, format_priority)| SubtitlePrefs {
                languages,
                want_forced,
                want_hearing_impaired,
                format_priority,
            },
        )
}

proptest! {
    #[test]
    fn selection_is_total_deterministic_and_valid(
        tracks in prop::collection::vec(track(), 0..16),
        prefs in prefs(),
    ) {
        let a = select(&tracks, &prefs);
        let b = select(&tracks, &prefs);
        prop_assert_eq!(&a, &b); // deterministic, and not panicking proves totality

        if let Some(sel) = a {
            prop_assert!(sel.track_index < tracks.len());
        }
    }

    #[test]
    fn selection_is_order_independent(
        tracks in prop::collection::vec(track(), 1..16),
        prefs in prefs(),
    ) {
        // Deduplicate ids so the chosen track is unambiguous regardless of order.
        let mut seen = std::collections::HashSet::new();
        let unique: Vec<SubtitleTrack> = tracks.into_iter().filter(|t| seen.insert(t.id.clone())).collect();
        let forward = select(&unique, &prefs).map(|s| unique[s.track_index].id.clone());

        let mut reversed = unique.clone();
        reversed.reverse();
        let backward = select(&reversed, &prefs).map(|s| reversed[s.track_index].id.clone());

        prop_assert_eq!(forward, backward);
    }

    #[test]
    fn required_language_is_honored_or_none(
        tracks in prop::collection::vec(track(), 0..16),
    ) {
        let prefs = SubtitlePrefs { languages: vec!["en".into()], ..Default::default() };
        if let Some(sel) = select(&tracks, &prefs) {
            // The chosen track must be in the required language (primary subtag "en").
            let chosen = &tracks[sel.track_index];
            let primary = chosen.lang.split(['-', '_']).next().unwrap_or(&chosen.lang).to_ascii_lowercase();
            prop_assert_eq!(primary, "en");
        } else {
            // None only when no track is English.
            let none_english = tracks.iter().all(|t| {
                let p = t.lang.split(['-', '_']).next().unwrap_or(&t.lang).to_ascii_lowercase();
                p != "en"
            });
            prop_assert!(none_english);
        }
    }
}
