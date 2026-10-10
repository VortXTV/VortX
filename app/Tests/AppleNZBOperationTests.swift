import Foundation

private final class Owner: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    func invalidate() { lock.withLock { current = false } }
    func check() -> Bool { lock.withLock { current } }
}
private final class CloseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

// The baseline adapter changes only the old URL return shape so the same wire assertions run.
// It supplies no operation ID, cancellation, owner monitoring, or selector behavior absent in production.
#if NZB_OPERATION_BASELINE
extension UsenetNodeClient {
    final class OperationLease: @unchecked Sendable, Equatable {
        static func == (lhs: OperationLease, rhs: OperationLease) -> Bool { lhs === rhs }
        let id = "baseline-has-no-operation"
        func close() {}
    }
    struct Selection: Sendable {
        struct Episode: Sendable { let season: Int; let episode: Int }
        var fileIdx: Int? = nil
        var fileMustInclude: String? = nil
        var episode: Episode? = nil
    }
    struct CreatedStream: Sendable { let url: URL; let lease: OperationLease? }
}
#endif

@main @MainActor private enum AppleNZBOperationTests {
    static var base: String { CommandLine.arguments[1] }
    static func snapshot() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/__snapshot")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func creates() async throws -> [[String: Any]] { try await snapshot()["creates"] as! [[String: Any]] }
    static func cancelled(_ id: String) async -> Bool {
        ((try? await snapshot()["cancels"] as? [String]) ?? []).contains(id)
    }
    static func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<60 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
    static func create(_ scenario: String = "ready", owner: Owner = Owner(),
                       selection: UsenetNodeClient.Selection = .init(), native: Bool = true) async throws -> UsenetNodeClient.CreatedStream {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        #if NZB_OPERATION_BASELINE
        let url = try await UsenetNodeClient.createStream(endpoint: .init(base: base, requiresNativeCapabilities: native),
            nzbURLs: ["https://fixture.invalid/" + scenario],
            servers: ["nntps://fixture:first@one.invalid:563/2", "nntps://fixture:second@two.invalid:563/2"],
            session: session, timeout: 4)
        return .init(url: url, lease: native ? .init() : nil)
        #else
        return try await UsenetNodeClient.createStream(endpoint: .init(base: base, requiresNativeCapabilities: native),
            nzbURLs: ["https://fixture.invalid/" + scenario],
            servers: ["nntps://fixture:first@one.invalid:563/2", "nntps://fixture:second@two.invalid:563/2"],
            session: session, timeout: 4, selection: selection, ownerIsCurrent: { owner.check() })
        #endif
    }

    static func main() async throws {
        var failed = 0
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1; print("PASS " + name) }
            else { failed += 1; print("FAIL " + name) }
        }
        let selected = try await create(selection: .init(fileIdx: 0, fileMustInclude: "/S01E02/i", episode: .init(season: 1, episode: 2)))
        let first = try await creates().last!
        let id = selected.lease!.id
        #if !NZB_OPERATION_BASELINE
        let closeCounter = CloseCounter()
        selected.lease?.onClose { closeCounter.increment() }
        #endif
        check(UUID(uuidString: first["operationId"] as? String ?? "") != nil, "UUID exists before native create")
        check(first["fileIdx"] as? Int == 0 && first["fileMustInclude"] as? String == "/S01E02/i"
              && (first["episode"] as? [String: Int]) == ["season": 1, "episode": 2], "all explicit selectors preserved including zero")
        check((first["servers"] as? [String])?.count == 2 && first["fileIdxOrder"] == nil, "ordered servers in one create; no invented index domain")
        check(!(await cancelled(id)), "returned lease survives resolver session invalidation")
        selected.lease?.close(); selected.lease?.close()
        #if !NZB_OPERATION_BASELINE
        selected.lease?.onClose { closeCounter.increment() }
        check(closeCounter.count == 2, "close observers fire once and late registration fires immediately")
        #endif
        check(await eventually { await cancelled(id) }, "explicit close works after resolver session invalidation")
        let cancellations = try await snapshot()["cancels"] as! [String]
        check(cancellations.filter { $0 == id }.count == 1, "repeated close is idempotent")

        let legacy = try await create(selection: .init(fileIdx: 7), native: false)
        let legacyBody = try await creates().last!
        check(legacy.lease == nil && legacyBody["operationId"] == nil && legacyBody["fileIdx"] == nil,
              "legacy payload and lifetime unchanged")

        let beforePending = try await creates().count
        let pending = Task { try await create("pending") }
        _ = await eventually { (try? await creates().count) == beforePending + 1 }
        let pendingID = try await creates().last!["operationId"] as? String ?? "baseline-pending"
        pending.cancel()
        do { _ = try await pending.value } catch {}
        check(await eventually { await cancelled(pendingID) }, "caller cancel retires unknown-key operation")

        let owner = Owner()
        let beforeOwnerPending = try await creates().count
        let ownedPending = Task { try await create("pending", owner: owner) }
        _ = await eventually { (try? await creates().count) == beforeOwnerPending + 1 }
        let ownedID = try await creates().last!["operationId"] as? String ?? "baseline-owned"
        owner.invalidate()
        let ownedResult = try? await ownedPending.value
        let ownedCancelled = await eventually { await cancelled(ownedID) }
        check(ownedResult == nil && ownedCancelled,
              "retired owner cannot publish a delayed key")

        let playbackOwner = Owner()
        let playing = try await create(owner: playbackOwner)
        let heldLaunchCopy = playing
        playbackOwner.invalidate()
        check(await eventually { await cancelled(playing.lease!.id) }, "owner retirement closes published lease despite retained reference")
        withExtendedLifetime(heldLaunchCopy) {}

        let current = try await create()
        let prepared = try await create()
        check(!(await cancelled(current.lease!.id)), "next-episode preparation does not retire current playback")
        prepared.lease?.close()
        let preparedCancelled = await eventually { await cancelled(prepared.lease!.id) }
        let currentStillLive = !(await cancelled(current.lease!.id))
        check(preparedCancelled && currentStillLive,
              "discarded prewarm closes only its own operation")

        let successor = try await create()
        // Exact one-argument SwiftUI onChange closure body/capture is extracted by the runner.
        let replacement = PlaybackHooks()
        replacement.curDebridRef = .init(nativeUsenetLease: current.lease)
        let changed = replacement.replacementCallback()
        changed(current.lease)
        check(!(await cancelled(current.lease!.id)), "same lease engine handoff does not retire playback")
        changed(successor.lease)
        let replacedCancelled = await eventually { await cancelled(current.lease!.id) }
        let successorStillLive = !(await cancelled(successor.lease!.id))
        check(replacedCancelled && successorStillLive,
              "accepted differing lease closes old playback while launch copy survives")

        let incoming = try await create()
        replacement.curDebridRef = .init(nativeUsenetLease: successor.lease)
        replacement.pendingAdvance = .init(debridRef: .init(nativeUsenetLease: incoming.lease))
        replacement.presentTerminalLoadFailure()
        replacement.leavePlayback()
        check(await eventually {
            let old = await cancelled(successor.lease!.id)
            let next = await cancelled(incoming.lease!.id)
            return old && next
        },
              "actual terminal and stop hooks retire pending and current idempotently")

        for scenario in ["failure", "mismatch", "malformed"] {
            do { _ = try await create(scenario); check(false, scenario + " refuses URL") }
            catch {
                #if !NZB_OPERATION_BASELINE
                if scenario == "mismatch" {
                    check(error as? UsenetNodeClient.ClientError == .selectionUnmatched,
                          "native selector mismatch is not diagnosed as unsupported archive")
                }
                #endif
                let failedID = try await creates().last!["operationId"] as? String ?? "baseline-failure"
                check(await eventually { await cancelled(failedID) }, scenario + " retires its UUID before retry")
            }
        }
        let retry = try await create()
        check(retry.lease?.id != id, "retry has a fresh operation ID")
        retry.lease?.close()

        func droppedLease() async throws -> String { try await create().lease!.id }
        let dropped = try await droppedLease()
        check(await eventually { await cancelled(dropped) }, "monitor does not retain discarded final reference")
        #if !NZB_OPERATION_BASELINE
        let admissionOwner = Owner()
        let admissionLease = try await create(owner: admissionOwner).lease!
        admissionOwner.invalidate()
        do {
            try await admissionLease.validateOwner()
            check(false, "consumer admission rejects retired owner without waiting for monitor")
        } catch {
            check(admissionLease.isClosed, "consumer admission rejects retired owner without waiting for monitor")
        }
        let invalidOwner = Owner(); invalidOwner.invalidate()
        let before = try await creates().count
        do { _ = try await create(owner: invalidOwner) } catch {}
        do { _ = try await create(selection: .init(fileIdx: -1)) } catch {}
        check(try await creates().count == before, "retired owner and invalid selector fail before create")
        let capture = CredentialScopeRegistry.shared.capture()
        let ownerCheck = UsenetLocalResolver.nativeOwnerCheck(capture: capture)
        let capturedValid = await ownerCheck()
        await MainActor.run { CoreBridge.shared.resolveJob = UUID() }
        let validAfterPrewarm = await ownerCheck()
        check(capturedValid && validAfterPrewarm, "actual owner predicate excludes prewarm resolve job")
        await MainActor.run { CoreBridge.shared.generation = UUID() }
        check(!(await ownerCheck()), "actual owner predicate rejects retired native installation")
        let nextCheck = UsenetLocalResolver.nativeOwnerCheck(capture: capture)
        CredentialScopeRegistry.shared.retire()
        check(!(await nextCheck()), "actual owner predicate rejects credential generation change")
        let freshCapture = CredentialScopeRegistry.shared.capture()
        let profileCheck = UsenetLocalResolver.nativeOwnerCheck(capture: freshCapture)
        await MainActor.run { ProfileStore.shared.activeID = UUID() }
        check(!(await profileCheck()), "actual owner predicate rejects profile change")
        await MainActor.run { StremioServer.usenetEndpoint = .init(base: base, requiresNativeCapabilities: true) }
        let routed = try await UsenetLocalResolver.resolveRouted(
            nzbURLs: ["https://fixture.invalid/ready"], servers: ["nntps://fixture:one@one.invalid:563/2"],
            selection: .init(fileIdx: 3, episode: .init(season: 0, episode: 1)), ownerIsCurrent: { true })!
        let routedBody = try await creates().last!
        check(routed.nativeLease != nil && routedBody["fileIdx"] as? Int == 3
              && (routedBody["episode"] as? [String: Int]) == ["season": 0, "episode": 1],
              "actual local resolver forwards selection and retains native lease")
        routed.nativeLease?.close()
        let coordinator = CoordinatorFixture()
        let stream = FixtureStream(usenetURLs: ["https://fixture.invalid/ready"],
                                   usenetServers: ["nntps://fixture:one@one.invalid:563/2"],
                                   fileIdx: 0, fileMustInclude: "/special/i")
        let ref = await coordinator.resolvedPlaybackRef(for: stream, episode: .init(season: 0, episode: 4))!
        let coordinatorBody = try await creates().last!
        check(ref.nativeUsenetLease != nil && coordinatorBody["fileIdx"] as? Int == 0
              && coordinatorBody["fileMustInclude"] as? String == "/special/i"
              && (coordinatorBody["episode"] as? [String: Int]) == ["season": 0, "episode": 4],
              "actual coordinator local create retains lease and selected episode")
        let separateConsumer = await coordinator.resolvedPlaybackRef(for: stream, episode: .init(season: 0, episode: 4))!
        ref.nativeUsenetLease?.close()
        let firstConsumerClosed = await eventually { await cancelled(ref.nativeUsenetLease!.id) }
        let secondConsumerLive = !(await cancelled(separateConsumer.nativeUsenetLease!.id))
        check(firstConsumerClosed && secondConsumerLive && ref.nativeUsenetLease != separateConsumer.nativeUsenetLease,
              "same source resolved twice has independent consumer operations")
        separateConsumer.nativeUsenetLease?.close()
        let ownerAtRecovery = UsenetLocalResolver.captureNativeOwner()
        check(await ownerAtRecovery.permitsRecovery(from: separateConsumer.nativeUsenetLease),
              "closed operation still permits fresh same-owner recovery")
        CoreBridge.shared.generation = UUID()
        let successorOwner = UsenetLocalResolver.captureNativeOwner()
        check(!(await successorOwner.permitsRecovery(from: separateConsumer.nativeUsenetLease)),
              "retired previous authority cannot be retargeted to successor recovery")
        #if !NZB_WARM_CAPTURE_BASELINE
        let recoveryCoordinator = CoordinatorFixture(savedServers: [
            .init(name: "Fixture", host: "saved.invalid", port: 563, username: "fixture", password: "synthetic",
                  maxConnections: 2, useSSL: true)
        ])
        let recoveryOriginal = await recoveryCoordinator.resolvedPlaybackRef(for: stream, episode: .init(season: 0, episode: 4))!
        recoveryOriginal.nativeUsenetLease?.close()
        let recovered = try await recoveryCoordinator.recoverUsenetPlayback(for: stream, previous: recoveryOriginal,
                                                                            episode: .init(season: 0, episode: 4))
        check(recovered?.usenetRoute == .savedNNTP && recovered?.nativeUsenetLease != recoveryOriginal.nativeUsenetLease,
              "actual recovery entry permits fresh saved route after same-owner close")
        recovered?.nativeUsenetLease?.close()
        CoreBridge.shared.generation = UUID()
        let beforeRetiredRecovery = try await creates().count
        let refusedRecovery = try? await recoveryCoordinator.recoverUsenetPlayback(for: stream, previous: recoveryOriginal,
                                                                                   episode: .init(season: 0, episode: 4))
        let afterRetiredRecovery = try await creates().count
        check(refusedRecovery == nil && beforeRetiredRecovery == afterRetiredRecovery,
              "actual recovery entry rejects retired old owner with zero new creates")

        let failureStream = FixtureStream(usenetURLs: ["https://fixture.invalid/failure"],
            usenetServers: stream.usenetServers, fileIdx: nil, fileMustInclude: nil)
        let failureGate = FixtureWarmGate()
        let failingCoordinator = CoordinatorFixture(failureGate: failureGate)
        let cloudBeforeRetirement = await FixtureCloudResolver.shared.calls
        let failing = Task { await failingCoordinator.resolvedPlaybackRef(for: failureStream) }
        _ = await eventually { await failureGate.entered }
        CoreBridge.shared.generation = UUID()
        await failureGate.release()
        let retiredFailureResult = await failing.value
        let cloudAfterRetirement = await FixtureCloudResolver.shared.calls
        check(retiredFailureResult == nil && cloudBeforeRetirement == cloudAfterRetirement,
              "actual final local error plus owner retirement makes zero cloud calls")
        let ordinaryFallback = await CoordinatorFixture().resolvedPlaybackRef(for: failureStream)
        let cloudAfterNormalFallback = await FixtureCloudResolver.shared.calls
        check(ordinaryFallback?.usenetRoute == .torBoxCloud && cloudAfterNormalFallback == cloudAfterRetirement + 1,
              "actual live-owner local failure preserves configured cloud fallback")

        await FixtureCloudResolver.shared.setExistingJob(true)
        let localBeforeCloudRetry = try await creates().count
        let resumedCloud = await CoordinatorFixture().resolvedPlaybackRef(for: stream)
        let localAfterCloudRetry = try await creates().count
        check(resumedCloud?.usenetRoute == .torBoxCloud && localBeforeCloudRetry == localAfterCloudRetry,
              "actual cloud Retry does not restart earlier native routes")
        let cloudBeforeGate = await FixtureCloudResolver.shared.calls
        let gatedRetry = await CoordinatorFixture().resolvedPlaybackRef(for: stream, confirmedUsenetURLs: [])
        let cloudAfterGate = await FixtureCloudResolver.shared.calls
        check(gatedRetry == nil && cloudBeforeGate == cloudAfterGate,
              "existing cloud job does not bypass unattended cache gate")
        await FixtureCloudResolver.shared.setDelay(.seconds(5))
        let deadlineStarted = ContinuousClock.now
        let deadlineResult = await CoordinatorFixture().resolvedPlaybackRef(
            for: stream, usenetResolveTimeout: .milliseconds(10))
        check(deadlineResult == nil && deadlineStarted.duration(to: .now) < .seconds(1),
              "actual coordinator deadline cancels cloud polling within caller budget")
        await FixtureCloudResolver.shared.setDelay(nil)
        await FixtureCloudResolver.shared.setError(.notReady)
        let explicitPending = await CoordinatorFixture().resolveExplicitUsenetPlayback(for: stream)
        if case .failed(let message) = explicitPending {
            check(message.contains("TorBox is still preparing") && !message.contains("Native playback supports"),
                  "actual explicit pending result explains same-job Retry instead of an archive failure")
        } else { check(false, "actual explicit pending result explains same-job Retry instead of an archive failure") }
        await FixtureCloudResolver.shared.setError(nil)
        await FixtureCloudResolver.shared.setExistingJob(false)

        let fallbackWarmGate = FixtureWarmGate()
        let fallbackCoordinator = CoordinatorFixture(warmGate: fallbackWarmGate)
        let fallbackAuthority = UsenetLocalResolver.captureNativeOwner()
        let cloudBeforeWarm = await FixtureCloudResolver.shared.calls
        let fallbackWarm = Task { try? await fallbackCoordinator.resolveUsenet(nzbUrl: "https://fixture.invalid/failure",
            fileMustInclude: nil, fileIdx: nil, episode: nil, inheritedNativeOwner: fallbackAuthority) }
        _ = await eventually { await fallbackWarmGate.entered }
        let fallbackProfile = ProfileStore.shared.activeID
        ProfileStore.shared.activeID = UUID(); CoreBridge.shared.generation = UUID()
        ProfileStore.shared.activeID = fallbackProfile; CoreBridge.shared.generation = UUID()
        await fallbackWarmGate.release()
        let staleFallback = await fallbackWarm.value
        let cloudAfterWarm = await FixtureCloudResolver.shared.calls
        check(staleFallback == nil && cloudBeforeWarm == cloudAfterWarm,
              "actual cloud worker keeps inherited owner through suspended warm A-B-A")

        let breakerGate = FixtureWarmGate()
        await ProviderCircuitBreaker.shared.gateAdmission(breakerGate)
        let breakerAuthority = UsenetLocalResolver.captureNativeOwner()
        let cloudBeforeBreaker = await FixtureCloudResolver.shared.calls
        let breakerWait = Task { try? await CoordinatorFixture().resolveUsenet(nzbUrl: "https://fixture.invalid/failure",
            fileMustInclude: nil, fileIdx: nil, episode: nil, inheritedNativeOwner: breakerAuthority) }
        _ = await eventually { await breakerGate.entered }
        CoreBridge.shared.generation = UUID()
        await breakerGate.release()
        let staleAdmission = await breakerWait.value
        let cloudAfterBreaker = await FixtureCloudResolver.shared.calls
        check(staleAdmission == nil && cloudBeforeBreaker == cloudAfterBreaker,
              "actual cloud worker refuses retired owner after breaker suspension")

        let outputGate = FixtureWarmGate()
        await FixtureCloudResolver.shared.gateOutput(outputGate)
        let outputAuthority = UsenetLocalResolver.captureNativeOwner()
        let outputWait = Task { try? await CoordinatorFixture().resolveUsenet(nzbUrl: "https://fixture.invalid/failure",
            fileMustInclude: nil, fileIdx: nil, episode: nil, inheritedNativeOwner: outputAuthority) }
        _ = await eventually { await outputGate.entered }
        CoreBridge.shared.generation = UUID()
        await outputGate.release()
        check(await outputWait.value == nil, "actual cloud worker rejects result after original owner retires")
        #endif

        let warmGate = FixtureWarmGate()
        let warmingCoordinator = CoordinatorFixture(warmGate: warmGate)
        let beforeWarm = try await creates().count
        let warming = Task { await warmingCoordinator.resolvedPlaybackRef(for: stream, episode: .init(season: 0, episode: 4)) }
        _ = await eventually { await warmGate.entered }
        let originalProfile = ProfileStore.shared.activeID
        ProfileStore.shared.activeID = UUID(); CoreBridge.shared.generation = UUID()
        ProfileStore.shared.activeID = originalProfile; CoreBridge.shared.generation = UUID()
        await warmGate.release()
        let staleWarmResult = await warming.value
        let createsAfterStaleWarm = try await creates().count
        check(staleWarmResult == nil && createsAfterStaleWarm == beforeWarm,
              "actual public entry rejects suspended-warm profile A-B-A with zero creates")

        let prewarmGate = FixtureWarmGate()
        let validCoordinator = CoordinatorFixture(warmGate: prewarmGate)
        let stillOwned = Task { await validCoordinator.resolvedPlaybackRef(for: stream, episode: .init(season: 0, episode: 4)) }
        _ = await eventually { await prewarmGate.entered }
        CoreBridge.shared.resolveJob = UUID()
        await prewarmGate.release()
        let validWarmResult = await stillOwned.value
        check(validWarmResult != nil, "actual public entry keeps same-owner warm after resolve-job change")
        validWarmResult?.nativeUsenetLease?.close()
        #endif
        print("RESULT \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
