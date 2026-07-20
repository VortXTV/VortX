// Standalone executable for the real torrent-only SourceIndexClient contract. VortX has no Xcode unit-test
// bundle, so this compiles the production SourceIndexContract.swift and SourceIndexClient.swift with only the
// surrounding app dependencies stubbed:
//
//   xcrun swiftc -o /tmp/source-index-contract-test \
//     app/SourcesShared/SourceIndexContract.swift \
//     app/SourcesShared/MoatToken.swift \
//     app/SourcesShared/SourceIndexClient.swift \
//     app/Tests/SourceIndexTorrentContractTests.swift && /tmp/source-index-contract-test
//
// This exercises the shipped descriptor, wire encoding, served-row filter, merge, and resume polling logic.

import Foundation

// MARK: - Minimal app dependency stubs

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
    var ytId: String?

    var isYouTubeTrailer: Bool { url == nil && infoHash == nil && !(ytId ?? "").isEmpty }

    init(
        name: String? = nil,
        description: String? = nil,
        infoHash: String? = nil,
        url: String? = nil,
        nzbUrl: String? = nil,
        ytId: String? = nil
    ) {
        self.name = name
        self.description = description
        self.infoHash = infoHash
        self.url = url
        self.nzbUrl = nzbUrl
        self.ytId = ytId
    }
}

struct CoreStreamSourceGroup {
    let id: String
    let addon: String
    let streams: [CoreStream]
}

enum StreamRanking {
    static func sizeForSort(_ stream: CoreStream) -> Double { 0 }
    static func qualityLabel(_ stream: CoreStream) -> String { stream.name ?? "Other" }
    static func seedersForSort(_ stream: CoreStream) -> Int { -1 }
}

enum VortXEdgeAuth { static func sign(_ request: inout URLRequest) {} }
enum VXProbe { static func log(_ channel: String, _ message: String) {} }
enum MoatConsent {
    static let key = "stremiox.moatContribute"
    nonisolated(unsafe) static var contributeAndConsume = true
}

struct RemoteConfigSnapshot {
    func isFeatureOn(_ key: String, default value: Bool) -> Bool { value }
    func endpoint(_ key: String) -> URL? { nil }
}

enum RemoteConfig {
    static let snapshot = RemoteConfigSnapshot()
    static let sourceIndexFeatureDidInstall = Notification.Name("test.sourceIndex.install")
    static let sourceIndexOldValueKey = "old"
    static let sourceIndexNewValueKey = "new"
}
enum RemoteConfigDefaults {
    static let featureSourceIndex = true
    static let endpointSources = "https://sources.vortx.tv"
}

enum Keychain {
    static func string(_ account: String) -> String? { nil }
}

@MainActor
final class VortXSyncManager {
    static let shared = VortXSyncManager()
    var isSignedIn = true
}

actor AttemptProbe {
    private var attempts = 0
    func record() { attempts += 1 }
    func count() -> Int { attempts }
}

final class LockedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Bool

    init(_ open: Bool) { self.open = open }

    func value() -> Bool { lock.withLock { open } }
    func close() { lock.withLock { open = false } }
    func reopen() { lock.withLock { open = true } }
}

final class SequencedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(_ values: [Bool]) { self.values = values }

    func value() -> Bool {
        lock.withLock {
            guard values.count > 1 else { return values.first ?? false }
            return values.removeFirst()
        }
    }
}

enum SequenceFetchError: Error { case failed }

actor SourceFetchSequence {
    enum Step: Sendable {
        case rows([SourceIndexClient.PooledSource])
        case failure
    }

    private var steps: [Step]
    private var calls = 0

    init(_ steps: [Step]) { self.steps = steps }

    func next() throws -> [SourceIndexClient.PooledSource] {
        calls += 1
        guard !steps.isEmpty else { return [] }
        switch steps.removeFirst() {
        case let .rows(rows): return rows
        case .failure: throw SequenceFetchError.failed
        }
    }

    func callCount() -> Int { calls }
}

actor ReleasableFetch {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private let result: [SourceIndexClient.PooledSource]

    init(result: [SourceIndexClient.PooledSource]) { self.result = result }

    func run() async -> [SourceIndexClient.PooledSource] {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return result
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func callCount() -> Int { calls }
}

actor CancellableFetch {
    private var calls = 0
    private var cancellations = 0

    func run() async throws -> [SourceIndexClient.PooledSource] {
        calls += 1
        do {
            try await Task<Never, Never>.sleep(nanoseconds: 60_000_000_000)
            return []
        } catch {
            cancellations += 1
            throw error
        }
    }

    func counts() -> (calls: Int, cancellations: Int) { (calls, cancellations) }
}

actor IndexedReleasableFetch {
    private var calls = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private let results: [[SourceIndexClient.PooledSource]]

    init(results: [[SourceIndexClient.PooledSource]]) { self.results = results }

    func run() async -> [SourceIndexClient.PooledSource] {
        calls += 1
        let call = calls
        await withCheckedContinuation { continuations[call] = $0 }
        return results.indices.contains(call - 1) ? results[call - 1] : []
    }

    func release(_ call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }

    func callCount() -> Int { calls }
}

actor DelayedLifecycleCancel {
    private let coalescer: SourceIndexFetchCoalescer
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var started = 0
    private var completed = 0

    init(coalescer: SourceIndexFetchCoalescer) { self.coalescer = coalescer }

    func cancel(upTo cutoff: UInt64) async {
        started += 1
        await withCheckedContinuation { waiting.append($0) }
        await coalescer.cancel(upToSourceGeneration: cutoff)
        completed += 1
    }

    func releaseNext() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }

    func releaseAll() {
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func counts() -> (started: Int, completed: Int) { (started, completed) }
}

final class MoatCredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var credential: MoatToken.Credential?

    init(_ credential: MoatToken.Credential?) { self.credential = credential }
    func value() -> MoatToken.Credential? { lock.withLock { credential } }
    func set(_ credential: MoatToken.Credential?) { lock.withLock { self.credential = credential } }
}

actor ScopedMintProbe {
    private var calls: [String] = []
    private var releaseA: CheckedContinuation<Void, Never>?

    func mint(_ bearer: String) async -> MoatToken.Minted? {
        calls.append(bearer)
        if bearer == "bearer-A" {
            await withCheckedContinuation { releaseA = $0 }
        }
        return MoatToken.Minted(
            token: "moat-" + bearer,
            expiresAt: Date().addingTimeInterval(600)
        )
    }

    func releaseAccountA() {
        releaseA?.resume()
        releaseA = nil
    }

    func callCount(_ bearer: String) -> Int { calls.filter { $0 == bearer }.count }
}

actor ControlledMintProbe {
    private var bearers: [String] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func mint(_ bearer: String) async -> MoatToken.Minted? {
        bearers.append(bearer)
        let call = bearers.count
        await withCheckedContinuation { continuations[call] = $0 }
        return MoatToken.Minted(
            token: "controlled-moat-\(call)",
            expiresAt: Date().addingTimeInterval(600)
        )
    }

    func release(_ call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }

    func callCount() -> Int { bearers.count }
}

actor DelayedMoatClear {
    private let moat: MoatToken
    private var values: [(UInt64?, UInt64?)] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var completed = 0

    init(moat: MoatToken) { self.moat = moat }

    func clear(session: UInt64?, consent: UInt64?) async {
        values.append((session, consent))
        await withCheckedContinuation { continuations.append($0) }
        await moat.clear(
            retiredSessionGeneration: session,
            retiredConsentGeneration: consent
        )
        completed += 1
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func snapshot() -> (values: [(UInt64?, UInt64?)], completed: Int) {
        (values, completed)
    }
}

actor LifecycleCleanupProbe {
    private var cancellationCutoffs: [UInt64] = []
    private var moatCutoffs: [(UInt64?, UInt64?)] = []

    func cancel(_ cutoff: UInt64) { cancellationCutoffs.append(cutoff) }
    func clearMoat(session: UInt64?, consent: UInt64?) { moatCutoffs.append((session, consent)) }
    func counts() -> (cancels: Int, moatClears: Int) {
        (cancellationCutoffs.count, moatCutoffs.count)
    }

    func moatValues() -> [(UInt64?, UInt64?)] { moatCutoffs }
}

enum LifecycleCloseChannel: Equatable {
    case consent
    case serve
    case fleet
}

struct LifecycleReopenResult {
    let initialPublished: Bool
    let immediateBlank: Bool
    let freshSurvivedDelayedCancel: Bool
    let freshPublished: Bool
    let cancelCount: Int
    let moatValues: [(UInt64?, UInt64?)]
    let closeGenerationAdvanced: Bool
    let reopenGenerationAdvanced: Bool
    let fleetGateClosedBeforeTransition: Bool
}

@MainActor
final class LifecycleParticipantProbe: SourceIndexLifecycleParticipant {
    private(set) var closeCount = 0
    private(set) var publishedRows = 1

    func sourceIndexLifecycleDidClose(retiredSourceGeneration _: UInt64) {
        closeCount += 1
        publishedRows = 0
    }
}

final class RedirectProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var originalHits = 0
    nonisolated(unsafe) private static var targetHits = 0

    static func reset() {
        lock.withLock {
            originalHits = 0
            targetHits = 0
        }
    }

    static func counts() -> (original: Int, target: Int) {
        lock.withLock { (originalHits, targetHits) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "redirect.test" || request.url?.host == "redirect-target.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path.hasPrefix("/target") {
            Self.lock.withLock { Self.targetHits += 1 }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        Self.lock.withLock { Self.originalHits += 1 }
        let status = Int(url.path.split(separator: "-").last ?? "") ?? 302
        let targetHost = url.path.contains("cross") ? "redirect-target.test" : "redirect.test"
        let target = URL(string: "https://\(targetHost)/target-\(status)")!
        var redirected = request
        redirected.url = target
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString, "Content-Length": "0"]
        )!
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RedirectDelegateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int] = []

    func record(_ status: Int) { lock.withLock { statuses.append(status) } }
    func values() -> [Int] { lock.withLock { statuses } }
}

// MARK: - Assertions

@main
struct SourceIndexTorrentContractTests {
    @MainActor
    static var failures = 0

    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    static func launchedDescriptors(
        _ decision: SourceUploadCoordinator.LaunchDecision
    ) -> [SourceIndexClient.Descriptor] {
        guard case let .launch(descriptors) = decision else { return [] }
        return descriptors
    }

    static func waitDelay(_ decision: SourceUploadCoordinator.LaunchDecision) -> UInt64? {
        guard case let .wait(delay) = decision else { return nil }
        return delay
    }

    static func isUnavailable(_ decision: SourceUploadCoordinator.LaunchDecision) -> Bool {
        guard case .unavailable = decision else { return false }
        return true
    }

    @MainActor
    static func exerciseLifecycleReopen(
        channel: LifecycleCloseChannel,
        initial: SourceIndexClient.PooledSource,
        fresh: SourceIndexClient.PooledSource
    ) async -> LifecycleReopenResult {
        let gate = LockedGate(true)
        let coalescer = SourceIndexFetchCoalescer()
        let fetch = IndexedReleasableFetch(results: [[initial], [initial], [fresh]])
        let delayedCancel = DelayedLifecycleCancel(coalescer: coalescer)
        let cleanup = LifecycleCleanupProbe()
        let scope = SourceIndexLifecycleScope(
            observeMutations: false,
            gateStateProvider: {
                SourceIndexPreferenceGateState(consent: true, serve: true, fleet: true)
            },
            cancelShared: { cutoff in await delayedCancel.cancel(upTo: cutoff) },
            clearMoat: { session, consent in
                await cleanup.clearMoat(session: session, consent: consent)
            }
        )
        let source = SourceIndexServeSource(
            fetchPooled: { _, _ in await fetch.run() },
            serveGate: { gate.value() },
            coalescer: coalescer
        )
        scope.register(source)

        source.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if await fetch.callCount() == 1 { break }
            await Task.yield()
        }
        await fetch.release(1)
        for _ in 0..<1_000 {
            if source.streams.first?.infoHash == initial.id { break }
            await Task.yield()
        }
        let initialPublished = source.streams.first?.infoHash == initial.id

        source.refresh(contentID: "tt7654321", isSignedIn: true)
        for _ in 0..<1_000 {
            if await fetch.callCount() == 2 { break }
            await Task.yield()
        }

        let beforeClose = SourceIndexLifecycleClock.snapshot()
        var fleetGateClosedBeforeTransition = true
        switch channel {
        case .consent:
            scope.preferencesWillApply(consent: false)
        case .serve:
            scope.preferencesWillApply(serve: false)
        case .fleet:
            // Production installs the false RemoteConfig snapshot first, then retires the generation on the
            // installing thread, and only then posts the UI-clear event.
            gate.close()
            fleetGateClosedBeforeTransition = !gate.value()
            let transition = SourceIndexLifecycleClock.closeSource()
            scope.remoteConfigDidInstall(oldFleet: true, newFleet: false, transition: transition)
        }
        if channel != .fleet { gate.close() }
        let afterClose = SourceIndexLifecycleClock.snapshot()
        let immediateBlank = source.streams.isEmpty

        switch channel {
        case .consent:
            scope.preferencesWillApply(consent: true)
        case .serve:
            scope.preferencesWillApply(serve: true)
        case .fleet:
            scope.remoteConfigDidInstall(oldFleet: false, newFleet: true, transition: nil)
        }
        let afterReopen = SourceIndexLifecycleClock.snapshot()
        gate.reopen()
        source.refresh(contentID: "tt7654321", isSignedIn: true)
        for _ in 0..<1_000 {
            if await fetch.callCount() == 3 { break }
            await Task.yield()
        }
        let expectedCleanups = channel == .consent || channel == .serve ? 2 : 1
        for _ in 0..<1_000 {
            if await delayedCancel.counts().started == expectedCleanups { break }
            await Task.yield()
        }

        await delayedCancel.releaseAll()
        for _ in 0..<1_000 {
            if await delayedCancel.counts().completed == expectedCleanups { break }
            await Task.yield()
        }
        let freshSurvivedDelayedCancel = await coalescer.activeCount() == 1
        await fetch.release(3)
        for _ in 0..<1_000 {
            if source.streams.first?.infoHash == fresh.id,
               await coalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        let freshPublished = source.streams.first?.infoHash == fresh.id
        await fetch.release(2)
        for _ in 0..<1_000 {
            if await cleanup.counts().moatClears == (channel == .consent ? 2 : 0) { break }
            await Task.yield()
        }
        let cancelCount = await delayedCancel.counts().completed
        let moatValues = await cleanup.moatValues()
        return LifecycleReopenResult(
            initialPublished: initialPublished,
            immediateBlank: immediateBlank,
            freshSurvivedDelayedCancel: freshSurvivedDelayedCancel,
            freshPublished: freshPublished,
            cancelCount: cancelCount,
            moatValues: moatValues,
            closeGenerationAdvanced: afterClose.sourceGeneration == beforeClose.sourceGeneration + 1,
            reopenGenerationAdvanced: afterReopen.sourceGeneration == afterClose.sourceGeneration + 1,
            fleetGateClosedBeforeTransition: fleetGateClosedBeforeTransition
        )
    }

    static func getStatus(
        transport: SourceIndexHTTPTransport,
        request: URLRequest
    ) async -> Int? {
        guard let (_, response) = try? await transport.boundedGetResponse(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    static func postStatus(
        transport: SourceIndexHTTPTransport,
        request: URLRequest
    ) async -> Int? {
        do {
            try await transport.discardResponse(for: request)
            return nil
        } catch let SourceIndexTransportError.badStatus(status) {
            return status
        } catch {
            return nil
        }
    }

    @MainActor
    static func main() async {
        let lower = "abcdef0123456789abcdef0123456789abcdef01"
        let upper = lower.uppercased()
        let privateURL = "https://debrid.example/file?token=private-token"
        let privateNZB = "https://indexer.example/file.nzb?apikey=private-key"

        expect(SourceIndexContract.normalizeInfoHash(upper) == lower,
               "contribution identity normalizes uppercase 40-hex")
        expect(SourceIndexContract.normalizeInfoHash("a".repeating(39)) == nil,
               "39-character identity is rejected")
        expect(SourceIndexContract.normalizeInfoHash("a".repeating(41)) == nil,
               "41-character identity is rejected")
        expect(SourceIndexContract.normalizeInfoHash("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567") == nil,
               "base32 identity is rejected")
        expect(SourceIndexContract.normalizeInfoHash("g".repeating(40)) == nil,
               "non-hex identity is rejected")
        expect(SourceIndexContract.canonicalStoredInfoHash(upper) == nil,
               "served uppercase identity fails closed")
        expect(SourceIndexClient.contentID(imdbId: "tt1234567", season: 1, episode: 2) == "tt1234567:1:2",
               "canonical title identity is built")
        expect(SourceIndexClient.contentID(imdbId: "tt12345678901") == nil,
               "overlong title identity is rejected")
        expect(SourceIndexClient.contentID(imdbId: "user@example.com") == nil,
               "user-shaped content identity is rejected")
        expect(SourceIndexContract.canonicalContentID("tt١٢٣٤٥٦") == nil,
               "Unicode-digit title identity is rejected")
        expect(SourceIndexClient.serveURL(contentID: "user@example.com") == nil,
               "serve boundary rejects a user-shaped title before request construction")
        expect(SourceIndexClient.serveURL(contentID: "tt1234567:1") == nil,
               "serve boundary rejects an incomplete episodic title")
        expect(SourceIndexClient.serveURL(contentID: "tmdb:123:1:2")?.absoluteString.contains("kind=torrent") == true,
               "serve boundary builds only the torrent query for a canonical TMDB episode")
        let exactOrigin = "https://sources.vortx.tv"
        let hostileOrigins = [
            "http://sources.vortx.tv",
            "HTTPS://sources.vortx.tv",
            "https://SOURCES.vortx.tv",
            "https://vortx.tv",
            "https://evil.vortx.tv",
            "https://sources.vortx.tv.evil.test",
            "https://evil.test/sources.vortx.tv",
            "https://user@sources.vortx.tv",
            "https://user:pass@sources.vortx.tv",
            "https://user%40evil.test@sources.vortx.tv",
            "https://sources.vortx.tv:443",
            "https://sources.vortx.tv:8443",
            "https://sources.vortx.tv/sources",
            "https://sources.vortx.tv//",
            "https://sources.vortx.tv?next=https://evil.test",
            "https://sources.vortx.tv#fragment",
        ]
        expect(SourceIndexClient.normalizedBaseURL(override: URL(string: exactOrigin + "/")).absoluteString == exactOrigin,
               "exact source-index root normalizes to the baked origin")
        expect(hostileOrigins.allSatisfy {
            SourceIndexClient.normalizedBaseURL(override: URL(string: $0)).absoluteString == exactOrigin
        }, "hostile source-index overrides fall back to the baked exact origin")
        expect(SourceIndexClient.batchSize == 16,
               "Apple batches match the worker's 49-statement D1-safe maximum")

        RedirectProbeURLProtocol.reset()
        let redirectConfiguration = URLSessionConfiguration.ephemeral
        redirectConfiguration.protocolClasses = [RedirectProbeURLProtocol.self]
        let redirectDelegateProbe = RedirectDelegateProbe()
        let redirectTransport = SourceIndexHTTPTransport(
            configuration: redirectConfiguration,
            redirectObserver: { redirectDelegateProbe.record($0) }
        )
        let redirectCodes = [301, 302, 303, 307, 308]
        var getRedirectStatuses: [Int] = []
        var postRedirectStatuses: [Int] = []
        for status in redirectCodes {
            let get = await getStatus(
                transport: redirectTransport,
                request: URLRequest(url: URL(string: "https://redirect.test/same-\(status)")!)
            )
            if let get { getRedirectStatuses.append(get) }

            var post = URLRequest(url: URL(string: "https://redirect.test/cross-\(status)")!)
            post.httpMethod = "POST"
            post.httpBody = Data("signed-body".utf8)
            post.setValue("private-moat", forHTTPHeaderField: "X-VX-Moat")
            post.setValue("private-signature", forHTTPHeaderField: "X-VX-Sig")
            if let status = await postStatus(transport: redirectTransport, request: post) {
                postRedirectStatuses.append(status)
            }
        }
        let redirectHits = RedirectProbeURLProtocol.counts()
        let delegatedRedirects = redirectDelegateProbe.values()
        expect(getRedirectStatuses == redirectCodes && postRedirectStatuses == redirectCodes,
               "one real URLSession surfaces every refused redirect class for GET and POST")
        expect(delegatedRedirects == redirectCodes.flatMap { [$0, $0] },
               "the no-redirect task delegate refuses every real URLSession redirect callback")
        expect(redirectHits.original == redirectCodes.count * 2 && redirectHits.target == 0,
               "all same-host and cross-host redirect targets receive no signed GET or POST")

        let responseCap = SourceIndexContract.maxResponseBodyBytes
        let exactResponse = Data(repeating: 0x61, count: responseCap)
        var capCancellationCount = 0
        var declaredOversizeReads = 0
        expect(SourceIndexContract.boundedResponseData(
            chunks: [exactResponse], contentLength: String(responseCap)
        )?.count == responseCap, "exact 64 KiB response body is accepted")
        expect(SourceIndexContract.boundedResponseData(
            chunks: [exactResponse, Data([0x62])],
            contentLength: "1",
            cancel: { capCancellationCount += 1 }
        ) == nil && capCancellationCount == 1,
               "dishonest Content-Length is caught at cap plus one and explicitly canceled")
        expect(SourceIndexContract.boundedResponseData(
            chunks: [Data([0x61])],
            contentLength: String(responseCap + 1),
            didRead: { declaredOversizeReads += 1 },
            cancel: { capCancellationCount += 1 }
        ) == nil && declaredOversizeReads == 0 && capCancellationCount == 2,
               "declared oversize response cancels before reading any body")
        expect(SourceIndexContract.boundedResponseData(
            chunks: [Data("{}".utf8)], contentLength: nil
        ) == Data("{}".utf8), "missing Content-Length still uses the actual-byte cap")
        expect(SourceIndexContract.boundedResponseData(
            chunks: [Data()], contentLength: "1, 2"
        ) == nil, "malformed or conflicting Content-Length fails closed")
        expect(SourceIndexClient.pooledSources(fromResponseData: Data("{not-json".utf8)).isEmpty,
               "malformed bounded JSON yields an empty source result")
        var discardedReads = 0
        var discardCancellations = 0
        expect(!SourceIndexContract.discardResponseBody(
            bytes: Array(repeating: 0x61, count: 1_024),
            contentLength: nil,
            didRead: { discardedReads += 1 },
            cancel: { discardCancellations += 1 }
        ) && discardedReads == SourceIndexContract.postResponseDrainBytes
          && discardCancellations == 1,
               "POST sink buffers nothing, drains at most 512 bytes, then cancels an oversized response")
        discardedReads = 0
        discardCancellations = 0
        expect(!SourceIndexContract.discardResponseBody(
            bytes: [0x61],
            contentLength: "513",
            didRead: { discardedReads += 1 },
            cancel: { discardCancellations += 1 }
        ) && discardedReads == 0 && discardCancellations == 1,
               "declared oversized POST response cancels before draining")

        let launchProbe = AttemptProbe()
        let canceledParent = Task {
            while !Task.isCancelled { await Task.yield() }
            return await SourceIndexClient.runCancellationIndependentAttempt {
                await launchProbe.record()
            }
        }
        canceledParent.cancel()
        let canceledParentSucceeded = await canceledParent.value
        let cancellationIndependentAttempts = await launchProbe.count()
        expect(canceledParentSucceeded && cancellationIndependentAttempts == 1,
               "parent cancellation after commit still launches exactly one detached attempt")

        let mixed = CoreStreamSourceGroup(
            id: "raw",
            addon: "Provider secret",
            streams: [
                CoreStream(name: "1080p", infoHash: upper, url: privateURL),
                CoreStream(name: "1080p", infoHash: lower),
                CoreStream(name: "1080p", url: privateURL),
                CoreStream(name: "1080p", nzbUrl: privateNZB),
                CoreStream(name: "1080p", infoHash: "a".repeating(39)),
            ]
        )
        let descriptors = SourceIndexClient.descriptors(from: [mixed])
        expect(descriptors.count == 1 && descriptors.first?.id == lower,
               "mixed-case duplicates collapse to one normalized torrent descriptor")

        let crafted: [SourceIndexClient.Descriptor] = [
            .init(kind: "torrent", id: upper, quality: privateURL, sizeBytes: -1, seeders: 1_000_001),
        ] + descriptors + [
            .init(kind: "direct", id: privateURL, quality: "4K", sizeBytes: 1, seeders: nil),
            .init(kind: "direct", id: upper, quality: "4K", sizeBytes: 1, seeders: nil),
            .init(kind: "torrent", id: privateNZB, quality: "4K", sizeBytes: 1, seeders: nil),
            .init(kind: "torrent", id: upper, quality: "1080p", sizeBytes: 0, seeders: nil),
        ]
        let uploadable = SourceIndexClient.uploadableDescriptors(crafted)
        expect(uploadable.count == 1 && uploadable.first?.kind == "torrent" && uploadable.first?.id == lower,
               "upload boundary rejects non-torrent values and deduplicates normalized hashes")
        expect(uploadable.first?.quality == "Other" && uploadable.first?.sizeBytes == 0
               && uploadable.first?.seeders == nil,
               "upload boundary closes quality and numeric metadata")

        let seventeen = (0..<17).map { index in
            SourceIndexClient.Descriptor(
                kind: "torrent",
                id: String(format: "%040x", index),
                quality: "Other",
                sizeBytes: 0,
                seeders: nil
            )
        }
        let workerSizedBatches = SourceIndexClient.uploadBatches(seventeen)
        expect(workerSizedBatches.map(\.count) == [16, 1],
               "17 canonical descriptors split into worker-safe 16 and 1 batches")
        expect(SourceIndexClient.contributionBody(
            contentID: "tt1234567", descriptors: Array(seventeen.prefix(16))
        ) != nil, "16-descriptor contribution body is accepted")
        expect(SourceIndexClient.contributionBody(
            contentID: "tt1234567", descriptors: seventeen
        ) == nil, "17-descriptor contribution body fails closed instead of relying on caller chunking")

        let encoded = SourceIndexClient.contributionBody(contentID: "tt1234567", descriptors: crafted) ?? Data()
        let wire = String(data: encoded, encoding: .utf8) ?? ""
        expect(wire.contains(lower), "wire body contains the canonical infohash")
        expect(!wire.contains(privateURL) && !wire.contains(privateNZB),
               "URL and NZB values never enter the descriptor wire body")
        expect(!wire.contains("sourceTag") && !wire.contains("Provider secret"),
               "provider metadata never enters the descriptor wire body")
        expect(!wire.contains("private-token"), "secret-shaped quality never enters the wire body")
        expect(SourceIndexClient.contributionBody(contentID: "user@example.com", descriptors: crafted) == nil,
               "user-shaped content identity never reaches the wire encoder")
        expect(SourceIndexClient.contributionBody(
            contentID: "tt1234567",
            descriptors: [.init(kind: "direct", id: privateURL, quality: "4K", sizeBytes: 1, seeders: nil)]
        ) == nil, "post-filter empty contribution never encodes a request")

        let secondHash = "b".repeating(40)
        let thirdHash = "c".repeating(40)
        let fourthHash = "d".repeating(40)
        let trusted = SourceIndexClient.PooledSource(
            kind: "torrent", id: lower, quality: privateURL, sizeBytes: 9_007_199_254_740_991,
            seeders: 1_000_000, corroboration: 2
        )
        let served = SourceIndexClient.streams(from: [
            trusted,
            .init(kind: "torrent", id: secondHash, quality: "4K", sizeBytes: 1,
                  seeders: 1, corroboration: nil),
            .init(kind: "torrent", id: thirdHash, quality: "4K", sizeBytes: 1,
                  seeders: 1, corroboration: 0),
            .init(kind: "torrent", id: fourthHash, quality: "4K", sizeBytes: 1,
                  seeders: 1, corroboration: 1),
            .init(kind: "torrent", id: upper, quality: "1080p", sizeBytes: 0,
                  seeders: nil, corroboration: 2),
            .init(kind: "direct", id: privateURL, quality: "1080p", sizeBytes: 0,
                  seeders: nil, corroboration: 2),
            .init(kind: "usenet", id: privateNZB, quality: "1080p", sizeBytes: 0,
                  seeders: nil, corroboration: 2),
        ])
        expect(served.count == 1 && served.first?.infoHash == lower,
               "serve reconstruction requires two witnesses and drops non-torrent or noncanonical rows")
        expect(served.first?.url == nil && served.first?.nzbUrl == nil,
               "served torrent has no URL or NZB payload")
        expect(served.first?.name == "Other · Singularity"
               && served.first?.description == "Singularity source"
               && !(served.first?.name ?? "").contains(privateURL),
               "served presentation ignores malicious response quality size and seeder metadata")
        expect(SourceIndexClient.streams(from: Array(repeating: trusted, count: 101)).count == 100,
               "direct reconstruction cannot exceed the worker's 100-row serve maximum")

        let encodedRows = (0..<101).map { _ in
            ["kind": "torrent", "id": lower, "quality": "Other", "sizeBytes": 0,
             "seeders": 0, "corroboration": 2] as [String: Any]
        }
        let encodedResponse = try? JSONSerialization.data(withJSONObject: ["sources": encodedRows])
        expect(encodedResponse.map(SourceIndexClient.pooledSources(fromResponseData:))?.count == 100,
               "bounded response decoding caps accepted source rows at 100")
        expect(encodedResponse.map {
            SourceIndexClient.pooledSources(statusCode: 503, fromResponseData: $0)
        }?.isEmpty == true, "GET 503 fails soft to local fallback without publishing pooled rows")

        let tokenWaitGate = LockedGate(true)
        let tokenWaitTransport = AttemptProbe()
        let tokenWaitResult = await SourceIndexClient.fetchPooledUsing(
            contentID: "tt1234567",
            isSignedIn: true,
            gate: { tokenWaitGate.value() },
            moatProvider: {
                tokenWaitGate.close()
                return "current-moat"
            },
            transport: { request in
                await tokenWaitTransport.record()
                return (
                    Data("{\"sources\":[]}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        let tokenWaitTransportCount = await tokenWaitTransport.count()
        expect(tokenWaitResult.isEmpty && tokenWaitTransportCount == 0,
               "GET gate closing during moat wait performs no transport")

        let preTransportGate = SequencedGate([true, true, false])
        let preTransportProbe = AttemptProbe()
        let preTransportResult = await SourceIndexClient.fetchPooledUsing(
            contentID: "tt1234567",
            isSignedIn: true,
            gate: { preTransportGate.value() },
            moatProvider: { "current-moat" },
            transport: { request in
                await preTransportProbe.record()
                return (
                    Data("{\"sources\":[]}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        let preTransportCount = await preTransportProbe.count()
        expect(preTransportResult.isEmpty && preTransportCount == 0,
               "GET rechecks its live gate immediately before transport")

        let missingMoatTransport = AttemptProbe()
        let missingMoat = await SourceIndexClient.fetchPooledUsing(
            contentID: "tt1234567",
            isSignedIn: true,
            gate: { true },
            moatProvider: { nil },
            transport: { request in
                await missingMoatTransport.record()
                return (
                    Data("{\"sources\":[]}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        let missingMoatTransportCount = await missingMoatTransport.count()
        expect(missingMoat.isEmpty && missingMoatTransportCount == 0,
               "GET requires current moat auth evidence before transport")

        let postResponseGate = SequencedGate([true, true, true, false])
        let postResponseTransport = AttemptProbe()
        let postResponseResult = await SourceIndexClient.fetchPooledUsing(
            contentID: "tt1234567",
            isSignedIn: true,
            gate: { postResponseGate.value() },
            moatProvider: { "current-moat" },
            transport: { request in
                await postResponseTransport.record()
                return (
                    Data("{\"sources\":[{\"kind\":\"torrent\",\"id\":\"\(lower)\",\"corroboration\":2}]}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        let postResponseTransportCount = await postResponseTransport.count()
        expect(postResponseResult.isEmpty && postResponseTransportCount == 1,
               "GET gate closing after response prevents decoded rows from escaping")

        let merged = SourceIndexServeSource.merge(
            served + [CoreStream(name: "direct", url: privateURL), CoreStream(name: "nzb", nzbUrl: privateNZB)],
            into: []
        )
        expect(merged.count == 1 && merged.first?.streams.count == 1,
               "merge admits only canonical torrent streams")

        let rotated = SourceIndexClient.PooledSource(
            kind: "torrent", id: secondHash, quality: "Other", sizeBytes: 0,
            seeders: 0, corroboration: 2
        )
        let lifecycleGate = LockedGate(true)
        let lifecycleCoalescer = SourceIndexFetchCoalescer()
        let lifecycleSequence = SourceFetchSequence([
            .rows([trusted]),
            .rows([]),
            .failure,
            .rows([rotated]),
        ])
        let lifecycleFetch: SourceIndexServeSource.FetchPooled = { _, _ in
            try await lifecycleSequence.next()
        }

        var priorSource: SourceIndexServeSource? = SourceIndexServeSource(
            fetchPooled: lifecycleFetch,
            serveGate: { lifecycleGate.value() },
            coalescer: lifecycleCoalescer
        )
        priorSource?.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if priorSource?.streams.first?.infoHash == lower,
               await lifecycleCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(priorSource?.streams.map(\.infoHash) == [lower],
               "a completed nonempty serve result publishes only to its live source instance")
        weak let releasedPriorSource = priorSource
        priorSource = nil
        for _ in 0..<100 where releasedPriorSource != nil { await Task.yield() }
        expect(releasedPriorSource == nil, "completed source instance is released without a retained result bank")

        let emptySource = SourceIndexServeSource(
            fetchPooled: lifecycleFetch,
            serveGate: { lifecycleGate.value() },
            coalescer: lifecycleCoalescer
        )
        emptySource.refresh(contentID: "tt1234567", isSignedIn: true)
        expect(emptySource.streams.isEmpty, "recreated source never warm-paints a prior completed result")
        for _ in 0..<1_000 {
            if await lifecycleSequence.callCount() >= 2,
               await lifecycleCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(emptySource.streams.isEmpty, "fresh empty response replaces prior nonempty lifecycle state")

        let failedSource = SourceIndexServeSource(
            fetchPooled: lifecycleFetch,
            serveGate: { lifecycleGate.value() },
            coalescer: lifecycleCoalescer
        )
        failedSource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if await lifecycleSequence.callCount() >= 3,
               await lifecycleCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(failedSource.streams.isEmpty, "fresh failed response cannot revive prior completed rows")

        let rotatedSource = SourceIndexServeSource(
            fetchPooled: lifecycleFetch,
            serveGate: { lifecycleGate.value() },
            coalescer: lifecycleCoalescer
        )
        rotatedSource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if rotatedSource.streams.first?.infoHash == secondHash,
               await lifecycleCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(rotatedSource.streams.map(\.infoHash) == [secondHash],
               "fresh rotation publishes only the new response without prior-row carryover")
        lifecycleGate.close()
        rotatedSource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if await lifecycleCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(rotatedSource.streams.isEmpty, "serve gate closure clears all published rows")

        let identitySequence = SourceFetchSequence([
            .rows([trusted]),
            .failure,
            .rows([trusted]),
        ])
        let identityCoalescer = SourceIndexFetchCoalescer()
        let identitySource = SourceIndexServeSource(
            fetchPooled: { _, _ in try await identitySequence.next() },
            serveGate: { true },
            coalescer: identityCoalescer
        )
        identitySource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if identitySource.streams.first?.infoHash == lower { break }
            await Task.yield()
        }
        identitySource.refresh(contentID: "tt7654321", isSignedIn: true)
        let accountBBlankedImmediately = identitySource.streams.isEmpty
        for _ in 0..<1_000 {
            if await identitySequence.callCount() == 2,
               await identityCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(accountBBlankedImmediately && identitySource.streams.isEmpty,
               "identity A to B clears A immediately and a failed B fetch stays empty")
        identitySource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if identitySource.streams.first?.infoHash == lower { break }
            await Task.yield()
        }
        identitySource.refresh(contentID: nil, isSignedIn: true)
        expect(identitySource.streams.isEmpty,
               "identity A to nil clears every previously published row synchronously")

        let lateIdentityFetch = IndexedReleasableFetch(results: [[trusted], [rotated]])
        let lateIdentityCoalescer = SourceIndexFetchCoalescer()
        let lateIdentitySource = SourceIndexServeSource(
            fetchPooled: { _, _ in await lateIdentityFetch.run() },
            serveGate: { true },
            coalescer: lateIdentityCoalescer
        )
        lateIdentitySource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if await lateIdentityFetch.callCount() == 1 { break }
            await Task.yield()
        }
        lateIdentitySource.refresh(contentID: "tt7654321", isSignedIn: true)
        for _ in 0..<1_000 {
            if await lateIdentityFetch.callCount() == 2 { break }
            await Task.yield()
        }
        await lateIdentityFetch.release(2)
        for _ in 0..<1_000 {
            if lateIdentitySource.streams.first?.infoHash == secondHash { break }
            await Task.yield()
        }
        await lateIdentityFetch.release(1)
        for _ in 0..<1_000 {
            if await lateIdentityCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(lateIdentitySource.streams.map(\.infoHash) == [secondHash],
               "late identity-A completion cannot overwrite identity-B rows")

        let liveAccountGate = LockedGate(true)
        let accountFenceFetch = IndexedReleasableFetch(results: [[trusted]])
        let accountFenceCoalescer = SourceIndexFetchCoalescer()
        let accountFenceSource = SourceIndexServeSource(
            fetchPooled: { _, _ in await accountFenceFetch.run() },
            serveGate: { true },
            accountGate: { liveAccountGate.value() },
            coalescer: accountFenceCoalescer
        )
        accountFenceSource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if await accountFenceFetch.callCount() == 1 { break }
            await Task.yield()
        }
        liveAccountGate.close()
        await accountFenceFetch.release(1)
        for _ in 0..<1_000 {
            if await accountFenceCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(accountFenceSource.streams.isEmpty,
               "live account closure before final publish cannot expose fetched rows")

        let waiterCoalescer = SourceIndexFetchCoalescer()
        let waiterFetch = ReleasableFetch(result: [trusted])
        let waiterA = Task {
            await waiterCoalescer.fetch(contentID: "tt1234567", isSignedIn: true) {
                await waiterFetch.run()
            }
        }
        for _ in 0..<1_000 {
            if await waiterFetch.callCount() == 1 { break }
            await Task.yield()
        }
        let waiterB = Task {
            await waiterCoalescer.fetch(contentID: "tt1234567", isSignedIn: true) {
                await waiterFetch.run()
            }
        }
        for _ in 0..<100 { await Task.yield() }
        let waiterCallsBeforeRelease = await waiterFetch.callCount()
        let waiterActiveBeforeRelease = await waiterCoalescer.activeCount()
        await waiterFetch.release()
        let waiterResults = await [waiterA.value, waiterB.value]
        let waiterActiveAfterDelivery = await waiterCoalescer.activeCount()
        expect(waiterCallsBeforeRelease == 1 && waiterActiveBeforeRelease == 1
               && waiterResults.allSatisfy { $0.map(\.id) == [lower] },
               "concurrent in-flight waiters share one request and identical response semantics")
        expect(waiterActiveAfterDelivery == 0,
               "in-flight coalescing map is empty before completed waiters resume")

        let replacementCoalescer = SourceIndexFetchCoalescer()
        let replacementFetch = ReleasableFetch(result: [trusted])
        var replacedSource: SourceIndexServeSource? = SourceIndexServeSource(
            fetchPooled: { _, _ in await replacementFetch.run() },
            serveGate: { true },
            coalescer: replacementCoalescer
        )
        replacedSource?.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if await replacementFetch.callCount() == 1 { break }
            await Task.yield()
        }
        replacedSource?.clearResults()
        replacedSource = nil
        let replacementSource = SourceIndexServeSource(
            fetchPooled: { _, _ in await replacementFetch.run() },
            serveGate: { true },
            coalescer: replacementCoalescer
        )
        replacementSource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<100 { await Task.yield() }
        let replacementCallsBeforeRelease = await replacementFetch.callCount()
        await replacementFetch.release()
        for _ in 0..<1_000 {
            if replacementSource.streams.first?.infoHash == lower,
               await replacementCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(replacementCallsBeforeRelease == 1 && replacementSource.streams.map(\.infoHash) == [lower],
               "ordinary view replacement retains only active in-flight coalescing")

        let closingGate = LockedGate(true)
        let closingCoalescer = SourceIndexFetchCoalescer()
        let closingFetch = CancellableFetch()
        let closingSource = SourceIndexServeSource(
            fetchPooled: { _, _ in try await closingFetch.run() },
            serveGate: { closingGate.value() },
            coalescer: closingCoalescer
        )
        let closingScope = SourceIndexLifecycleScope(
            observeMutations: false,
            gateStateProvider: {
                SourceIndexPreferenceGateState(consent: true, serve: true, fleet: true)
            },
            cancelShared: { retiredGeneration in
                await closingCoalescer.cancel(upToSourceGeneration: retiredGeneration)
            },
            clearMoat: { _, _ in }
        )
        closingScope.register(closingSource)
        closingSource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if await closingFetch.counts().calls == 1 { break }
            await Task.yield()
        }
        closingScope.preferencesWillApply(serve: false)
        closingGate.close()
        closingSource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            let counts = await closingFetch.counts()
            if counts.cancellations == 1, await closingCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        let closingCounts = await closingFetch.counts()
        let closingActive = await closingCoalescer.activeCount()
        expect(closingCounts.calls == 1 && closingCounts.cancellations == 1
               && closingActive == 0 && closingSource.streams.isEmpty,
               "gate closure cancels the shared operation, empties waiters, and cannot republish")

        let consentReopen = await exerciseLifecycleReopen(
            channel: .consent, initial: trusted, fresh: rotated
        )
        expect(consentReopen.initialPublished && consentReopen.immediateBlank
               && consentReopen.freshSurvivedDelayedCancel && consentReopen.freshPublished
               && consentReopen.cancelCount == 2
               && consentReopen.closeGenerationAdvanced && consentReopen.reopenGenerationAdvanced,
               "consent close clears now and delayed retired cleanup cannot cancel reopened work")
        expect(consentReopen.moatValues.count == 2
               && consentReopen.moatValues.allSatisfy { $0.0 == nil && $0.1 != nil },
               "consent close and reopen clear only their retired moat generations")

        let liminalServeGate = LockedGate(true)
        let liminalServeCoalescer = SourceIndexFetchCoalescer()
        let liminalServeFetch = IndexedReleasableFetch(results: [[trusted], [rotated]])
        let liminalServeCancel = DelayedLifecycleCancel(coalescer: liminalServeCoalescer)
        let liminalServeCleanup = LifecycleCleanupProbe()
        let liminalServeScope = SourceIndexLifecycleScope(
            observeMutations: false,
            gateStateProvider: {
                SourceIndexPreferenceGateState(consent: true, serve: true, fleet: true)
            },
            cancelShared: { cutoff in await liminalServeCancel.cancel(upTo: cutoff) },
            clearMoat: { session, consent in
                await liminalServeCleanup.clearMoat(session: session, consent: consent)
            }
        )
        let liminalServeSource = SourceIndexServeSource(
            fetchPooled: { _, _ in await liminalServeFetch.run() },
            serveGate: { liminalServeGate.value() },
            coalescer: liminalServeCoalescer
        )
        liminalServeScope.register(liminalServeSource)
        let beforeServeClose = SourceIndexLifecycleClock.snapshot()
        liminalServeScope.preferencesWillApply(serve: false)
        let afterServeClose = SourceIndexLifecycleClock.snapshot()
        liminalServeSource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if await liminalServeFetch.callCount() == 1 { break }
            await Task.yield()
        }
        liminalServeGate.close()
        liminalServeScope.preferencesWillApply(serve: true)
        let afterServeReopen = SourceIndexLifecycleClock.snapshot()
        liminalServeGate.reopen()
        liminalServeSource.refresh(contentID: "tt1234567", isSignedIn: true)
        for _ in 0..<1_000 {
            if await liminalServeFetch.callCount() == 2 { break }
            await Task.yield()
        }
        await liminalServeFetch.release(1)
        for _ in 0..<1_000 {
            if await liminalServeCoalescer.activeCount() == 1 { break }
            await Task.yield()
        }
        let liminalServeNeverPublished = liminalServeSource.streams.isEmpty
        for _ in 0..<1_000 {
            if await liminalServeCancel.counts().started == 2 { break }
            await Task.yield()
        }
        await liminalServeCancel.releaseAll()
        for _ in 0..<1_000 {
            if await liminalServeCancel.counts().completed == 2 { break }
            await Task.yield()
        }
        let freshServeSurvivedRetiredCancels = await liminalServeCoalescer.activeCount() == 1
        await liminalServeFetch.release(2)
        for _ in 0..<1_000 {
            if liminalServeSource.streams.first?.infoHash == secondHash,
               await liminalServeCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        let liminalServeCleanupCounts = await liminalServeCleanup.counts()
        let liminalServeCallCount = await liminalServeFetch.callCount()
        expect(afterServeClose.sourceGeneration == beforeServeClose.sourceGeneration + 1
               && afterServeClose.consentGeneration == beforeServeClose.consentGeneration
               && afterServeReopen.sourceGeneration == afterServeClose.sourceGeneration + 1
               && afterServeReopen.consentGeneration == afterServeClose.consentGeneration,
               "serve close and reopen each rotate only the source generation before persistence")
        expect(liminalServeCallCount == 2
               && liminalServeNeverPublished
               && freshServeSurvivedRetiredCancels
               && liminalServeSource.streams.map(\.infoHash) == [secondHash]
               && liminalServeCleanupCounts.moatClears == 0,
               "liminal serve request never publishes or joins the fresh same-title reopen request")

        let serveReopen = await exerciseLifecycleReopen(
            channel: .serve, initial: trusted, fresh: rotated
        )
        expect(serveReopen.initialPublished && serveReopen.immediateBlank
               && serveReopen.freshSurvivedDelayedCancel && serveReopen.freshPublished
               && serveReopen.cancelCount == 2 && serveReopen.moatValues.isEmpty
               && serveReopen.closeGenerationAdvanced && serveReopen.reopenGenerationAdvanced,
               "serve close preserves moat and delayed retired cleanup cannot cancel reopened work")

        let fleetReopen = await exerciseLifecycleReopen(
            channel: .fleet, initial: trusted, fresh: rotated
        )
        expect(fleetReopen.initialPublished && fleetReopen.immediateBlank
               && fleetReopen.freshSurvivedDelayedCancel && fleetReopen.freshPublished
               && fleetReopen.cancelCount == 1 && fleetReopen.moatValues.isEmpty
               && fleetReopen.closeGenerationAdvanced && !fleetReopen.reopenGenerationAdvanced
               && fleetReopen.fleetGateClosedBeforeTransition,
               "fleet installs false before one close rotation and delayed cleanup preserves reopened work")

        let sessionCleanup = LifecycleCleanupProbe()
        let sessionParticipant = LifecycleParticipantProbe()
        let sessionScope = SourceIndexLifecycleScope(
            observeMutations: false,
            gateStateProvider: {
                SourceIndexPreferenceGateState(consent: true, serve: true, fleet: true)
            },
            cancelShared: { cutoff in await sessionCleanup.cancel(cutoff) },
            clearMoat: { session, consent in
                await sessionCleanup.clearMoat(session: session, consent: consent)
            }
        )
        sessionScope.register(sessionParticipant)
        sessionScope.sessionWillMutate()
        let sessionClearedImmediately = sessionParticipant.closeCount == 1
            && sessionParticipant.publishedRows == 0
        for _ in 0..<1_000 {
            if await sessionCleanup.counts().moatClears == 1 { break }
            await Task.yield()
        }
        let sessionCounts = await sessionCleanup.counts()
        let sessionMoatValues = await sessionCleanup.moatValues()
        expect(sessionClearedImmediately && sessionCounts.cancels == 1 && sessionCounts.moatClears == 1
               && sessionMoatValues.first?.0 != nil && sessionMoatValues.first?.1 == nil,
               "account mutation clears participants and only its retired moat generation")

        let generationCoalescer = SourceIndexFetchCoalescer()
        let accountAFetch = ReleasableFetch(result: [trusted])
        let accountBFetch = ReleasableFetch(result: [rotated])
        let accountALifecycle = SourceIndexLifecycleClock.snapshot()
        let accountAWaiter = Task {
            await generationCoalescer.fetch(
                contentID: "tt1234567", isSignedIn: true, lifecycle: accountALifecycle
            ) {
                await accountAFetch.run()
            }
        }
        for _ in 0..<1_000 {
            if await accountAFetch.callCount() == 1 { break }
            await Task.yield()
        }
        let accountTransition = SourceIndexLifecycleClock.mutateSession()
        let accountBWaiter = Task {
            await generationCoalescer.fetch(
                contentID: "tt1234567", isSignedIn: true, lifecycle: accountTransition.current
            ) {
                await accountBFetch.run()
            }
        }
        for _ in 0..<1_000 {
            if await accountBFetch.callCount() == 1 { break }
            await Task.yield()
        }
        await generationCoalescer.cancel(
            upToSourceGeneration: accountTransition.retired.sourceGeneration
        )
        let activeAfterDelayedAccountCancel = await generationCoalescer.activeCount()
        let accountAResult = await accountAWaiter.value
        await accountBFetch.release()
        let accountBResult = await accountBWaiter.value
        await accountAFetch.release()
        expect(accountAResult.isEmpty && activeAfterDelayedAccountCancel == 1
               && accountBResult.map(\.id) == [secondHash],
               "delayed account-A cancellation cannot join or cancel account-B coalescing")

        let credentialBox = MoatCredentialBox(
            .init(bearer: "bearer-A", identityDigest: "digest-A")
        )
        let mintProbe = ScopedMintProbe()
        let scopedMoat = MoatToken(
            credentialProvider: { credentialBox.value() },
            mintProvider: { bearer in await mintProbe.mint(bearer) }
        )
        let accountAMoat = Task { await scopedMoat.current(isSignedIn: true) }
        for _ in 0..<1_000 {
            if await mintProbe.callCount("bearer-A") == 1 { break }
            await Task.yield()
        }
        let moatAccountTransition = SourceIndexLifecycleClock.mutateSession()
        credentialBox.set(.init(bearer: "bearer-B", identityDigest: "digest-B"))
        let accountBMoat = await scopedMoat.current(isSignedIn: true)
        await scopedMoat.clear(
            retiredSessionGeneration: moatAccountTransition.retired.sessionGeneration,
            retiredConsentGeneration: nil
        )
        let accountBMoatAfterDelayedClear = await scopedMoat.current(isSignedIn: true)
        await mintProbe.releaseAccountA()
        let retiredAccountMoat = await accountAMoat.value
        let accountAMints = await mintProbe.callCount("bearer-A")
        let accountBMintsBeforeConsent = await mintProbe.callCount("bearer-B")
        expect(retiredAccountMoat == nil && accountBMoat == "moat-bearer-B"
               && accountBMoatAfterDelayedClear == accountBMoat
               && accountAMints == 1 && accountBMintsBeforeConsent == 1,
               "real MoatToken never returns account-A mint or lets delayed A clear erase B cache")

        let moatConsentTransition = SourceIndexLifecycleClock.rotateConsentAuthorization()
        let reenabledConsentMoat = await scopedMoat.current(isSignedIn: true)
        await scopedMoat.clear(
            retiredSessionGeneration: nil,
            retiredConsentGeneration: moatConsentTransition.retired.consentGeneration
        )
        let consentMoatAfterDelayedClear = await scopedMoat.current(isSignedIn: true)
        let accountBMintsAfterConsent = await mintProbe.callCount("bearer-B")
        expect(reenabledConsentMoat == "moat-bearer-B"
               && consentMoatAfterDelayedClear == reenabledConsentMoat
               && accountBMintsAfterConsent == 2,
               "real MoatToken remints after consent retirement and old clear cannot erase the new cache")

        MoatConsent.contributeAndConsume = true
        let consentGapCredential = MoatCredentialBox(
            .init(bearer: "bearer-gap", identityDigest: "digest-gap")
        )
        let consentGapMint = ControlledMintProbe()
        let consentGapMoat = MoatToken(
            credentialProvider: { consentGapCredential.value() },
            mintProvider: { bearer in await consentGapMint.mint(bearer) }
        )
        let delayedConsentClear = DelayedMoatClear(moat: consentGapMoat)
        let consentGapScope = SourceIndexLifecycleScope(
            observeMutations: false,
            gateStateProvider: {
                SourceIndexPreferenceGateState(consent: true, serve: true, fleet: true)
            },
            cancelShared: { _ in },
            clearMoat: { session, consent in
                await delayedConsentClear.clear(session: session, consent: consent)
            }
        )
        let beforeConsentClose = SourceIndexLifecycleClock.snapshot()
        consentGapScope.preferencesWillApply(consent: false)
        let afterConsentClose = SourceIndexLifecycleClock.snapshot()
        let liminalConsentMint = Task { await consentGapMoat.current(isSignedIn: true) }
        for _ in 0..<1_000 {
            if await consentGapMint.callCount() == 1 { break }
            await Task.yield()
        }
        MoatConsent.contributeAndConsume = false
        await consentGapMint.release(1)
        let rejectedLiminalToken = await liminalConsentMint.value
        for _ in 0..<1_000 {
            if await delayedConsentClear.snapshot().values.count == 1 { break }
            await Task.yield()
        }

        consentGapScope.preferencesWillApply(consent: true)
        let afterConsentReopen = SourceIndexLifecycleClock.snapshot()
        for _ in 0..<1_000 {
            if await delayedConsentClear.snapshot().values.count == 2 { break }
            await Task.yield()
        }
        MoatConsent.contributeAndConsume = true
        let reopenedConsentMint = Task { await consentGapMoat.current(isSignedIn: true) }
        for _ in 0..<1_000 {
            if await consentGapMint.callCount() == 2 { break }
            await Task.yield()
        }
        await consentGapMint.release(2)
        let reopenedConsentToken = await reopenedConsentMint.value
        await delayedConsentClear.releaseAll()
        for _ in 0..<1_000 {
            if await delayedConsentClear.snapshot().completed == 2 { break }
            await Task.yield()
        }
        let tokenAfterRetiredConsentClears = await consentGapMoat.current(isSignedIn: true)
        let consentGapMintCount = await consentGapMint.callCount()
        let consentClearSnapshot = await delayedConsentClear.snapshot()
        let consentCutoffs = Set(consentClearSnapshot.values.compactMap { $0.1 })
        expect(afterConsentClose.sourceGeneration == beforeConsentClose.sourceGeneration + 1
               && afterConsentClose.consentGeneration == beforeConsentClose.consentGeneration + 1
               && afterConsentReopen.sourceGeneration == afterConsentClose.sourceGeneration + 1
               && afterConsentReopen.consentGeneration == afterConsentClose.consentGeneration + 1,
               "consent close and reopen each rotate source and consent authorization before persistence")
        expect(rejectedLiminalToken == nil
               && reopenedConsentToken == "controlled-moat-2"
               && tokenAfterRetiredConsentClears == reopenedConsentToken
               && consentGapMintCount == 2
               && consentClearSnapshot.values.allSatisfy { $0.0 == nil }
               && consentCutoffs == Set([
                    beforeConsentClose.consentGeneration,
                    afterConsentClose.consentGeneration,
               ]),
               "real MoatToken rejects the opt-out gap mint and retired clears preserve one fresh reopen mint")

        var resumePoll = 0
        let late = await SourceIndexClient.resumedDescriptors(maxWaitMs: 3, pollIntervalMs: 1) {
            resumePoll += 1
            return resumePoll == 1
                ? [CoreStreamSourceGroup(id: "direct", addon: "Direct", streams: [CoreStream(url: privateURL)])]
                : [CoreStreamSourceGroup(id: "torrent", addon: "Addon", streams: [CoreStream(infoHash: upper)])]
        }
        expect(resumePoll == 2 && late.count == 1 && late.first?.id == lower,
               "resume polling ignores direct-first and captures the later torrent")

        let ledger = SourceUploadCoordinator(maxEntries: 10)
        let firstReservation = await ledger.reserve(
            contentID: "tt1234567", descriptors: uploadable
        )
        let duplicatePending = await ledger.reserve(
            contentID: "tt1234567", descriptors: uploadable
        )
        let firstClaim: [SourceIndexClient.Descriptor]
        if let firstReservation {
            firstClaim = launchedDescriptors(await ledger.prepareLaunch(
                firstReservation, nowNanoseconds: 10_000, intervalNanoseconds: 1_100
            ))
        } else {
            firstClaim = []
        }
        let duplicateCommitted = await ledger.reserve(
            contentID: "tt1234567", descriptors: uploadable
        )
        let lateReservation = await ledger.reserve(
            contentID: "tt1234567",
            descriptors: [.init(kind: "torrent", id: secondHash, quality: "720p", sizeBytes: 0, seeders: nil)]
        )
        let lateClaim: [SourceIndexClient.Descriptor]
        if let lateReservation {
            lateClaim = launchedDescriptors(await ledger.prepareLaunch(
                lateReservation, nowNanoseconds: 11_100, intervalNanoseconds: 1_100
            ))
        } else {
            lateClaim = []
        }
        let otherTitleReservation = await ledger.reserve(
            contentID: "tt7654321", descriptors: uploadable
        )
        let otherTitleClaim: [SourceIndexClient.Descriptor]
        if let otherTitleReservation {
            otherTitleClaim = launchedDescriptors(await ledger.prepareLaunch(
                otherTitleReservation, nowNanoseconds: 12_200, intervalNanoseconds: 1_100
            ))
        } else {
            otherTitleClaim = []
        }
        expect(firstClaim.map(\.id) == [lower] && duplicatePending == nil && duplicateCommitted == nil,
               "atomic pending and committed ledgers suppress overlapping detail and resume claims")
        expect(lateClaim.map(\.id) == [secondHash] && otherTitleClaim.map(\.id) == [lower],
               "shared ledger preserves late hashes and scopes dedup by title")

        let boundedLedger = SourceUploadCoordinator(maxEntries: 2)
        let firstDescriptor = SourceIndexClient.Descriptor(
            kind: "torrent", id: lower, quality: "1080p", sizeBytes: 0, seeders: nil
        )
        let secondDescriptor = SourceIndexClient.Descriptor(
            kind: "torrent", id: secondHash, quality: "1080p", sizeBytes: 0, seeders: nil
        )
        let thirdDescriptor = SourceIndexClient.Descriptor(
            kind: "torrent", id: thirdHash, quality: "1080p", sizeBytes: 0, seeders: nil
        )
        let saturation = await boundedLedger.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor, secondDescriptor]
        )
        if let saturation {
            _ = await boundedLedger.prepareLaunch(
                saturation, nowNanoseconds: 10_000, intervalNanoseconds: 1_100
            )
        }
        let refusedAtCapacity = await boundedLedger.reserve(
            contentID: "tt1234567", descriptors: [thirdDescriptor]
        )
        let oldestStillSuppressed = await boundedLedger.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        expect(refusedAtCapacity == nil && oldestStillSuppressed == nil,
               "saturated ledger refuses new claims without evicting its oldest process-lifetime claim")

        let pacer = SourceUploadCoordinator(maxEntries: 10)
        let firstPaced = await pacer.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        let emptyDuplicate = await pacer.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        let secondPaced = await pacer.reserve(
            contentID: "tt1234567", descriptors: [secondDescriptor]
        )
        let firstLaunch: [SourceIndexClient.Descriptor]
        if let firstPaced {
            firstLaunch = launchedDescriptors(await pacer.prepareLaunch(
                firstPaced, nowNanoseconds: 10_000, intervalNanoseconds: 1_100
            ))
        } else { firstLaunch = [] }
        let secondWait: UInt64?
        if let secondPaced {
            secondWait = waitDelay(await pacer.prepareLaunch(
                secondPaced, nowNanoseconds: 10_000, intervalNanoseconds: 1_100
            ))
        } else { secondWait = nil }
        let secondLaunch: [SourceIndexClient.Descriptor]
        if let secondPaced {
            secondLaunch = launchedDescriptors(await pacer.prepareLaunch(
                secondPaced, nowNanoseconds: 11_100, intervalNanoseconds: 1_100
            ))
        } else { secondLaunch = [] }
        expect(firstLaunch.map(\.id) == [lower]
               && emptyDuplicate == nil && secondWait == 1_100
               && secondLaunch.map(\.id) == [secondHash],
               "empty duplicates consume no slot and launch-time pacing stays global")

        let closingPacer = SourceUploadCoordinator(maxEntries: 10)
        let closingFirst = await closingPacer.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        if let closingFirst {
            _ = await closingPacer.prepareLaunch(
                closingFirst,
                nowNanoseconds: 10_000,
                intervalNanoseconds: 1_100,
                gate: { true }
            )
        }
        let closingPending = await closingPacer.reserve(
            contentID: "tt1234567", descriptors: [secondDescriptor]
        )
        let closingInitialWait: UInt64?
        if let closingPending {
            closingInitialWait = waitDelay(await closingPacer.prepareLaunch(
                closingPending,
                nowNanoseconds: 10_000,
                intervalNanoseconds: 1_100,
                gate: { true }
            ))
        } else { closingInitialWait = nil }
        let closedDecision: SourceUploadCoordinator.LaunchDecision
        if let closingPending {
            closedDecision = await closingPacer.prepareLaunch(
                closingPending,
                nowNanoseconds: 11_100,
                intervalNanoseconds: 1_100,
                gate: { false }
            )
        } else { closedDecision = .unavailable }
        let releasedAfterClose = await closingPacer.reserve(
            contentID: "tt1234567", descriptors: [secondDescriptor]
        )
        expect(closingInitialWait == 1_100 && isUnavailable(closedDecision)
               && releasedAfterClose != nil,
               "consent closing during pacing releases the claim and permits no POST launch")

        let cancellationLedger = SourceUploadCoordinator(maxEntries: 10)
        let canceled = await cancellationLedger.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        if let canceled { await cancellationLedger.release(canceled) }
        let claimAfterCancellation = await cancellationLedger.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        let startedLedger = SourceUploadCoordinator(maxEntries: 10)
        let started = await startedLedger.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        let committed: [SourceIndexClient.Descriptor]
        if let started {
            committed = launchedDescriptors(await startedLedger.prepareLaunch(
                started, nowNanoseconds: 10_000, intervalNanoseconds: 1_100
            ))
        } else {
            committed = []
        }
        let duplicateAfterFailure = await startedLedger.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        expect(canceled != nil && claimAfterCancellation != nil,
               "cancellation before launch releases the pending descriptor claim")
        expect(committed.map(\.id) == [lower] && duplicateAfterFailure == nil,
               "one started failed attempt stays claimed and cannot amplify into a retry")

        let overlappingLedger = SourceUploadCoordinator(maxEntries: 10)
        async let overlappingA = overlappingLedger.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        async let overlappingB = overlappingLedger.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        let overlapping = await [overlappingA, overlappingB]
        expect(overlapping.compactMap { $0 }.count == 1,
               "actor reservation is an atomic compare-and-set for overlapping identical batches")

        let failurePacer = SourceUploadCoordinator(maxEntries: 10)
        let failedAttempt = await failurePacer.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        if let failedAttempt {
            _ = await failurePacer.prepareLaunch(
                failedAttempt, nowNanoseconds: 10_000, intervalNanoseconds: 1_100
            )
        }
        let alreadySleeping = await failurePacer.reserve(
            contentID: "tt1234567", descriptors: [secondDescriptor]
        )
        let initialSleep: UInt64?
        if let alreadySleeping {
            initialSleep = waitDelay(await failurePacer.prepareLaunch(
                alreadySleeping, nowNanoseconds: 10_000, intervalNanoseconds: 1_100
            ))
        } else { initialSleep = nil }
        let continueFailedLoop = await failurePacer.finishAttempt(
            succeeded: SourceIndexClient.isSuccessfulHTTPStatus(503),
            nowNanoseconds: 11_000,
            intervalNanoseconds: 1_100
        )
        let retryFailedClaim = await failurePacer.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        let shiftedSleep: UInt64?
        if let alreadySleeping {
            shiftedSleep = waitDelay(await failurePacer.prepareLaunch(
                alreadySleeping, nowNanoseconds: 11_100, intervalNanoseconds: 1_100
            ))
        } else { shiftedSleep = nil }
        let afterFailure: [SourceIndexClient.Descriptor]
        if let alreadySleeping {
            afterFailure = launchedDescriptors(await failurePacer.prepareLaunch(
                alreadySleeping, nowNanoseconds: 12_100, intervalNanoseconds: 1_100
            ))
        } else { afterFailure = [] }
        expect(!continueFailedLoop && retryFailedClaim == nil,
               "POST 503 stops the current loop and its held claim cannot fan out into a retry")
        expect(initialSleep == 1_100 && shiftedSleep == 1_000 && afterFailure.map(\.id) == [secondHash],
               "an overlapping sleeper rechecks and honors one full interval after failure")

        let delayedPacer = SourceUploadCoordinator(maxEntries: 10)
        let delayedFirst = await delayedPacer.reserve(
            contentID: "tt1234567", descriptors: [firstDescriptor]
        )
        if let delayedFirst {
            _ = await delayedPacer.prepareLaunch(
                delayedFirst, nowNanoseconds: 10_000, intervalNanoseconds: 1_100
            )
        }
        let delayedSecond = await delayedPacer.reserve(
            contentID: "tt1234567", descriptors: [secondDescriptor]
        )
        let delayedThird = await delayedPacer.reserve(
            contentID: "tt1234567", descriptors: [thirdDescriptor]
        )
        let delayedSecondLaunch: [SourceIndexClient.Descriptor]
        if let delayedSecond {
            delayedSecondLaunch = launchedDescriptors(await delayedPacer.prepareLaunch(
                delayedSecond, nowNanoseconds: 30_000, intervalNanoseconds: 1_100
            ))
        } else { delayedSecondLaunch = [] }
        let delayedThirdWait: UInt64?
        if let delayedThird {
            delayedThirdWait = waitDelay(await delayedPacer.prepareLaunch(
                delayedThird, nowNanoseconds: 30_000, intervalNanoseconds: 1_100
            ))
        } else { delayedThirdWait = nil }
        let delayedThirdLaunch: [SourceIndexClient.Descriptor]
        if let delayedThird {
            delayedThirdLaunch = launchedDescriptors(await delayedPacer.prepareLaunch(
                delayedThird, nowNanoseconds: 31_100, intervalNanoseconds: 1_100
            ))
        } else { delayedThirdLaunch = [] }
        expect(delayedSecondLaunch.map(\.id) == [secondHash] && delayedThirdWait == 1_100
               && delayedThirdLaunch.map(\.id) == [thirdHash],
               "delayed sleepers recheck launch slots instead of bursting together")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}

private extension String {
    func repeating(_ count: Int) -> String { String(repeating: self, count: count) }
}
