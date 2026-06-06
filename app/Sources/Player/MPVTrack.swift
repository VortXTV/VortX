import Foundation

/// An audio or subtitle track exposed by libmpv's track-list. Shared by the iOS and tvOS players.
struct MPVTrack: Identifiable {
    let id: Int
    let type: String
    let title: String
    let lang: String
    let selected: Bool

    var label: String {
        if !title.isEmpty && !lang.isEmpty { return "\(title) (\(lang.uppercased()))" }
        if !title.isEmpty { return title }
        if !lang.isEmpty { return lang.uppercased() }
        return "Track \(id)"
    }
}
