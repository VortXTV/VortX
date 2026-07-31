import Foundation

/// Picks the audio and subtitle track to auto-select from the available tracks and the user's
/// preferences. Pure and side-effect free, so it is unit-testable. Shared by both players.
enum TrackSelector {
    /// Selection setters may have side effects even when the requested row is already active (MPV arms a
    /// cache hold; AVPlayer's source-audio lane can remount). Make that no-op executable for both engines.
    static func shouldApplyAudioSelection(_ id: Int, to tracks: [MPVTrack]) -> Bool {
        !tracks.contains { $0.id == id && $0.selected }
    }

    /// A remux has already made its primary audio choice before AVPlayer can load its track inventory.
    /// Suppress only the automatic setter in that case; explicit picker actions call the engine directly.
    static func automaticAudioSelection(_ id: Int?,
                                        remuxOwnsInitialSelection: Bool) -> Int? {
        remuxOwnsInitialSelection ? nil : id
    }

    /// The audio and subtitle track ids to select. A subtitle id of -1 means "off"; a nil audio id
    /// means "leave the engine's default" (neither the user's chain nor the English fallback matched).
    static func select(audio: [MPVTrack], subtitles: [MPVTrack], preferences p: TrackPreferences) -> (audio: Int?, subtitle: Int?) {
        let chainPick = firstAudioMatch(audio, languages: p.audioLanguages, reject: p.rejectTerms)
        // No track matches the user's language chain (#76, ozdek's report): do NOT leave the pick to the
        // engine default. Unpicked, both engines defer to the container's default/first audio track, which
        // on multi-language European releases is frequently the local dub, so a Turkish-only preference
        // played French. Fall back to English, the original language of the overwhelming majority of the
        // catalog (the app has no per-title original-language metadata to prefer first, and MPVTrack
        // carries no channel counts to break ties on, so English is the strongest fallback available).
        // A file with neither a chain match nor an English track still leaves the engine default.
        // The subtitle policy keys off the CHAIN match, not the fallback: English-fallback audio counts as
        // foreign-language content, so full subtitles in the user's language still auto-enable.
        let audioPick = chainPick ?? firstAudioMatch(audio, languages: ["en"], reject: p.rejectTerms)
        let subtitle = selectSubtitle(subtitles, preferences: p, gotPreferredAudio: chainPick != nil)
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

    /// Audio rows within one language tier are otherwise ordered only by the engine/container. Keep the row
    /// already playing so an automatic pass cannot turn a no-op into a source-audio remount.
    private static func firstAudioMatch(_ tracks: [MPVTrack], languages: [String], reject: [String]) -> MPVTrack? {
        for lang in languages {
            var firstEligible: MPVTrack?
            for track in tracks where track.isSelectable
                && matches(track.lang, lang)
                && !isRejected(track, reject) {
                if track.selected { return track }
                if firstEligible == nil { firstEligible = track }
            }
            if let firstEligible { return firstEligible }
        }
        return nil
    }

    /// First track whose language matches the priority list and whose title isn't rejected.
    private static func firstMatch(_ tracks: [MPVTrack], languages: [String], reject: [String]) -> MPVTrack? {
        for lang in languages {
            if let t = tracks.first(where: {
                $0.isSelectable
                    && matches($0.lang, lang)
                    && !isRejected($0, reject)
            }) { return t }
        }
        return nil
    }

    private static func selectSubtitle(_ subs: [MPVTrack], preferences p: TrackPreferences, gotPreferredAudio: Bool) -> Int? {
        let selectable = subs.filter(\.isSelectable)
        guard !selectable.isEmpty else { return -1 }
        // Foreign-language content (no preferred audio matched): show full subtitles so you can follow.
        if !gotPreferredAudio {
            return firstMatch(selectable, languages: p.subtitleLanguages, reject: p.rejectTerms)?.id ?? -1
        }
        switch p.forcedPolicy {
        case .off:
            return -1
        case .always:
            return firstMatch(selectable, languages: p.subtitleLanguages, reject: p.rejectTerms)?.id ?? -1
        case .forced:
            // Match by the container's FORCED disposition flag FIRST: real forced tracks are flagged
            // (AV_DISPOSITION_FORCED / mpv track-list forced), not labelled "forced" in the title, so the old
            // title-only match never fired for them and forced subtitles never turned on. Prefer a forced track
            // in a preferred subtitle language, then ANY forced track (forced subs are meant to show regardless
            // of language), then fall back to the legacy title-contains-"forced" heuristic for the rare
            // container that only labels forced in its title. Off if nothing qualifies.
            for lang in p.subtitleLanguages {
                if let t = selectable.first(where: { $0.forced && matches($0.lang, lang) && !isRejected($0, p.rejectTerms) }) {
                    return t.id
                }
            }
            if let t = selectable.first(where: { $0.forced && !isRejected($0, p.rejectTerms) }) {
                return t.id
            }
            for lang in p.subtitleLanguages {
                if let t = selectable.first(where: { matches($0.lang, lang) && $0.title.lowercased().contains("forced") && !isRejected($0, p.rejectTerms) }) {
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

    /// Filter an external-subtitle list to the preferred subtitle languages when the opt-in
    /// `TrackPreferences.subtitlesOnlyPreferred` toggle is on; a no-op (returns `items` unchanged) otherwise.
    /// Unknown/undetermined languages ("", "und", "unknown") are ALWAYS kept so the filter can never hide every
    /// option (add-on and embedded-upload subs frequently report no language). Uses the tolerant `matches`, so
    /// "tur"/"tr-TR" still satisfy a "tr" preference. Generic over the row type via a `language` accessor so
    /// both the add-on rows (`AddonSubtitle`) and the community-pooled rows share one path.
    static func keepingPreferredSubtitleLanguages<T>(_ items: [T], language: (T) -> String) -> [T] {
        guard TrackPreferences.subtitlesOnlyPreferred else { return items }
        let prefs = TrackPreferences.current.subtitleLanguages
        guard !prefs.isEmpty else { return items }
        return items.filter { item in
            let raw = language(item).trimmingCharacters(in: .whitespaces).lowercased()
            if raw.isEmpty || raw == "und" || raw == "unknown" { return true }
            return prefs.contains { matches(language(item), $0) }
        }
    }

    /// Reduce a language code to its canonical base identity (eng → en, en-US → en, ja → ja).
    static func canonical(_ code: String) -> String {
        AudioLanguagePolicy.canonical(code)
    }
}
