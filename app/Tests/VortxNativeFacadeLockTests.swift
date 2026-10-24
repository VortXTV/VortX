import Foundation
import Darwin
import os
import XCTest

// The extractor inserts whole current declarations. The worker below is explicit RAM state,
// not an app facade, Session, ABI, credential, live receipt owner, or checkpoint implementation.
// PRODUCTION_DECLARATIONS

private final class LockEvents: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    func record(_ value: String) { state.withLock { $0.append(value) } }
    var values: [String] { state.withLock { $0 } }
}
private final class LockBox<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { state = OSAllocatedUnfairLock(initialState: value) }
    func set(_ value: Value) { state.withLock { $0 = value } }
    var value: Value { state.withLock { $0 } }
}
private enum LockWorkerProbe {
    // Explicit barriers, without sleeps. Success requires ANOTHER worker to acquire F while
    // this synchronous callback/destructor is still on the stack. A timeout bounds RED cases.
    static func acquire(_ boundary: VortxNativeFacadeLock) -> Bool {
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            started.signal()
            boundary.withLock {}
            finished.signal()
        }
        guard started.wait(timeout: .now() + 2) == .success else { return false }
        return finished.wait(timeout: .now() + 2) == .success
    }
}
private struct LockActiveSource: VortxMutationAuthority {
    func withActive(_ operation: () throws -> Void) throws { try operation() }
}

// Only fixture ownership is unchecked: the production mutable facade is not being declared
// Sendable by this test. All worker storage access goes through its real common boundary.
private final class FacadePublishWorker: @unchecked Sendable {
    let lock: VortxNativeFacadeLock
    let fifo: VortxNativeFIFOAdmission
    // PRODUCTION_RECEIPT_SUPPORT
    private var values: [String: VortxJSON] = [:]
    private var generations: [String: UUID] = [:]
    private var closed = false
    private let changed: @Sendable ([String]) -> Void
    private var metadataLibraryMembership = VortxLibraryMembership()
    private var playback: VortxJSON?
    private var externalMetadataReceipts: [Data: (Data, UUID)] = [:]
    private var externalMetadataObservation = UUID()

    init(sourceChangedDelivery: (@Sendable ([String], ChangeReceipt?) -> (@Sendable () -> Void)?)? = nil,
         ownedChange: (@Sendable (ChangeReceipt) -> Void)? = nil,
         changed: @escaping @Sendable ([String]) -> Void) {
        let boundary = VortxNativeFacadeLock()
        lock = boundary; fifo = VortxNativeFIFOAdmission(lock: boundary); self.changed = changed
        self.ownedChange = ownedChange
        self.sourceChangedDelivery = sourceChangedDelivery
        // Explicit RAM acknowledged identity, solely so the REAL receipt builder can run.
        values["native_state"] = .object(["activeProfileId": .string("fixture-profile")])
    }
    func arm(_ field: String) -> UUID {
        lock.withLock {
            if resourceSelections[field] == nil { resourceSelections[field] = UUID() }
            let ticket = UUID(); generations[field] = ticket; return ticket
        }
    }
    func read(_ field: String) -> VortxJSON? { lock.withLock { values[field] } }
    func closeForFixture() { lock.withLock { closed = true } }
    func publishForFixture(_ fields: [String: VortxJSON], field: String, ticket: UUID) {
        publish(fields, field: field, ticket: ticket)
    }
    // PRODUCTION_WORKER_METHODS
}

private final class DeliveryCapture: Sendable {
    private let boundary: VortxNativeFacadeLock
    private let events: LockEvents
    init(_ boundary: VortxNativeFacadeLock, _ events: LockEvents) { self.boundary = boundary; self.events = events }
    func used() { events.record("delivery") }
    deinit { events.record("destroy-worker-\(LockWorkerProbe.acquire(boundary))") }
}

/// Lock/callback timing and the real FIFO primitive only. No durable success/owned-receipt claim.
final class VortxNativeFacadeLockTests: XCTestCase {
    private enum ExpectedFailure: Error { case requested }

    func testStandaloneAndEmptyTransactionsReturnSynchronously() {
        let boundary = VortxNativeFacadeLock(), events = LockEvents()
        boundary.withLock {}
        XCTAssertTrue(events.values.isEmpty)
        boundary.afterOutermostUnlock {
            events.record("callback-worker-\(LockWorkerProbe.acquire(boundary))")
        }
        events.record("return")
        XCTAssertEqual(events.values, ["callback-worker-true", "return"])
    }

    func testActualPublishWaitsForOutermostCommonLockAndNestedFIFO() throws {
        let events = LockEvents(), box = LockBox<FacadePublishWorker?>(nil)
        let worker = FacadePublishWorker { fields in
            let held = box.value!
            events.record("changed-\(fields.joined(separator: ","))-worker-\(LockWorkerProbe.acquire(held.lock))")
        }
        box.set(worker)
        defer { box.set(nil) }
        let ticket = worker.arm("board")
        var member: VortxNativeFIFOAdmission.Member?
        try worker.lock.withLock {
            member = try worker.fifo.admit()
            worker.lock.withLock {
                worker.publishForFixture(["board": .string("accepted")], field: "board", ticket: ticket)
            }
            XCTAssertTrue(events.values.isEmpty, "inner publish unlock is not the outer common-F unlock")
            XCTAssertEqual(worker.read("board"), .string("accepted"))
            events.record("inside")
        }
        events.record("return")
        XCTAssertEqual(events.values, ["inside", "changed-board-worker-true", "return"])
        let admitted = try XCTUnwrap(member)
        try admitted.begin(); admitted.finish()
    }

    func testActualPublishSuppressesEmptyUnchangedStaleAndClosed() {
        let events = LockEvents(), worker = FacadePublishWorker { fields in events.record(fields.joined(separator: ",")) }
        let ticket = worker.arm("board")
        worker.publishForFixture([:], field: "board", ticket: ticket)
        XCTAssertTrue(events.values.isEmpty)
        worker.publishForFixture(["board": .string("one")], field: "board", ticket: ticket)
        XCTAssertEqual(events.values, ["board"])
        worker.publishForFixture(["board": .string("one")], field: "board", ticket: ticket)
        worker.publishForFixture(["board": .string("stale")], field: "board", ticket: UUID())
        worker.closeForFixture()
        worker.publishForFixture(["board": .string("closed")], field: "board", ticket: ticket)
        XCTAssertEqual(events.values, ["board"])
        XCTAssertEqual(worker.read("board"), .string("one"))
    }

    func testActualPublishSortsFieldsAndPublishesBeforeCallback() {
        let events = LockEvents(), ownedEvents = LockEvents(), box = LockBox<FacadePublishWorker?>(nil)
        // This is the generic staging seam, not a fake typed Facade source envelope.
        let worker = FacadePublishWorker(sourceChangedDelivery: { fields, receipt in
            ownedEvents.record("staged")
            return {
                let held = box.value!
                ownedEvents.record("source-\(fields.joined(separator: ","))-original-\(receipt?.fields == fields)-worker-\(LockWorkerProbe.acquire(held.lock))")
            }
        }, ownedChange: { receipt in
            let held = box.value!
            ownedEvents.record("owned-\(receipt.fields.joined(separator: ","))-worker-\(LockWorkerProbe.acquire(held.lock))")
        }) { fields in
            ownedEvents.record("legacy")
            let held = box.value!
            events.record(fields.joined(separator: ","))
            events.record("visible-\(held.read("a") == .integer(1) && held.read("z") == .integer(2))")
            events.record("worker-\(LockWorkerProbe.acquire(held.lock))")
        }
        box.set(worker)
        defer { box.set(nil) }
        let ticket = worker.arm("board")
        worker.lock.withLock {
            worker.publishForFixture(["z": .integer(2), "a": .integer(1)], field: "board", ticket: ticket)
            XCTAssertEqual(ownedEvents.values, ["staged"], "builder captures before the original outer F drains")
        }
        events.record("return")
        XCTAssertEqual(events.values, ["a,z", "visible-true", "worker-true", "return"])
        XCTAssertEqual(ownedEvents.values,
                       ["staged", "source-a,z-original-true-worker-true", "owned-a,z-worker-true", "legacy"],
                       "captured generic source delivery precedes owned and legacy, all after outermost F")
    }

    func testThrowingNestedTransactionsDrainFIFOAfterUnlock() {
        let boundary = VortxNativeFacadeLock(), events = LockEvents()
        XCTAssertThrowsError(try boundary.withLock {
            boundary.afterOutermostUnlock { events.record("first-worker-\(LockWorkerProbe.acquire(boundary))") }
            boundary.withLock {
                boundary.afterOutermostUnlock { events.record("second") }
            }
            XCTAssertTrue(events.values.isEmpty)
            throw ExpectedFailure.requested
        })
        events.record("caught")
        boundary.withLock {}
        XCTAssertEqual(events.values, ["first-worker-true", "second", "caught"])
    }

    func testCapturedDeliveryDestructionHappensOutsideFacadeLock() {
        let boundary = VortxNativeFacadeLock(), events = LockEvents()
        func installOnlyOwner() {
            let capture = DeliveryCapture(boundary, events)
            boundary.afterOutermostUnlock { [capture] in capture.used() }
        }
        boundary.lock()
        installOnlyOwner()
        XCTAssertTrue(events.values.isEmpty)
        boundary.unlock()
        events.record("return")
        XCTAssertEqual(events.values, ["delivery", "destroy-worker-true", "return"])
    }

    func testReadAdmissionUsesSameRecursiveBoundaryAndPreservesMemberOrder() throws {
        let events = LockEvents(), box = LockBox<FacadePublishWorker?>(nil)
        let worker = FacadePublishWorker { fields in
            events.record("changed-\(fields.joined(separator: ","))-worker-\(LockWorkerProbe.acquire(box.value!.lock))")
        }
        box.set(worker)
        defer { box.set(nil) }
        let ticket = worker.arm("read")
        let read = try worker.fifo.capture(source: LockActiveSource()) {}
        var admitted: VortxNativeFIFOAdmission.Member?
        try worker.lock.withLock {
            try worker.fifo.admit(read) {
                admitted = $0
                worker.publishForFixture(["read": .string("installed")], field: "read", ticket: ticket)
                XCTAssertTrue(events.values.isEmpty)
                events.record("installed")
            }
            XCTAssertTrue(events.values == ["installed"])
        }
        events.record("admit-return")
        XCTAssertEqual(events.values, ["installed", "changed-read-worker-true", "admit-return"])
        let first = try XCTUnwrap(admitted), next = try worker.fifo.admit()
        XCTAssertThrowsError(try next.begin())
        XCTAssertThrowsError(try read.withActive {})
        try first.begin()
        XCTAssertNoThrow(try read.withActive {})
        first.finish()
        XCTAssertThrowsError(try read.withActive {})
        try next.begin(); next.finish()
        XCTAssertNoThrow(try worker.fifo.capture(source: LockActiveSource()) {})
    }

    func testCallbackCanReenterPublishAndAdmitFIFO() {
        let events = LockEvents(), box = LockBox<FacadePublishWorker?>(nil)
        let worker = FacadePublishWorker { fields in
            let held = box.value!
            events.record(fields.joined(separator: ","))
            if fields == ["outer"] {
                do {
                    let member = try held.fifo.admit()
                    try member.begin(); member.finish()
                    let ticket = held.arm("inner")
                    held.publishForFixture(["inner": .bool(true)], field: "inner", ticket: ticket)
                    events.record("reentry-return")
                } catch { events.record("reentry-failed") }
            }
        }
        box.set(worker)
        defer { box.set(nil) }
        let ticket = worker.arm("outer")
        worker.publishForFixture(["outer": .bool(true)], field: "outer", ticket: ticket)
        events.record("producer-return")
        XCTAssertEqual(events.values, ["outer", "inner", "reentry-return", "producer-return"])
    }

    func testSynchronousNotificationCompletesBeforeProducerReturn() {
        let center = NotificationCenter(), name = Notification.Name("VortX.fixture.facade-lock")
        let events = LockEvents(), box = LockBox<FacadePublishWorker?>(nil)
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            events.record("notification-worker-\(LockWorkerProbe.acquire(box.value!.lock))")
        }
        defer { center.removeObserver(token) }
        let worker = FacadePublishWorker { _ in
            events.record("changed-enter")
            center.post(name: name, object: nil)
            events.record("changed-return")
        }
        box.set(worker)
        defer { box.set(nil) }
        let ticket = worker.arm("board")
        worker.publishForFixture(["board": .bool(true)], field: "board", ticket: ticket)
        events.record("producer-return")
        XCTAssertEqual(events.values, ["changed-enter", "notification-worker-true", "changed-return", "producer-return"])
    }
}
