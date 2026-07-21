// Standalone executable for the real torrent-only SourceIndexClient contract. VortX has no Xcode unit-test
// bundle, so this compiles the production SourceIndexContract.swift and SourceIndexClient.swift with only the
// surrounding app dependencies stubbed:
//
//   xcrun swiftc -o /tmp/source-index-contract-test \
//     app/SourcesShared/SourceIndexContract.swift \
//     app/SourcesShared/SourceIndexIdentity.swift \
//     app/SourcesShared/MoatToken.swift \
//     app/SourcesShared/SourceIndexClient.swift \
//     app/Tests/SourceIndexTorrentContractTests.swift && /tmp/source-index-contract-test
//
// (Run from the repo root. SourceIndexIdentity.swift is REQUIRED: it holds the shared resolver and the whole
// diagnostics vocabulary. A previous round shipped a header command that omitted it and therefore did not
// compile, which is the same class of defect as a comment that overstates what the code does.)
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

/// Mirrors the add-on-declared public fields the descriptor path reads. `bingeGroup` and `sources` are
/// modelled because a DEBRID-mode add-on returns a resolved `url` row with NO `infoHash`, carrying the public
/// 40-hex only in these fields -- and because `sources` also carries `tracker:` URLs whose private passkeys
/// must never be mistaken for an infohash (see the negative tests below).
struct CoreStreamBehaviorHints: Codable, Equatable {
    var bingeGroup: String?
    init(bingeGroup: String? = nil) { self.bingeGroup = bingeGroup }
}

struct CoreStream: Codable, Equatable {
    var name: String?
    var description: String?
    var infoHash: String?
    var url: String?
    var nzbUrl: String?
    var ytId: String?
    var sources: [String]?
    var behaviorHints: CoreStreamBehaviorHints?

    var isYouTubeTrailer: Bool { url == nil && infoHash == nil && !(ytId ?? "").isEmpty }

    init(
        name: String? = nil,
        description: String? = nil,
        infoHash: String? = nil,
        url: String? = nil,
        nzbUrl: String? = nil,
        ytId: String? = nil,
        sources: [String]? = nil,
        behaviorHints: CoreStreamBehaviorHints? = nil
    ) {
        self.name = name
        self.description = description
        self.infoHash = infoHash
        self.url = url
        self.nzbUrl = nzbUrl
        self.ytId = ytId
        self.sources = sources
        self.behaviorHints = behaviorHints
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

/// Mirrors the members of the real `ResolvedConfig` that `SourceIndexClient` reads. Every value here MUST equal the
/// baked default in `RemoteConfigDefaults`, so this harness exercises the same behaviour the app ships with an absent
/// remote block. A member added to the real snapshot and not added here does not fail a test: it stops the whole
/// harness COMPILING, which reads as "no test signal" rather than as a failure. Keep the two in step.
/// Steerable stand-in for the fleet kill switch. Default `nil` means "no remote value", which is exactly the
/// baked behaviour (`isFeatureOn` returns the call site's default), so every existing case is unaffected.
enum RemoteConfigTestState {
    nonisolated(unsafe) static var fleetOverride: Bool?
}

struct RemoteConfigSnapshot {
    func isFeatureOn(_ key: String, default value: Bool) -> Bool { RemoteConfigTestState.fleetOverride ?? value }
    func endpoint(_ key: String) -> URL? { nil }

    var sourceIndexInterBatchDelayMs: Int { 1100 }
    var sourceIndexBatchSize: Int { 16 }
    var sourceIndexMaxDescriptorsPerTitle: Int { 2000 }
    var sourceIndexResumeHoardMaxWaitMs: Int { 5000 }
    var sourceIndexResumeHoardPollIntervalMs: Int { 250 }
    /// The CONSTANT cap (60), deliberately not the derived count (20). The two used to be one field, and the
    /// harness inherited the ambiguity from the app.
    var sourceIndexResumeHoardAttemptCap: Int { 60 }
    var sourceIndexResumeHoardAttempts: Int { 20 }
    var sourceIndexRequestTimeout: TimeInterval { 8 }
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

/// Capture seam for `SourceIndexClient.diagnosticSink`. The diagnostics land in a log the USER EXPORTS AND
/// SHARES PUBLICLY, so the suite asserts on the exact bytes that would be written rather than trusting a code
/// read that no raw identifier is interpolated.
final class CapturedDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []

    func append(_ line: String) { lock.withLock { captured.append(line) } }
    func lines() -> [String] { lock.withLock { captured } }
}

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

private func publicationTarget(_ titleID: String?) -> SourceIndexIdentity.TargetResolution {
    guard let titleID else { return .absent }
    return SourceIndexIdentity.publicationTarget(
        SourceIndexIdentity.Roles(
            catalogID: titleID,
            defaultVideoID: nil,
            currentVideoID: nil,
            kind: .movie
        )
    )
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

        source.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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

        source.refresh(target: publicationTarget("tt7654321"), isSignedIn: true)
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
        source.refresh(target: publicationTarget("tt7654321"), isSignedIn: true)
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
        // INVERTED (decision REQ-260721-33). This case used to assert that a TMDB episode key built a serve
        // URL. It now asserts the opposite, because TMDB reuses its numeric ids across the movie and tv
        // namespaces (`/movie/11` and `/tv/11` are different titles) while `content_id` carries no entity
        // type, so a tmdb key merges two unrelated titles into one pool bucket in both directions.
        expect(SourceIndexClient.serveURL(contentID: "tmdb:123:1:2") == nil,
               "serve boundary REFUSES a tmdb key: pool keys are IMDb-only")
        expect(SourceIndexClient.serveURL(contentID: "tt1234567:1:2")?.absoluteString.contains("kind=torrent") == true,
               "serve boundary builds only the torrent query for a canonical IMDb episode")
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
        // CONTRACT CHANGED 2026-07-21: the client floor now MIRRORS the worker's torrent floor of 1 instead of
        // re-filtering at 2. The worker serves single-witness torrents deliberately (a self-verifying infohash
        // never strands a lone early contributor); the old client floor of 2 discarded exactly those rows, which
        // in a young pool is nearly all of them. So `fourthHash` (corroboration 1) is now SERVED. Rows with 0 or
        // absent corroboration stay dropped as anomalous, and non-torrent / non-canonical rows stay dropped.
        expect(served.count == 2 && served.map(\.infoHash) == [lower, fourthHash],
               "serve reconstruction mirrors the worker floor (>=1), still dropping 0/absent, non-torrent, and noncanonical rows")
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
        // Count follows `served`, which is now 2 under the corrected worker-mirrored floor (>=1). The INTENT is
        // unchanged and still enforced: the appended direct and nzb rows must NOT appear in the merged output.
        expect(merged.count == 1 && merged.first?.streams.count == 2,
               "merge admits only canonical torrent streams (direct/nzb rows excluded)")

        let mismatchTransport = AttemptProbe()
        let mismatchSource = SourceIndexServeSource(
            fetchPooled: { _, _ in
                await mismatchTransport.record()
                return [trusted]
            },
            serveGate: { true },
            coalescer: SourceIndexFetchCoalescer()
        )
        let mismatchTarget = SourceIndexIdentity.publicationTarget(
            SourceIndexIdentity.Roles(
                catalogID: "tt0903747",
                defaultVideoID: "tt1375666",
                currentVideoID: "tt2861424:1:1",
                kind: .series
            ),
            season: 1,
            episode: 1
        )
        mismatchSource.refresh(target: mismatchTarget, isSignedIn: true)
        await Task.yield()
        let mismatchTransportCount = await mismatchTransport.count()
        let ordinaryGroups = [CoreStreamSourceGroup(
            id: "ordinary", addon: "Ordinary", streams: [CoreStream(name: "ordinary", url: "https://example.test")]
        )]
        expect(mismatchTransportCount == 0 && mismatchSource.streams.isEmpty,
               "REQ-50: a typed mismatch launches zero SourceIndex transport and publishes zero rows")
        expect(mismatchSource.merged(into: ordinaryGroups, for: mismatchTarget).count == ordinaryGroups.count,
               "REQ-50: mismatch leaves the ordinary engine-only groups available")

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
        priorSource?.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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
        emptySource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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
        failedSource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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
        rotatedSource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
        for _ in 0..<1_000 {
            if rotatedSource.streams.first?.infoHash == secondHash,
               await lifecycleCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(rotatedSource.streams.map(\.infoHash) == [secondHash],
               "fresh rotation publishes only the new response without prior-row carryover")
        lifecycleGate.close()
        rotatedSource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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
        identitySource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
        for _ in 0..<1_000 {
            if identitySource.streams.first?.infoHash == lower { break }
            await Task.yield()
        }
        identitySource.refresh(target: publicationTarget("tt7654321"), isSignedIn: true)
        let accountBBlankedImmediately = identitySource.streams.isEmpty
        for _ in 0..<1_000 {
            if await identitySequence.callCount() == 2,
               await identityCoalescer.activeCount() == 0 { break }
            await Task.yield()
        }
        expect(accountBBlankedImmediately && identitySource.streams.isEmpty,
               "identity A to B clears A immediately and a failed B fetch stays empty")
        identitySource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
        for _ in 0..<1_000 {
            if identitySource.streams.first?.infoHash == lower { break }
            await Task.yield()
        }
        identitySource.refresh(target: .absent, isSignedIn: true)
        expect(identitySource.streams.isEmpty,
               "identity A to nil clears every previously published row synchronously")

        let lateIdentityFetch = IndexedReleasableFetch(results: [[trusted], [rotated]])
        let lateIdentityCoalescer = SourceIndexFetchCoalescer()
        let lateIdentitySource = SourceIndexServeSource(
            fetchPooled: { _, _ in await lateIdentityFetch.run() },
            serveGate: { true },
            coalescer: lateIdentityCoalescer
        )
        lateIdentitySource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
        for _ in 0..<1_000 {
            if await lateIdentityFetch.callCount() == 1 { break }
            await Task.yield()
        }
        lateIdentitySource.refresh(target: publicationTarget("tt7654321"), isSignedIn: true)
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
        expect(lateIdentitySource.merged(
                   into: [], for: publicationTarget("tt1234567")).isEmpty,
               "REQ-50: rows fetched for title B cannot merge into title A")
        expect(lateIdentitySource.merged(
                   into: [], for: publicationTarget("tt7654321")).first?.streams.map(\.infoHash) == [secondHash],
               "REQ-50: rows merge only when the selected target exactly matches their publication target")

        let liveAccountGate = LockedGate(true)
        let accountFenceFetch = IndexedReleasableFetch(results: [[trusted]])
        let accountFenceCoalescer = SourceIndexFetchCoalescer()
        let accountFenceSource = SourceIndexServeSource(
            fetchPooled: { _, _ in await accountFenceFetch.run() },
            serveGate: { true },
            accountGate: { liveAccountGate.value() },
            coalescer: accountFenceCoalescer
        )
        accountFenceSource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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
        replacedSource?.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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
        replacementSource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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
        closingSource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
        for _ in 0..<1_000 {
            if await closingFetch.counts().calls == 1 { break }
            await Task.yield()
        }
        closingScope.preferencesWillApply(serve: false)
        closingGate.close()
        closingSource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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
        liminalServeSource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
        for _ in 0..<1_000 {
            if await liminalServeFetch.callCount() == 1 { break }
            await Task.yield()
        }
        liminalServeGate.close()
        liminalServeScope.preferencesWillApply(serve: true)
        let afterServeReopen = SourceIndexLifecycleClock.snapshot()
        liminalServeGate.reopen()
        liminalServeSource.refresh(target: publicationTarget("tt1234567"), isSignedIn: true)
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

        // MARK: - Singularity field-failure fixes (2026-07-21). Regressions for the four defects that made the
        // source pool contribute and serve NOTHING in the field, plus the credential leak caught in cross-review.

        // CAUSE A: series call sites pass behaviorHints.defaultVideoId, which on a series is ALREADY "tt…:S:E".
        // Appending this episode's :S:E produced "tt…:1:1:3:5", which canonicalContentID rejects -> nil -> the
        // call site returned silently, killing contribute AND serve for every episode of every such show.
        expect(SourceIndexContract.canonicalTitleID("tt0903747:1:1") == "tt0903747",
               "canonicalTitleID reduces an episode-scoped imdb id to its title id")
        expect(SourceIndexContract.canonicalTitleID("tmdb:1399:2:3") == "tmdb:1399",
               "canonicalTitleID reduces an episode-scoped tmdb id to its title id")
        expect(SourceIndexContract.canonicalTitleID("tt0903747") == "tt0903747",
               "canonicalTitleID passes a bare title id through unchanged")
        expect(SourceIndexContract.canonicalTitleID(nil) == nil
               && SourceIndexContract.canonicalTitleID("kitsu:42") == nil
               && SourceIndexContract.canonicalTitleID("tt0903747:garbage") == nil,
               "canonicalTitleID refuses nil, non-canonical namespaces, and a non-episode tail")
        expect(SourceIndexClient.contentID(imdbId: "tt0903747:1:1", season: 3, episode: 5) == "tt0903747:3:5",
               "THE FIELD BUG: an already-episode-scoped id no longer composes tt…:1:1:3:5, it composes tt…:3:5")
        expect(SourceIndexClient.contentID(imdbId: "tt0903747", season: 3, episode: 5) == "tt0903747:3:5"
               && SourceIndexClient.contentID(imdbId: "tt0903747") == "tt0903747",
               "contentID still composes correctly from a bare title id, and passes a movie id through")

        // CAUSE B + the credential leak (cross-review REQ-260721-05): a debrid row republishes the public 40-hex in
        // `sources` as `dht:<40hex>`. Recovering it is REQUIRED, but `sources` also carries tracker: URLs whose
        // PRIVATE PASSKEYS are also 40-hex. An "any 40-hex anywhere" scan would upload a user's tracker
        // credential into the shared pool. Exact-schema matching is the only safe shape.
        let realHash = "bbe3eb70b55e5ffc0e4eb30fbf33c2ca92fad49e"
        let passkey = "0123456789abcdef0123456789abcdef01234567"
        expect(SourceIndexContract.infoHashFromSourceEntry("dht:" + realHash) == realHash,
               "infoHashFromSourceEntry accepts the exact documented dht:<40hex> form")
        expect(SourceIndexContract.infoHashFromSourceEntry("tracker:https://tr.example/\(passkey)/announce") == nil,
               "SECURITY: a private tracker passkey inside a tracker: URL is NEVER lifted out as an infohash")
        expect(SourceIndexContract.infoHashFromSourceEntry("tracker:udp://tr.example:1337/announce") == nil
               && SourceIndexContract.infoHashFromSourceEntry("dht:" + realHash + "extra") == nil
               && SourceIndexContract.infoHashFromSourceEntry(nil) == nil,
               "infoHashFromSourceEntry refuses trackers, over-long tails, and nil")

        // End-to-end through the real descriptor path: a DEBRID row (resolved url, NO infoHash) yields a
        // descriptor from its documented `dht:` entry, while a row whose only 40-hex lives in a tracker URL
        // must not. `bingeGroup` is unconstrained add-on text and is no longer a recovery source AT ALL, so a
        // row carrying a 40-hex ONLY there contributes nothing: reintroducing that path would admit an
        // attacker-chosen, credential-shaped value into the shared pool.
        let debridRow = CoreStream(name: "1080p", url: "https://real-debrid.example/d/TOKEN/file.mkv",
                                   sources: ["dht:" + realHash, "tracker:udp://tr.example:1337/announce"])
        let trackerOnlyRow = CoreStream(name: "1080p", url: "https://real-debrid.example/d/TOKEN/file.mkv",
                                        sources: ["tracker:https://tr.example/\(passkey)/announce"])
        let bingeOnlyRow = CoreStream(name: "1080p", url: "https://real-debrid.example/d/TOKEN/file.mkv",
                                      behaviorHints: CoreStreamBehaviorHints(bingeGroup: "comet|torbox|" + realHash))
        let bingeOverrideRow = CoreStream(name: "1080p", url: "https://real-debrid.example/d/TOKEN/file.mkv",
                                          sources: ["dht:" + realHash],
                                          behaviorHints: CoreStreamBehaviorHints(bingeGroup: "provider|user|" + passkey))
        func descriptorIDs(_ stream: CoreStream) -> [String] {
            SourceIndexClient.descriptors(from: [CoreStreamSourceGroup(id: "g", addon: "a", streams: [stream])])
                .map(\.id)
        }
        expect(descriptorIDs(debridRow) == [realHash],
               "CAUSE B: a debrid row with no infoHash still contributes, recovered from its dht: sources entry")
        expect(descriptorIDs(trackerOnlyRow).isEmpty,
               "SECURITY: a row whose only 40-hex is a tracker passkey contributes NOTHING")
        expect(descriptorIDs(bingeOnlyRow).isEmpty,
               "SECURITY (F2): a 40-hex living ONLY in add-on-controlled bingeGroup text is never contributed")
        expect(descriptorIDs(bingeOverrideRow) == [realHash],
               "SECURITY (F2): a credential-shaped bingeGroup token can no longer override the real dht: hash")
        expect(descriptorIDs(CoreStream(name: "1080p", infoHash: realHash.uppercased(),
                                        sources: ["dht:" + passkey])) == [realHash],
               "PRECEDENCE (F2): the explicit infoHash field outranks a sources entry, most-authoritative first")

        // ---- F1/F3: the ONE shared role-aware resolver, compiled INTO this suite ----
        // The old inline copies lived in two view files this harness cannot compile, so reverting them left
        // every case below green. Everything the views now call is here, and `IdentityCallerGateTests` reads
        // the view sources themselves so a view-only revert is red there.
        //
        // ROLES, NOT ORDER. The previous signature was `preferred(candidates: [String?])` and the array order
        // silently chose a winner: `preferred(["tt0903747:1:1", "tt1375666"])` returned `tt0903747`, even
        // though the valid catalog head named another title. These cases pin the typed mismatch instead.
        func roles(catalog: String?, defaultVideo: String?, currentVideo: String?,
                   kind: SourceIndexIdentity.ContentKind) -> SourceIndexIdentity.Roles {
            SourceIndexIdentity.Roles(catalogID: catalog, defaultVideoID: defaultVideo,
                                      currentVideoID: currentVideo, kind: kind)
        }

        // REQ-260721-50: any two VALID IMDb heads that disagree are a typed mismatch. No role is allowed to
        // choose a winner because the loser may name the file actually selected by an add-on. The ordinary
        // engine path remains independent; only the auxiliary target becomes unavailable.
        expect(SourceIndexIdentity.resolve(
                   roles(catalog: "tt1375666", defaultVideo: "tt0903747:1:1",
                         currentVideo: nil, kind: .movie)) == .mismatch,
               "REQ-50: conflicting movie heads return the typed mismatch")
        expect(SourceIndexIdentity.resolve(
                   roles(catalog: "tt1375666", defaultVideo: "tt0903747:1:1",
                         currentVideo: "tt0903747:1:1", kind: .live)) == .mismatch,
               "REQ-50: conflicting live heads return the typed mismatch while ignoring current-video")
        let conflictingSeriesRoles = roles(
            catalog: "tt0903747", defaultVideo: "tt1375666",
            currentVideo: "tt2861424:1:1", kind: .series
        )
        expect(SourceIndexIdentity.resolve(conflictingSeriesRoles) == .mismatch,
               "REQ-50: conflicting series heads return the typed mismatch")
        expect(SourceIndexIdentity.publicationTarget(
                   conflictingSeriesRoles, season: 1, episode: 1) == .mismatch,
               "REQ-50: a conflicting series produces no auxiliary publication target")

        // An episode-scoped default is canonicalized, never returned unchanged.
        let episodeScoped = SourceIndexIdentity.resolve(
            roles(catalog: "tmdb:1399", defaultVideo: "tt0903747:1:1",
                  currentVideo: "tt0903747:3:5", kind: .series))
        expect(episodeScoped.titleID == "tt0903747",
               "F1: an EPISODE-scoped defaultVideoId is canonicalized, not returned unchanged")
        expect(SourceIndexClient.contentID(imdbId: episodeScoped.titleID, season: 3, episode: 5) == "tt0903747:3:5",
               "F1 end-to-end: the resolved identity composes tt0903747:3:5, never tt0903747:1:1:3:5")

        // THE PRESERVED FIELD CASE: tmdb-identified series, NO defaultVideoId, imdb identity ONLY on the
        // episode video id. The current-video role is the only source of an identity here, and it must work.
        let fieldCase = SourceIndexIdentity.resolve(
            roles(catalog: "tmdb:94997", defaultVideo: nil, currentVideo: "tt0460649:3:6", kind: .series))
        expect(fieldCase.titleID == "tt0460649",
               "F1 field case: an imdb EPISODE video id supplies the identity when no other role carries one")
        let fieldTarget = SourceIndexIdentity.publicationTarget(
            roles(catalog: "tmdb:94997", defaultVideo: nil,
                  currentVideo: "tt0460649:3:0", kind: .series),
            season: 3, episode: 0
        )
        expect(fieldTarget.target?.titleID == "tt0460649"
               && fieldTarget.target?.contentID == "tt0460649:3:0"
               && fieldTarget.target?.season == 3
               && fieldTarget.target?.episode == 0,
               "REQ-50: episode-only IMDb identity remains valid and preserves explicit E0")
        // The same inputs on a MOVIE resolve to nothing: a movie has no episode, so that role is not consulted.
        expect(SourceIndexIdentity.resolve(
                   roles(catalog: "tmdb:94997", defaultVideo: nil,
                         currentVideo: "tt0460649:3:6", kind: .movie)).titleID == nil,
               "F1: the current-video role is IGNORED for a movie, so kind is load-bearing, not decoration")

        // An episode-scoped default from a DIFFERENT episode than the one being viewed: the coordinates on the
        // id are noise and must be discarded, not carried into the key for the episode actually on screen.
        let otherEpisodeDefault = SourceIndexIdentity.resolve(
            roles(catalog: "tt0903747", defaultVideo: "tt0903747:1:1",
                  currentVideo: "tt0903747:5:9", kind: .series))
        expect(SourceIndexClient.contentID(imdbId: otherEpisodeDefault.titleID, season: 5, episode: 9) == "tt0903747:5:9",
               "F1: a default video id from a DIFFERENT episode never leaks its own coordinates into the key")

        // A malformed role is SKIPPED so a later good one still wins, and an all-malformed set resolves to
        // nothing rather than to a half-parsed value.
        expect(SourceIndexIdentity.resolve(
                   roles(catalog: "tt0903747:garbage", defaultVideo: "tt0903747",
                         currentVideo: nil, kind: .series)).titleID == "tt0903747",
               "F1: a malformed role is skipped, and the next canonical role wins")
        expect(SourceIndexIdentity.resolve(
                   roles(catalog: "kitsu:42", defaultVideo: "not-an-id",
                         currentVideo: nil, kind: .series)).titleID == nil,
               "F1: an all-malformed role set resolves to no identity at all")
        expect(SourceIndexIdentity.resolve(
                   roles(catalog: nil, defaultVideo: nil,
                         currentVideo: nil, kind: .series)) == .absent
               && SourceIndexIdentity.publicationTarget(
                   roles(catalog: nil, defaultVideo: nil,
                         currentVideo: nil, kind: .series),
                   season: 0, episode: 0) == .absent,
               "REQ-50: nil identity remains an explicit absent result, including S0E0")

        // `selecting` re-points the current-video role and nothing else (the batch coordinator's per-episode
        // step). Proven by a case where the current-video role is the ONLY identity source.
        let showLevel = roles(catalog: "tmdb:94997", defaultVideo: nil, currentVideo: nil, kind: .series)
        expect(SourceIndexIdentity.resolve(showLevel).titleID == nil
               && SourceIndexIdentity.resolve(showLevel.selecting(currentVideoID: "tt0460649:2:4")).titleID == "tt0460649",
               "F1 batch: selecting() supplies the per-episode current-video role the coordinator used to omit")

        // ---- REQ-260721-33: pool keys are IMDb ONLY, both platforms, movie / series / live ----
        // TMDB reuses numeric ids across the movie and tv namespaces and `content_id` carries no entity type,
        // so `tmdb:11` names two different titles. It may RESOLVE an IMDb id; it never becomes a key.
        expect(SourceIndexContract.canonicalContentID("tmdb:1399") == nil
               && SourceIndexContract.canonicalContentID("tmdb:1399:2:3") == nil,
               "REQ-33: the pool key gate refuses a tmdb key, bare and episode-scoped")
        expect(SourceIndexIdentity.resolve(
                   roles(catalog: "tmdb:1399", defaultVideo: nil,
                         currentVideo: "tmdb:1399:2:3", kind: .series)).titleID == nil,
               "REQ-33: a tmdb-only title resolves to NO identity, so it contributes nothing rather than a wrong key")
        expect(SourceIndexClient.contentID(imdbId: "tmdb:1399", season: 2, episode: 3) == nil
               && SourceIndexClient.contentID(imdbId: "tmdb:1399") == nil,
               "REQ-33: the client refuses a tmdb key on both the composed and the bare-title branch")
        expect(SourceIndexIdentity.imdbTitleID("tmdb:1399") == nil
               && SourceIndexIdentity.imdbTitleID("tt0903747:1:1") == "tt0903747"
               && SourceIndexIdentity.imdbTitleID("tt0903747") == "tt0903747",
               "REQ-33: the boundary validator accepts only a BARE imdb title id (TorBox stays bare-IMDb)")

        // ---- REQ-260721-38: the direct-resume identity fence ----
        // THE WORKED FAILURE: library item tt1375666 with a stored video tt0903747:1:1 published Game of
        // Thrones' assembled groups under tt1375666:1:1. The old guard compared episode NUMBERS, which
        // MATCHED, so it caught nothing. Compare canonical TITLE HEADS.
        expect(SourceIndexIdentity.resumeKey(itemID: "tt1375666", videoID: "tt0903747:1:1",
                                             season: 1, episode: 1) == nil,
               "F6: a resume whose item and stored video name DIFFERENT titles contributes NOTHING")
        expect(SourceIndexClient.resumeContentID(itemID: "tt1375666", videoID: "tt0903747:1:1",
                                                 season: 1, episode: 1) == nil,
               "F6: the same refusal through the client entry the resume paths actually call")
        expect(SourceIndexIdentity.resumeKey(itemID: "tt0903747", videoID: "tt0903747:1:1",
                                             season: 1, episode: 1) == "tt0903747:1:1",
               "F6: matching heads still contribute, with the coordinates the resume carries")
        expect(SourceIndexIdentity.resumeKey(itemID: "tt1375666", videoID: nil,
                                             season: nil, episode: nil) == "tt1375666",
               "F6: a movie resume has no stored video id to disagree with, so the item head stands alone")
        expect(SourceIndexIdentity.resumeKey(itemID: "tt0903747", videoID: "tt0903747:1:1",
                                             season: 1, episode: nil) == nil,
               "F6: the tuple-exact rule still applies to a resume, a partial pair is not widened")
        expect(SourceIndexIdentity.resumeKey(itemID: "tmdb:1399", videoID: "tmdb:1399:1:1",
                                             season: 1, episode: 1) == nil,
               "F6: matching TMDB heads still yield no key, because pool keys are IMDb-only")

        // ---- A1: the 128-byte identity CAP, asserted for the first time ----
        //
        // WHAT THE OLD ASSERTION HERE ACTUALLY TESTED. It read
        //     preferred(candidates: [String(repeating: "t", into: 4096)]).indexID == nil
        // and was labelled "an unbounded identity input is capped BEFORE parsing and rejected". It tested no
        // such thing. 4096 "t" characters fail `canonicalTitleID` on their FIRST character, because the anchor
        // is ^(tt[0-9]{6,10}|tmdb:[0-9]{1,10}) and "ttt" has no digit in position three. The case passed with
        // `maxIdentityInputBytes` set to Int.max, so it proved only that the regex rejects a non-id. It was a
        // false-confidence test: green either way, and worse than no test, because it occupied the slot where
        // the real one belonged.
        //
        // The three assertions below fail the moment the cap is removed or moved.
        expect(SourceIndexIdentity.maxIdentityInputBytes == 128,
               "A1: the identity input cap is pinned at 128 bytes (real ids are ~20)")
        expect(SourceIndexIdentity.boundedIdentityInput(String(repeating: "a", into: 128)) != nil,
               "A1: an input EXACTLY at the cap is accepted, so the bound is not off by one")
        expect(SourceIndexIdentity.boundedIdentityInput(String(repeating: "a", into: 129)) == nil,
               "A1: an input ONE BYTE over the cap is rejected before any parsing happens")
        expect(SourceIndexIdentity.boundedIdentityInput(String(repeating: "a", into: 105_000)) == nil,
               "A1: a 105 KB add-on-controlled identifier never reaches the parser")
        // The cap is applied BEFORE measurement too, so an unbounded value cannot inflate the one number the
        // diagnostics are allowed to print about it.
        expect(SourceIndexDiag.identityLength(String(repeating: "9", into: 105_000))
               == SourceIndexDiag.identityLengthOverCap,
               "A1: an over-cap identity reports the fixed sentinel, never its own 105000-byte length")

        // ---- A2: contentKey's OWN canonicalization guard ----
        // `contentKey` re-canonicalizes its `titleID` rather than trusting the caller, and nothing asserted it:
        // replacing that guard with `let title = titleID` left the whole suite green. It is the F1 defect class
        // one level down -- an episode-scoped id passed straight through -- so it gets its own coverage.
        expect(SourceIndexIdentity.contentKey(titleID: "tt0903747:1:1", season: nil, episode: nil) == "tt0903747",
               "A2: contentKey REDUCES an episode-scoped title id to the bare title, it does not pass it through")
        expect(SourceIndexIdentity.contentKey(titleID: "tt0903747:1:1", season: 3, episode: 5) == "tt0903747:3:5",
               "A2: contentKey composes from the REDUCED title, never tt0903747:1:1:3:5")
        // INVERTED (REQ-260721-33): the reduction still happens (canonicalTitleID is a reducer, and the
        // resume fence needs tmdb heads), but the reduced value is refused as a KEY at the final gate.
        expect(SourceIndexIdentity.contentKey(titleID: "tmdb:1399:2:3", season: 4, episode: 6) == nil
               && SourceIndexIdentity.contentKey(titleID: "tmdb:1399", season: nil, episode: nil) == nil,
               "A2: a tmdb head is refused as a pool key in BOTH the composed and the bare-title branch")
        expect(SourceIndexIdentity.contentKey(titleID: "kitsu:42", season: nil, episode: nil) == nil
               && SourceIndexIdentity.contentKey(titleID: "tt0903747:garbage", season: nil, episode: nil) == nil,
               "A2: a non-canonical titleID yields NO key, rather than being echoed back as one")

        // MOVIE behaviour: a movie page has no video-id role and no coordinates.
        let movie = SourceIndexIdentity.resolve(
            roles(catalog: "tt1375666", defaultVideo: "tt1375666", currentVideo: nil, kind: .movie))
        expect(movie.titleID == "tt1375666"
               && SourceIndexClient.contentID(imdbId: movie.titleID) == "tt1375666",
               "F1: a movie resolves to a bare title id and keys the pool without coordinates")

        // SEASON ZERO is VALID (specials air as S00Exx). Presence, never truthiness.
        expect(SourceIndexIdentity.contentKey(titleID: "tt0903747", season: 0, episode: 1) == "tt0903747:0:1",
               "F5: season zero is a VALID coordinate and still composes")

        // F5: PARTIAL coordinate pairs are REJECTED; both-absent is a valid show-wide request.
        expect(SourceIndexIdentity.contentKey(titleID: "tt0903747", season: 3, episode: nil) == nil
               && SourceIndexIdentity.contentKey(titleID: "tt0903747", season: nil, episode: 5) == nil,
               "F5: a PARTIAL coordinate pair is rejected, never widened to the show-wide key")
        expect(SourceIndexIdentity.contentKey(titleID: "tt0903747", season: nil, episode: nil) == "tt0903747",
               "F5: both coordinates absent is a valid bare-title request")
        expect(SourceIndexClient.contentID(imdbId: "tt0903747", season: 3) == nil
               && SourceIndexClient.contentID(imdbId: "tt0903747", episode: 5) == nil
               && SourceIndexClient.contentID(imdbId: "tt0903747", season: 0, episode: 1) == "tt0903747:0:1",
               "F5 through the client: partial pairs bail, season zero composes")

        // ---- F4: bounded, category-only diagnostics ----
        // The diag log is EXPORTED AND SHARED PUBLICLY by users. Prove that no catalog id and no rejected
        // add-on text ever reaches it, including newline-forging and unbounded inputs.
        let captured = CapturedDiagnostics()
        let previousSink = SourceIndexClient.diagnosticSink
        SourceIndexClient.diagnosticSink = { captured.append($0) }
        let secretID = "tt0903747:3:5"
        let hostileID = "tt0903747\nsing FORGED reason=fake token=SECRET-abc123"
        let hugeID = String(repeating: "9", into: 5000)
        _ = SourceIndexClient.contentID(imdbId: hostileID, season: 3, episode: 5)
        _ = SourceIndexClient.contentID(imdbId: hugeID, season: 3, episode: 5)
        _ = SourceIndexClient.contentID(imdbId: secretID, season: 3, episode: nil)
        await SourceIndexClient.contribute(contentID: secretID, descriptors: [])
        _ = await SourceIndexClient.fetchPooledUsing(
            contentID: secretID, isSignedIn: false,
            gate: { false }, moatProvider: { nil }, transport: { _ in throw SequenceFetchError.failed }
        )
        _ = SourceIndexClient.streams(from: [])
        SourceIndexClient.diagnosticSink = previousSink
        let emitted = captured.lines()
        expect(!emitted.isEmpty, "F4: the bail paths still emit diagnostics (silence was the original defect)")
        expect(emitted.allSatisfy { !$0.contains("tt0903747") && !$0.contains("0903747") },
               "F4: a raw catalog id (which IS viewing history) never reaches the exported diag log")
        expect(emitted.allSatisfy { !$0.contains("SECRET-abc123") && !$0.contains("FORGED") },
               "F4: rejected add-on-controlled text never reaches the exported diag log")
        expect(emitted.allSatisfy { !$0.contains("\n") && $0.utf8.count < 200 },
               "F4: no emitted line can be newline-forged or grown unbounded by a hostile identifier")
        expect(emitted.allSatisfy { $0.contains("run=") },
               "F4: every line carries the random per-process correlation token")
        expect(!emitted.contains(where: { $0.contains("consent=") || $0.contains("isSignedIn=") }),
               "F4: account/consent state is never a logged value")
        // USEFULNESS is half the fix: the reasons must still tell the bail paths apart.
        let reasons = Set(emitted.compactMap { line -> String? in
            line.split(separator: " ").first(where: { $0.hasPrefix("reason=") }).map(String.init)
        })
        expect(reasons.contains("reason=not-a-title-id")
               && reasons.contains("reason=non-canonical-episode-key")
               && reasons.contains("reason=gate-closed"),
               "F4: every distinct bail path is still individually identifiable by its reason")

        // A1 (continued): the CAP's observable consequence in the exported log. With the cap removed the
        // 5000-byte hostile id above is regex-parsed in full and its true length lands on the line.
        expect(emitted.contains(where: { $0.contains("rawLen=\(SourceIndexDiag.identityLengthOverCap)") }),
               "A1: an over-cap identifier logs the sentinel length, and the capped path is what emitted it")
        expect(emitted.allSatisfy { line in
            loggedLengths(in: line).allSatisfy { $0 >= -2 && $0 <= 128 }
        }, "A1: no length a line can carry exceeds the 128-byte cap, whatever the add-on sent")

        // ---- C3: three identity conditions, three distinguishable values ----
        // nil / empty / over-cap used to map onto only two values, so "the add-on sent nothing" and "the
        // add-on sent 105 KB" were the same number in the log. They are different bugs.
        let lengthValues = [SourceIndexDiag.identityLength(nil),
                            SourceIndexDiag.identityLength(""),
                            SourceIndexDiag.identityLength(String(repeating: "9", into: 105_000)),
                            SourceIndexDiag.identityLength("tt0903747")]
        expect(Set(lengthValues).count == 4,
               "C3: nil, empty, over-cap and ordinary identities are FOUR distinguishable logged values")
        expect(lengthValues[0] == 0 && lengthValues[1] == -1 && lengthValues[2] == -2 && lengthValues[3] == 9,
               "C3: and each one is the documented sentinel or the real bounded length")

        // ---- C1: the worker outcome survives, through a CLOSED enum ----
        // Two 200 responses, one login_required and one ok, used to emit the byte-identical line
        // `fetchPooled HTTP OK status=200 corroboratedSources=0`, because both decode to zero rows. SERVE is
        // login-gated by owner decision, so login_required is the single most useful answer there is.
        func fetchLine(reason: String) async -> [String] {
            let capture = CapturedDiagnostics()
            let previous = SourceIndexClient.diagnosticSink
            SourceIndexClient.diagnosticSink = { capture.append($0) }
            _ = await SourceIndexClient.fetchPooledUsing(
                contentID: "tt0903747:3:5", isSignedIn: true,
                gate: { true }, moatProvider: { "moat" },
                transport: { _ in
                    (Data(#"{"sources":[],"reason":"\#(reason)"}"#.utf8),
                     HTTPURLResponse(url: URL(string: "https://sources.vortx.tv/sources")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            )
            SourceIndexClient.diagnosticSink = previous
            return capture.lines().filter { $0.contains("fetchPooled HTTP OK") }
        }
        let loginLines = await fetchLine(reason: "login_required")
        let okLines = await fetchLine(reason: "ok")
        expect(loginLines.count == 1 && okLines.count == 1,
               "C1: a 200 read emits exactly one HTTP OK line")
        expect(loginLines != okLines,
               "C1: a login_required empty read and a genuinely empty pool are NOT byte-identical any more")
        expect(loginLines.first?.contains("outcome=login-required") == true
               && okLines.first?.contains("outcome=ok") == true,
               "C1: each maps onto its own closed-enum outcome")
        // The value is MAPPED, never echoed: hostile server text cannot reach the log through this field.
        // The two characters backslash-n, so the JSON body carries a valid \n ESCAPE and the decoded reason
        // really does contain a newline. A raw newline would be invalid JSON and would prove nothing.
        let hostileOutcome = await fetchLine(reason: "ok\\nsing FORGED token=SECRET-abc123")
        expect(hostileOutcome.first?.contains("outcome=other") == true,
               "C1: an unrecognised worker reason degrades to the closed `other` case")
        expect(hostileOutcome.allSatisfy { !$0.contains("FORGED") && !$0.contains("SECRET-abc123") && !$0.contains("\n") },
               "C1: server-authored free text never reaches the exported log, however it is spelled")

        // ---- C2: the fleet kill switch and the user gate are DIFFERENT reasons ----
        // One `gate-off` covered both, so a support reader could not tell "we disabled it fleet-wide" from
        // "this user opted out". Only the fleet flag's value is logged.
        func contributeGateReason(fleet: Bool) async -> [String] {
            RemoteConfigTestState.fleetOverride = fleet
            MoatConsent.contributeAndConsume = fleet ? false : true
            let capture = CapturedDiagnostics()
            let previous = SourceIndexClient.diagnosticSink
            SourceIndexClient.diagnosticSink = { capture.append($0) }
            await SourceIndexClient.contribute(contentID: "tt0903747:3:5", descriptors: [])
            SourceIndexClient.diagnosticSink = previous
            RemoteConfigTestState.fleetOverride = nil
            MoatConsent.contributeAndConsume = true
            return capture.lines()
        }
        let consentClosed = await contributeGateReason(fleet: true)    // fleet ON, consent OFF
        let fleetClosed = await contributeGateReason(fleet: false)     // fleet OFF
        expect(consentClosed.contains(where: { $0.contains("reason=gate-off") }),
               "C2: a fleet-enabled build with consent withdrawn reports the neutral user-gate reason")
        expect(fleetClosed.contains(where: { $0.contains("reason=fleet-off") }),
               "C2: the fleet kill switch reports itself by name (server config, not user data)")
        expect(!fleetClosed.contains(where: { $0.contains("reason=gate-off") }),
               "C2: and the two never collapse back onto one reason")
        expect((consentClosed + fleetClosed).allSatisfy { !$0.contains("consent=") && !$0.contains("=true") && !$0.contains("=false") },
               "C2: neither line prints a consent VALUE, only which gate is shut")

        // ---- C4: the mid-flight SERVE bails are distinguishable ----
        // Two silent `return []`s inside the do-block. They are not the same event: one means the gate shut
        // before a request was spent, the other means it shut with the response already in the air.
        func midFlightReasons(_ sequence: [Bool]) async -> Set<String> {
            let capture = CapturedDiagnostics()
            let previous = SourceIndexClient.diagnosticSink
            SourceIndexClient.diagnosticSink = { capture.append($0) }
            let gate = SequencedGate(sequence)
            _ = await SourceIndexClient.fetchPooledUsing(
                contentID: "tt0903747:3:5", isSignedIn: true,
                gate: { gate.value() }, moatProvider: { "moat" },
                transport: { _ in
                    (Data(#"{"sources":[]}"#.utf8),
                     HTTPURLResponse(url: URL(string: "https://sources.vortx.tv/sources")!,
                                     statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            )
            SourceIndexClient.diagnosticSink = previous
            return Set(capture.lines().compactMap { line -> String? in
                line.split(separator: " ").first(where: { $0.hasPrefix("reason=") }).map(String.init)
            })
        }
        let beforeTransport = await midFlightReasons([true, true, false, true])
        let afterTransport = await midFlightReasons([true, true, true, false])
        expect(beforeTransport.contains("reason=gate-closed-before-transport"),
               "C4: the gate closing BEFORE transport is no longer a silent return")
        expect(afterTransport.contains("reason=gate-closed-after-transport"),
               "C4: the gate closing AFTER transport names itself, and names itself DIFFERENTLY")
        expect(beforeTransport != afterTransport,
               "C4: the two mid-flight bails leave different traces")

        // C4 (contribute): a succeeded and a failed POST must not leave identical traces. The network attempt
        // itself is not exercised offline -- `contribute` reaches URLSession directly -- so what is asserted
        // here is the line each outcome produces, which is the part that was missing entirely.
        expect(SourceIndexDiag.line(.contributePostResult, counts: [(.batch, 1), (.succeeded, 1)])
               != SourceIndexDiag.line(.contributePostResult, counts: [(.batch, 1), (.succeeded, 0)]),
               "C4: a successful and a failed contribute POST are distinguishable in the log")
        expect(SourceIndexDiag.line(.contributeStop, reason: .postFailed).contains("reason=post-failed")
               && SourceIndexDiag.line(.contributeStop, reason: .cancelled).contains("reason=cancelled")
               && SourceIndexDiag.line(.contributeSkip, reason: .alreadyClaimed).contains("reason=already-claimed"),
               "C4: every newly-closed contribute exit has its own reason")

        // ---- B: the closed vocabulary itself ----
        // The claim on `diag` is that no free text can be interpolated. That is now a type property, so what
        // is checkable at runtime is that the vocabulary is DISTINCT: two events or two reasons sharing a
        // spelling would reintroduce exactly the blindness the reasons exist to cure.
        let allEvents: [SourceIndexDiag.Event] = [
            .contentIDSkip, .contributeSkip, .contributeBegin, .contributePost, .contributePostResult,
            .contributeStop, .fetchPooledSkip, .fetchPooledGate, .fetchPooledGateClosed, .fetchPooledGet,
            .fetchPooledHTTP, .fetchPooledHTTPOK, .streamsReconstruct, .refreshPublish, .refreshPublishSkipped,
        ]
        expect(Set(allEvents.map(\.rawValue)).count == allEvents.count,
               "B: every event label is distinct")
        let allReasons: [SourceIndexDiag.Reason] = [
            .notATitleID, .nonCanonicalEpisodeKey, .fleetOff, .gateOff, .nonCanonicalContentID,
            .nothingUploadable, .alreadyClaimed, .bodyEncodingFailed, .cancelled, .postFailed, .gateClosed,
            .gateChangedOrNoMoat, .gateClosedBeforeTransport, .gateClosedAfterTransport, .httpNon2xx,
            .httpError, .staleOrCancelled, .malformedServeURL,
        ]
        expect(Set(allReasons.map(\.rawValue)).count == allReasons.count,
               "B: every bail reason is distinct")
        expect(Set([SourceIndexDiag.Outcome(worker: nil), .init(worker: "ok"), .init(worker: "LOGIN_REQUIRED"),
                    .init(worker: "something-else")].map(\.rawValue)).count == 4,
               "B: the worker-outcome mapping is closed AND total: four inputs, four distinct closed cases")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}

/// Every `rawLen=` / `contentLen=` value on one emitted line. Used to assert that NO identity-derived number
/// a diagnostic can carry ever exceeds the input cap, whatever an add-on sent.
func loggedLengths(in line: String) -> [Int] {
    line.split(separator: " ").compactMap { token -> Int? in
        for prefix in ["rawLen=", "contentLen="] where token.hasPrefix(prefix) {
            return Int(token.dropFirst(prefix.count))
        }
        return nil
    }
}

private extension String {
    func repeating(_ count: Int) -> String { String(repeating: self, count: count) }
    /// Disambiguating spelling used by the identity/diagnostic cases, whose `repeating` reads as a method on a
    /// literal and collides with the extension above at the call site.
    init(repeating value: String, into count: Int) { self.init(repeating: value, count: count) }
}
