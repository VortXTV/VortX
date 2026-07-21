// Production-linked executable for the TorBox half of REQ-260721-50.
//
//   xcrun swiftc -warnings-as-errors -o /tmp/torbox-identity-boundary \
//     app/SourcesShared/SourceIndexContract.swift \
//     app/SourcesShared/SourceIndexIdentity.swift \
//     app/SourcesShared/TorBoxSearchSource.swift \
//     app/Tests/TorBoxIdentityBoundaryTests.swift && /tmp/torbox-identity-boundary
//
// It compiles the shipping identity resolver and TorBox owner. The surrounding app types are deliberately
// minimal stubs, so the test can exercise transport suppression, publication ownership, and merge fencing
// without an account, a network request, or an Xcode test target.

import Foundation

@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

protocol ObservableObject: AnyObject {}

struct CoreStream: Codable, Equatable {
    var name: String?
    var description: String?
    var infoHash: String?
    var url: String?
    var nzbUrl: String?
    var sources: [String]?

    init(name: String? = nil, description: String? = nil, infoHash: String? = nil,
         url: String? = nil, nzbUrl: String? = nil, sources: [String]? = nil) {
        self.name = name
        self.description = description
        self.infoHash = infoHash
        self.url = url
        self.nzbUrl = nzbUrl
        self.sources = sources
    }
}

struct CoreStreamSourceGroup {
    let id: String
    let addon: String
    let streams: [CoreStream]
}

enum DebridService { case torBox }

@MainActor
final class DebridKeys {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { true }
    func key(for service: DebridService) -> String { "test-key" }
}

enum VXProbe {
    static func log(_ channel: String, _ message: String) {}
}

enum VXProbeRedaction {
    static func identityToken(_ value: String?) -> String { "redacted" }
}

actor ControlledSearch {
    private var requested: [String] = []
    private var pending: [String: CheckedContinuation<TorBoxSearchSource.SearchResult, Never>] = [:]

    func run(target: SourceIndexIdentity.PublicationTarget,
             apiKey: String) async -> TorBoxSearchSource.SearchResult {
        requested.append(target.contentID)
        return await withCheckedContinuation { continuation in
            pending[target.contentID] = continuation
        }
    }

    func release(_ contentID: String, streams: [CoreStream]) {
        pending.removeValue(forKey: contentID)?.resume(
            returning: (streams: streams, rateLimited: false, transportError: false)
        )
    }

    func calls() -> [String] { requested }
}

@main
struct TorBoxIdentityBoundaryTests {
    @MainActor static var failures = 0

    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    static func roles(catalog: String?, defaultVideo: String?, currentVideo: String?)
        -> SourceIndexIdentity.Roles {
        SourceIndexIdentity.Roles(
            catalogID: catalog,
            defaultVideoID: defaultVideo,
            currentVideoID: currentVideo,
            kind: .series
        )
    }

    @MainActor
    static func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
    }

    @MainActor
    static func main() async {
        let probe = ControlledSearch()
        let source = TorBoxSearchSource(
            fetchStreams: { target, key in await probe.run(target: target, apiKey: key) },
            hasKey: { true },
            keyProvider: { "test-key" }
        )
        let mismatch = SourceIndexIdentity.publicationTarget(
            roles(catalog: "tt0903747", defaultVideo: "tt1375666",
                  currentVideo: "tt2861424:1:1"),
            season: 1,
            episode: 1
        )

        source.refresh(target: mismatch)
        await Task.yield()
        let mismatchCalls = await probe.calls()
        expect(mismatchCalls.isEmpty,
               "REQ-50: a typed mismatch launches zero TorBox transport")
        expect(source.streams.isEmpty && source.publishedContentID == nil,
               "REQ-50: a typed mismatch publishes no TorBox rows")

        let targetA = SourceIndexIdentity.publicationTarget(
            roles(catalog: "tt0903747", defaultVideo: "tt0903747:1:1",
                  currentVideo: "tt0903747:1:1"),
            season: 1,
            episode: 1
        )
        let targetB = SourceIndexIdentity.publicationTarget(
            roles(catalog: "tt2861424", defaultVideo: "tt2861424:2:0",
                  currentVideo: "tt2861424:2:0"),
            season: 2,
            episode: 0
        )
        let rowA = CoreStream(name: "A", infoHash: String(repeating: "a", count: 40))
        let rowB = CoreStream(name: "B", infoHash: String(repeating: "b", count: 40))
        let ordinary = [CoreStreamSourceGroup(
            id: "engine", addon: "Engine", streams: [CoreStream(name: "ordinary", url: "https://example.test")]
        )]

        source.refresh(target: targetA)
        await waitUntil { await probe.calls().count == 1 }
        source.refresh(target: targetB)
        await waitUntil { await probe.calls().count == 2 }
        await probe.release(targetA.target!.contentID, streams: [rowA])
        await Task.yield()
        expect(source.streams.isEmpty,
               "REQ-50: delayed title A cannot publish after title B becomes current")

        await probe.release(targetB.target!.contentID, streams: [rowB])
        await waitUntil { source.streams == [rowB] }
        expect(source.publishedContentID == targetB.target?.contentID,
               "REQ-50: TorBox publication records the exact fetched target")
        expect(source.merged(into: ordinary, for: targetA).count == ordinary.count,
               "REQ-50: title B rows cannot merge into title A")
        expect(source.merged(into: ordinary, for: targetB).last?.streams == [rowB],
               "REQ-50: rows merge only for their exact publication target")

        source.refresh(target: mismatch)
        expect(source.streams.isEmpty && source.publishedContentID == nil,
               "REQ-50: a later mismatch synchronously clears the previous publication")
        expect(source.merged(into: ordinary, for: mismatch).count == ordinary.count,
               "REQ-50: mismatch preserves the ordinary engine-only groups")

        let episodeZero = SourceIndexIdentity.publicationTarget(
            roles(catalog: "tmdb:94997", defaultVideo: nil,
                  currentVideo: "tt0460649:3:0"),
            season: 3,
            episode: 0
        )
        expect(episodeZero.target?.contentID == "tt0460649:3:0",
               "REQ-50: episode-only IMDb identity and E0 remain queryable")
        expect(SourceIndexIdentity.publicationTarget(
                   roles(catalog: nil, defaultVideo: nil, currentVideo: nil),
                   season: 0, episode: 0) == .absent,
               "REQ-50: nil identity remains absent even with complete zero coordinates")

        print("")
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
