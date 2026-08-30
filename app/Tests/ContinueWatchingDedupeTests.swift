import Foundation

private struct Fixture: Decodable {
    let version: Int
    let cases: [Case]

    struct Case: Decodable {
        let name: String
        let items: [Item]
        let expected: [String]
    }

    struct Item: Decodable, Equatable {
        let key: String
        let id: String
        let type: String
        let name: String
        let poster: String?
        let aliases: [String]
        let position: Double
        let duration: Double
        let updatedAt: Double?
        let removed: Bool?

        var hasValidProgress: Bool {
            position.isFinite && duration.isFinite && position > 0 && duration > 0
        }
    }
}

private func fixture() throws -> Fixture {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = repository.appendingPathComponent("test-fixtures/continue-watching-dedupe.json")
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
}

@main
private enum ContinueWatchingDedupeTests {
    static func main() throws {
        var failures = 0
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if condition() { print("PASS: \(message)") }
            else { failures += 1; print("FAIL: \(message)") }
        }

        let parity = try fixture()
        expect(parity.version == 1, "cross-platform fixture schema is version 1")
        for testCase in parity.cases {
            let folded = ContinueWatchingDedupe.fold(testCase.items) {
                .init(
                    id: $0.id,
                    type: $0.type,
                    aliases: $0.aliases,
                    freshness: $0.updatedAt,
                    hasValidProgress: $0.hasValidProgress,
                    removed: $0.removed ?? false
                )
            }
            expect(folded.map(\.key) == testCase.expected, "parity: \(testCase.name)")
        }

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

        struct OverlayRow: Equatable {
            let type: String
            let alias: String
            let freshness: Double?
            let valid: Bool
        }
        func overlayIdentity(_ id: String, _ row: OverlayRow) -> ContinueWatchingDedupe.Identity {
            .init(id: id, type: row.type, aliases: [row.alias], freshness: row.freshness,
                  hasValidProgress: row.valid)
        }
        let deviceA = [
            "tmdb:1396": OverlayRow(type: "series", alias: "tt0903747:5:16", freshness: 100, valid: true)
        ]
        let removedKeys = OverlayWatchRemovalPolicy.componentKeys(
            seedID: "tmdb:1396", seed: deviceA["tmdb:1396"]!, entries: deviceA, identity: overlayIdentity
        )
        let dismissed = OverlayWatchRemovalPolicy.resolve(
            entries: deviceA,
            removals: [OverlayWatchRemoval(keys: removedKeys.sorted(), removedAt: 200)],
            identity: overlayIdentity
        )
        expect(dismissed.entries.isEmpty && dismissed.removals.count == 1,
               "overlay dismiss removes the live alias component and retains its tombstone")

        let stalePeer = [
            "imdb:tt0903747": OverlayRow(type: "series", alias: "tt0903747:5:15", freshness: 150, valid: true)
        ]
        let staleMerge = OverlayWatchRemovalPolicy.resolve(
            entries: stalePeer, removals: dismissed.removals, identity: overlayIdentity
        )
        expect(staleMerge.entries.isEmpty && staleMerge.removals.count == 1,
               "stale peer alias cannot resurrect a dismissed overlay title")

        let newerPeer = [
            "imdb:tt0903747": OverlayRow(type: "series", alias: "tt0903747:5:17", freshness: 201, valid: true)
        ]
        let newerMerge = OverlayWatchRemovalPolicy.resolve(
            entries: newerPeer, removals: dismissed.removals, identity: overlayIdentity
        )
        expect(newerMerge.entries == newerPeer && newerMerge.removals.isEmpty,
               "strictly newer valid rewatch restores the overlay and clears its tombstone")

        let largeRemoval = OverlayWatchRemoval(keys: removedKeys.sorted(), removedAt: 1_000)
        let decoys = (0..<130).map { index in
            OverlayWatchInboundPolicy.Row(
                id: "tmdb:movie:\(10_000 + index)",
                entry: OverlayRow(type: "movie", alias: "", freshness: 800 - Double(index), valid: true)
            )
        }
        let oldBridge = OverlayWatchInboundPolicy.Row(
            id: "tmdb:1396",
            entry: OverlayRow(type: "series", alias: "tt0903747:5:1", freshness: 1, valid: true)
        )
        let newestRewatch = OverlayWatchInboundPolicy.Row(
            id: "imdb:tt0903747",
            entry: OverlayRow(type: "series", alias: "tt0903747:5:17", freshness: 1_100, valid: true)
        )
        let orderedRows = decoys + [newestRewatch, oldBridge]
        let forward = OverlayWatchInboundPolicy.select(
            rows: orderedRows, removals: [largeRemoval], identity: overlayIdentity
        )
        let reversed = OverlayWatchInboundPolicy.select(
            rows: orderedRows.reversed(), removals: [largeRemoval], identity: overlayIdentity
        )
        expect(forward?.entries["imdb:tt0903747"] == newestRewatch.entry && forward?.removals.isEmpty == true,
               "newest rewatch survives a shuffled oversized payload through an old alias bridge")
        let forwardKeys = Set(forward?.entries.keys.map { $0 } ?? [])
        let reversedKeys = Set(reversed?.entries.keys.map { $0 } ?? [])
        expect(forwardKeys == reversedKeys && forward?.entries == reversed?.entries &&
               forward?.removals == reversed?.removals,
               "oversized inbound selection is deterministic across insertion orders")
        expect(forward?.entries.count == OverlayWatchInboundPolicy.liveLimit,
               "inbound live output remains bounded after alias closure")

        let staleRewatch = OverlayWatchInboundPolicy.Row(
            id: "imdb:tt0903747",
            entry: OverlayRow(type: "series", alias: "tt0903747:5:15", freshness: 900, valid: true)
        )
        let staleLarge = OverlayWatchInboundPolicy.select(
            rows: decoys + [staleRewatch, oldBridge], removals: [largeRemoval], identity: overlayIdentity
        )
        expect(staleLarge?.entries["imdb:tt0903747"] == nil && staleLarge?.removals.count == 1 &&
               staleLarge?.removals.first?.removedAt == largeRemoval.removedAt,
               "old bridge carries a tombstone to suppress stale progress below the live cap")
        expect(OverlayWatchInboundPolicy.select(
            rows: Array(repeating: oldBridge, count: OverlayWatchInboundPolicy.parseLimit + 1),
            removals: [], identity: overlayIdentity
        ) == nil, "hostile oversized inbound arrays are rejected before candidate folding")

        if failures == 0 {
            print("ContinueWatchingDedupeTests: \(checks) checks passed")
        } else {
            fputs("ContinueWatchingDedupeTests: \(failures)/\(checks) checks failed\n", stderr)
            exit(1)
        }
    }
}
