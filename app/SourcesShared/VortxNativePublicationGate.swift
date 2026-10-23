import Foundation

/// Explicitly OFF. A host fixture, header, symbol or source revision is not SDK proof.
/// No production caller consumes this foundation packet or may turn this on implicitly.
enum VortxPersistentHandleArtifactPolicy {
    static let enabled = false
}

/// UNWIRED leaf P from the reviewed design, not a replacement for the real session lease.
/// Stores only fixed-size value metadata, accepts no closures and acquires no other locks.
/// The future session MUST call advance/invalidate/retire under its real L as specified;
/// facade readers may call the read methods under F. Never acquire L from a gate reader.
final class VortxNativePublicationGate: @unchecked Sendable {
    enum Failure: Error, Equatable { case retired, staleReceipt, uncertain, notDurable, reusedPublication }
    enum Acceptance: Equatable, Sendable { case volatile, durable }

    /// Issued only by this gate. An old receipt proves an earlier admission, not current
    /// ownership; every consumer must call the appropriate live admission method again.
    struct Receipt: Equatable, Sendable {
        let ownerGeneration: UUID
        let handleGeneration: UUID
        let publication: UUID
        let acceptance: Acceptance
        fileprivate let gateIdentity: UUID
        fileprivate init(owner: UUID, handle: UUID, publication: UUID,
                         acceptance: Acceptance, gateIdentity: UUID) {
            ownerGeneration = owner
            handleGeneration = handle
            self.publication = publication
            self.acceptance = acceptance
            self.gateIdentity = gateIdentity
        }
    }

    let ownerGeneration: UUID
    private let identity = UUID()
    private let lock = NSLock()
    private var ownerActive = true
    private var uncertain = false
    private var current: Receipt?

    init(ownerGeneration: UUID) { self.ownerGeneration = ownerGeneration }

    /// Initial adoption uses expected nil. Every later ownership/publication transition is
    /// a CAS against the exact receipt, including the gate identity. Caller preallocates a
    /// fresh publication UUID for EVERY advance; this leaf keeps no historical ID registry.
    /// Volatile ownership must never be relabeled as durable by a cache/read operation.
    @discardableResult
    func advance(expected: Receipt?, handleGeneration: UUID, publication: UUID,
                 acceptance: Acceptance) throws -> Receipt {
        let next = Receipt(owner: ownerGeneration, handle: handleGeneration, publication: publication,
                           acceptance: acceptance, gateIdentity: identity)
        lock.lock(); defer { lock.unlock() }
        guard ownerActive else { throw Failure.retired }
        guard !uncertain else { throw Failure.uncertain }
        guard current == expected else { throw Failure.staleReceipt }
        guard current?.publication != publication else { throw Failure.reusedPublication }
        current = next
        return next
    }

    /// Post-attempt uncertainty is a one-way export/certification latch for this owner.
    /// Existing acknowledged cache reads remain possible, but no new receipt can certify it.
    func invalidateCertification(expected: Receipt?) throws {
        lock.lock(); defer { lock.unlock() }
        guard ownerActive else { throw Failure.retired }
        guard current == expected else { throw Failure.staleReceipt }
        uncertain = true
    }

    /// Call from actual lease revoke before L is released. This method cannot reactivate P.
    func retire() {
        lock.lock(); defer { lock.unlock() }
        ownerActive = false
    }

    /// Cached acknowledged values/bindings still require THIS live owner, even in the gap
    /// between revoke-all and facade close. No fresh valid binding is manufactured on failure.
    func admitsOwner(_ expectedOwner: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ownerActive && ownerGeneration == expectedOwner
    }

    /// Optional by design: retired/uncertain/unadopted owners have no current receipt.
    func currentReceipt() -> Receipt? {
        lock.lock(); defer { lock.unlock() }
        guard ownerActive && !uncertain else { return nil }
        return current
    }

    /// An export must be exact current state, not merely an old matching owner. A volatile
    /// receipt permits live projection only when the caller explicitly allows it; it cannot
    /// become durable fast-lane admission or outgoing payload certification by default.
    func requireCurrent(_ receipt: Receipt, durable: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        guard ownerActive else { throw Failure.retired }
        guard !uncertain else { throw Failure.uncertain }
        guard receipt.gateIdentity == identity, current == receipt else { throw Failure.staleReceipt }
        guard !durable || receipt.acceptance == .durable else { throw Failure.notDurable }
    }

    /// Payload-free notification of an ALREADY accepted durable batch is not a current-state
    /// export. Later same-owner publication/handle replacement must not erase its dirty signal.
    /// The caller still must check the ORIGINAL installation on main and invoke its synchronous
    /// effect in that same turn. This Boolean must never authorize a delayed callback elsewhere.
    func admitsDurableNotification(_ receipt: Receipt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ownerActive && receipt.gateIdentity == identity
            && receipt.ownerGeneration == ownerGeneration && receipt.acceptance == .durable
    }
}
