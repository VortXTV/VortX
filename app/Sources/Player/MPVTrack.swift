import Foundation

/// An audio or subtitle track exposed by libmpv's track-list. Shared by the iOS and tvOS players.
struct MPVTrack: Identifiable {
    let id: Int
    let type: String
    let title: String
    let lang: String
    let selected: Bool
    /// The container's FORCED disposition (mpv `track-list/N/forced`, AV_DISPOSITION_FORCED). Real forced
    /// subtitle tracks are flagged here, NOT by the word "forced" in the title, so forced-subtitle auto-select
    /// must key off this, not the title text. Defaults false so a track built without the flag is "not forced".
    var forced: Bool = false
    /// Non-nil keeps a real source row visible while making the reason it cannot be selected explicit.
    /// Today this is used for image-based subtitles on AVPlayer, which cannot be converted to WebVTT.
    var unavailableReason: String? = nil
    var isSelectable: Bool { unavailableReason == nil }

    var label: String {
        let base: String
        if !title.isEmpty && !lang.isEmpty {
            base = "\(title) (\(lang.uppercased()))"
        } else if !title.isEmpty {
            base = title
        } else if !lang.isEmpty {
            base = lang.uppercased()
        } else {
            base = "Track \(id)"
        }
        return unavailableReason.map { "\(base) | \($0)" } ?? base
    }
}

/// The viewer's explicit in-session subtitle choice, captured just before an engine switch (#76, mandated
/// check 8) so the NEW engine re-applies it instead of re-running the preference-derived auto pick. Auto
/// select would otherwise override an explicit Off or an explicit language choice on the fresh mount. Track
/// id spaces differ per engine, so an embedded pick matches by lang/title and an external/pooled pick is
/// re-added by URL / pool id on the new engine. Shared by the iOS and tvOS players.
enum SubtitleChoice: Equatable {
    /// Subtitles were explicitly turned Off.
    case off
    /// An embedded container track, matched on the new engine by language + title.
    case embedded(lang: String, title: String)
    /// An add-on external subtitle, re-added on the new engine via `addExternalSubtitle`.
    case external(url: String, title: String, lang: String)
    /// A community-pooled subtitle, re-added on the new engine via `selectPooledSubtitle`.
    case pooled(id: Int)
}
