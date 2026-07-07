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

    var label: String {
        if !title.isEmpty && !lang.isEmpty { return "\(title) (\(lang.uppercased()))" }
        if !title.isEmpty { return title }
        if !lang.isEmpty { return lang.uppercased() }
        return "Track \(id)"
    }
}
