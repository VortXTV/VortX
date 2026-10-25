// Exact extracted production session/startup controls, under inert dependencies. No app build,
// Keychain, accounts, log-cache access, listener, HTTP, Finder or share-sheet execution.
import Foundation
import os

protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
typealias Image = String

@MainActor final class ReplyGate {
    var continuation: CheckedContinuation<(url: String, qr: Image)?, Never>?
    func wait() async -> (url: String, qr: Image)? {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: (url: String, qr: Image)?) {
        continuation?.resume(returning: value); continuation = nil
    }
}

@MainActor final class VXDiagExport {
    static var instances: [VXDiagExport] = []
    let gate = ReplyGate()
    var stops = 0
    static func makeSession() -> VXDiagExport {
        let instance = VXDiagExport(); instances.append(instance); return instance
    }
    func startAsync() async -> (url: String, qr: Image)? { await gate.wait() }
    func stopOwnedSession() { stops += 1 }
}

/* PRODUCTION_SESSION */

/* PRODUCTION_CANCELLATION */

/// Inert Network-worker stand-in. Real startAsync and cancellation flag are extracted verbatim;
/// only listener bring-up and the clock budget/gap are substituted.
final class WorkerExport: @unchecked Sendable {
    private let presentationOwned: Bool
    private static let coldStartBudget: TimeInterval = 0.1
    private static let coldStartRetryGap: TimeInterval = 0.002
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fixture-export-teardown")
    private var attempts = 0
    private var teardown = 0
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let blockStart: Bool
    init(owned: Bool, blockStart: Bool = true) {
        presentationOwned = owned; self.blockStart = blockStart
    }
    var starts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return teardown }
    private static func lanIPv4() -> String? { "fixture-only" }
    private func start() -> (url: String, qr: Image)? {
        lock.lock(); attempts += 1; lock.unlock()
        entered.signal()
        if blockStart { _ = release.wait(timeout: .now() + 2) }
        return ("fixture-only", "fixture-qr")
    }
    func stop() { lock.lock(); teardown += 1; lock.unlock() }
    private func tearDownListener() { stop() }
    func holdTeardownQueue() {
        queue.async {
            self.entered.signal()
            _ = self.release.wait(timeout: .now() + 2)
        }
    }
    /* PRODUCTION_STOP */
    /* PRODUCTION_START */
}

@main struct PreProfileDiagnosticExportTests {
    @MainActor static func main() async {
        var passed = 0
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL \(message)") }
            passed += 1; print("PASS \(message)")
        }
        func waitFor(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<1000 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            fatalError("fixture did not reach awaited control boundary")
        }

        let session = DiagnosticLogExportSession()
        let first = Task { await session.prepare() }
        await waitFor { VXDiagExport.instances.last?.gate.continuation != nil }
        let old = VXDiagExport.instances.last!
        expect(session.preparing && session.payload == nil, "cold start has a visible preparation state")
        session.stop()
        expect(!session.preparing && old.stops == 1, "dismissal stops its owned listener immediately")
        old.gate.finish(("old", "qr"))
        await first.value
        expect(session.payload == nil && !session.preparing, "late cold reply cannot repaint a dismissed export")
        expect(old.stops == 2, "late startup is torn down again after an early stop")

        let abandoned = Task { await session.prepare() }
        await waitFor { VXDiagExport.instances.last?.gate.continuation != nil }
        let abandonedExport = VXDiagExport.instances.last!
        let replacement = Task { await session.prepare() }
        await waitFor { VXDiagExport.instances.last !== abandonedExport && VXDiagExport.instances.last?.gate.continuation != nil }
        let current = VXDiagExport.instances.last!
        current.gate.finish(("current", "qr")); await replacement.value
        expect(session.payload?.url == "current" && !session.preparing, "current export publishes its own QR")
        abandonedExport.gate.finish(("abandoned", "qr")); await abandoned.value
        expect(session.payload?.url == "current", "old reply cannot overwrite replacement QR")
        expect(current.stops == 0 && abandonedExport.stops == 2, "old cleanup never stops the replacement listener")

        let failure = Task { await session.prepare() }
        await waitFor { VXDiagExport.instances.last?.gate.continuation != nil }
        let failed = VXDiagExport.instances.last!
        failed.gate.finish(nil); await failure.value
        expect(session.payload == nil && !session.preparing && failed.stops == 1, "failed start is terminal and stopped, not an endless spinner")

        let cancelled = Task { await session.prepare() }
        await waitFor { VXDiagExport.instances.last?.gate.continuation != nil }
        let cancelledExport = VXDiagExport.instances.last!
        cancelled.cancel(); cancelledExport.gate.finish(("cancelled", "qr")); await cancelled.value
        expect(session.payload == nil && !session.preparing && cancelledExport.stops == 1, "cancelled task cannot publish a ready QR")

        let ownedWorker = WorkerExport(owned: true)
        let work = Task { await ownedWorker.startAsync() }
        await waitFor { ownedWorker.starts == 1 }
        work.cancel(); ownedWorker.release.signal()
        let cancelledResult = await work.value
        expect(cancelledResult == nil && ownedWorker.stops == 1, "cancellation during blocking startup closes the newly opened listener")

        let alreadyCancelled = WorkerExport(owned: true, blockStart: false)
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await alreadyCancelled.startAsync()
        }
        let preCancelledResult = await preCancelled.value
        expect(preCancelledResult == nil && alreadyCancelled.starts == 0, "already-cancelled presentation never starts a listener")

        let legacyShared = WorkerExport(owned: false)
        let sharedWork = Task { await legacyShared.startAsync() }
        await waitFor { legacyShared.starts == 1 }
        sharedWork.cancel(); legacyShared.release.signal()
        let sharedResult = await sharedWork.value
        expect(sharedResult != nil && legacyShared.stops == 0, "old singleton caller cannot acquire new cancellation teardown authority")

        let blockedCleanup = WorkerExport(owned: true)
        blockedCleanup.holdTeardownQueue()
        await waitFor { blockedCleanup.entered.wait(timeout: .now()) == .success }
        blockedCleanup.stopOwnedSession()
        expect(blockedCleanup.stops == 0, "owned cleanup returns without blocking the main actor on busy startup queue")
        blockedCleanup.release.signal()
        await waitFor { blockedCleanup.stops == 1 }
        expect(blockedCleanup.stops == 1, "deferred owned cleanup still tears down after the startup queue releases")
        legacyShared.stopOwnedSession()
        expect(legacyShared.stops == 0, "owned cleanup cannot tear down the shared Settings instance")

        session.stop()
        print("PASS \(passed) exact-source pre-profile export lifecycle checks")
    }
}
