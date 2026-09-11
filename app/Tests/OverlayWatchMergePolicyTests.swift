import Foundation

// Production-shaped fixture makes the pure policy executable without app runtime dependencies.
struct WatchEntry: Equatable {
    var videoId: String?
    var timeOffsetMs: Int
    var durationMs: Int
    var lastWatched: String
    var name: String
    var type: String
    var poster: String?
    var watchedVideoIds: [String] = []
    var markedAt: [String: Double]? = nil
    var unmarkedAt: [String: Double]? = nil
}

@main
enum OverlayWatchMergePolicyTests {
    static func entry(_ watched: [String], _ stamp: String, ma: [String: Double]? = nil,
                      ua: [String: Double]? = nil) -> WatchEntry {
        WatchEntry(videoId: nil, timeOffsetMs: 0, durationMs: 0, lastWatched: stamp,
                   name: "Show", type: "series", poster: nil, watchedVideoIds: watched,
                   markedAt: ma, unmarkedAt: ua)
    }

    static func main() {
        let old = "2026-09-09T10:00:00.000Z"
        let new = "2026-09-10T10:00:00.000Z"
        let newerUnwatch = entry([], new)
        let olderWatch = entry(["ep1"], old)
        precondition(OverlayWatchMergePolicy.mergeEntry(existing: newerUnwatch, incoming: olderWatch)
            .watchedVideoIds.isEmpty, "older watched snapshot must not resurrect newer unwatch")
        precondition(OverlayWatchMergePolicy.mergeEntry(existing: olderWatch, incoming: newerUnwatch)
            .watchedVideoIds.isEmpty, "newer unwatch must shrink legacy watched snapshot")
        let local = entry(["ep1"], old, ma: ["ep1": 100])
        let remote = entry(["ep2"], new, ma: ["ep2": 200], ua: ["ep1": 150])
        let merged = OverlayWatchMergePolicy.mergeEntry(existing: local, incoming: remote)
        precondition(merged.watchedVideoIds == ["ep2"],
                     "newer explicit unmark wins while independent episode mark survives")
        print("Overlay watch merge policy tests passed")
    }
}
