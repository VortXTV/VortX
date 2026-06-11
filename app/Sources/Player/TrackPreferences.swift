import Foundation

enum PlaybackSettings {
    enum Key {
        static let directLinksOnly = "stremiox.directLinksOnly"
    }

    static var directLinksOnlyForced: Bool {
        #if STREMIOX_NO_EMBEDDED_SERVER
        true
        #else
        false
        #endif
    }

    static var directLinksOnly: Bool {
        #if STREMIOX_NO_EMBEDDED_SERVER
        true
        #else
        UserDefaults.standard.bool(forKey: Key.directLinksOnly)
        #endif
    }

    static var torrentsDisabled: Bool { directLinksOnly }
}

/// What audio and subtitle track the player should pick automatically. Persisted in UserDefaults and
/// shared by the iOS and tvOS players; configured from tvOS Settings, with sensible defaults until then.
struct TrackPreferences: Equatable {
    /// Preferred languages in priority order, as ISO codes (e.g. ["en", "ja"]).
    var audioLanguages: [String]
    var subtitleLanguages: [String]
    /// What subtitles to show when you DID get your preferred audio language.
    var forcedPolicy: ForcedPolicy
    /// Track titles containing any of these (case-insensitive) are never auto-picked (e.g. "commentary").
    var rejectTerms: [String]

    enum ForcedPolicy: String, CaseIterable, Equatable {
        case off       // never auto-show subtitles once you have your audio language
        case forced    // only forced subtitles (foreign-dialogue captions)
        case always    // always show full subtitles in your language

        var label: String {
            switch self {
            case .off:    return "Off"
            case .forced: return "Forced only"
            case .always: return "Always on"
            }
        }
    }

    // MARK: Persistence

    enum Key {
        static let audio = "stremiox.tracks.audioLangs"
        static let subtitle = "stremiox.tracks.subLangs"
        static let forced = "stremiox.tracks.forced"
        static let reject = "stremiox.tracks.reject"
    }

    /// Curated language choices for the settings UI (id is the stored ISO code).
    static let commonLanguages: [(id: String, label: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("hi", "Hindi"), ("ja", "Japanese"),
        ("ko", "Korean"), ("zh", "Chinese"), ("ar", "Arabic"), ("ru", "Russian"),
    ]

    /// The device's preferred languages as ISO codes, deduplicated, used as the default.
    static var deviceLanguages: [String] {
        var seen = Set<String>(); var out: [String] = []
        for id in Locale.preferredLanguages {
            let code = Locale(identifier: id).language.languageCode?.identifier ?? String(id.prefix(2))
            if seen.insert(code).inserted { out.append(code) }
        }
        return out.isEmpty ? ["en"] : out
    }

    /// Current preferences: device languages plus sensible defaults until the user customizes them.
    static var current: TrackPreferences {
        let d = UserDefaults.standard
        return TrackPreferences(
            audioLanguages: list(d.string(forKey: Key.audio)) ?? deviceLanguages,
            subtitleLanguages: list(d.string(forKey: Key.subtitle)) ?? deviceLanguages,
            forcedPolicy: ForcedPolicy(rawValue: d.string(forKey: Key.forced) ?? "") ?? .forced,
            rejectTerms: list(d.string(forKey: Key.reject)) ?? ["commentary", "sdh"]
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(audioLanguages.joined(separator: ","), forKey: Key.audio)
        d.set(subtitleLanguages.joined(separator: ","), forKey: Key.subtitle)
        d.set(forcedPolicy.rawValue, forKey: Key.forced)
        d.set(rejectTerms.joined(separator: ","), forKey: Key.reject)
    }

    private static func list(_ s: String?) -> [String]? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }
}
