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
            position.isFinite && duration.isFinite && position > 0 && duration >= 0
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

        if failures == 0 {
            print("ContinueWatchingDedupeTests: \(checks) checks passed")
        } else {
            fputs("ContinueWatchingDedupeTests: \(failures)/\(checks) checks failed\n", stderr)
            exit(1)
        }
    }
}
