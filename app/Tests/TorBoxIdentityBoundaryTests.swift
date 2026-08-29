// Production-linked executable for the non-forgeable auxiliary identity boundary.
//
//   xcrun swiftc -D SOURCE_INDEX_IDENTITY_TESTING -swift-version 6 \
//     -strict-concurrency=complete -warnings-as-errors -o /tmp/torbox-identity-boundary \
//     app/SourcesShared/SourceIndexContract.swift \
//     app/SourcesShared/SourceIndexIdentity.swift \
//     app/SourcesShared/ProviderCircuitBreaker.swift \
//     app/SourcesShared/TorBoxSearchSource.swift \
//     app/Tests/TorBoxIdentityBoundaryTests.swift && /tmp/torbox-identity-boundary
//
// This compiles the shipping identity resolver and TorBox owner. The surrounding app types are deliberately
// minimal stubs, so the test exercises transport suppression, publication ownership, and merge fencing without
// an account, a network request, or an Xcode test target.

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

enum AuxiliarySourcePipeline {
    struct Call: Sendable {
        let resolution: SourceIndexIdentity.TargetResolution
    }

    static func callForTesting(_ resolution: SourceIndexIdentity.TargetResolution) -> Call {
        Call(resolution: resolution)
    }
}

enum VXProbe {
    static func log(_ channel: String, _ message: String) {}
}

enum VXProbeRedaction {
    static func identityToken(_ value: String?) -> String { "redacted" }
}

enum SourceContributorSettlement: String, Equatable, Sendable {
    case inactive
    case pending
    case terminal
}

enum SourceContributorCompletionOwnership {
    static func accepts(completedKey: String, shownKey: String?, inFlightKey: String?, canceled: Bool) -> Bool {
        !canceled && shownKey == completedKey && inFlightKey == completedKey
    }
}

struct RemoteConfigSnapshot {
    func isFeatureOn(_ key: String, default value: Bool) -> Bool { value }
}

enum RemoteConfig {
    static let snapshot = RemoteConfigSnapshot()
}

enum RemoteConfigDefaults {
    static let featureTorBoxSearch = true
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

actor CacheHitRevisitSearch {
    struct Request: Sendable {
        let id: Int
        let key: String
    }

    private var nextID = 0
    private var requested: [Request] = []
    private var pending: [Int: CheckedContinuation<TorBoxSearchSource.SearchResult, Never>] = [:]
    private var cancelled: Set<Int> = []

    func run(target: SourceIndexIdentity.PublicationTarget,
             apiKey _: String) async -> TorBoxSearchSource.SearchResult {
        let request = Request(id: nextID, key: target.contentID)
        nextID += 1
        requested.append(request)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                pending[request.id] = continuation
            }
        }, onCancel: {
            Task { await self.recordCancellation(request.id) }
        })
    }

    func requestIDs(for key: String) -> [Int] {
        requested.filter { $0.key == key }.map(\.id)
    }

    func cancellationCount() -> Int { cancelled.count }

    func release(_ id: Int, streams: [CoreStream]) {
        pending.removeValue(forKey: id)?.resume(
            returning: (streams: streams, rateLimited: false, transportError: false)
        )
    }

    private func recordCancellation(_ id: Int) {
        cancelled.insert(id)
    }
}

actor CancellationProbe {
    private var started = 0
    private var cancelled = 0

    func run() async -> TorBoxSearchSource.SearchResult {
        started += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelled += 1
        }
        return (streams: [], rateLimited: false, transportError: false)
    }

    func startedCount() -> Int { started }
    func cancelledCount() -> Int { cancelled }
}

actor OutcomeProbe {
    private var requests = 0
    private let result: TorBoxSearchSource.SearchResult

    init(result: TorBoxSearchSource.SearchResult) {
        self.result = result
    }

    func run() -> TorBoxSearchSource.SearchResult {
        requests += 1
        return result
    }

    func count() -> Int { requests }
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
               "mismatched roles launch zero TorBox transport")
        expect(source.streams.isEmpty && source.publishedTarget?.contentID == nil,
               "mismatched roles publish no TorBox rows")

        let forged = SourceIndexIdentity.uncheckedTargetForTesting(
            titleID: "tt0903747",
            contentID: "tt1375666:1:1",
            season: 1,
            episode: 1
        )
        source.refresh(target: forged)
        await Task.yield()
        let forgedCalls = await probe.calls()
        expect(forgedCalls.isEmpty,
               "relationally forged targets launch zero TorBox transport")
        expect(source.streams.isEmpty && source.publishedTarget?.contentID == nil,
               "relationally forged targets publish no TorBox rows")

        let cancellation = CancellationProbe()
        let cancellingSource = TorBoxSearchSource(
            fetchStreams: { _, _ in await cancellation.run() },
            hasKey: { true },
            keyProvider: { "test-key" }
        )
        let cancellableTarget = SourceIndexIdentity.publicationTarget(
            roles(catalog: "tt0903747", defaultVideo: nil, currentVideo: nil),
            season: 1,
            episode: 1
        )
        cancellingSource.refresh(target: cancellableTarget)
        await waitUntil { await cancellation.startedCount() == 1 }
        cancellingSource.refresh(target: mismatch)
        await waitUntil { await cancellation.cancelledCount() == 1 }
        let cancellationCount = await cancellation.cancelledCount()
        expect(cancellationCount == 1,
               "a mismatched refresh cancels the retired TorBox request")

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
        if let targetAValue = targetA.target {
            await probe.release(targetAValue.contentID, streams: [rowA])
        }
        await Task.yield()
        expect(source.streams.isEmpty,
               "delayed title A cannot publish after title B becomes current")

        if let targetBValue = targetB.target {
            await probe.release(targetBValue.contentID, streams: [rowB])
        }
        await waitUntil { source.streams == [rowB] }
        expect(source.publishedTarget?.contentID == targetB.target?.contentID,
               "TorBox publication records the exact fetched target")
        expect(source.merged(into: ordinary, for: targetA).count == ordinary.count,
               "title B rows cannot merge into title A")
        expect(source.merged(into: ordinary, for: targetB).last?.streams == [rowB],
               "rows merge only for their exact publication target")

        let revisitProbe = CacheHitRevisitSearch()
        let revisitSource = TorBoxSearchSource(
            fetchStreams: { target, key in await revisitProbe.run(target: target, apiKey: key) },
            hasKey: { true },
            keyProvider: { "test-key" }
        )
        let targetAContent = targetA.target!.contentID
        let targetBContent = targetB.target!.contentID
        revisitSource.refresh(target: targetB)
        await waitUntil { await revisitProbe.requestIDs(for: targetBContent).count == 1 }
        let cachedBRequest = await revisitProbe.requestIDs(for: targetBContent)[0]
        await revisitProbe.release(cachedBRequest, streams: [rowB])
        await waitUntil { revisitSource.streams == [rowB] }
        revisitSource.refresh(target: targetB)
        await Task.yield()
        let repeatedBCount = await revisitProbe.requestIDs(for: targetBContent).count
        expect(repeatedBCount == 1,
               "repeated TorBox cache hits do not duplicate transport")

        revisitSource.refresh(target: targetA)
        await waitUntil { await revisitProbe.requestIDs(for: targetAContent).count == 1 }
        let oldARequest = await revisitProbe.requestIDs(for: targetAContent)[0]
        revisitSource.refresh(target: targetB)
        await waitUntil { await revisitProbe.cancellationCount() == 1 }
        let ownerAfterCachedReplacement = revisitSource.ownerStateForTesting
        expect(ownerAfterCachedReplacement.inFlightKey == nil
               && !ownerAfterCachedReplacement.hasTask
               && revisitSource.streams == [rowB],
               "cached TorBox replacement cancels A and clears its owner state before publishing B")

        revisitSource.refresh(target: targetA)
        await waitUntil { await revisitProbe.requestIDs(for: targetAContent).count == 2 }
        let freshARequest = await revisitProbe.requestIDs(for: targetAContent)[1]
        let ownerOnFreshA = revisitSource.ownerStateForTesting
        expect(freshARequest != oldARequest
               && ownerOnFreshA.inFlightKey == targetAContent
               && ownerOnFreshA.hasTask,
               "revisiting A after a cached B starts exactly one fresh TorBox request")
        await revisitProbe.release(oldARequest, streams: [CoreStream(name: "late A")])
        for _ in 0..<100 { await Task.yield() }
        expect(revisitSource.streams.isEmpty,
               "late canceled TorBox A cannot publish after A is revisited")
        await revisitProbe.release(freshARequest, streams: [rowA])
        await waitUntil { revisitSource.streams == [rowA] }

        source.refresh(target: mismatch)
        expect(source.streams.isEmpty && source.publishedTarget?.contentID == nil,
               "a later mismatch synchronously clears the previous publication")
        expect(source.merged(into: ordinary, for: mismatch).count == ordinary.count,
               "mismatch preserves the ordinary engine-only groups")

        let episodeZero = SourceIndexIdentity.publicationTarget(
            roles(catalog: "tmdb:94997", defaultVideo: nil,
                  currentVideo: "tt0460649:3:0"),
            season: 3,
            episode: 0
        )
        expect(episodeZero.target?.contentID == "tt0460649:3:0",
               "episode-only IMDb identity and E0 remain queryable")
        expect(SourceIndexIdentity.publicationTarget(
                   roles(catalog: nil, defaultVideo: nil, currentVideo: nil),
                   season: 0, episode: 0) == .absent,
               "nil identity remains absent even with complete zero coordinates")

        // The production two-leg search keeps rows from a completed leg even if its sibling transport fails.
        // `transportError` is therefore reserved for all-empty attempts, which must not poison the cache.
        let partialProbe = OutcomeProbe(result: (streams: [rowA], rateLimited: false, transportError: false))
        let partialSource = TorBoxSearchSource(
            fetchStreams: { _, _ in await partialProbe.run() },
            hasKey: { true }, keyProvider: { "test-key" }
        )
        partialSource.refresh(target: targetA)
        await waitUntil { await partialProbe.count() == 1 && partialSource.streams == [rowA] }
        partialSource.refresh(target: targetA)
        await Task.yield()
        let partialCalls = await partialProbe.count()
        expect(partialCalls == 1 && partialSource.streams == [rowA],
               "a usable primary-leg result survives sibling transport failure and is cached")

        let allTransportProbe = OutcomeProbe(result: (streams: [], rateLimited: false, transportError: true))
        let allTransportSource = TorBoxSearchSource(
            fetchStreams: { _, _ in await allTransportProbe.run() },
            hasKey: { true }, keyProvider: { "test-key" }
        )
        let transportTarget = SourceIndexIdentity.publicationTarget(
            roles(catalog: "tt1375666", defaultVideo: "tt1375666:1:2", currentVideo: "tt1375666:1:2"),
            season: 1, episode: 2
        )
        allTransportSource.refresh(target: transportTarget)
        await waitUntil { await allTransportProbe.count() == 1 && !allTransportSource.ownerStateForTesting.hasTask }
        allTransportSource.refresh(target: transportTarget)
        await waitUntil { await allTransportProbe.count() == 2 && !allTransportSource.ownerStateForTesting.hasTask }
        let allTransportCalls = await allTransportProbe.count()
        expect(allTransportCalls == 2 && allTransportSource.streams.isEmpty,
               "all-primary transport failure is not cached and advances a fresh retry")

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SourcesShared/TorBoxSearchSource.swift")
        let sourceText = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        expect(!sourceText.contains("/v1/api/torrents/search"),
               "the undocumented account-host fallback route is absent")
        expect(sourceText.contains("guard (200...299).contains(code)")
               && sourceText.contains("return ([], false, false)"),
               "non-2xx search responses are unavailable rather than transport-success results")
        expect(sourceText.contains("forHTTPHeaderField: \"Authorization\"")
               && !sourceText.contains("URLQueryItem(name: \"apikey\"")
               && !sourceText.contains("URLQueryItem(name: \"token\""),
               "TorBox API keys stay in the Authorization header, never the URL")

        print("")
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
