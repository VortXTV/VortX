// Standalone strict executable for the production Debrid provider-task lease.
//
// Run with:
//   swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -o /tmp/debrid-cancellation \
//     app/SourcesShared/CredentialScope.swift \
//     app/SourcesShared/DebridResolver.swift \
//     app/Tests/DebridCredentialCancellationTests.swift && /tmp/debrid-cancellation

import Foundation

// Minimal non-UI production dependencies for compiling the real coordinator in this standalone harness.
protocol ObservableObject {}

@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value

    init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}

enum VXProbe { static let enabled = false }

enum DebridService: String, CaseIterable, Hashable, Sendable {
    case realDebrid, allDebrid, premiumize, torBox

    var poolProviderTag: String { rawValue }
}

struct DebridCredentialSnapshot: Sendable, Equatable {
    let owner: CredentialScope
    let authorityCapture: CredentialScopeRegistry.Capture
    let revision: UInt64
    let keys: [DebridService: String]
}

@MainActor
final class DebridKeys {
    static let shared = DebridKeys()

    var credentialSnapshot: DebridCredentialSnapshot {
        DebridCredentialSnapshot(
            owner: .signedOutDevice,
            authorityCapture: CredentialScopeRegistry.shared.capture(),
            revision: 0,
            keys: [:])
    }
}

struct EpisodePlaybackIdentity {
    struct FileCandidate {
        init(offset: Int, name: String, size: Int64, isVideo: Bool) {}
    }

    static func providerArrayFallbackAllowed(
        requiresSemanticSelection: Bool,
        season: Int?,
        episode: Int?,
        sourceFilename: String?
    ) -> Bool { true }

    static func pickFileOffset(
        _ candidates: [FileCandidate],
        season: Int?,
        episode: Int?,
        sourceFilename: String?
    ) -> Int? { candidates.first.map { _ in 0 } }
}

struct CoreStream: Sendable {
    struct BehaviorHints: Sendable { let filename: String? }

    var sources: [String]?
    var behaviorHints: BehaviorHints?
    var fileIdx: Int?
    var fileMustInclude: String?
    var infoHash: String?
    var isUsenet: Bool
    var nzbUrl: String?
    var url: URL?
}

struct CoreStreamSourceGroup: Sendable {
    var streams: [CoreStream]
}

enum StreamRanking {
    static func resolutionRank(_ stream: CoreStream) -> Int { 0 }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationErrorReceived = false
    private var completionCount = 0

    func recordCancellation() {
        lock.lock()
        cancellationErrorReceived = true
        lock.unlock()
    }

    func recordCompletion() {
        lock.lock()
        completionCount += 1
        lock.unlock()
    }

    func snapshot() -> (cancelled: Bool, completions: Int) {
        lock.lock()
        let value = (cancellationErrorReceived, completionCount)
        lock.unlock()
        return value
    }
}

private final class CoordinatorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private var didReceiveCancellation = false
    private var didComplete = false
    private var didRelease = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func entered() {
        lock.lock()
        didEnter = true
        lock.unlock()
    }

    func cancelled() {
        lock.lock()
        didReceiveCancellation = true
        lock.unlock()
    }

    func completed() {
        lock.lock()
        didComplete = true
        lock.unlock()
    }

    func snapshot() -> (entered: Bool, cancelled: Bool, completed: Bool, released: Bool) {
        lock.lock()
        let value = (didEnter, didReceiveCancellation, didComplete, didRelease)
        lock.unlock()
        return value
    }

    func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if didRelease {
                lock.unlock()
                continuation.resume()
            } else {
                releaseContinuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        didRelease = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private actor SuspendingResolver: DebridResolving {
    nonisolated let service: DebridService = .torBox

    private let probe: CoordinatorProbe
    private let workStream: AsyncStream<Void>
    private let workContinuation: AsyncStream<Void>.Continuation

    init(probe: CoordinatorProbe) {
        self.probe = probe
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        workStream = stream
        workContinuation = continuation
    }

    func checkCache(hashes: [String]) async throws -> [String: [DebridFile]] { [:] }

    func resolve(
        infoHash: String,
        magnet: String,
        fileIdx: Int?,
        episode: DebridEpisode?
    ) async throws -> URL {
        probe.entered()
        do {
            try await withTaskCancellationHandler {
                for await _ in workStream { }
                try Task.checkCancellation()
            } onCancel: {
                workContinuation.finish()
            }
            probe.completed()
            return URL(string: "https://provider.invalid/\(infoHash)")!
        } catch is CancellationError {
            probe.cancelled()
            await probe.waitForRelease()
            throw CancellationError()
        }
    }
}

private final class CoordinatorFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [(revision: UInt64, resolver: SuspendingResolver, probe: CoordinatorProbe)] = []

    func make(_ snapshot: DebridCredentialSnapshot) -> [DebridService: any DebridResolving] {
        guard !snapshot.keys.isEmpty else { return [:] }
        let probe = CoordinatorProbe()
        let resolver = SuspendingResolver(probe: probe)
        lock.lock()
        created.append((snapshot.revision, resolver, probe))
        lock.unlock()
        return [.torBox: resolver]
    }

    func latest() -> (revision: UInt64, resolver: SuspendingResolver, probe: CoordinatorProbe)? {
        lock.lock()
        let value = created.last
        lock.unlock()
        return value
    }

    func count() -> Int {
        lock.lock()
        let value = created.count
        lock.unlock()
        return value
    }
}

@MainActor private var failures: [String] = []
@MainActor private var checks = 0

@MainActor
private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

private func source(_ relativePath: String) -> String? {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = testsDirectory.deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

private func sourceRegion(_ source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else { return "" }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func containsInOrder(_ source: String, _ fragments: [String]) -> Bool {
    var remainder = source[...]
    for fragment in fragments {
        guard let range = remainder.range(of: fragment) else { return false }
        remainder = remainder[range.upperBound...]
    }
    return true
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<2_000 {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private func testProductionWiring() -> (resolver: Bool, keys: Bool, sync: Bool) {
    let resolver = source("SourcesShared/DebridResolver.swift") ?? ""
    let keys = source("SourcesShared/DebridKeys.swift") ?? ""
    let sync = source("SourcesShared/VortXSyncManager.swift") ?? ""
    let providerLeaseCalls = resolver.components(separatedBy: "runProvider(").count - 1
    let setKeyRegion = sourceRegion(keys, from: "func setKey(", to: "func applyRemoteKeys(")
    let remoteApplyRegion = sourceRegion(keys, from: "func applyRemoteKeys(", to: "private func reloadResolvers(")
    let primarySyncApplyRegion = sourceRegion(
        sync,
        from: "if let keys = doc[\"apiKeys\"] as? [String: String] {",
        to: "if doc[\"apiKeys\"] == nil, !pendingDebridValues.isEmpty {")
    let setKeyWiring = containsInOrder(setKeyRegion, [
        "let authorityCapture = CredentialScopeRegistry.shared.capture()",
        "guard authorityCapture.scope == owner,\n              CredentialScopeRegistry.shared.isCurrent(authorityCapture) else { return false }",
        "guard owner == boundOwner,\n                  CredentialScopeRegistry.shared.isCurrent(authorityCapture) else { return false }",
        "guard storage.mutate(expected, for: account) == .success else { continue }",
        "guard certified,\n              owner == boundOwner,\n              CredentialScopeRegistry.shared.isCurrent(authorityCapture) else { return false }",
        "revision &+= 1",
        "let snapshot = self.credentialSnapshot(capture: authorityCapture)",
        "await DebridCoordinator.shared.reload(snapshot: snapshot)"
    ])
    let remoteApplyWiring = containsInOrder(remoteApplyRegion, [
        "let remoteServices = Set(values.keys.compactMap(DebridService.init(rawValue:)))",
        "guard owner == capture.scope,\n              capture.scope == owner,\n              CredentialScopeRegistry.shared.isCurrent(capture) else {",
        "for service in DebridService.allCases {",
        "guard let value = values[service.rawValue] else { continue }",
        "guard CredentialScopeRegistry.shared.isCurrent(capture), owner == capture.scope else {",
        "if value != key(for: service), !setKey(value, for: service) {"
    ])
    let primaryApplyWiring = containsInOrder(primarySyncApplyRegion, [
        "guard isCurrent(capture) else { return }",
        "DebridKeys.shared.applyRemoteKeys(remoteDebridValues, capture: capture)"
    ])
    return (
        resolver.contains("DebridProviderTaskRegistry")
            && resolver.contains("beginTransition()")
            && resolver.contains("runProvider")
            && resolver.contains("await taskRegistry.finishTransition")
            && providerLeaseCalls >= 8,
        keys.contains("migrateLegacyIfEligible")
            && setKeyWiring
            && remoteApplyWiring,
        sync.contains("private func bindCredentialOwner")
            && sync.contains("bindCredentialOwner(.signedOutDevice)")
            && sync.contains("guard isCurrent(capture)")
            && primaryApplyWiring
            && sync.contains("DebridKeys.shared.applyRemoteKeys(pendingDebridValues, capture: capture)")
    )
}

private func testProviderPollingCancellationWiring() -> (
    realDebridFileList: Bool,
    realDebridReady: Bool,
    allDebrid: Bool
) {
    let resolver = source("SourcesShared/DebridResolver.swift") ?? ""
    func region(_ start: String, _ end: String) -> String {
        guard let startRange = resolver.range(of: start),
              let endRange = resolver.range(of: end, range: startRange.upperBound..<resolver.endIndex) else { return "" }
        return String(resolver[startRange.lowerBound..<endRange.lowerBound])
    }
    func loopBodies(_ region: String) -> [String] {
        let marker = "for attempt in 0..<12"
        var rest = region
        var bodies: [String] = []
        while let range = rest.range(of: marker) {
            rest = String(rest[range.upperBound...])
            if let next = rest.range(of: marker) {
                bodies.append(String(rest[..<next.lowerBound]))
                rest = String(rest[next.lowerBound...])
            } else {
                bodies.append(rest)
                break
            }
        }
        return bodies
    }
    let rdLoops = loopBodies(region("actor RealDebridResolver", "actor AllDebridResolver"))
    let adLoops = loopBodies(region("actor AllDebridResolver", "actor PremiumizeResolver"))
    let rdReady = rdLoops.count >= 2
        && rdLoops.prefix(2).allSatisfy {
            $0.contains("try await Task.sleep(nanoseconds: 2_000_000_000)")
                && $0.contains("try Task.checkCancellation()")
                && !$0.contains("try? await Task.sleep")
        }
    let ad = adLoops.count >= 1
        && adLoops[0].contains("try await Task.sleep(nanoseconds: 3_000_000_000)")
        && adLoops[0].contains("try Task.checkCancellation()")
        && !adLoops[0].contains("try? await Task.sleep")
    return (rdLoops.count >= 2 && rdLoops.prefix(2).allSatisfy { $0.contains("try Task.checkCancellation()") }, rdReady, ad)
}

private func testRealCoordinatorCancellation() async -> (
    oldTaskCancelled: Bool,
    newOwnerDidNotWait: Bool,
    staleCompletionDidNotPublish: Bool,
    newOwnerAdmitted: Bool,
    repeatedReloadIdempotent: Bool,
    signOutTaskCancelled: Bool,
    signedOutNoResolver: Bool
) {
    let accountA = CredentialScope(canonicalRemoteAccountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    let captureA = await MainActor.run { CredentialScopeRegistry.shared.bind(accountA) }
    let factory = CoordinatorFactory()
    let coordinator = DebridCoordinator(resolverFactory: { snapshot in factory.make(snapshot) })
    let snapshotA = DebridCredentialSnapshot(
        owner: accountA,
        authorityCapture: captureA,
        revision: 1,
        keys: [.torBox: "A-key"])
    await coordinator.reload(snapshot: snapshotA)
    guard let old = factory.latest() else {
        return (false, false, false, false, false, false, false)
    }

    let oldResolve = Task {
        do {
            _ = try await coordinator.resolve(
                service: .torBox,
                infoHash: "old-hash",
                magnet: "magnet:?xt=urn:btih:old",
                fileIdx: nil,
                episode: nil)
            return true
        } catch {
            return false
        }
    }
    let oldEntered = await waitUntil { old.probe.snapshot().entered }
    let captureB = await MainActor.run { CredentialScopeRegistry.shared.bind(accountB) }
    let snapshotB = DebridCredentialSnapshot(
        owner: accountB,
        authorityCapture: captureB,
        revision: 2,
        keys: [.torBox: "B-key"])
    let reloadB = Task { await coordinator.reload(snapshot: snapshotB) }
    let oldCancelled = await waitUntil { old.probe.snapshot().cancelled }
    let beforeRelease = old.probe.snapshot()

    // The old provider is deliberately held after receiving CancellationError. The coordinator actor must
    // still answer an authority-fenced new-owner query immediately while reload waits to retire that task.
    let hasResolverDuringRetirement = await coordinator.hasAnyResolver
    let newOwnerDidNotWait = oldEntered
        && oldCancelled
        && !beforeRelease.released
        && !hasResolverDuringRetirement

    old.probe.release()
    _ = await reloadB.result
    let oldReturnedValue = await oldResolve.value
    let afterRelease = old.probe.snapshot()
    let staleCompletionDidNotPublish = !oldReturnedValue && !afterRelease.completed
        && factory.count() == 2
    let newOwnerAdmitted = await coordinator.hasAnyResolver

    // Same owner/revision is latest-only and must not rebuild or cancel a newly published resolver set.
    await coordinator.reload(snapshot: snapshotB)
    let repeatedReloadIdempotent = factory.count() == 2
    guard let new = factory.latest() else {
        return (oldCancelled, newOwnerDidNotWait, staleCompletionDidNotPublish, newOwnerAdmitted,
                repeatedReloadIdempotent, false, false)
    }
    let newResolve = Task {
        do {
            _ = try await coordinator.resolve(
                service: .torBox,
                infoHash: "new-hash",
                magnet: "magnet:?xt=urn:btih:new",
                fileIdx: nil,
                episode: nil)
            return true
        } catch {
            return false
        }
    }
    let newEntered = await waitUntil { new.probe.snapshot().entered }
    let signedOutCapture = await MainActor.run { CredentialScopeRegistry.shared.bind(.signedOutDevice) }
    let signedOutSnapshot = DebridCredentialSnapshot(
        owner: .signedOutDevice,
        authorityCapture: signedOutCapture,
        revision: 3,
        keys: [:])
    let reloadSignedOut = Task { await coordinator.reload(snapshot: signedOutSnapshot) }
    let signOutCancelledObserved = await waitUntil { new.probe.snapshot().cancelled }
    let signOutTaskCancelled = newEntered && signOutCancelledObserved
    new.probe.release()
    _ = await reloadSignedOut.result
    _ = await newResolve.value
    let signedOutHasNoResolver = !(await coordinator.hasAnyResolver)

    return (
        oldCancelled,
        newOwnerDidNotWait,
        staleCompletionDidNotPublish,
        newOwnerAdmitted,
        repeatedReloadIdempotent,
        signOutTaskCancelled,
        signedOutHasNoResolver
    )
}

private func testCancellationLifecycle() async -> (
    oldTaskCancelled: Bool,
    oldTaskDidNotPublish: Bool,
    newOwnerDidNotWait: Bool,
    newOwnerAdmitted: Bool,
    staleLeaseCouldNotRetireNewOwner: Bool,
    repeatedTransitionIdempotent: Bool,
    exactRevisionFence: Bool
) {
    let accountA = CredentialScope(canonicalRemoteAccountID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let accountB = CredentialScope(canonicalRemoteAccountID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    let staleCapture = await MainActor.run { CredentialScopeRegistry.shared.bind(accountA) }
    let currentA = await MainActor.run { CredentialScopeRegistry.shared.bind(accountA) }
    let registry = DebridProviderTaskRegistry()
    let probe = CancellationProbe()
    let (stream, continuation) = AsyncStream<Void>.makeStream()

    let staleLease = await registry.start(
        owner: accountA,
        capture: staleCapture,
        revision: 1,
        operation: { () }
    )
    let exactRevisionFence = staleLease == nil

    let admitted = await registry.start(
        owner: accountA,
        capture: currentA,
        revision: 2,
        operation: {
            do {
                try await withTaskCancellationHandler {
                    for await _ in stream { }
                    try Task.checkCancellation()
                } onCancel: {
                    continuation.finish()
                }
                probe.recordCompletion()
            } catch is CancellationError {
                probe.recordCancellation()
                throw CancellationError()
            }
        }
    )
    guard let admitted else {
        continuation.finish()
        return (false, false, false, false, false, false, exactRevisionFence)
    }

    let captureB = await MainActor.run { CredentialScopeRegistry.shared.bind(accountB) }
    let transitionTask = Task { await registry.beginTransition() }
    let transferStarted = await waitUntil { await registry.isTransitionInProgress }
    let duringTransfer = await registry.start(
        owner: accountB,
        capture: captureB,
        revision: 3,
        operation: { () }
    ) == nil
    let newOwnerDidNotWait = transferStarted && duringTransfer

    let transition = await transitionTask.value
    await registry.finishTransition(transition)
    let probeResult = probe.snapshot()
    let oldTaskCancelled = probeResult.cancelled && probeResult.completions == 0

    let newLease = await registry.start(
        owner: accountB,
        capture: captureB,
        revision: 3,
        operation: { () }
    )
    let newOwnerAdmitted = newLease != nil

    // A late old completion cannot remove a new owner's lease because retirement is token-identity bound.
    await registry.finishTransition(transition)
    let stillAdmitted = await registry.contains(newLease?.lease)
    let staleLeaseCouldNotRetireNewOwner = stillAdmitted
    if let newLease { await registry.finish(newLease.lease) }
    await registry.finish(admitted.lease)

    let secondTransition = await registry.beginTransition()
    await registry.finishTransition(secondTransition)
    let thirdTransition = await registry.beginTransition()
    await registry.finishTransition(thirdTransition)
    let repeatedTransitionIdempotent = await registry.activeCount == 0

    return (
        oldTaskCancelled,
        probeResult.completions == 0,
        newOwnerDidNotWait,
        newOwnerAdmitted,
        staleLeaseCouldNotRetireNewOwner,
        repeatedTransitionIdempotent,
        exactRevisionFence
    )
}

@main
struct DebridCredentialCancellationTestRunner {
    @MainActor
    static func main() async {
        let wiring = testProductionWiring()
        expect(wiring.resolver, "DebridResolver is wired to the production owner/revision task registry")
        expect(wiring.keys, "DebridKeys preserves certified setKey reload delegation and migration wiring")
        expect(wiring.sync, "VortXSyncManager preserves fenced remote-key delegation and pending apply wiring")

        let polling = testProviderPollingCancellationWiring()
        expect(polling.realDebridFileList,
               "Real-Debrid file-list polling checks cancellation before every request")
        expect(polling.realDebridReady,
               "Real-Debrid readiness polling uses throwing sleeps and cancellation checks")
        expect(polling.allDebrid,
               "AllDebrid polling uses throwing sleeps and cancellation checks")

        let coordinator = await testRealCoordinatorCancellation()
        expect(coordinator.oldTaskCancelled,
               "the real DebridCoordinator provider task receives CancellationError on owner switch")
        expect(coordinator.newOwnerDidNotWait,
               "the real DebridCoordinator answers a new-owner query without waiting behind old work")
        expect(coordinator.staleCompletionDidNotPublish,
               "the real DebridCoordinator rejects stale completion publication")
        expect(coordinator.newOwnerAdmitted,
               "the real DebridCoordinator admits the new owner after physical retirement")
        expect(coordinator.repeatedReloadIdempotent,
               "the real DebridCoordinator ignores repeated same-revision reloads")
        expect(coordinator.signOutTaskCancelled,
               "the real DebridCoordinator physically cancels provider work on sign-out")
        expect(coordinator.signedOutNoResolver,
               "the real DebridCoordinator publishes the signed-out no-key resolver state")

        let lifecycle = await testCancellationLifecycle()
        expect(lifecycle.oldTaskCancelled,
               "an old provider task receives CancellationError during authority transfer")
        expect(lifecycle.oldTaskDidNotPublish,
               "a cancelled old provider completion cannot publish a result")
        expect(lifecycle.newOwnerDidNotWait,
               "a new owner is rejected immediately during old-task retirement instead of waiting")
        expect(lifecycle.newOwnerAdmitted,
               "the new owner is admitted immediately after old tasks retire")
        expect(lifecycle.staleLeaseCouldNotRetireNewOwner,
               "a stale old lease cannot retire a new owner's exact lease")
        expect(lifecycle.repeatedTransitionIdempotent,
               "repeated empty reload transitions are idempotent")
        expect(lifecycle.exactRevisionFence,
               "a stale capture/revision cannot register provider work")

        if failures.isEmpty {
            print("PASS: \(checks) Debrid credential cancellation checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
