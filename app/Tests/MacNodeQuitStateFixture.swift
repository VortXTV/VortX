// Standalone identity-only quit-state regression fixture. Append these complete bytes after
// the complete actual SourcesShared/MacNodeServer.swift and one LF in a disposable compiler input.
// Do not compile this extension separately or widen production private members for access.
// Invoke only through a separately reviewed bounded standalone runner, never from the app.
#if os(macOS)

private final class QuitFixtureLatch: Sendable {
    private struct State: Sendable {
        var signaled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func signal() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.signaled else { return [] }
            state.signaled = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                if state.signaled { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private struct QuitFixtureObservation: Sendable {
    let stopped: Bool
    let activeAttempt: UUID?
    let fenced: Bool
    let owner: ObjectIdentifier?
}

@MainActor
private final class QuitFixtureCallbackProbe {
    let retired = QuitFixtureLatch()
    private(set) var observations: [QuitFixtureObservation] = []
    private var firstWaiter: CheckedContinuation<QuitFixtureObservation, Never>?

    func record(_ observation: QuitFixtureObservation) {
        observations.append(observation)
        let waiter = firstWaiter
        firstWaiter = nil
        waiter?.resume(returning: observation)
    }

    func first() async -> QuitFixtureObservation {
        if let first = observations.first { return first }
        return await withCheckedContinuation { continuation in
            precondition(firstWaiter == nil, "only one first-delivery waiter")
            firstWaiter = continuation
        }
    }
}

/// Only the production callback closure retains this ticket. No fixture-held callback copy
/// may survive fixtureAccept's return. Its release handshake waits for all scheduled copies,
/// allowing the probe to inspect the complete delivery count without a sleep/drain heuristic.
private final class QuitFixtureCallbackLifetime: Sendable {
    private let retired: QuitFixtureLatch
    init(retired: QuitFixtureLatch) { self.retired = retired }
    deinit { retired.signal() }
}

private struct QuitFixtureFiles {
    let directory: URL
    let ownedA: URL
    let ownedB: URL
    let unrelated: URL

    init(parent: URL, allowedBuildRoot: URL) throws {
        precondition(parent.isFileURL)
        precondition(allowedBuildRoot.isFileURL)
        let allowed = allowedBuildRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        precondition(resolvedParent.path.hasPrefix(allowed.path + "/"),
                     "parent must be an already allocated disposable gate beneath the supplied test-build root")
        directory = resolvedParent.appendingPathComponent("quit-state-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        ownedA = directory.appendingPathComponent("owned-A.port")
        ownedB = directory.appendingPathComponent("owned-B.port")
        unrelated = directory.appendingPathComponent("unrelated-sentinel.txt")
        try Data("11470\n".utf8).write(to: ownedA, options: .withoutOverwriting)
        try Data("11470\n".utf8).write(to: ownedB, options: .withoutOverwriting)
        try Data("must survive all production cleanup calls\n".utf8).write(to: unrelated, options: .withoutOverwriting)
    }

    func requireAllPresent() {
        precondition(FileManager.default.fileExists(atPath: ownedA.path))
        precondition(FileManager.default.fileExists(atPath: ownedB.path))
        precondition(FileManager.default.fileExists(atPath: unrelated.path))
    }
}

extension NodeServer {
    /// Test-only initial-state seam. The complete production RuntimeState and lock are used;
    /// there is no duplicate quit reducer. Only unlaunched fixture Process identities are installed.
    private static func fixtureInstall(owner: Process?, receipt: String?, published: Bool) {
        let previous = runtime.withLock { state in
            precondition(state.quitAttempt == nil, "never reset an unresolved production attempt")
            let previous = state
            state = RuntimeState()
            state.started = owner != nil
            state.exitCode = owner == nil ? nil : 37
            state.process = owner
            state.nativePortReceipt = receipt
            return previous
        }
        withExtendedLifetime(previous) {}
        if published, let owner, let receipt {
            publishNativeProcess(owner, receipt: receipt)
            runtime.withLock { state in
                state.nativeBoundPort = 11470
                state.nativeReceiptReadAt = 17
            }
        }
    }

    @MainActor
    private static func fixtureCallback(_ probe: QuitFixtureCallbackProbe) -> @MainActor @Sendable (Bool) -> Void {
        let lifetime = QuitFixtureCallbackLifetime(retired: probe.retired)
        return { stopped in
            let observation = runtime.withLock { state in
                QuitFixtureObservation(stopped: stopped, activeAttempt: state.quitAttempt?.id,
                    fenced: state.shutdownRequested, owner: state.process.map(ObjectIdentifier.init))
            }
            probe.record(observation)
            withExtendedLifetime(lifetime) {}
        }
    }

    /// Test-only acceptance setup. This seeds the real private QuitAttempt instead of calling
    /// stop(), which would schedule a timer and inspect/terminate a Process. API admission and
    /// queue/deadline wiring are therefore NOT runtime-tested by this fixture.
    @MainActor
    private static func fixtureAccept(_ id: UUID, probe: QuitFixtureCallbackProbe) {
        let completion = fixtureCallback(probe)
        runtime.withLock { state in
            precondition(state.quitAttempt == nil)
            state.quitAttempt = QuitAttempt(id: id, completion: completion)
            state.shutdownRequested = true
            state.quitFailure = nil
        }
    }

    @MainActor
    private static func fixtureAwait(_ probe: QuitFixtureCallbackProbe, stopped: Bool,
                                     owner: Process?, fenced: Bool) async {
        let first = await probe.first()
        await probe.retired.wait()
        precondition(probe.observations.count == 1, "one delivery after all callback copies retire")
        precondition(first.stopped == stopped)
        precondition(first.activeAttempt == nil)
        precondition(first.fenced == fenced)
        precondition(first.owner == owner.map(ObjectIdentifier.init))
    }

    private static func fixtureRequireRetained(_ owner: Process, receipt: String, published: Bool,
                                               attempt: UUID?, fenced: Bool, admitted: Bool = false) {
        runtime.withLock { state in
            precondition(state.process === owner)
            precondition(state.started && state.exitCode == 37)
            precondition(state.nativePortReceipt == receipt)
            precondition(state.quitAttempt?.id == attempt)
            precondition(state.shutdownRequested == fenced)
            if attempt != nil { precondition(state.quitAttempt?.termAdmitted == admitted) }
            if published {
                precondition(state.nativePublication?.process === owner)
                precondition(state.nativePublication?.receipt == receipt)
                precondition(state.nativeBoundPort == 11470 && state.nativeReceiptReadAt == 17)
            } else {
                precondition(state.nativePublication == nil)
                precondition(state.nativeBoundPort == nil && state.nativeReceiptReadAt == -1)
            }
            if attempt == nil, !fenced { precondition(state.quitFailure != nil) }
        }
    }

    @MainActor
    private static func fixtureNoChild() async -> Int {
        fixtureInstall(owner: nil, receipt: nil, published: false)
        let identity = Process(), id = UUID(), probe = QuitFixtureCallbackProbe()
        precondition(!admitQuitTermination(id, owner: identity), "no active attempt refuses admission")
        fixtureAccept(id, probe: probe)
        precondition(!beginLaunch(identity), "pending quit fences launch")
        precondition(completeQuitAttempt(id, stopped: true, owner: nil))
        precondition(probe.observations.isEmpty, "MainActor callback is not inline")
        precondition(!completeQuitAttempt(id, stopped: false, owner: nil), "old timer is inert")
        precondition(!completeQuitAttempt(id, stopped: true, owner: nil), "duplicate completion is inert")
        precondition(!beginLaunch(identity), "confirmed quit remains fenced")
        runtime.withLock { state in
            precondition(!state.started && state.exitCode == nil && state.process == nil)
            precondition(state.nativePortReceipt == nil && state.nativePublication == nil)
            precondition(state.quitAttempt == nil && state.shutdownRequested && state.quitFailure == nil)
        }
        await fixtureAwait(probe, stopped: true, owner: nil, fenced: true)
        return 1
    }

    @MainActor
    private static func fixtureCompetingCompletions() async -> Int {
        fixtureInstall(owner: nil, receipt: nil, published: false)
        let id = UUID(), probe = QuitFixtureCallbackProbe()
        fixtureAccept(id, probe: probe)
        let successReady = QuitFixtureLatch(), failureReady = QuitFixtureLatch(), release = QuitFixtureLatch()
        let success = Task.detached { () -> Bool in
            successReady.signal()
            await release.wait()
            return completeQuitAttempt(id, stopped: true, owner: nil)
        }
        let failure = Task.detached { () -> Bool in
            failureReady.signal()
            await release.wait()
            return completeQuitAttempt(id, stopped: false, owner: nil)
        }
        await successReady.wait()
        await failureReady.wait()
        release.signal()
        let successWon = await success.value
        let failureWon = await failure.value
        precondition(successWon != failureWon, "exactly one real locked completion wins")
        await fixtureAwait(probe, stopped: successWon, owner: nil, fenced: successWon)
        return 1
    }

    @MainActor
    private static func fixtureCancellation(files: QuitFixtureFiles, published: Bool) async -> Int {
        let owner = Process(), other = Process(), id = UUID(), probe = QuitFixtureCallbackProbe()
        fixtureInstall(owner: owner, receipt: files.ownedA.path, published: published)
        fixtureAccept(id, probe: probe)
        precondition(!admitQuitTermination(UUID(), owner: owner), "wrong UUID cannot admit")
        precondition(!admitQuitTermination(id, owner: other), "wrong owner cannot consume admission")
        fixtureRequireRetained(owner, receipt: files.ownedA.path, published: published,
                               attempt: id, fenced: true)
        // Explicit synthetic guard case, not a production transition or fake liveness result.
        runtime.withLock { $0.shutdownRequested = false }
        precondition(!admitQuitTermination(id, owner: owner), "lowered fence refuses admission")
        runtime.withLock { $0.shutdownRequested = true }
        precondition(admitQuitTermination(id, owner: owner), "exact active owner admits once")
        precondition(!admitQuitTermination(id, owner: owner), "second admission is refused")
        fixtureRequireRetained(owner, receipt: files.ownedA.path, published: published,
                               attempt: id, fenced: true, admitted: true)
        precondition(completeQuitAttempt(id, stopped: false, owner: nil))
        precondition(probe.observations.isEmpty)
        precondition(!completeQuitAttempt(id, stopped: false, owner: nil))
        precondition(!completeQuitAttempt(id, stopped: true, owner: owner))
        fixtureRequireRetained(owner, receipt: files.ownedA.path, published: published,
                               attempt: nil, fenced: false)
        precondition(!beginLaunch(other), "retained owner cannot be overwritten")
        precondition(!admitQuitTermination(id, owner: owner), "canceled attempt cannot readmit")
        files.requireAllPresent()
        await fixtureAwait(probe, stopped: false, owner: owner, fenced: false)
        return 1
    }

    @MainActor
    private static func fixtureLaunchAfterCancellation() async -> Int {
        fixtureInstall(owner: nil, receipt: nil, published: false)
        let owner = Process(), other = Process(), id = UUID(), probe = QuitFixtureCallbackProbe()
        fixtureAccept(id, probe: probe)
        precondition(!beginLaunch(owner))
        precondition(completeQuitAttempt(id, stopped: false, owner: nil))
        precondition(probe.observations.isEmpty)
        await fixtureAwait(probe, stopped: false, owner: nil, fenced: false)
        precondition(beginLaunch(owner), "cancellation with no child reopens launch admission")
        runtime.withLock { precondition($0.process === owner) }
        precondition(!beginLaunch(other) && !beginLaunch(owner), "parking is exclusive before any real run")
        return 1
    }

    @MainActor
    private static func fixtureCancelBeforeAdmission(files: QuitFixtureFiles, acceptNext: Bool) async -> Int {
        let owner = Process(), id = UUID(), probe = QuitFixtureCallbackProbe()
        fixtureInstall(owner: owner, receipt: files.ownedA.path, published: true)
        fixtureAccept(id, probe: probe)
        let entered = QuitFixtureLatch(), resume = QuitFixtureLatch()
        let entryDecision = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let actions = OSAllocatedUnfairLock<[ObjectIdentifier]>(initialState: [])
        let worker = Task.detached { () -> Bool in
            // Literal production queue-entry predicate, not the production queue/Process path.
            let allowed = runtime.withLock({ $0.quitAttempt?.id == id })
            entryDecision.withLock { $0 = allowed }
            entered.signal()
            await resume.wait()
            guard allowed, admitQuitTermination(id, owner: owner) else { return false }
            actions.withLock { $0.append(ObjectIdentifier(owner)) }
            return true
        }
        await entered.wait()
        precondition(entryDecision.withLock { $0 == true }, "A passed entry before cancellation")
        precondition(completeQuitAttempt(id, stopped: false, owner: nil))
        precondition(probe.observations.isEmpty)
        await fixtureAwait(probe, stopped: false, owner: owner, fenced: false)
        let nextID = UUID(), nextProbe = QuitFixtureCallbackProbe()
        if acceptNext { fixtureAccept(nextID, probe: nextProbe) }
        resume.signal()
        let admitted = await worker.value
        precondition(!admitted && actions.withLock { $0.isEmpty }, "cancel-before-admit cannot act")
        precondition(!completeQuitAttempt(id, stopped: true, owner: owner), "old worker cannot resolve B")
        precondition(!completeQuitAttempt(id, stopped: false, owner: nil), "old timer cannot cancel B")
        fixtureRequireRetained(owner, receipt: files.ownedA.path, published: true,
                               attempt: acceptNext ? nextID : nil, fenced: acceptNext)
        files.requireAllPresent()
        if acceptNext {
            precondition(nextProbe.observations.isEmpty)
            precondition(admitQuitTermination(nextID, owner: owner), "A did not consume B's admission")
            precondition(completeQuitAttempt(nextID, stopped: false, owner: nil))
            await fixtureAwait(nextProbe, stopped: false, owner: owner, fenced: false)
        }
        precondition(probe.observations.count == 1)
        return acceptNext ? 2 : 1
    }

    @MainActor
    private static func fixtureAdmissionBeforeCancellation(files: QuitFixtureFiles, acceptNext: Bool) async -> Int {
        let owner = Process(), id = UUID(), probe = QuitFixtureCallbackProbe()
        fixtureInstall(owner: owner, receipt: files.ownedA.path, published: true)
        fixtureAccept(id, probe: probe)
        let admittedBoundary = QuitFixtureLatch(), resume = QuitFixtureLatch()
        let decision = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let actions = OSAllocatedUnfairLock<[ObjectIdentifier]>(initialState: [])
        let worker = Task.detached { () -> Bool in
            let admitted = admitQuitTermination(id, owner: owner)
            decision.withLock { $0 = admitted }
            admittedBoundary.signal()
            await resume.wait()
            // Harness marker only: a previously granted action can proceed after cancellation.
            // This is not a Process.terminate substitute embedded into production code.
            if admitted { actions.withLock { $0.append(ObjectIdentifier(owner)) } }
            return admitted
        }
        await admittedBoundary.wait()
        precondition(decision.withLock { $0 == true })
        precondition(actions.withLock { $0.isEmpty })
        fixtureRequireRetained(owner, receipt: files.ownedA.path, published: true,
                               attempt: id, fenced: true, admitted: true)
        precondition(completeQuitAttempt(id, stopped: false, owner: nil))
        precondition(probe.observations.isEmpty)
        await fixtureAwait(probe, stopped: false, owner: owner, fenced: false)
        let nextID = UUID(), nextProbe = QuitFixtureCallbackProbe()
        if acceptNext { fixtureAccept(nextID, probe: nextProbe) }
        resume.signal()
        let admitted = await worker.value
        precondition(admitted && actions.withLock { $0 == [ObjectIdentifier(owner)] },
                     "already-admitted marker is not retroactively retracted")
        precondition(!completeQuitAttempt(id, stopped: true, owner: owner))
        precondition(!completeQuitAttempt(id, stopped: false, owner: nil))
        fixtureRequireRetained(owner, receipt: files.ownedA.path, published: true,
                               attempt: acceptNext ? nextID : nil, fenced: acceptNext)
        files.requireAllPresent()
        if acceptNext {
            precondition(nextProbe.observations.isEmpty)
            precondition(admitQuitTermination(nextID, owner: owner), "A cannot consume B's admission")
            precondition(completeQuitAttempt(nextID, stopped: false, owner: nil))
            await fixtureAwait(nextProbe, stopped: false, owner: owner, fenced: false)
        }
        precondition(probe.observations.count == 1)
        return acceptNext ? 2 : 1
    }

    @MainActor
    private static func fixtureSuccessfulCleanup(files: QuitFixtureFiles) async -> Int {
        let owner = Process(), other = Process(), id = UUID(), probe = QuitFixtureCallbackProbe()
        fixtureInstall(owner: owner, receipt: files.ownedA.path, published: true)
        fixtureAccept(id, probe: probe)
        precondition(!completeQuitAttempt(id, stopped: true, owner: other), "wrong owner cannot clean")
        precondition(!completeQuitAttempt(id, stopped: true, owner: nil), "nil owner cannot clear a child")
        fixtureRequireRetained(owner, receipt: files.ownedA.path, published: true, attempt: id, fenced: true)
        files.requireAllPresent()
        precondition(probe.observations.isEmpty)
        // `stopped: true` is an injected observation, NOT an observed OS exit of this unlaunched token.
        precondition(completeQuitAttempt(id, stopped: true, owner: owner))
        precondition(probe.observations.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: files.ownedA.path))
        precondition(FileManager.default.fileExists(atPath: files.ownedB.path))
        precondition(FileManager.default.fileExists(atPath: files.unrelated.path))
        runtime.withLock { state in
            precondition(!state.started && state.exitCode == nil && state.process == nil)
            precondition(state.nativePortReceipt == nil && state.nativePublication == nil)
            precondition(state.nativeBoundPort == nil && state.nativeReceiptReadAt == -1)
            precondition(state.quitAttempt == nil && state.shutdownRequested && state.quitFailure == nil)
        }
        precondition(!completeQuitAttempt(id, stopped: true, owner: other))
        precondition(!completeQuitAttempt(id, stopped: false, owner: nil))
        precondition(!beginLaunch(other))
        await fixtureAwait(probe, stopped: true, owner: nil, fenced: true)
        return 1
    }

    /// Sole test entry, callable only from a separately authorized standalone fixture runner.
    /// Never invoke in the real app. The supplied parent must be an allocated disposable gate.
    @MainActor
    static func runQuitStateFixture(disposableParent: URL, allowedBuildRoot: URL) async throws -> [String: String] {
        runtime.withLock { state in
            precondition(!state.started && state.process == nil && state.exitCode == nil)
            precondition(state.nativePortReceipt == nil && state.nativePublication == nil)
            precondition(state.quitAttempt == nil && !state.shutdownRequested)
        }
        let files = try QuitFixtureFiles(parent: disposableParent, allowedBuildRoot: allowedBuildRoot)
        var callbacks = 0
        callbacks += await fixtureNoChild()
        callbacks += await fixtureCompetingCompletions()
        callbacks += await fixtureCancellation(files: files, published: true)
        callbacks += await fixtureCancellation(files: files, published: false)
        callbacks += await fixtureLaunchAfterCancellation()
        callbacks += await fixtureCancelBeforeAdmission(files: files, acceptNext: false)
        callbacks += await fixtureCancelBeforeAdmission(files: files, acceptNext: true)
        callbacks += await fixtureAdmissionBeforeCancellation(files: files, acceptNext: false)
        callbacks += await fixtureAdmissionBeforeCancellation(files: files, acceptNext: true)
        callbacks += await fixtureSuccessfulCleanup(files: files)
        precondition(callbacks == 12)
        fixtureInstall(owner: nil, receipt: nil, published: false)
        // Retain directory + B/sentinel as evidence. No fixture recursive deletion is performed.
        return ["scope": "actual V2 admission/completion/launch-fence methods; identity-only Process tokens",
                "cases": "10", "callbackDeliveries": String(callbacks),
                "realProcessOrAppKitEvidence": "none", "disposableDirectory": files.directory.path]
    }
}
#endif
