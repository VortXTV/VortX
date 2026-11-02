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
@MainActor final class CredentialScopeRegistry {
    struct Capture: Equatable, Sendable { let generation: Int }
    static let shared = CredentialScopeRegistry()
    private var generation = 0
    func capture() -> Capture { .init(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture == self.capture() }
    func change() { generation += 1 }
}
@MainActor private final class DiagnosticPolicy { var allowed = true }

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
    static func makeSession(deliveryAuthorization: (@MainActor @Sendable () -> Bool)? = nil) -> VXDiagExport {
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
    private let deliveryRetirement = VXDiagExportStartCancellation()
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

// Inert Network stand-ins. The actual authorization, payload/header, chunks, completion and owned-stop
// methods below are extracted verbatim. Callback delivery is controlled; no socket or log is opened.
private final class NWConnection: @unchecked Sendable {
    enum ContentContext: Sendable { case defaultMessage, finalMessage }
    enum SendCompletion: Sendable { case contentProcessed(@Sendable (Error?) -> Void) }
    private let lock = NSLock()
    private var sent: [Data] = []
    private var callbacks: [@Sendable (Error?) -> Void] = []
    private var retired = false
    var sends: [Data] { lock.lock(); defer { lock.unlock() }; return sent }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return retired }
    func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true,
              completion: SendCompletion) {
        lock.lock(); defer { lock.unlock() }
        if let content { sent.append(content) }
        if case .contentProcessed(let callback) = completion { callbacks.append(callback) }
    }
    func completeNext() {
        lock.lock(); let callback = callbacks.isEmpty ? nil : callbacks.removeFirst(); lock.unlock()
        callback?(nil)
    }
    func cancel() { lock.lock(); retired = true; lock.unlock() }
}
private final class DeliveryExport: @unchecked Sendable {
    typealias DeliveryAuthorization = @MainActor @Sendable () -> Bool
    private let deliveryAuthorization: DeliveryAuthorization?
    private let deliveryRetirement = VXDiagExportStartCancellation()
    private let presentationOwned = true
    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "fixture-delivery-teardown")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var transferGate = VXDiagExportPolicy.TransferGate()
    private struct ExportPayload { let body: Data }
    private static let payloadLock = NSLock()
    nonisolated(unsafe) private static var payloadCount = 0
    static var payloadReads: Int { payloadLock.lock(); defer { payloadLock.unlock() }; return payloadCount }
    private static func exportPayload() -> ExportPayload {
        payloadLock.lock(); payloadCount += 1; payloadLock.unlock()
        return .init(body: Data(repeating: 0x61, count: VXDiagExportPolicy.responseChunkBytes + 7))
    }
    init(deliveryAuthorization: DeliveryAuthorization? = nil) { self.deliveryAuthorization = deliveryAuthorization }
    func request(_ connection: NWConnection) -> VXDiagExportPolicy.TransferClaim {
        stateLock.lock()
        transferGate.reset(); connections[ObjectIdentifier(connection)] = connection
        let claim = transferGate.claim()!
        stateLock.unlock()
        serve(connection, claim: claim)
        return claim
    }
    func stillOwns(_ claim: VXDiagExportPolicy.TransferClaim) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return transferGate.owns(claim)
    }
    private func tearDownListener() {
        stateLock.lock(); let open = Array(connections.values); connections.removeAll(); transferGate.reset(); stateLock.unlock()
        open.forEach { $0.cancel() }
    }
    private func waitForPeerClose(_ connection: NWConnection) {} // Receiver plumbing is intentionally inert.
    /* PRODUCTION_DELIVERY_AUTHORIZATION */
    /* PRODUCTION_DELIVERY_OWNS */
    /* PRODUCTION_DELIVERY_SERVE */
    /* PRODUCTION_DELIVERY_CHUNKS */
    /* PRODUCTION_DELIVERY_FINISH */
    /* PRODUCTION_DELIVERY_STOP */
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
        let first = Task { await session.prepare(grant: nil) }
        await waitFor { VXDiagExport.instances.last?.gate.continuation != nil }
        let old = VXDiagExport.instances.last!
        expect(session.preparing && session.payload == nil, "cold start has a visible preparation state")
        session.stop()
        expect(!session.preparing && old.stops == 1, "dismissal stops its owned listener immediately")
        old.gate.finish(("old", "qr"))
        await first.value
        expect(session.payload == nil && !session.preparing, "late cold reply cannot repaint a dismissed export")
        expect(old.stops == 2, "late startup is torn down again after an early stop")

        let abandoned = Task { await session.prepare(grant: nil) }
        await waitFor { VXDiagExport.instances.last?.gate.continuation != nil }
        let abandonedExport = VXDiagExport.instances.last!
        let replacement = Task { await session.prepare(grant: nil) }
        await waitFor { VXDiagExport.instances.last !== abandonedExport && VXDiagExport.instances.last?.gate.continuation != nil }
        let current = VXDiagExport.instances.last!
        current.gate.finish(("current", "qr")); await replacement.value
        expect(session.payload?.url == "current" && !session.preparing, "current export publishes its own QR")
        abandonedExport.gate.finish(("abandoned", "qr")); await abandoned.value
        expect(session.payload?.url == "current", "old reply cannot overwrite replacement QR")
        expect(current.stops == 0 && abandonedExport.stops == 2, "old cleanup never stops the replacement listener")

        let failure = Task { await session.prepare(grant: nil) }
        await waitFor { VXDiagExport.instances.last?.gate.continuation != nil }
        let failed = VXDiagExport.instances.last!
        failed.gate.finish(nil); await failure.value
        expect(session.payload == nil && !session.preparing && failed.stops == 1, "failed start is terminal and stopped, not an endless spinner")

        let cancelled = Task { await session.prepare(grant: nil) }
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

        // Real post-request payload/header/chunk controls with deterministic deferred callbacks.
        do {
            let policy = DiagnosticPolicy(), capture = CredentialScopeRegistry.shared.capture()
            let grant = ProfilePickerToolsDiagnosticGrant(allowed: true, credential: capture, admission: { policy.allowed })
            let connection = NWConnection(), export = DeliveryExport(deliveryAuthorization: { grant.permitsExport })
            let before = DeliveryExport.payloadReads
            _ = export.request(connection)
            policy.allowed = false // Before queued MainActor admission, before any snapshot is collected.
            await waitFor { connection.isCancelled }
            expect(DeliveryExport.payloadReads == before && connection.sends.isEmpty,
                   "revoked request cannot materialize or release a fresh diagnostic payload before cleanup")
        }
        do {
            let policy = DiagnosticPolicy()
            let grant = ProfilePickerToolsDiagnosticGrant(allowed: true, credential: CredentialScopeRegistry.shared.capture(), admission: { policy.allowed })
            let connection = NWConnection(), export = DeliveryExport(deliveryAuthorization: { grant.permitsExport })
            _ = export.request(connection)
            await waitFor { connection.sends.count == 1 } // Header handed off, body deferred.
            CredentialScopeRegistry.shared.change()
            connection.completeNext()
            await waitFor { connection.isCancelled }
            expect(connection.sends.count == 1, "credential revocation after payload/header forbids the deferred first body chunk")
        }
        do {
            let policy = DiagnosticPolicy()
            let grant = ProfilePickerToolsDiagnosticGrant(allowed: true, credential: CredentialScopeRegistry.shared.capture(), admission: { policy.allowed })
            let connection = NWConnection(), export = DeliveryExport(deliveryAuthorization: { grant.permitsExport })
            _ = export.request(connection); await waitFor { connection.sends.count == 1 }
            connection.completeNext(); await waitFor { connection.sends.count == 2 }
            policy.allowed = false; connection.completeNext()
            await waitFor { connection.isCancelled }
            expect(connection.sends.count == 2, "live policy revocation after one body chunk forbids every later chunk")
        }
        do {
            let connection = NWConnection(), export = DeliveryExport(deliveryAuthorization: { true })
            let before = DeliveryExport.payloadReads
            _ = export.request(connection); export.stopOwnedSession()
            await waitFor { connection.isCancelled }
            expect(DeliveryExport.payloadReads == before && connection.sends.isEmpty,
                   "synchronous owned retirement defeats queued authorized payload work before deferred teardown")
        }
        do {
            let connection = NWConnection(), export = DeliveryExport() // Existing nil/default unlocked path.
            let claim = export.request(connection)
            expect(connection.sends.count == 1, "nil authorization preserves immediate ordinary header release")
            connection.completeNext(); connection.completeNext(); connection.completeNext()
            expect(connection.sends.count == 3 && !export.stillOwns(claim),
                   "nil authorization preserves exact sequential chunks and one-shot completion")
        }

        session.stop()
        print("PASS \(passed) exact-source pre-profile export lifecycle checks")
    }
}
