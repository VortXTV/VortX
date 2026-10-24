// The standalone primitive runner prepends the two exact production
// declarations at this marker. This fixture covers only F/W scalar admission
// and cancellation ordering; it is not the
// real Facade, Session, CoreBridge owner, lifecycle, or receiver.

// PRODUCTION_DECLARATIONS

private final class PrimitiveEvents: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    func record(_ value: String) { state.withLock { $0.append(value) } }
    var values: [String] { state.withLock { $0 } }
}

private final class PrimitiveBox<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { state = OSAllocatedUnfairLock(initialState: value) }
    func set(_ value: Value) { state.withLock { $0 = value } }
    func update(_ body: @Sendable (inout Value) -> Void) { state.withLock(body) }
    var value: Value { state.withLock { $0 } }
}

/// B/M storage is checked-lock RAM only. The initial M request is deliberately
/// joined to the real W request before this object becomes observable.
private final class RAMAdmissionState: Sendable {
    struct BridgeState: Sendable { var writes = 0 }
    struct MetadataState: Sendable {
        var request: UUID
        var writes = 0
    }

    let facade: VortxNativeFacadeLock
    let witness: VortxNativeMetadataAdmissionFence
    private let bridge: OSAllocatedUnfairLock<BridgeState>
    private let metadata: OSAllocatedUnfairLock<MetadataState>

    init() {
        let facade = VortxNativeFacadeLock()
        let witness = VortxNativeMetadataAdmissionFence()
        let request = UUID()
        self.facade = facade
        self.witness = witness
        self.bridge = OSAllocatedUnfairLock(initialState: .init())
        self.metadata = OSAllocatedUnfairLock(initialState: .init(request: request))
        // Join M's initial scalar to W before any caller can capture a stamp.
        witness.replaceRequest(request)
    }

    func stamp() -> VortxNativeMetadataAdmissionFence.Stamp {
        .init(installation: witness.captureInstallation(),
              request: metadata.withLock { $0.request })
    }

    func admit(_ stamp: VortxNativeMetadataAdmissionFence.Stamp,
               _ operation: @Sendable () -> Bool) -> Bool {
        facade.withLock { witness.withCurrent(stamp, operation) ?? false }
    }

    func replaceRequest(beforeWitness: (@Sendable () -> Void)? = nil) -> UUID {
        metadata.withLock { state in
            let request = UUID()
            state.request = request
            state.writes += 1
            beforeWitness?()
            witness.replaceRequest(request)
            return request
        }
    }

    func retireInstallation(beforeWitness: (@Sendable () -> Void)? = nil) {
        bridge.withLock { state in
            state.writes += 1
            beforeWitness?()
            witness.retireInstallation()
        }
    }

    var bridgeWrites: Int { bridge.withLock { $0.writes } }
    var metadataWrites: Int { metadata.withLock { $0.writes } }
}

private func boundedCrossThread(_ operation: @escaping @Sendable () -> Void) -> Bool {
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        operation()
        finished.signal()
    }
    return finished.wait(timeout: .now() + 2) == .success
}

/// Keep bounded test-gate waits off Swift's cooperative executor. The real
/// Task and its cancellation handler remain alive while this wait is pending.
private func awaitSignal(_ signal: DispatchSemaphore, seconds: Double = 2) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: signal.wait(timeout: .now() + seconds) == .success)
        }
    }
}

/// Uses actual Swift Task handles. The operation blocks on a bounded gate;
/// cancellation is observed only through the real onCancel handler. No RAM
/// closure stands in for Task.cancel().
private final class ActualTaskTable: Sendable {
    private let facade: VortxNativeFacadeLock
    private let state = OSAllocatedUnfairLock(initialState: [String: Task<Void, Never>]())
    init(facade: VortxNativeFacadeLock) { self.facade = facade }

    func install(_ task: Task<Void, Never>, for key: String) {
        facade.withLock { state.withLock { $0[key] = task } }
    }

    func replace(_ task: Task<Void, Never>, for key: String) {
        facade.withLock {
            let previous = state.withLock { value -> Task<Void, Never>? in
                let old = value[key]
                value[key] = task
                return old
            }
            if let previous { facade.afterOutermostUnlock { previous.cancel() } }
        }
    }

}

enum VortxNativeAdmissionPrimitiveTests {
    private static let checkCount = PrimitiveBox(0)

    private static func check(_ condition: Bool, _ message: String,
                              line: Int = #line) {
        checkCount.update { $0 += 1 }
        precondition(condition, "native-admission-primitive assertion at line \(line): \(message)")
    }

    private static func staleAndABA() {
        let state = RAMAdmissionState()
        let original = state.stamp()
        check(state.admit(original) { true }, "initial M/W join admits")
        let request = state.replaceRequest()
        check(request != original.request, "M rotates request")
        check(!state.admit(original) { true }, "stale same-install request rejects")
        state.retireInstallation()
        let middle = state.stamp()
        state.retireInstallation()
        check(middle.installation != state.stamp().installation, "installation ABA rotates")
        check(!state.admit(middle) { true }, "installation ABA stamp rejects")
        check(!state.admit(original) { true }, "original installation stamp cannot revive")
    }

    private static func writerRaces() {
        let state = RAMAdmissionState(), events = PrimitiveEvents()
        let original = state.stamp()
        let fStarted = DispatchSemaphore(value: 0), writerEntered = DispatchSemaphore(value: 0)
        let fReleased = DispatchSemaphore(value: 0), fFinished = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let admitted = PrimitiveBox(false), writerWaited = PrimitiveBox(false)
        let writerBlockedWhileW = PrimitiveBox(false)
        DispatchQueue.global(qos: .utility).async {
            state.facade.withLock {
                admitted.set(state.witness.withCurrent(original) {
                    events.record("F")
                    fStarted.signal()
                    let signalled = writerEntered.wait(timeout: .now() + 2) == .success
                    writerWaited.set(signalled)
                    if signalled {
                        writerBlockedWhileW.set(writerFinished.wait(timeout: .now() + 0.1) == .timedOut)
                    }
                    fReleased.signal()
                    return true
                } ?? false)
            }
            fFinished.signal()
        }
        check(fStarted.wait(timeout: .now() + 2) == .success, "F/W acquired")
        DispatchQueue.global(qos: .utility).async {
            _ = state.replaceRequest {
                events.record("M")
                writerEntered.signal()
            }
            writerFinished.signal()
        }
        check(fReleased.wait(timeout: .now() + 2) == .success, "F released W")
        check(writerFinished.wait(timeout: .now() + 2) == .success, "M finished")
        check(fFinished.wait(timeout: .now() + 2) == .success, "F worker finished")
        check(writerWaited.value && writerBlockedWhileW.value && admitted.value,
              "M remains unfinished while F holds W and F admits")
        check(state.metadataWrites == 1, "M count")

        let second = state.stamp()
        let bStarted = DispatchSemaphore(value: 0), bFinished = DispatchSemaphore(value: 0)
        let secondFFinished = DispatchSemaphore(value: 0)
        let bAdmitted = PrimitiveBox(false), bWaitedForWriter = PrimitiveBox(false)
        let bWriterBlockedWhileW = PrimitiveBox(false)
        DispatchQueue.global(qos: .utility).async {
            state.facade.withLock {
                bAdmitted.set(state.witness.withCurrent(second) {
                    bStarted.signal()
                    let signalled = writerEntered.wait(timeout: .now() + 2) == .success
                    bWaitedForWriter.set(signalled)
                    if signalled {
                        bWriterBlockedWhileW.set(bFinished.wait(timeout: .now() + 0.1) == .timedOut)
                    }
                    return true
                } ?? false)
            }
            secondFFinished.signal()
        }
        check(bStarted.wait(timeout: .now() + 2) == .success, "second F/W acquired")
        DispatchQueue.global(qos: .utility).async {
            state.retireInstallation { writerEntered.signal() }
            bFinished.signal()
        }
        check(bFinished.wait(timeout: .now() + 2) == .success, "B finished")
        check(secondFFinished.wait(timeout: .now() + 2) == .success, "second F worker finished")
        check(bWaitedForWriter.value && bWriterBlockedWhileW.value && bAdmitted.value,
              "B remains unfinished while F holds W and F admits")
        check(state.bridgeWrites == 1, "B count")
        check(!state.admit(second) { true }, "B retirement rejects second stamp")
    }

    private static func recursiveDrain() {
        let state = RAMAdmissionState(), events = PrimitiveEvents()
        let stamp = state.stamp()
        state.facade.withLock {
            state.facade.withLock {
                state.facade.afterOutermostUnlock {
                    let f = boundedCrossThread { state.facade.withLock {} }
                    let w = boundedCrossThread { _ = state.witness.withCurrent(stamp) { true } }
                    events.record("drain-\(f)-\(w)")
                }
                events.record("inner")
            }
            check(events.values == ["inner"], "nested callback waits for outer F")
            events.record("outer")
        }
        check(events.values == ["inner", "outer", "drain-true-true"],
              "callback probes F/W only after release")
    }

    private static func task(_ entered: DispatchSemaphore, _ release: DispatchSemaphore,
                             onCancel: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task {
            await withTaskCancellationHandler(operation: {
                entered.signal()
                _ = await awaitSignal(release)
            }, onCancel: onCancel)
        }
    }

    private static func actualTaskCancellation() async {
        let state = RAMAdmissionState(), events = PrimitiveEvents()
        let table = ActualTaskTable(facade: state.facade)
        let enteredA = DispatchSemaphore(value: 0), releaseA = DispatchSemaphore(value: 0)
        let enteredB = DispatchSemaphore(value: 0), releaseB = DispatchSemaphore(value: 0)
        let cancelA = DispatchSemaphore(value: 0), cancelB = DispatchSemaphore(value: 0)
        let cancelObserved = PrimitiveBox(false)
        let originalStamp = state.stamp()
        let a = task(enteredA, releaseA) {
            let f = boundedCrossThread { state.facade.withLock {} }
            let w = boundedCrossThread { _ = state.witness.withCurrent(state.stamp()) { true } }
            cancelObserved.set(f && w)
            events.record("cancel-A")
            cancelA.signal()
        }
        check(await awaitSignal(enteredA), "A Task entered")
        table.install(a, for: "meta")
        let b = task(enteredB, releaseB) {
            events.record("cancel-B")
            cancelB.signal()
        }
        check(await awaitSignal(enteredB), "B Task entered")
        let deferredA = PrimitiveBox(false), deferredB = PrimitiveBox(false)
        let admitted = state.admit(originalStamp) {
            table.replace(b, for: "meta")
            deferredA.set(cancelA.wait(timeout: .now() + 0.2) == .timedOut)
            deferredB.set(cancelB.wait(timeout: .now() + 0.2) == .timedOut)
            return true
        }
        check(admitted, "task replacement ran inside real F/W admission")
        check(deferredA.value, "A cancellation is deferred under outer F/W")
        check(deferredB.value, "successor B is not cancelled under outer F/W")
        check(await awaitSignal(cancelA),
              "captured original A Task is cancelled after F/W release")
        check(cancelObserved.value, "A onCancel acquires F/W after release")
        releaseA.signal(); await a.value
        check(!(await awaitSignal(cancelB, seconds: 0.2)),
              "B remains uncancelled after A completion")
        releaseB.signal(); await b.value
        check(events.values == ["cancel-A"], "only original Task cancellation ran")
    }

    static func run() async -> Int {
        checkCount.set(0)
        staleAndABA()
        writerRaces()
        recursiveDrain()
        await actualTaskCancellation()
        let count = checkCount.value
        print("Native admission primitives v3: \(count) checks PASS; exact Facade F/W plus checked RAM B/M and real Task cancellation; no whole Facade/Session/CoreBridge proof")
        return count
    }
}
