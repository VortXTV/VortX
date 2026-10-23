import Foundation
import Darwin

// Saved source only. No real Session lease/store/facade/CoreBridge or SDK is exercised.
private final class FoundationABI: VortxRuntimeABI, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt = 0
    private var live = Set<UInt>()
    private var calls: [String] = []
    private var freeCount = 0
    private var hydrateFailure = false
    private var nilState = false
    private var dispatchHook: (@Sendable () -> Void)?
    var log: [String] { lock.withLock { calls } }
    var frees: Int { lock.withLock { freeCount } }
    func failHydrate(_ value: Bool) { lock.withLock { hydrateFailure = value } }
    func returnNilState(_ value: Bool) { lock.withLock { nilState = value } }
    func onDispatch(_ hook: (@Sendable () -> Void)?) { lock.withLock { dispatchHook = hook } }
    func create(ownerID: String, ownerName: String) -> UInt { hydrate("create") }
    func hydrate(_ snapshot: String) -> UInt {
        lock.withLock {
            calls.append("hydrate")
            if hydrateFailure { return 0 }
            next += 1
            live.insert(next)
            return next
        }
    }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? {
        let hook: (@Sendable () -> Void)? = lock.withLock {
            FoundationTests.check(live.contains(handle), "dispatch_live_handle")
            calls.append("dispatch")
            return dispatchHook
        }
        hook?() // Intentionally outside the fake's lock; real CABI has no callback.
        return #"{"ok":true,"events":[]}"#
    }
    func resolve(_ handle: UInt, request: String) -> String? {
        lock.withLock {
            FoundationTests.check(live.contains(handle), "resolve_live_handle")
            calls.append("resolve")
            return "resolve"
        }
    }
    func state(_ handle: UInt) -> String? {
        lock.withLock {
            FoundationTests.check(live.contains(handle), "state_live_handle")
            calls.append("state")
            return nilState ? nil : "state"
        }
    }
    func delta(_ handle: UInt) -> String? {
        lock.withLock {
            FoundationTests.check(live.contains(handle), "delta_live_handle")
            calls.append("delta")
            return "delta"
        }
    }
    func free(_ handle: UInt) {
        lock.withLock {
            FoundationTests.check(live.remove(handle) != nil, "exactly_once_free")
            freeCount += 1
            calls.append("free")
        }
    }
}

private final class EventLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.withLock { events.append(event) } }
    var snapshot: [String] { lock.withLock { events } }
}

@main enum FoundationTests {
    typealias Runtime = VortxNativeRuntime
    typealias Gate = VortxNativePublicationGate
    enum FixtureError: Error, Equatable { case stop }
    static func fail(_ label: String) -> Never {
        let bytes = Data(("FAIL foundation " + String(label.prefix(180)) + "\n").utf8)
        try? FileHandle.standardError.write(contentsOf: bytes)
        Darwin.exit(1)
    }
    static func check(_ value: Bool, _ label: String) { if !value { fail(label) } }
    static func rejects<E: Error & Equatable>(_ expected: E, _ label: String, _ body: () throws -> Void) {
        do { try body(); fail(label + "_accepted") }
        catch { check((error as? E) == expected, label + "_wrong_error") }
    }
    static func group(_ name: String, _ body: () throws -> Void) throws {
        print("START foundation " + name)
        try body()
        print("PASS foundation " + name)
    }
    private static func makeRuntime() throws -> (FoundationABI, Runtime) {
        let abi = FoundationABI()
        return (abi, try Runtime(abi: abi, snapshot: "opaque-baseline"))
    }

    static func legacyAndGeneration() throws {
        let (abi, runtime) = try makeRuntime()
        let first = try runtime.currentGeneration()
        check(try runtime.stateJSON() == "state", "legacy_state")
        check(try runtime.resolve("query") == "resolve", "legacy_resolve")
        check(try runtime.takeDeltaJSON() == "delta", "legacy_delta")
        _ = try runtime.dispatch("action", now: 7)
        abi.failHydrate(true)
        rejects(VortxNativeError.invalidSnapshot, "failed_hydrate") { try runtime.replaceFromSnapshot("bad") }
        check(try runtime.currentGeneration() == first, "failed_hydrate_generation")
        check(try runtime.stateJSON() == "state" && abi.frees == 0, "failed_hydrate_incumbent")
        abi.failHydrate(false)
        try runtime.replaceFromSnapshot("next")
        check(try runtime.currentGeneration() != first && abi.frees == 1, "replace_generation_and_free")
        abi.returnNilState(true)
        rejects(VortxNativeError.unavailable, "nil_state") { _ = try runtime.stateJSON() }
        abi.returnNilState(false)
        check(try runtime.stateJSON() == "state", "nil_state_guard_released")
        check(runtime.close() && runtime.close() && abi.frees == 2, "idempotent_close")
        rejects(VortxNativeError.closed, "closed_state") { _ = try runtime.stateJSON() }
        rejects(VortxNativeError.closed, "closed_reservation") { try runtime.withReservation { _ in } }
        let (otherABI, other) = try makeRuntime() // Both fakes allocate numeric handle 1.
        check(try other.currentGeneration() != first, "numeric_pointer_reuse_not_generation")
        check(other.close() && otherABI.frees == 1, "other_close")
    }

    static func reservationAndBusy() throws {
        let (abi, runtime) = try makeRuntime()
        let generation = try runtime.currentGeneration()
        try runtime.withReservation { capability in
            check(try capability.currentGeneration() == generation, "reserved_actual_generation")
            let before = abi.log
            rejects(Runtime.OwnershipFailure.busy, "raw_state_busy") { _ = try runtime.stateJSON() }
            rejects(Runtime.OwnershipFailure.busy, "raw_resolve_busy") { _ = try runtime.resolve("q") }
            rejects(Runtime.OwnershipFailure.busy, "raw_delta_busy") { _ = try runtime.takeDeltaJSON() }
            rejects(Runtime.OwnershipFailure.busy, "raw_dispatch_busy") { _ = try runtime.dispatch("a", now: 0) }
            rejects(Runtime.OwnershipFailure.busy, "raw_generation_busy") { _ = try runtime.currentGeneration() }
            rejects(Runtime.OwnershipFailure.busy, "raw_replace_busy") { try runtime.replaceFromSnapshot("x") }
            rejects(Runtime.OwnershipFailure.busy, "nested_reservation_busy") { try runtime.withReservation { _ in } }
            check(!runtime.close() && abi.log == before, "busy_close_no_abi_or_free")
            check(try capability.stateJSON() == "state", "reserved_state")
            check(try capability.resolve("q") == "resolve", "reserved_resolve")
            _ = try capability.dispatch("a", now: 8)
            check(try capability.takeDeltaJSON() == "delta", "reserved_delta")
            check(try capability.currentGeneration() == generation, "reserved_generation_stable")
        }
        check(abi.log == ["hydrate", "state", "resolve", "dispatch", "delta"], "reserved_exact_call_sequence")
        check(try runtime.currentGeneration() == generation && runtime.close(), "reservation_release")
    }

    static func throwAndLifetime() throws {
        let (abi, runtime) = try makeRuntime()
        rejects(FixtureError.stop, "body_throw") {
            try runtime.withReservation { capability in
                _ = try capability.stateJSON()
                throw FixtureError.stop
            }
        }
        check(try runtime.stateJSON() == "state", "throw_releases_reservation")
        check(runtime.close() && abi.frees == 1, "throw_close_once")
        let heldABI = FoundationABI()
        weak var weakRuntime: Runtime?
        func releaseExternalReference() throws {
            var held: Runtime? = try Runtime(abi: heldABI, snapshot: "opaque")
            weakRuntime = held
            try held!.withReservation { capability in
                held = nil
                check(weakRuntime != nil && heldABI.frees == 0, "capability_strong_owner")
                check(try capability.stateJSON() == "state", "capability_after_external_release")
            }
        }
        try releaseExternalReference()
        check(weakRuntime == nil && heldABI.frees == 1, "lifetime_ends_after_reservation")
    }

    static func reentryAndUnlockedGap() throws {
        let (abi, runtime) = try makeRuntime()
        let ledger = EventLedger()
        abi.onDispatch {
            rejects(Runtime.OwnershipFailure.busy, "abi_reentry_state") { _ = try runtime.stateJSON() }
            rejects(Runtime.OwnershipFailure.busy, "abi_reentry_reserve") { try runtime.withReservation { _ in } }
            rejects(Runtime.OwnershipFailure.busy, "abi_reentry_replace") { try runtime.replaceFromSnapshot("x") }
            check(!runtime.close(), "abi_reentry_close_busy")
            ledger.append("reentry-rejected")
        }
        _ = try runtime.dispatch("unreserved", now: 1)
        try runtime.withReservation { capability in
            _ = try capability.dispatch("reserved", now: 2)
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                rejects(Runtime.OwnershipFailure.busy, "gap_raw_state") { _ = try runtime.stateJSON() }
                check(!runtime.close(), "gap_raw_close")
                ledger.append("gap-rejected")
                done.signal()
            }
            // Deadline fails a deadlock; success relies on the causal signal while the
            // reservation is still held, not on elapsed time or a fake lease/revoke.
            check(done.wait(timeout: .now() + 5) == .success, "gap_mutex_not_held")
            check(try capability.stateJSON() == "state", "gap_owner_still_usable")
        }
        abi.onDispatch(nil) // Break the fixture's deliberate strong hook ownership.
        check(ledger.snapshot == ["reentry-rejected", "reentry-rejected", "gap-rejected"], "reentry_gap_ledger")
        check(abi.log == ["hydrate", "dispatch", "dispatch", "state"], "no_reentrant_abi")
        check(runtime.close() && abi.frees == 1, "reentry_close_once")
    }

    static func gateLifecycle() throws {
        let owner = UUID(), gate = Gate(ownerGeneration: owner)
        check(gate.currentReceipt() == nil && gate.admitsOwner(owner), "unadopted_owner_not_receipt")
        let first = try gate.advance(expected: nil, handleGeneration: UUID(), publication: UUID(), acceptance: .durable)
        try gate.requireCurrent(first)
        let held = try gate.advance(expected: first, handleGeneration: UUID(), publication: UUID(), acceptance: .volatile)
        try gate.requireCurrent(held, durable: false)
        rejects(Gate.Failure.notDurable, "held_progress_not_durable") { try gate.requireCurrent(held) }
        check(!gate.admitsDurableNotification(held), "volatile_not_dirty_ack")
        rejects(Gate.Failure.staleReceipt, "old_export") { try gate.requireCurrent(first) }
        check(gate.admitsDurableNotification(first), "later_same_owner_dirty_positive")
        let afterFlush = try gate.advance(expected: held, handleGeneration: held.handleGeneration,
                                         publication: UUID(), acceptance: .durable)
        try gate.requireCurrent(afterFlush)
        rejects(Gate.Failure.staleReceipt, "stale_cas") {
            _ = try gate.advance(expected: first, handleGeneration: UUID(), publication: UUID(), acceptance: .durable)
        }
        rejects(Gate.Failure.reusedPublication, "same_publication") {
            _ = try gate.advance(expected: afterFlush, handleGeneration: afterFlush.handleGeneration,
                                 publication: afterFlush.publication, acceptance: .durable)
        }
        check(gate.currentReceipt() == afterFlush, "gate_rejection_atomic")
        try gate.invalidateCertification(expected: afterFlush)
        check(gate.admitsOwner(owner) && gate.currentReceipt() == nil, "uncertain_cache_only")
        rejects(Gate.Failure.uncertain, "uncertain_export") { try gate.requireCurrent(afterFlush) }
        rejects(Gate.Failure.uncertain, "uncertain_no_recertification") {
            _ = try gate.advance(expected: afterFlush, handleGeneration: UUID(), publication: UUID(), acceptance: .durable)
        }
        gate.retire(); gate.retire()
        check(!gate.admitsOwner(owner) && !gate.admitsDurableNotification(first) && gate.currentReceipt() == nil, "retired_no_owner_or_dirty")
        rejects(Gate.Failure.retired, "retired_advance") {
            _ = try gate.advance(expected: afterFlush, handleGeneration: UUID(), publication: UUID(), acceptance: .durable)
        }
    }

    static func gateABA() throws {
        let owner = UUID()
        let old = Gate(ownerGeneration: owner)
        let receipt = try old.advance(expected: nil, handleGeneration: UUID(), publication: UUID(), acceptance: .durable)
        old.retire()
        // Deliberately reuse even owner/handle/publication values: gate instance identity
        // still refuses an earlier instance. Real owners MUST allocate fresh UUIDs too.
        let fresh = Gate(ownerGeneration: owner)
        let next = try fresh.advance(expected: nil, handleGeneration: receipt.handleGeneration,
                                     publication: receipt.publication, acceptance: .durable)
        check(next != receipt, "gate_instance_aba")
        rejects(Gate.Failure.staleReceipt, "other_gate_export") { try fresh.requireCurrent(receipt) }
        check(!fresh.admitsDurableNotification(receipt) && fresh.admitsDurableNotification(next), "other_gate_dirty_reject")
        check(!fresh.admitsOwner(UUID()), "foreign_owner")
        fresh.retire()
    }

    // Independent oracle copied from the accepted test convention, not the production
    // comparator: tagged bytes, sorted raw UTF-8 object keys, exact enum and Double bits.
    static func image(_ value: VortxJSON) -> [UInt8] {
        func frame(_ text: String) -> [UInt8] { Array("\(text.utf8.count):".utf8) + Array(text.utf8) }
        switch value {
        case .object(let fields):
            return Array("o\(fields.count):".utf8) + fields.keys.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }.flatMap { frame($0) + image(fields[$0]!) }
        case .array(let values): return Array("a\(values.count):".utf8) + values.flatMap(image)
        case .string(let text): return [115] + frame(text)
        case .integer(let value): return Array("i\(value);".utf8)
        case .unsigned(let value): return Array("u\(value);".utf8)
        case .number(let value): return Array("d\(value.bitPattern);".utf8)
        case .bool(let value): return Array((value ? "true;" : "false;").utf8)
        case .null: return Array("null;".utf8)
        }
    }
    static func comparator() {
        let nfc = "\u{e9}", nfd = "e\u{301}"
        check(Array(nfc.utf8) != Array(nfd.utf8), "independent_unicode_oracle")
        let pairs: [(VortxJSON, VortxJSON, Bool)] = [
            (.string(nfc), .string(nfc), true), (.string(nfc), .string(nfd), false),
            (.object([nfc: .null]), .object([nfd: .null]), false),
            (.array([.string(nfc), .unsigned(UInt64.max)]), .array([.string(nfd), .unsigned(UInt64.max)]), false),
            (.integer(1), .unsigned(1), false), (.integer(1), .number(1), false),
            (.number(0.0), .number(-0.0), false), (.number(-0.0), .number(-0.0), true),
            (.array([.integer(1), .integer(2)]), .array([.integer(2), .integer(1)]), false),
            (.array([.null]), .array([.null, .null]), false),
            (.object(["opaque": .array([.unsigned(UInt64.max), .string(nfc), .null])]),
             .object(["opaque": .array([.unsigned(UInt64.max), .string(nfc), .null])]), true)
        ]
        for (left, right, expected) in pairs {
            check((image(left) == image(right)) == expected, "independent_value_oracle")
            check(VortxNativeDeltaApplier.exactlyMatchesPreparedBaseline(left, right) == expected, "exact_comparator_seam")
        }
    }

    static func main() {
        do {
            check(!VortxPersistentHandleArtifactPolicy.enabled, "artifact_gate_default_off")
            try group("legacy-generation", legacyAndGeneration)
            try group("reservation-busy", reservationAndBusy)
            try group("throw-lifetime", throwAndLifetime)
            try group("reentry-gap", reentryAndUnlockedGap)
            try group("gate-lifecycle", gateLifecycle)
            try group("gate-aba", gateABA)
            try group("exact-comparator", comparator)
            print("PASS foundation groups=7 integration=UNWIRED sdk=UNPROVEN")
        } catch { fail("unexpected_top_level_error") }
    }
}
