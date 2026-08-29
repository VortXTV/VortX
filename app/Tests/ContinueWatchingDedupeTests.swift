import Foundation

private struct Item: Equatable {
    let id: String
    let type: String
    let name: String
    let poster: String?
}

private func merge(engine: [Item], synthesized: [Item]) -> [Item] {
    var ids = Set<String>()
    var fingerprints = Set<String>()
    let identity: (Item) -> ContinueWatchingDedupe.Identity = {
        .init(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster)
    }
    let live = ContinueWatchingDedupe.filterUnique(
        engine, seenIDs: &ids, seenFingerprints: &fingerprints, identity: identity)
    let recovered = ContinueWatchingDedupe.filterUnique(
        synthesized, seenIDs: &ids, seenFingerprints: &fingerprints, identity: identity)
    return live + recovered
}

@main
private enum ContinueWatchingDedupeTests {
    static func main() {
        var failures = 0
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if condition() { print("PASS: \(message)") }
            else { failures += 1; print("FAIL: \(message)") }
        }

        let live = Item(id: "tt0903747", type: "series", name: "Breaking Bad", poster: "https://img/poster.jpg")
        let exact = Item(id: "TT0903747", type: "series", name: "Breaking Bad", poster: "https://img/poster.jpg")
        let alias = Item(id: "tmdb:1396", type: "series", name: " breaking   bad ", poster: "https://img/poster.jpg")
        let remake = Item(id: "tmdb:999", type: "series", name: "Breaking Bad", poster: "https://img/remake.jpg")
        let noPoster = Item(id: "tmdb:1000", type: "series", name: "Breaking Bad", poster: nil)

        expect(merge(engine: [live, exact], synthesized: []).map(\.id) == [live.id],
               "exact ids collapse case-insensitively")
        expect(merge(engine: [live], synthesized: [alias]).map(\.id) == [live.id],
               "strong tmdb/imdb display aliases collapse and the engine item wins")
        expect(merge(engine: [live], synthesized: [remake]).map(\.id) == [live.id, remake.id],
               "same-title series with different posters stay distinct")
        expect(merge(engine: [live], synthesized: [noPoster]).map(\.id) == [live.id, noPoster.id],
               "title alone never collapses an identity with missing poster evidence")
        expect(merge(engine: [live, remake], synthesized: []).map(\.id) == [live.id, remake.id],
               "engine order is preserved")
        expect(WatchedMembershipPolicy.changed(["s1e1"], ["s1e2"]),
               "same-count watched episode replacement is observable")
        expect(!WatchedMembershipPolicy.changed(["s1e2", "s1e1"], ["s1e1", "s1e2"]),
               "watched episode ordering alone is ignored")

        let liveWatch = ["show": 42]
        let diskWatch = ["show": 21]
        expect(OverlayWatchSyncPolicy.snapshot(
            requestedID: "active", activeID: "active", live: liveWatch, persisted: diskWatch
        ) == liveWatch, "active overlay sync reads the newer live snapshot")
        expect(OverlayWatchSyncPolicy.snapshot(
            requestedID: "inactive", activeID: "active", live: liveWatch, persisted: diskWatch
        ) == diskWatch, "inactive overlay sync reads its persisted cache")

        if failures == 0 {
            print("ContinueWatchingDedupeTests: \(checks) checks passed")
        } else {
            fputs("ContinueWatchingDedupeTests: \(failures)/\(checks) checks failed\n", stderr)
            exit(1)
        }
    }
}
