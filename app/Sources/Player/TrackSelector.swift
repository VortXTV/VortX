import Foundation

/// Picks the audio and subtitle track to auto-select from the available tracks and the user's
/// preferences. Pure and side-effect free, so it is unit-testable. Shared by both players.
enum TrackSelector {
    /// The audio and subtitle track ids to select. A subtitle id of -1 means "off"; a nil audio id
    /// means "leave mpv's default" (no preferred-language match was found).
    static func select(audio: [MPVTrack], subtitles: [MPVTrack], preferences p: TrackPreferences) -> (audio: Int?, subtitle: Int?) {
        let audioPick = firstMatch(audio, languages: p.audioLanguages, reject: p.rejectTerms)
        let subtitle = selectSubtitle(subtitles, preferences: p, gotPreferredAudio: audioPick != nil)
        return (audioPick?.id, subtitle)
    }

    /// Whether the chrome should fall back to an EXTERNAL (add-on) subtitle for this load: the user's
    /// preferences wanted FULL subtitles but no embedded track matched the language chain. Mirrors
    /// `selectSubtitle`'s policy logic exactly, so the add-on fallback never fires when the user asked for
    /// subtitles off / forced-only while their preferred audio is present, and never fires when an embedded
    /// track already satisfies the chain (the embedded auto-select handles that case).
    static func wantsExternalSubtitle(audio: [MPVTrack], subtitles: [MPVTrack], preferences p: TrackPreferences) -> Bool {
        let gotPreferredAudio = firstMatch(audio, languages: p.audioLanguages, reject: p.rejectTerms) != nil
        // With preferred audio present, only the "always" policy shows full subtitles; off/forced-only must
        // not trigger a full external sub. Foreign-language content (no preferred audio) always wants them.
        if gotPreferredAudio && p.forcedPolicy != .always { return false }
        return firstMatch(subtitles, languages: p.subtitleLanguages, reject: p.rejectTerms) == nil
    }

    /// First track whose language matches the priority list and whose title isn't rejected.
    private static func firstMatch(_ tracks: [MPVTrack], languages: [String], reject: [String]) -> MPVTrack? {
        for lang in languages {
            if let t = tracks.first(where: { matches($0.lang, lang) && !isRejected($0, reject) }) { return t }
        }
        return nil
    }

    private static func selectSubtitle(_ subs: [MPVTrack], preferences p: TrackPreferences, gotPreferredAudio: Bool) -> Int? {
        guard !subs.isEmpty else { return -1 }
        // Foreign-language content (no preferred audio matched): show full subtitles so you can follow.
        if !gotPreferredAudio {
            return firstMatch(subs, languages: p.subtitleLanguages, reject: p.rejectTerms)?.id ?? -1
        }
        switch p.forcedPolicy {
        case .off:
            return -1
        case .always:
            return firstMatch(subs, languages: p.subtitleLanguages, reject: p.rejectTerms)?.id ?? -1
        case .forced:
            // Match by the container's FORCED disposition flag FIRST: real forced tracks are flagged
            // (AV_DISPOSITION_FORCED / mpv track-list forced), not labelled "forced" in the title, so the old
            // title-only match never fired for them and forced subtitles never turned on. Prefer a forced track
            // in a preferred subtitle language, then ANY forced track (forced subs are meant to show regardless
            // of language), then fall back to the legacy title-contains-"forced" heuristic for the rare
            // container that only labels forced in its title. Off if nothing qualifies.
            for lang in p.subtitleLanguages {
                if let t = subs.first(where: { $0.forced && matches($0.lang, lang) && !isRejected($0, p.rejectTerms) }) {
                    return t.id
                }
            }
            if let t = subs.first(where: { $0.forced && !isRejected($0, p.rejectTerms) }) {
                return t.id
            }
            for lang in p.subtitleLanguages {
                if let t = subs.first(where: { matches($0.lang, lang) && $0.title.lowercased().contains("forced") && !isRejected($0, p.rejectTerms) }) {
                    return t.id
                }
            }
            return -1
        }
    }

    private static func isRejected(_ track: MPVTrack, _ reject: [String]) -> Bool {
        let title = track.title.lowercased()
        return reject.contains { !$0.isEmpty && title.contains($0.lowercased()) }
    }

    /// Language match, tolerant of 2- vs 3-letter ISO codes (en/eng) and region suffixes (en-US).
    static func matches(_ a: String, _ b: String) -> Bool {
        let ca = canonical(a)
        return !ca.isEmpty && ca == canonical(b)
    }

    /// Reduce a language code to a canonical 2-letter form (eng → en, en-US → en, ja → ja).
    static func canonical(_ code: String) -> String {
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? ""
        if base.count == 3, let two = alpha3to2[base] { return two }
        return String(base.prefix(2))
    }

    private static let alpha3to2: [String: String] = [
        "eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de",
        "ita": "it", "por": "pt", "rus": "ru", "jpn": "ja", "kor": "ko", "zho": "zh",
        "chi": "zh", "ara": "ar", "hin": "hi", "nld": "nl", "dut": "nl", "swe": "sv",
        "nor": "no", "dan": "da", "fin": "fi", "pol": "pl", "tur": "tr", "tha": "th",
        "vie": "vi", "ind": "id", "heb": "he", "ell": "el", "gre": "el", "ces": "cs", "cze": "cs",
    ]
}
