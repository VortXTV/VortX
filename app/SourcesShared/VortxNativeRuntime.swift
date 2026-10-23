import Foundation
import Darwin
import VortxEngine

/// The native store ABI, kept separate from the shipping Stremio screen facade. Snapshots belong
/// to the explicit account/profile owner passed by the caller. This layer never reads credentials,
/// writes preferences, migrates legacy storage, or chooses an engine on the user's behalf.
protocol VortxRuntimeABI: Sendable {
    func create(ownerID: String, ownerName: String) -> UInt
    func hydrate(_ snapshot: String) -> UInt
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String?
    func resolve(_ handle: UInt, request: String) -> String?
    func state(_ handle: UInt) -> String?
    func delta(_ handle: UInt) -> String?
    /// Stateless evidence admission. It never borrows or changes an engine handle.
    func canonicalizeOwnerHistoryEvidence(_ evidence: String) -> String?
    func free(_ handle: UInt)
}

extension VortxRuntimeABI {
    // Older SDKs and standalone fixtures cannot advertise this newer capability.
    func canonicalizeOwnerHistoryEvidence(_ evidence: String) -> String? { nil }
}

enum VortxNativeError: Error, Equatable {
    case unavailable, closed, invalidSnapshot, invalidResponse, superseded, checkpointUncertain

    static func diagnosticCode(_ error: Error?) -> String {
        guard let error else { return "not_dispatched" }
        switch error as? Self {
        case .unavailable: return "unavailable"
        case .closed: return "closed"
        case .invalidSnapshot: return "invalid_snapshot"
        case .invalidResponse: return "invalid_response"
        case .superseded: return "superseded"
        case .checkpointUncertain: return "checkpoint_uncertain"
        case nil: return "restore_or_storage_failed"
        }
    }
}

/// Per-call locking plus one logical reservation owned by a non-suspending caller.
/// A reservation does not hold this mutex across host/store/authority work. It grants no
/// session lease, durability, SDK capability, publication or authentication authority.
final class VortxNativeRuntime: @unchecked Sendable {
    enum OwnershipFailure: Error, Equatable { case busy, staleReservation }

    /// Noncopyable and passed inout to a nonescaping synchronous closure. The owner never
    /// exposes a pointer. This capability must not be consumed, stored or sent to a Task.
    struct Reservation: ~Copyable {
        private let owner: VortxNativeRuntime
        private let identity: UUID
        private let generation: UUID

        fileprivate init(owner: VortxNativeRuntime, identity: UUID, generation: UUID) {
            self.owner = owner
            self.identity = identity
            self.generation = generation
        }
        func currentGeneration() throws -> UUID { try owner.reservedGeneration(identity, generation: generation) }
        func dispatch(_ action: String, now: UInt64) throws -> String {
            try owner.call(reservation: identity, generation: generation) { owner.abi.dispatch($0, action: action, now: now) }
        }
        func resolve(_ request: String) throws -> String {
            try owner.call(reservation: identity, generation: generation) { owner.abi.resolve($0, request: request) }
        }
        func stateJSON() throws -> String {
            try owner.call(reservation: identity, generation: generation) { owner.abi.state($0) }
        }
        func takeDeltaJSON() throws -> String {
            try owner.call(reservation: identity, generation: generation) { owner.abi.delta($0) }
        }
    }

    private let abi: any VortxRuntimeABI
    // Recursive acquisition only permits detecting same-thread ABI reentry. abiActive
    // always rejects it before a second ABI call or ownership transition can occur.
    private let lock = NSRecursiveLock()
    private var handle: UInt
    private var generation = UUID()
    private var reservation: UUID?
    private var abiActive = false

    init(abi: any VortxRuntimeABI, ownerID: String, ownerName: String) throws {
        self.abi = abi
        handle = abi.create(ownerID: ownerID, ownerName: ownerName)
        guard handle != 0 else { throw VortxNativeError.unavailable }
    }

    init(abi: any VortxRuntimeABI, snapshot: String) throws {
        self.abi = abi
        handle = abi.hydrate(snapshot)
        guard handle != 0 else { throw VortxNativeError.invalidSnapshot }
    }

    deinit { close() }

    /// Busy is NOT closed. The reservation owner must release its capability and then
    /// confirm close before releasing its scope writer. Never call this under a lease.
    @discardableResult
    func close() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !abiActive, reservation == nil else { return false }
        guard handle != 0 else { return true }
        let retired = handle
        handle = 0
        abiActive = true
        defer { abiActive = false }
        abi.free(retired)
        return true
    }

    func currentGeneration() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        try requireAccess(reservation: nil)
        return generation
    }

    /// Success changes generation even if an allocator later reuses a numeric pointer.
    /// A failed hydrate leaves both the incumbent handle and generation unchanged.
    func replaceFromSnapshot(_ snapshot: String) throws {
        let replacementGeneration = UUID()
        lock.lock(); defer { lock.unlock() }
        try requireAccess(reservation: nil)
        abiActive = true
        defer { abiActive = false }
        let replacement = abi.hydrate(snapshot)
        guard replacement != 0 else { throw VortxNativeError.invalidSnapshot }
        let retired = handle
        handle = replacement
        generation = replacementGeneration
        abi.free(retired)
    }

    /// Claims only metadata under R, then runs the owner closure WITHOUT R held.
    /// Each capability call independently acquires R. No await/escaping capability is
    /// permitted, and no session/store/publication callback is invoked from an ABI call.
    func withReservation<Result>(_ operation: (inout Reservation) throws -> Result) throws -> Result {
        let identity = UUID()
        let reservedGeneration: UUID
        lock.lock()
        do {
            try requireAccess(reservation: nil)
            reservedGeneration = generation
            reservation = identity
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        var capability = Reservation(owner: self, identity: identity, generation: reservedGeneration)
        defer { releaseReservation(identity, generation: reservedGeneration) }
        return try withExtendedLifetime(self) { try operation(&capability) }
    }

    func dispatch(_ action: String, now: UInt64) throws -> String {
        try call(reservation: nil) { abi.dispatch($0, action: action, now: now) }
    }
    func resolve(_ request: String) throws -> String {
        try call(reservation: nil) { abi.resolve($0, request: request) }
    }
    func stateJSON() throws -> String { try call(reservation: nil) { abi.state($0) } }
    /// Destructive drain remains exclusively the persistence owner's responsibility.
    func takeDeltaJSON() throws -> String { try call(reservation: nil) { abi.delta($0) } }

    private func requireAccess(reservation expected: UUID?, generation expectedGeneration: UUID? = nil) throws {
        guard !abiActive else { throw OwnershipFailure.busy }
        guard handle != 0 else { throw VortxNativeError.closed }
        if let expected {
            guard let expectedGeneration, reservation == expected, generation == expectedGeneration else {
                throw OwnershipFailure.staleReservation
            }
        } else {
            guard reservation == nil else { throw OwnershipFailure.busy }
        }
    }
    private func reservedGeneration(_ identity: UUID, generation expectedGeneration: UUID) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        try requireAccess(reservation: identity, generation: expectedGeneration)
        return generation
    }
    private func releaseReservation(_ identity: UUID, generation expectedGeneration: UUID) {
        lock.lock(); defer { lock.unlock() }
        // Only the lexical owner can reach this path; every permitted call is synchronous.
        precondition(reservation == identity && generation == expectedGeneration && !abiActive)
        reservation = nil
    }
    private func call(reservation identity: UUID?, generation expectedGeneration: UUID? = nil,
                      _ operation: (UInt) -> String?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        try requireAccess(reservation: identity, generation: expectedGeneration)
        abiActive = true
        defer { abiActive = false }
        guard let result = operation(handle) else { throw VortxNativeError.unavailable }
        return result
    }
}

// Deliberate artifact gate: old frameworks contain no public hydration declaration. Enable only
// after the header/export audit passes for every linked slice. Mac/Lite are not newly linked here.
struct VortxCABI: VortxRuntimeABI {
    private func copy(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { vortx_string_free(pointer) }
        return String(cString: pointer)
    }
    func create(ownerID: String, ownerName: String) -> UInt {
        guard let p = vortx_init_runtime(ownerID, ownerName) else { return 0 }
        return UInt(bitPattern: p)
    }
    func hydrate(_ snapshot: String) -> UInt {
        guard let p = vortx_init_from_state_json(snapshot) else { return 0 }
        return UInt(bitPattern: p)
    }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? {
        copy(vortx_dispatch_json(OpaquePointer(bitPattern: handle), action, now))
    }
    func resolve(_ handle: UInt, request: String) -> String? {
        copy(vortx_resolve_json(OpaquePointer(bitPattern: handle), request))
    }
    func state(_ handle: UInt) -> String? { copy(vortx_get_state_json(OpaquePointer(bitPattern: handle))) }
    func delta(_ handle: UInt) -> String? { copy(vortx_get_state_delta_json(OpaquePointer(bitPattern: handle))) }
    func canonicalizeOwnerHistoryEvidence(_ evidence: String) -> String? {
        guard let pointer = vortx_owner_history_canonicalize_evidence_json(evidence) else { return nil }
        defer { vortx_string_free(pointer) }
        let length = strnlen(pointer, 16 * 1024 * 1024 + 1)
        guard length <= 16 * 1024 * 1024 else { return nil }
        return String(data: Data(bytes: pointer, count: length), encoding: .utf8)
    }
    func free(_ handle: UInt) { vortx_engine_free(OpaquePointer(bitPattern: handle)) }
}
