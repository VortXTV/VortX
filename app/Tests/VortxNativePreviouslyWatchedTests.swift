// The Library keeps every title watched or started unless the viewer removed it after
// its last watch. Run: scripts/test-library-previously-watched.sh
import Foundation

@main enum PreviouslyWatchedTests {
    static func check(_ condition: Bool, _ message: String) {
        if condition { print("PASS  " + message) } else { print("FAIL  " + message); exit(1) }
    }
    static func row(_ meta: String, _ type: String, video: String? = nil, at: UInt64, name: String? = nil) -> VortxJSON {
        var fields: [String: VortxJSON] = ["metaId": .string(meta), "type": .string(type), "updatedAt": .unsigned(at),
                                           "offsetMs": .unsigned(0), "durationMs": .unsigned(0), "timesWatched": .unsigned(0), "watched": .bool(true)]
        if let video { fields["videoId"] = .string(video) }
        if let name { fields["name"] = .string(name) }
        return .object(fields)
    }

    static func main() {
        let playback: VortxJSON = .object([
            "continueWatching": .array([row("tt-naruto", "series", video: "tt-naruto:1:49", at: 1_800, name: "Naruto")]),
            "history": .array([
                row("tt-naruto", "series", video: "tt-naruto:1:48", at: 1_700, name: "Naruto"),
                row("tt-movie", "movie", at: 1_500, name: "Movie"),
                row("tt-saved", "movie", at: 1_900, name: "Saved"),
                row("tt-removed", "movie", at: 1_200, name: "Removed"),
                row("tt-rewatched", "movie", at: 1_600, name: "Rewatched"),
                row("", "movie", at: 1_000), row("tt-untyped", "", at: 1_000),
            ]),
        ])
        let removals: [String: UInt64] = ["movie:tt-removed": 1_300, "movie:tt-rewatched": 1_550]
        let titles = VortxNativePreviouslyWatched.titles(playback: playback, excluding: ["tt-saved"]) { removals[$0 + ":" + $1] }
        check(titles.map(\.id) == ["tt-naruto", "tt-rewatched", "tt-movie"], "watched and started titles, newest first, saved and removed ones left out: \(titles.map(\.id))")
        check(titles[0].lastWatched == 1_800 && titles[0].type == "series" && titles[0].name == .string("Naruto"), "a series counts once, at its latest episode")
        check(titles.contains { $0.id == "tt-rewatched" }, "watching after a removal brings the title back")
        check(!titles.contains { $0.id == "tt-removed" }, "a removal after the last watch keeps it out")
        let none = VortxNativePreviouslyWatched.titles(playback: nil, excluding: []) { _, _ in nil }
        check(none.isEmpty, "no playback, no titles")
        check(VortxNativePreviouslyWatched.type(of: "tt-movie", playback: playback) == "movie"
              && VortxNativePreviouslyWatched.type(of: "tt-unknown", playback: playback) == nil, "a watched title's own type keys its removal")
        print("All Library previously-watched checks passed")
    }
}
