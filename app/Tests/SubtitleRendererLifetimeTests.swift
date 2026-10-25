import Foundation

/// Actual CredentialPublicationOutbox/E implementation; only native cleanup is a controlled fixture.
@MainActor
enum SubtitleRendererLifetimeTests {
    private final class Cleanup: @unchecked Sendable {
        private let lock = NSLock()
        private var invocations = 0
        private var confirmed = true
        private let preflight: @Sendable () -> Bool
        init(preflight: @escaping @Sendable () -> Bool = { true }) { self.preflight = preflight }
        func setConfirmed(_ value: Bool) { lock.withLock { confirmed = value } }
        var calls: Int { lock.withLock { invocations } }
        func revoke() -> Bool {
            precondition(preflight(), "original B/F/E lock remains held during native cleanup")
            // These real APIs must return, proving C is unlocked and auth reentry is denied.
            precondition(CredentialPublicationOutbox.acquireBoundary() == .reentrant)
            precondition(CredentialPublicationOutbox.beginMutation() == nil)
            return lock.withLock { invocations += 1; return confirmed }
        }
    }

    /// Models the original serial native queue/ticket contract, not libmpv or its renderer.
    private final class NativeQueue: @unchecked Sendable {
        let queue = DispatchQueue(label: "vortx.subtitle.renderer-lifetime-fixture")
        private let key = DispatchSpecificKey<Int>()
        let occupied = DispatchSemaphore(value: 0)
        let allowNestedDrain = DispatchSemaphore(value: 0)
        let offQueueRequested = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        private let state = NSLock()
        private var activeTicket = 1
        private var removedOriginal = 0
        init() { queue.setSpecific(key: key, value: 1) }
        /// A synchronous, zero-timeout signal probe only; it never blocks this cooperative task.
        func tryConsumeSignal(_ signal: DispatchSemaphore) -> Bool {
            signal.wait(timeout: .now()) == .success
        }
        func revokeOriginal() -> Bool {
            if DispatchQueue.getSpecific(key: key) == 1 { return detachOriginal() }
            offQueueRequested.signal()
            return queue.sync { detachOriginal() }
        }
        private func detachOriginal() -> Bool {
            dispatchPrecondition(condition: .onQueue(queue))
            return state.withLock {
                if activeTicket == 1 { activeTicket = 0; removedOriginal += 1 }
                return true // old ticket absent is terminal even when a successor is present
            }
        }
        func installSuccessorOnQueue() {
            dispatchPrecondition(condition: .onQueue(queue))
            state.withLock { activeTicket = 2 }
        }
        var preservedSuccessor: Bool { state.withLock { activeTicket == 2 && removedOriginal == 1 } }
    }

    static func run() async -> Int {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1; print("PASS renderer \(label)")
        }
        func register(_ core: CoreBridge, _ target: PlaybackMutationTarget, _ epoch: UUID,
                      _ cleanup: Cleanup) -> CredentialPublicationOutbox.SubtitleRendererRegistration {
            guard let owner = core.captureNativeSubtitleOwner(target, originalApplicationEpoch: epoch),
                  let effect = CredentialPublicationOutbox.tryBeginSubtitleEffect(owner),
                  let registration = CredentialPublicationOutbox.registerSubtitleRenderer(effect,
                    revoke: { cleanup.revoke() }) else { fatalError("original renderer reserve") }
            CredentialPublicationOutbox.endSubtitleEffect(effect)
            return registration
        }

        // Active playback does not monopolize the transient credential mutation lease.
        let (core, target, facade, epoch) = CoreBridge.fixture()
        let cleanup = Cleanup()
        let original = register(core, target, epoch, cleanup)
        guard let ordinary = CredentialPublicationOutbox.beginMutation() else { fatalError("active renderer blocked ordinary mutation") }
        CredentialPublicationOutbox.endMutation(ordinary)
        check(cleanup.calls == 0, "ordinary work preserves active renderer")
        let retirement = CredentialPublicationOutbox.beginSubtitleRetirement(domain: facade.sourceID)
        check(!CredentialPublicationOutbox.finishSubtitleRetirement(retirement), "domain cannot finish with active ticket")
        check(CredentialPublicationOutbox.drainSubtitleRenderers(retirement), "domain exact native cleanup confirmed")
        check(cleanup.calls == 1, "domain invokes original cleanup synchronously")
        await CredentialPublicationOutbox.waitForSubtitleRetirement(retirement)
        check(CredentialPublicationOutbox.finishSubtitleRetirement(retirement), "domain finishes only after cleanup")
        check(CredentialPublicationOutbox.unregisterSubtitleRenderer(original), "late old unregister is harmless")
        check(cleanup.calls == 1, "late unregister does not repeat removed registration")

        let replacementCleanup = Cleanup()
        let replacement = register(core, target, epoch, replacementCleanup)
        check(replacement != original, "replacement owns fresh opaque registration")
        check(CredentialPublicationOutbox.unregisterSubtitleRenderer(original), "old ID cannot target replacement")
        check(replacementCleanup.calls == 0, "replacement remains active after late old callback")
        guard CredentialScopeRegistry.shared.tryBind(.account(UUID())) != nil else { fatalError("native cleanup did not permit boundary") }
        check(replacementCleanup.calls == 1, "account boundary drains before granting new owner")
        check(CredentialPublicationOutbox.unregisterSubtitleRenderer(replacement), "old account cleanup stays idempotent")

        // Unknown native response never becomes successful retirement. A later proper teardown retries it.
        let (failedCore, failedTarget, failedFacade, failedEpoch) = CoreBridge.fixture()
        let uncertain = Cleanup(); uncertain.setConfirmed(false)
        let failedRegistration = register(failedCore, failedTarget, failedEpoch, uncertain)
        check(!CredentialPublicationOutbox.unregisterSubtitleRenderer(failedRegistration), "unconfirmed native response remains retained")
        check(CredentialPublicationOutbox.beginMutation() == nil, "retiring native failure blocks successor credential mutation")
        check(CredentialPublicationOutbox.acquireBoundary() == .busy, "synchronous boundary reports busy on unconfirmed cleanup")
        let boundary = Task { await CredentialPublicationOutbox.waitForBoundary() }
        for _ in 0..<1_024 {
            if CredentialPublicationOutbox.fixtureBoundaryWaiterCount() == 1 { break }
            await Task.yield()
        }
        check(CredentialPublicationOutbox.fixtureBoundaryWaiterCount() == 1, "async boundary waits cooperatively on same failed registration")
        let retryDomain = CredentialPublicationOutbox.beginSubtitleRetirement(domain: failedFacade.sourceID)
        uncertain.setConfirmed(true)
        check(CredentialPublicationOutbox.drainSubtitleRenderers(retryDomain), "later DOMAIN retry confirms retained registration")
        check(await boundary.value == .acquired, "domain drain wakes parked credential writer without explicit unregister or later lease end")
        CredentialPublicationOutbox.endBoundary()
        await CredentialPublicationOutbox.waitForSubtitleRetirement(retryDomain)
        check(CredentialPublicationOutbox.finishSubtitleRetirement(retryDomain), "settled old domain can retire normally")
        check(CredentialPublicationOutbox.unregisterSubtitleRenderer(failedRegistration), "late completed failure registration is harmless")

        let (retryCore, retryTarget, _, retryEpoch) = CoreBridge.fixture()
        let retryCleanup = Cleanup(); retryCleanup.setConfirmed(false)
        let retryRegistration = register(retryCore, retryTarget, retryEpoch, retryCleanup)
        check(!CredentialPublicationOutbox.unregisterSubtitleRenderer(retryRegistration), "manual unconfirmed cleanup is retained")
        retryCleanup.setConfirmed(true)
        check(CredentialPublicationOutbox.unregisterSubtitleRenderer(retryRegistration), "proper original teardown retries same registration successfully")

        let (profileCore, profileTarget, _, profileEpoch) = CoreBridge.fixture()
        let profileCleanup = Cleanup(preflight: {
            if case .stale = LegacyWatchOwnership.applicationEpochState(profileEpoch) { return true }
            return false
        })
        let profileRegistration = register(profileCore, profileTarget, profileEpoch, profileCleanup)
        LegacyWatchOwnership.beginProfileMutation(retire: false)
        LegacyWatchOwnership.endProfileMutation()
        check(profileCleanup.calls == 0, "nonmaterial name/theme publication retains active renderer")
        LegacyWatchOwnership.beginProfileMutation(retire: true)
        check(profileCleanup.calls == 1, "material profile change drains after E unlock before returning")
        LegacyWatchOwnership.endProfileMutation()
        LegacyWatchOwnership.invalidateSession()
        check(profileCleanup.calls == 1, "material ABA cannot resurrect old observer")
        check(CredentialPublicationOutbox.unregisterSubtitleRenderer(profileRegistration), "retired profile registration is idempotent")

        let (bridgeCore, bridgeTarget, _, bridgeEpoch) = CoreBridge.fixture()
        let bridgeLock = bridgeCore.fixtureBridgeLock()
        let bridgeCleanup = Cleanup(preflight: {
            guard bridgeLock.try() else { return false }
            bridgeLock.unlock(); return true
        })
        _ = register(bridgeCore, bridgeTarget, bridgeEpoch, bridgeCleanup)
        bridgeCore.retireActualBridgeLifetime()
        check(bridgeCleanup.calls == 1, "Bridge helper releases B before synchronous native cleanup")

        let (fCore, fTarget, fFacade, fEpoch) = CoreBridge.fixture()
        let facadeLockIsUnheld = fFacade.fixtureLockIsUnheld
        let facadeCleanup = Cleanup(preflight: { facadeLockIsUnheld() })
        _ = register(fCore, fTarget, fEpoch, facadeCleanup)
        fFacade.fixtureRetireForUncertainty()
        check(facadeCleanup.calls == 1, "actual Facade afterOutermostUnlock releases F before cleanup")

        // Reproduces the deadlock of waiting for a run-once off-queue drainer from its own native queue.
        let (queueCore, queueTarget, _, queueEpoch) = CoreBridge.fixture()
        let native = NativeQueue()
        guard let owner = queueCore.captureNativeSubtitleOwner(queueTarget, originalApplicationEpoch: queueEpoch),
              let effect = CredentialPublicationOutbox.tryBeginSubtitleEffect(owner),
              let queueRegistration = CredentialPublicationOutbox.registerSubtitleRenderer(effect,
                revoke: { native.revokeOriginal() }) else { fatalError("queue fixture reserve") }
        CredentialPublicationOutbox.endSubtitleEffect(effect)
        native.queue.async {
            native.occupied.signal()
            native.allowNestedDrain.wait()
            precondition(CredentialPublicationOutbox.unregisterSubtitleRenderer(queueRegistration))
            native.installSuccessorOnQueue()
            native.finished.signal()
        }
        while !native.tryConsumeSignal(native.occupied) { await Task.yield() }
        let offQueue = Task.detached { CredentialPublicationOutbox.unregisterSubtitleRenderer(queueRegistration) }
        while !native.tryConsumeSignal(native.offQueueRequested) { await Task.yield() }
        native.allowNestedDrain.signal()
        check(await offQueue.value, "native queue can satisfy concurrent off-queue cleanup without coordinator wait inversion")
        while !native.tryConsumeSignal(native.finished) { await Task.yield() }
        check(native.preservedSuccessor, "late duplicate exact cleanup preserves new native ticket")
        return checks
    }
}
