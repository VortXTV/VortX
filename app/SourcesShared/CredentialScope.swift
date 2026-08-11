import Foundation

/// Result of a credential mutation at the durable storage boundary. A caller may keep a volatile intent for
/// ordinary UI continuity, but migration and ownership transfer must proceed only after `.success`.
enum CredentialMutationResult: Equatable, Sendable {
    case success
    case failure
}

/// Tri-state durable storage truth. `missing` is a confirmed absence; `failure` is unknown and must never be
/// treated as a successful readback during credential migration.
enum CredentialDurableReadResult: Equatable, Sendable {
    case value(String)
    case missing
    case failure
}

/// The one durable pointer that selects a complete credential tuple. The base slots remain a compatibility
/// mirror for pre-pointer installs, but once `pointer` is non-nil they are never authority.
struct CredentialTupleAuthority: Equatable, Sendable {
    let pointer: String?
    let values: [String]
}

enum CredentialTupleReadResult: Equatable, Sendable {
    case none
    case authority(CredentialTupleAuthority)
    case failure
}

enum CredentialTupleTransitionResult: Equatable, Sendable {
    case activated(CredentialTupleAuthority)
    case alreadyActive(CredentialTupleAuthority)
    case cleanupPending(CredentialTupleAuthority)
    case failedBeforeActivation
    case activationStateUnknown
}

enum CredentialPublicationOutboxState: Equatable, Sendable {
    case missing
    case pending(String)
    case dispatching(String)
    case acknowledged(String)
    case failure
}

/// Durable intent for the synchronous authentication-boundary publication. The marker is written before
/// the transaction removes its candidate identity. A local dispatch claim is written and certified before
/// the external boundary is called; if completion is ambiguous, the claim remains dispatching and all
/// later recovery fails closed instead of replaying the callback.
enum CredentialPublicationOutbox {
    enum BoundaryAcquisition: Equatable, Sendable {
        case acquired
        case busy
        case reentrant
    }

    struct DispatchLease: Equatable, Sendable {
        fileprivate let id: UInt64
        fileprivate let account: String
        fileprivate let sessionID: String
        fileprivate let epoch: UInt64
    }

    struct MutationLease: Equatable, Sendable {
        fileprivate let id: UInt64
        fileprivate let epoch: UInt64
    }

    private struct DispatchRecord {
        let account: String
        let threadID: ObjectIdentifier
    }

    private struct MutationRecord {
        let threadID: ObjectIdentifier
    }

    private final class Coordination: @unchecked Sendable {
        let condition = NSCondition()
        var nextLeaseID: UInt64 = 0
        var epoch: UInt64 = 0
        var boundaryActive = false
        var active: [UInt64: DispatchRecord] = [:]
        var mutations: [UInt64: MutationRecord] = [:]
        var boundaryWaiters: [CheckedContinuation<BoundaryAcquisition, Never>] = []
    }

    private static let coordination = Coordination()
    /// Synchronous observers execute under the dispatch task-local. This is more reliable than a worker
    /// thread identity on cooperative executors, where a callback may resume on a different thread while
    /// still being logically reentrant with the live dispatch lease.
    @TaskLocal private static var callbackLeaseID: UInt64?

    /// Try to acquire the publication boundary without holding the coordination mutex across callbacks.
    /// Callers that can suspend retry `.busy` cooperatively; synchronous callers fail closed rather than
    /// blocking the main actor or an observer that must return before the lease can drain.
    static func acquireBoundary() -> BoundaryAcquisition {
        if callbackLeaseIsActive() { return .reentrant }
        let threadID = ObjectIdentifier(Thread.current)
        coordination.condition.lock()
        if coordination.active.values.contains(where: { $0.threadID == threadID }) {
            coordination.condition.unlock()
            return .reentrant
        }
        if coordination.mutations.values.contains(where: { $0.threadID == threadID }) {
            coordination.condition.unlock()
            return .reentrant
        }
        guard !coordination.boundaryActive,
              coordination.active.isEmpty,
              coordination.mutations.isEmpty,
              coordination.boundaryWaiters.isEmpty else {
            coordination.condition.unlock()
            return .busy
        }
        coordination.boundaryActive = true
        coordination.epoch &+= 1
        coordination.condition.unlock()
        return .acquired
    }

    static func beginBoundary() -> Bool {
        acquireBoundary() == .acquired
    }

    static func withCallback<T>(
        _ lease: DispatchLease,
        _ callback: () throws -> T
    ) rethrows -> T {
        try $callbackLeaseID.withValue(lease.id, operation: callback)
    }

    /// Wait cooperatively for an ordinary credential boundary. The continuation is resumed only after all
    /// callback leases drain and owns the boundary before it runs, so a new dispatch cannot overtake it.
    static func waitForBoundary() async -> BoundaryAcquisition {
        if callbackLeaseIsActive() { return .reentrant }
        return await withCheckedContinuation { continuation in
            let threadID = ObjectIdentifier(Thread.current)
            coordination.condition.lock()
            if coordination.active.values.contains(where: { $0.threadID == threadID }) {
                coordination.condition.unlock()
                continuation.resume(returning: .reentrant)
                return
            }
            if coordination.mutations.values.contains(where: { $0.threadID == threadID }) {
                coordination.condition.unlock()
                continuation.resume(returning: .reentrant)
                return
            }
            if !coordination.boundaryActive,
               coordination.active.isEmpty,
               coordination.mutations.isEmpty,
               coordination.boundaryWaiters.isEmpty {
                coordination.boundaryActive = true
                coordination.epoch &+= 1
                coordination.condition.unlock()
                continuation.resume(returning: .acquired)
                return
            }
            coordination.boundaryWaiters.append(continuation)
            coordination.condition.unlock()
        }
    }

    static func endBoundary() {
        coordination.condition.lock()
        coordination.boundaryActive = false
        let waiter = acquireNextBoundaryWaiterLocked()
        coordination.condition.broadcast()
        coordination.condition.unlock()
        waiter?.resume(returning: .acquired)
    }

    /// Hold the same ownership domain used by bind/clear from before the first durable credential write
    /// through publication ACK. Acquisition never blocks MainActor or an observer: callers propagate a
    /// nil lease and retry the mutation after the competing boundary completes.
    static func beginMutation() -> MutationLease? {
        if callbackLeaseIsActive() { return nil }
        let threadID = ObjectIdentifier(Thread.current)
        coordination.condition.lock()
        if coordination.active.values.contains(where: { $0.threadID == threadID }) {
            coordination.condition.unlock()
            return nil
        }
        guard !coordination.boundaryActive,
              coordination.boundaryWaiters.isEmpty else {
            coordination.condition.unlock()
            return nil
        }
        coordination.nextLeaseID &+= 1
        let lease = MutationLease(id: coordination.nextLeaseID, epoch: coordination.epoch)
        coordination.mutations[lease.id] = MutationRecord(threadID: threadID)
        coordination.condition.unlock()
        return lease
    }

    static func endMutation(_ lease: MutationLease) {
        coordination.condition.lock()
        var waiter: CheckedContinuation<BoundaryAcquisition, Never>?
        if coordination.mutations.removeValue(forKey: lease.id) != nil {
            waiter = acquireNextBoundaryWaiterLocked()
            coordination.condition.broadcast()
        }
        coordination.condition.unlock()
        waiter?.resume(returning: .acquired)
    }

    /// Claim a certified pending intent and keep its local lease live through the callback and ACK. The
    /// durable dispatching write is performed with the mutex released, but the active lease prevents a
    /// clear/owner boundary from overtaking it and prevents another local drainer from claiming it.
    static func beginDispatch(
        sessionID: String,
        account: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> DispatchLease? {
        let threadID = ObjectIdentifier(Thread.current)
        coordination.condition.lock()
        guard !coordination.boundaryActive,
              coordination.boundaryWaiters.isEmpty,
              !coordination.active.values.contains(where: { $0.account == account }),
              case let .pending(existing) = state(account: account, read: read),
              existing == sessionID else {
            coordination.condition.unlock()
            return nil
        }
        coordination.nextLeaseID &+= 1
        let lease = DispatchLease(
            id: coordination.nextLeaseID,
            account: account,
            sessionID: sessionID,
            epoch: coordination.epoch
        )
        coordination.active[lease.id] = DispatchRecord(account: account, threadID: threadID)
        coordination.condition.unlock()

        guard writeExact("dispatching:\(sessionID)", account: account, read: read, write: write) else {
            endDispatch(lease)
            return nil
        }
        return lease
    }

    static func endDispatch(_ lease: DispatchLease) {
        coordination.condition.lock()
        var waiter: CheckedContinuation<BoundaryAcquisition, Never>?
        if coordination.active.removeValue(forKey: lease.id) != nil {
            waiter = acquireNextBoundaryWaiterLocked()
            coordination.condition.broadcast()
        }
        coordination.condition.unlock()
        waiter?.resume(returning: .acquired)
    }

    static func state(
        account: String,
        read: (String) -> CredentialDurableReadResult
    ) -> CredentialPublicationOutboxState {
        switch read(account) {
        case .missing:
            return .missing
        case .failure:
            return .failure
        case let .value(raw) where raw.hasPrefix("dispatching:"):
            let session = String(raw.dropFirst("dispatching:".count))
            return session.isEmpty ? .failure : .dispatching(session)
        case let .value(raw) where raw.hasPrefix("pending:"):
            let session = String(raw.dropFirst("pending:".count))
            return session.isEmpty ? .failure : .pending(session)
        case let .value(raw) where raw.hasPrefix("ack:"):
            let session = String(raw.dropFirst("ack:".count))
            return session.isEmpty ? .failure : .acknowledged(session)
        case .value:
            return .failure
        }
    }

    /// Passive credential surfaces may only inspect a certified settled intent. Pending and dispatching
    /// entries intentionally hide the selected tuple: they have not completed their synchronous boundary.
    static func permitsPassiveRead(
        account: String,
        sessionID: String? = nil,
        read: (String) -> CredentialDurableReadResult
    ) -> Bool {
        switch state(account: account, read: read) {
        case .missing:
            return true
        case let .acknowledged(acknowledgedSession):
            return sessionID == acknowledgedSession
        case .pending, .dispatching, .failure:
            return false
        }
    }

    /// Heal a fail-after-persist outbox invalidation before any caller interprets or publishes its intent.
    /// Recovery bytes are evidence only: the exact raw marker is rewritten and accepted only after the
    /// certified reader returns the same pending/acknowledged state.
    static func recoverIfUncertain(
        account: String,
        certifiedRead: (String) -> CredentialDurableReadResult,
        recoveryRead: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        switch certifiedRead(account) {
        case .value:
            return true
        case .missing:
            switch state(account: account, read: recoveryRead) {
            case let .pending(session):
                let raw = "pending:" + session
                guard write(raw, account) == .success else { return false }
                return state(account: account, read: certifiedRead) == state(account: account, read: { _ in .value(raw) })
            case let .acknowledged(session):
                let raw = "ack:" + session
                guard write(raw, account) == .success else { return false }
                return state(account: account, read: certifiedRead) == state(account: account, read: { _ in .value(raw) })
            case .dispatching:
                return false
            case .missing:
                return true
            case .failure:
                return false
            }
        case .failure:
            switch state(account: account, read: recoveryRead) {
            case let .pending(session):
                let raw = "pending:" + session
                guard write(raw, account) == .success else { return false }
                return state(account: account, read: certifiedRead) == state(account: account, read: { _ in .value(raw) })
            case let .acknowledged(session):
                let raw = "ack:" + session
                guard write(raw, account) == .success else { return false }
                return state(account: account, read: certifiedRead) == state(account: account, read: { _ in .value(raw) })
            case .dispatching:
                return false
            case .missing:
                guard write(nil, account) == .success else { return false }
                guard case .missing = certifiedRead(account) else { return false }
                return true
            case .failure:
                return false
            }
        }
    }

    static func prepare(
        sessionID: String,
        account: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        let current = state(account: account, read: read)
        switch current {
        case .missing:
            return writeExact("pending:\(sessionID)", account: account, read: read, write: write)
        case let .pending(existing), let .acknowledged(existing):
            return existing == sessionID
        case .dispatching:
            return false
        case .failure:
            return false
        }
    }

    /// Remove a pre-activation intent only when it is still pending for the exact candidate session.
    /// A dispatching or acknowledged value is never erased by transaction rollback: it has crossed the
    /// publication boundary and must be resolved by the durable replay path.
    static func removePending(
        sessionID: String,
        account: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        switch state(account: account, read: read) {
        case .missing:
            return true
        case let .pending(existing) where existing == sessionID:
            return deleteExact(account, read: read, write: write)
        default:
            return false
        }
    }

    static func acknowledge(
        sessionID: String,
        account: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        switch state(account: account, read: read) {
        case let .dispatching(existing) where existing == sessionID:
            return writeExact("ack:\(sessionID)", account: account, read: read, write: write)
        case let .acknowledged(existing) where existing == sessionID:
            return true
        default:
            return false
        }
    }

    static func removeAcknowledged(
        sessionID: String,
        account: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        switch state(account: account, read: read) {
        case .missing:
            return true
        case let .acknowledged(existing) where existing == sessionID:
            return deleteExact(account, read: read, write: write)
        default:
            return false
        }
    }

    private static func writeExact(
        _ value: String,
        account: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        guard write(value, account) == .success else { return false }
        guard case let .value(readBack) = read(account) else { return false }
        return readBack == value
    }

    private static func deleteExact(
        _ account: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        guard write(nil, account) == .success else { return false }
        guard case .missing = read(account) else { return false }
        return true
    }

    /// Called with `coordination.condition` held. Giving the waiter ownership before resuming it removes
    /// the race where a fresh dispatch could enter between the final callback return and boundary work.
    private static func acquireNextBoundaryWaiterLocked() -> CheckedContinuation<BoundaryAcquisition, Never>? {
        guard !coordination.boundaryActive,
              coordination.active.isEmpty,
              coordination.mutations.isEmpty,
              !coordination.boundaryWaiters.isEmpty else { return nil }
        coordination.boundaryActive = true
        coordination.epoch &+= 1
        return coordination.boundaryWaiters.removeFirst()
    }

    private static func callbackLeaseIsActive() -> Bool {
        guard let leaseID = callbackLeaseID else { return false }
        coordination.condition.lock()
        let active = coordination.active[leaseID] != nil
        coordination.condition.unlock()
        return active
    }
}

/// Shared transaction protocol for owner-scoped multi-slot credentials. It is intentionally storage-agnostic:
/// the production Keychain adapter and the standalone hostile harnesses both provide the same result seams.
enum CredentialTupleTransaction {
    private struct MarkerIdentity {
        let account: String
        let rawValue: String
    }

    private enum CleanupPhase {
        case preLegacy(String)
        case preExisting(String)
        case preUnknown(String)
        case post(String)
    }

    private enum PointerOutcome {
        case old
        case candidate
        case unknown
    }

    static func readAuthority(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String? = nil,
        candidateMarker: String? = nil,
        read: (String) -> CredentialDurableReadResult
    ) -> CredentialTupleReadResult {
        readAuthority(
            baseAccounts: baseAccounts,
            activePointer: activePointer,
            cleanupMarker: cleanupMarker,
            candidateMarker: candidateMarker,
            certifiedRead: read
        )
    }

    static func readAuthority(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String? = nil,
        candidateMarker: String? = nil,
        certifiedRead: (String) -> CredentialDurableReadResult
    ) -> CredentialTupleReadResult {
        let read = certifiedRead
        guard !baseAccounts.isEmpty else { return .failure }
        switch read(activePointer) {
        case .failure:
            return .failure
        case let .value(rawPointer):
            guard let pointer = canonicalPointer(rawPointer) else { return .failure }
            var values: [String] = []
            values.reserveCapacity(baseAccounts.count)
            for account in baseAccounts {
                switch read(stageAccount(account, pointer: pointer)) {
                case let .value(value): values.append(value)
                case .missing, .failure: return .failure
                }
            }
            return gateAuthority(
                CredentialTupleAuthority(pointer: pointer, values: values),
                cleanupMarker: cleanupMarker,
                candidateMarker: candidateMarker,
                read: read
            )
        case .missing:
            var values: [String] = []
            values.reserveCapacity(baseAccounts.count)
            var present = false
            var missing = false
            for account in baseAccounts {
                switch read(account) {
                case let .value(value):
                    present = true
                    values.append(value)
                case .missing:
                    missing = true
                    values.append("")
                case .failure:
                    return .failure
                }
            }
            if !present { return .none }
            guard !missing else { return .failure }
            return gateAuthority(
                CredentialTupleAuthority(pointer: nil, values: values),
                cleanupMarker: cleanupMarker,
                candidateMarker: candidateMarker,
                read: read
            )
        }
    }

    static func readStagedAuthority(
        baseAccounts: [String],
        pointer: String,
        certifiedRead: (String) -> CredentialDurableReadResult
    ) -> CredentialTupleReadResult {
        guard !baseAccounts.isEmpty,
              canonicalPointer(pointer) != nil else { return .failure }
        var values: [String] = []
        values.reserveCapacity(baseAccounts.count)
        for account in baseAccounts {
            switch certifiedRead(stageAccount(account, pointer: pointer)) {
            case let .value(value):
                values.append(value)
            case .missing, .failure:
                return .failure
            }
        }
        return .authority(CredentialTupleAuthority(pointer: pointer, values: values))
    }

    private static func gateAuthority(
        _ authority: CredentialTupleAuthority,
        cleanupMarker: String?,
        candidateMarker: String?,
        read: (String) -> CredentialDurableReadResult
    ) -> CredentialTupleReadResult {
        if let candidateMarker {
            switch read(candidateMarker) {
            case .failure:
                return .failure
            case .missing:
                break
            case let .value(raw):
                guard let pointer = markerPointer(raw, prefix: "candidate:") else { return .failure }
                if authority.pointer == nil || authority.pointer == pointer { return .failure }
            }
        }
        if let cleanupMarker {
            switch read(cleanupMarker) {
            case .failure:
                return .failure
            case .missing:
                break
            case let .value(raw):
                guard let phase = cleanupPhase(raw) else { return .failure }
                let pointer: String
                switch phase {
                case let .preLegacy(value), let .preExisting(value), let .preUnknown(value), let .post(value):
                    pointer = value
                }
                if case .preUnknown = phase { return .failure }
                // A nil pointer plus any cleanup identity is an in-flight or ambiguous migration, never a
                // certified legacy mirror. Only the transaction's typed legacy recovery may remove that
                // identity before a nil-pointer read is allowed to reconstruct the base tuple.
                guard authority.pointer != nil else { return .failure }
                // A marker naming the currently selected tuple is a pre-flip/retry marker and does not
                // hide the still-certified old authority. A different selected pointer means B won and
                // old-A cleanup is incomplete, so all outward reads remain gated until retry resolves it.
                if let authorityPointer = authority.pointer, authorityPointer != pointer {
                    return .failure
                }
            }
        }
        return .authority(authority)
    }

    static func transition(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String,
        candidateMarker: String,
        candidateValues: [String],
        publicationMarker: String? = nil,
        publicationValue: String? = nil,
        promoteLegacyMirror: Bool = false,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> CredentialTupleTransitionResult {
        transition(
            baseAccounts: baseAccounts,
            activePointer: activePointer,
            cleanupMarker: cleanupMarker,
            candidateMarker: candidateMarker,
            candidateValues: candidateValues,
            publicationMarker: publicationMarker,
            publicationValue: publicationValue,
            promoteLegacyMirror: promoteLegacyMirror,
            certifiedRead: read,
            recoveryRead: nil,
            write: write
        )
    }

    static func transition(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String,
        candidateMarker: String,
        candidateValues: [String],
        publicationMarker: String? = nil,
        publicationValue: String? = nil,
        promoteLegacyMirror: Bool = false,
        certifiedRead: (String) -> CredentialDurableReadResult,
        recoveryRead: ((String) -> CredentialDurableReadResult)? = nil,
        write: (String?, String) -> CredentialMutationResult
    ) -> CredentialTupleTransitionResult {
        let read = certifiedRead
        guard !baseAccounts.isEmpty, baseAccounts.count == candidateValues.count else {
            return .failedBeforeActivation
        }

        guard (publicationMarker == nil) == (publicationValue == nil) else {
            return .failedBeforeActivation
        }

        func preparePublicationIntent(_ sessionID: String) -> Bool {
            guard let publicationMarker else { return true }
            switch CredentialPublicationOutbox.state(account: publicationMarker, read: read) {
            case .missing:
                return CredentialPublicationOutbox.prepare(
                    sessionID: sessionID,
                    account: publicationMarker,
                    read: read,
                    write: write
                )
            case let .pending(existing), let .acknowledged(existing):
                return existing == sessionID
            case .dispatching, .failure:
                return false
            }
        }

        func hasCertifiedSameSessionProvenance(_ authority: CredentialTupleAuthority) -> Bool {
            guard let sessionID = authority.values.last,
                  !sessionID.isEmpty,
                  case let .value(rawCleanup) = read(cleanupMarker),
                  cleanupPriorSession(rawCleanup) == sessionID else { return false }
            return true
        }

        if let recoveryRead,
           !recoverUncertainStateImpl(
               baseAccounts: baseAccounts,
               activePointer: activePointer,
               cleanupMarker: cleanupMarker,
               candidateMarker: candidateMarker,
               publicationMarker: publicationMarker,
               candidateValues: candidateValues,
               certifiedRead: certifiedRead,
               recoveryRead: recoveryRead,
               write: write
           ) {
            return .activationStateUnknown
        }

        // A typed legacy migration can crash after writing pre:legacy:/candidate: identities but before the
        // active pointer is durable. Resolve only that known shape before reconstructing the old mirror.
        // Existing-authority pre markers, post markers, candidate-only states, and old ambiguous pre markers
        // are unknown with a nil pointer: retain every stage and marker and never certify the base mirror.
        switch read(activePointer) {
        case .failure:
            return .activationStateUnknown
        case let .value(raw):
            guard canonicalPointer(raw) != nil else { return .activationStateUnknown }
        case .missing:
            switch read(cleanupMarker) {
                case .failure:
                    return .activationStateUnknown
            case .missing:
                break
            case let .value(raw):
                guard let phase = cleanupPhase(raw) else { return .activationStateUnknown }
                switch phase {
                case let .preLegacy(pointer):
                    guard cleanupStage(baseAccounts: baseAccounts, pointer: pointer, read: read, write: write),
                          deleteExact(cleanupMarker, read: read, write: write) else {
                        return .failedBeforeActivation
                    }
                case .preExisting, .preUnknown, .post:
                    return .activationStateUnknown
                }
            }
            switch read(candidateMarker) {
            case .failure:
                return .activationStateUnknown
            case .missing:
                break
            case let .value(raw):
                guard let pointer = markerPointer(raw, prefix: "candidate:") else {
                    return .activationStateUnknown
                }
                switch readStagedAuthority(
                    baseAccounts: baseAccounts,
                    pointer: pointer,
                    certifiedRead: read
                ) {
                case let .authority(candidate) where candidate.values == candidateValues:
                    // A recovered nil-active candidate has no selected-session provenance. Its exact
                    // publication intent must therefore be certified before it can become authoritative.
                    if let publicationValue {
                        guard candidate.values.last == publicationValue,
                              preparePublicationIntent(publicationValue) else {
                            return .failedBeforeActivation
                        }
                    }
                    guard writeExact(
                        pointer,
                        account: activePointer,
                        read: read,
                        write: write
                    ) else { return .activationStateUnknown }
                case .authority, .failure, .none:
                    // A candidate that is incomplete or belongs to another caller is not a winner. Its
                    // namespace may be removed only through certified exact deletion; otherwise remain
                    // closed and retryable without selecting raw bytes.
                    guard cleanupCandidate(
                        baseAccounts: baseAccounts,
                        pointer: pointer,
                        candidateMarker: candidateMarker,
                        read: read,
                        write: write
                    ) else { return .failedBeforeActivation }
                }
            }
        }

        let initial: CredentialTupleAuthority?
        switch readAuthority(baseAccounts: baseAccounts, activePointer: activePointer, read: read) {
        case .failure:
            return .failedBeforeActivation
        case .none:
            initial = nil
        case let .authority(authority):
            initial = authority
        }

        var activeCandidateMarker = false
        switch read(candidateMarker) {
        case .failure:
            return .activationStateUnknown
        case .missing:
            break
        case let .value(raw):
            guard let pointer = markerPointer(raw, prefix: "candidate:") else {
                return .activationStateUnknown
            }
            if initial?.pointer == pointer {
                activeCandidateMarker = true
            } else {
                guard cleanupStage(baseAccounts: baseAccounts, pointer: pointer, read: read, write: write),
                      deleteExact(candidateMarker, read: read, write: write) else {
                    return initial.map { .cleanupPending($0) } ?? .failedBeforeActivation
                }
            }
        }
        let recoveredPending: Bool
        switch read(cleanupMarker) {
        case .missing:
            recoveredPending = activeCandidateMarker
        case .value:
            recoveredPending = true
        case .failure:
            if let initial, initial.pointer != nil {
                return .cleanupPending(initial)
            }
            return .failedBeforeActivation
        }

        guard resolvePendingCleanup(
            baseAccounts: baseAccounts,
            activePointer: activePointer,
            cleanupMarker: cleanupMarker,
            current: initial,
            retainProvenance: activeCandidateMarker,
            read: read,
            write: write
        ) else {
            if let initial, initial.pointer != nil { return .cleanupPending(initial) }
            return .failedBeforeActivation
        }

        let current: CredentialTupleAuthority?
        switch readAuthority(baseAccounts: baseAccounts, activePointer: activePointer, read: read) {
        case .failure:
            return .activationStateUnknown
        case .none:
            current = nil
        case let .authority(authority):
            current = authority
        }

        let recoveredActiveCandidateMarker = activeCandidateMarker
        if activeCandidateMarker {
            guard let current,
                  ensureMirror(
                      baseAccounts: baseAccounts,
                      values: current.values,
                      read: read,
                      recoveryRead: recoveryRead,
                      write: write
                  ) else {
                return current.map { .cleanupPending($0) } ?? .activationStateUnknown
            }
            if let publicationMarker {
                if current.values == candidateValues {
                    if let publicationValue {
                        guard current.values.last == publicationValue,
                              preparePublicationIntent(publicationValue) else {
                            return .cleanupPending(current)
                        }
                    }
                } else {
                    // B is still the selected tuple, but the caller is requesting C. Finalize B without
                    // preparing C's publication intent. An acknowledged B intent is safe to remove; a
                    // pending or mismatched intent must be replayed/resolved before C can be staged.
                    switch CredentialPublicationOutbox.state(account: publicationMarker, read: read) {
                    case .missing:
                        // B may lose its candidate identity without a publication record only when the
                        // certified cleanup marker proves it is a same-session refresh. Otherwise C's
                        // staging failure would strand an externally invisible B.
                        guard hasCertifiedSameSessionProvenance(current) else {
                            return .cleanupPending(current)
                        }
                    case let .acknowledged(existing)
                        where current.values.last.map({ $0 == existing }) == true:
                        guard CredentialPublicationOutbox.removeAcknowledged(
                            sessionID: existing,
                            account: publicationMarker,
                            read: read,
                            write: write
                        ) else { return .cleanupPending(current) }
                    case .pending, .dispatching, .acknowledged, .failure:
                        return .cleanupPending(current)
                    }
                }
            }
            guard deleteExact(candidateMarker, read: read, write: write) else {
                return .cleanupPending(current)
            }
            activeCandidateMarker = false
            guard resolvePendingCleanup(
                baseAccounts: baseAccounts,
                activePointer: activePointer,
                cleanupMarker: cleanupMarker,
                current: current,
                retainProvenance: false,
                read: read,
                write: write
            ) else {
                return .cleanupPending(current)
            }
        }

        if let current,
           current.values == candidateValues,
           !promoteLegacyMirror || current.pointer != nil {
            guard ensureMirror(
                baseAccounts: baseAccounts,
                values: candidateValues,
                read: read,
                recoveryRead: recoveryRead,
                write: write
            ) else { return .cleanupPending(current) }
            if recoveredPending && !recoveredActiveCandidateMarker,
               let publicationMarker, let publicationValue {
                guard CredentialPublicationOutbox.prepare(
                    sessionID: publicationValue,
                    account: publicationMarker,
                    read: read,
                    write: write
                ) else { return .cleanupPending(current) }
            }
            return recoveredPending ? .activated(current) : .alreadyActive(current)
        }

        let candidatePointer = UUID().uuidString.lowercased()
        guard writeExact(
            "candidate:\(candidatePointer)",
            account: candidateMarker,
            read: read,
            write: write
        ) else {
            return .failedBeforeActivation
        }
        guard stage(
            baseAccounts: baseAccounts,
            pointer: candidatePointer,
            values: candidateValues,
            read: read,
            write: write
        ) else {
            // Retain the candidate namespace and every sibling slot. A stage write can persist raw bytes
            // while returning failure; deleting the siblings here would destroy the only complete-tuple
            // evidence available to a refresh retry. Recovery will certify an exact raw slot or confirm its
            // absence before the next transition decides whether to clean and re-stage.
            if recoveredActiveCandidateMarker {
                _ = cleanupCandidate(
                    baseAccounts: baseAccounts,
                    pointer: candidatePointer,
                    candidateMarker: candidateMarker,
                    read: read,
                    write: write
                )
            }
            return .failedBeforeActivation
        }

        // The complete candidate tuple is certified before the active pointer can switch. Persist its
        // publication intent at this same pre-flip point so an active-pointer, cleanup, or mirror failure
        // leaves a replayable boundary rather than an active candidate with no publication evidence.
        if let publicationMarker, let publicationValue {
            guard CredentialPublicationOutbox.prepare(
                sessionID: publicationValue,
                account: publicationMarker,
                read: read,
                write: write
            ) else { return current.map { .cleanupPending($0) } ?? .failedBeforeActivation }
        }

        func removePreparedPublication() -> Bool {
            guard let publicationMarker, let publicationValue else { return true }
            return CredentialPublicationOutbox.removePending(
                sessionID: publicationValue,
                account: publicationMarker,
                read: read,
                write: write
            )
        }

        var oldPointer = current?.pointer
        if let current, current.pointer == nil {
            let oldStagePointer = UUID().uuidString.lowercased()
            guard writeExact(
                cleanupMarkerValue(
                    prefix: "pre:legacy",
                    pointer: oldStagePointer,
                    session: current.values.last
                ),
                account: cleanupMarker,
                read: read,
                write: write
            ) else {
                guard removePreparedPublication() else {
                    return .cleanupPending(current)
                }
                guard cleanupCandidate(
                    baseAccounts: baseAccounts,
                    pointer: candidatePointer,
                    candidateMarker: candidateMarker,
                    read: read,
                    write: write
                ) else { return .cleanupPending(current) }
                return .failedBeforeActivation
            }
            guard stage(
                baseAccounts: baseAccounts,
                pointer: oldStagePointer,
                values: current.values,
                read: read,
                write: write
            ) else {
                guard removePreparedPublication() else {
                    return .cleanupPending(current)
                }
                guard cleanupCandidate(
                    baseAccounts: baseAccounts,
                    pointer: candidatePointer,
                    candidateMarker: candidateMarker,
                    read: read,
                    write: write
                ) else { return .cleanupPending(current) }
                _ = cleanupStage(baseAccounts: baseAccounts, pointer: oldStagePointer, read: read, write: write)
                return .failedBeforeActivation
            }
            if !writeExact(
                oldStagePointer,
                account: activePointer,
                read: read,
                write: write
            ) {
                switch classifyPointerFailure(
                    expectedOld: current,
                    expectedOldPointer: oldStagePointer,
                    candidatePointer: candidatePointer,
                    candidateValues: candidateValues,
                    baseAccounts: baseAccounts,
                    activePointer: activePointer,
                    cleanupMarker: cleanupMarker,
                    candidateMarker: candidateMarker,
                    read: read
                ) {
                case .candidate:
                    break
                case .old:
                    guard removePreparedPublication() else {
                        return .cleanupPending(current)
                    }
                    guard cleanupCandidate(
                        baseAccounts: baseAccounts,
                        pointer: candidatePointer,
                        candidateMarker: candidateMarker,
                        read: read,
                        write: write
                    ) else { return .cleanupPending(current) }
                    return .failedBeforeActivation
                case .unknown:
                    return .activationStateUnknown
                }
            }
            oldPointer = oldStagePointer
        }

        if let oldPointer, current?.pointer != nil {
            guard writeExact(
                cleanupMarkerValue(
                    prefix: "pre:existing",
                    pointer: oldPointer,
                    session: current?.values.last
                ),
                account: cleanupMarker,
                read: read,
                write: write
            ) else {
                guard removePreparedPublication() else {
                    return current.map { .cleanupPending($0) } ?? .failedBeforeActivation
                }
                guard cleanupCandidate(
                    baseAccounts: baseAccounts,
                    pointer: candidatePointer,
                    candidateMarker: candidateMarker,
                    read: read,
                    write: write
                ) else {
                    return current.map { .cleanupPending($0) } ?? .failedBeforeActivation
                }
                return current.map { .cleanupPending($0) } ?? .failedBeforeActivation
            }
        }

        // A direct-slot mirror can be stale or partially present. Remove it while the certified old pointer
        // still selects A; a failed delete therefore cannot strand a mixed tuple or demote the old authority.
        guard removeBaseMirror(baseAccounts: baseAccounts, read: read, write: write) else {
            if let current {
                restoreMirror(
                    baseAccounts: baseAccounts,
                    values: current.values,
                    read: read,
                    write: write
                )
            }
            guard removePreparedPublication() else {
                return oldPointer.map { .cleanupPending(CredentialTupleAuthority(pointer: $0, values: current?.values ?? [])) }
                    ?? .failedBeforeActivation
            }
            guard cleanupCandidate(
                baseAccounts: baseAccounts,
                pointer: candidatePointer,
                candidateMarker: candidateMarker,
                read: read,
                write: write
            ) else {
                return oldPointer.map { .cleanupPending(CredentialTupleAuthority(pointer: $0, values: current?.values ?? [])) }
                    ?? .failedBeforeActivation
            }
            return oldPointer.map { .cleanupPending(CredentialTupleAuthority(pointer: $0, values: current?.values ?? [])) }
                ?? .failedBeforeActivation
        }

        var activePointerWon = true
        if !writeExact(
            candidatePointer,
            account: activePointer,
            read: read,
            write: write
        ) {
            switch classifyPointerFailure(
                expectedOld: current,
                expectedOldPointer: oldPointer,
                candidatePointer: candidatePointer,
                candidateValues: candidateValues,
                baseAccounts: baseAccounts,
                activePointer: activePointer,
                cleanupMarker: cleanupMarker,
                candidateMarker: candidateMarker,
                read: read
            ) {
            case .candidate:
                activePointerWon = true
            case .old:
                guard removePreparedPublication() else {
                    return failureResult(for: current)
                }
                let candidateClean = cleanupCandidate(
                    baseAccounts: baseAccounts,
                    pointer: candidatePointer,
                    candidateMarker: candidateMarker,
                    read: read,
                    write: write
                )
                _ = deleteExact(cleanupMarker, read: read, write: write)
                return candidateClean ? .failedBeforeActivation : failureResult(for: current)
            case .unknown:
                return .activationStateUnknown
            }
        }

        guard activePointerWon else { return .activationStateUnknown }
        let active = CredentialTupleAuthority(pointer: candidatePointer, values: candidateValues)
        if let oldPointer {
            guard writeExact(
                cleanupMarkerValue(
                    prefix: "post",
                    pointer: oldPointer,
                    session: current?.values.last
                ),
                account: cleanupMarker,
                read: read,
                write: write
            ) else { return .cleanupPending(active) }
            guard cleanupStage(baseAccounts: baseAccounts, pointer: oldPointer, read: read, write: write) else {
                return .cleanupPending(active)
            }
        }

        guard ensureMirror(
            baseAccounts: baseAccounts,
            values: candidateValues,
            read: read,
            recoveryRead: recoveryRead,
            write: write
        ) else { return .cleanupPending(active) }
        // Keep the cleanup marker, including its prior-session provenance, until the active candidate
        // marker is certified absent. A fail-after-persist candidate delete can otherwise leave a rotated
        // same-session tuple with neither identity available for the next recovery pass.
        guard deleteExact(candidateMarker, read: read, write: write) else {
            return .cleanupPending(active)
        }
        if oldPointer != nil {
            guard deleteExact(cleanupMarker, read: read, write: write) else {
                return .cleanupPending(active)
            }
        }
        return .activated(active)
    }

    /// Delete one owner-scoped credential tuple after a durable sign-out read has identified every staged
    /// pointer. Marker identities are retained until their exact stages are confirmed absent, and the
    /// caller publishes the nil boundary only after this function returns true.
    static func clear(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String,
        candidateMarker: String,
        extraAccounts: [String] = [],
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        clear(
            baseAccounts: baseAccounts,
            activePointer: activePointer,
            cleanupMarker: cleanupMarker,
            candidateMarker: candidateMarker,
            extraAccounts: extraAccounts,
            certifiedRead: read,
            recoveryRead: nil,
            write: write
        )
    }

    static func clear(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String,
        candidateMarker: String,
        extraAccounts: [String] = [],
        certifiedRead: (String) -> CredentialDurableReadResult,
        recoveryRead: ((String) -> CredentialDurableReadResult)? = nil,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        let read = certifiedRead
        guard !baseAccounts.isEmpty else { return false }

        if let recoveryRead,
           !recoverUncertainClearState(
               baseAccounts: baseAccounts,
               activePointer: activePointer,
               cleanupMarker: cleanupMarker,
               candidateMarker: candidateMarker,
               extraAccounts: extraAccounts,
               certifiedRead: certifiedRead,
               recoveryRead: recoveryRead,
               write: write
           ) {
            return false
        }

        var pointers = Set<String>()
        var markerIdentities: [MarkerIdentity] = []
        switch read(activePointer) {
        case .missing:
            break
        case .failure:
            return false
        case let .value(raw):
            guard let pointer = canonicalPointer(raw) else { return false }
            pointers.insert(pointer)
            markerIdentities.append(MarkerIdentity(account: activePointer, rawValue: raw))
        }

        switch read(candidateMarker) {
        case .missing:
            break
        case .failure:
            return false
        case let .value(raw):
            guard let pointer = markerPointer(raw, prefix: "candidate:") else { return false }
            pointers.insert(pointer)
            markerIdentities.append(MarkerIdentity(account: candidateMarker, rawValue: raw))
        }

        switch read(cleanupMarker) {
        case .missing:
            break
        case .failure:
            return false
        case let .value(raw):
            guard let phase = cleanupPhase(raw) else { return false }
            switch phase {
            case let .preLegacy(pointer), let .preExisting(pointer), let .post(pointer):
                pointers.insert(pointer)
                markerIdentities.append(MarkerIdentity(account: cleanupMarker, rawValue: raw))
            case .preUnknown:
                return false
            }
        }

        for pointer in pointers.sorted() {
            guard cleanupStage(baseAccounts: baseAccounts, pointer: pointer, read: read, write: write) else {
                return false
            }
        }

        var accounts: [String] = []
        var seen = Set<String>()
        for account in baseAccounts + extraAccounts where seen.insert(account).inserted {
            accounts.append(account)
        }
        for account in accounts {
            guard deleteExact(account, read: read, write: write) else { return false }
        }

        for identity in [candidateMarker, cleanupMarker, activePointer] {
            guard deleteExact(identity, read: read, write: write) else {
                if let marker = markerIdentities.first(where: { $0.account == identity }) {
                    _ = retainMarkerIdentity(marker, read: read, write: write)
                }
                return false
            }
        }

        for pointer in pointers {
            for account in baseAccounts {
                guard case .missing = read(stageAccount(account, pointer: pointer)) else { return false }
            }
        }
        for account in accounts + [candidateMarker, cleanupMarker, activePointer] {
            guard case .missing = read(account) else { return false }
        }
        return true
    }

    private static func recoverUncertainClearState(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String,
        candidateMarker: String,
        extraAccounts: [String],
        certifiedRead: (String) -> CredentialDurableReadResult,
        recoveryRead: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        var pointers = Set<String>()
        var uncertainMarkers: [MarkerIdentity] = []
        let markerAccounts = [candidateMarker, cleanupMarker, activePointer]

        func pointer(for account: String, raw: String) -> String? {
            if account == activePointer { return canonicalPointer(raw) }
            if account == candidateMarker { return markerPointer(raw, prefix: "candidate:") }
            guard account == cleanupMarker, let phase = cleanupPhase(raw) else { return nil }
            switch phase {
            case let .preLegacy(value), let .preExisting(value), let .post(value):
                return value
            case .preUnknown:
                return nil
            }
        }

        for account in markerAccounts {
            switch certifiedRead(account) {
            case let .value(raw):
                guard let pointer = pointer(for: account, raw: raw) else { return false }
                pointers.insert(pointer)
            case .missing:
                switch recoveryRead(account) {
                case let .value(raw):
                    guard let pointer = pointer(for: account, raw: raw) else { return false }
                    pointers.insert(pointer)
                    uncertainMarkers.append(MarkerIdentity(account: account, rawValue: raw))
                case .missing:
                    break
                case .failure:
                    return false
                }
            case .failure:
                switch recoveryRead(account) {
                case let .value(raw):
                    guard let pointer = pointer(for: account, raw: raw) else { return false }
                    pointers.insert(pointer)
                    uncertainMarkers.append(MarkerIdentity(account: account, rawValue: raw))
                case .missing:
                    guard retryDeleteAndConfirm(account: account, certifiedRead: certifiedRead, write: write) else {
                        return false
                    }
                case .failure:
                    return false
                }
            }
        }

        for pointer in pointers.sorted() {
            for account in baseAccounts {
                let stageAccount = stageAccount(account, pointer: pointer)
                switch certifiedRead(stageAccount) {
                case .value:
                    break
                case .missing:
                    switch recoveryRead(stageAccount) {
                    case let .value(raw) where !raw.isEmpty:
                        guard certifyRecoveredValue(raw, account: stageAccount, certifiedRead: certifiedRead, write: write) else {
                            return false
                        }
                    case .missing:
                        break
                    case .failure, .value:
                        return false
                    }
                case .failure:
                    switch recoveryRead(stageAccount) {
                    case let .value(raw) where !raw.isEmpty:
                        guard certifyRecoveredValue(raw, account: stageAccount, certifiedRead: certifiedRead, write: write) else {
                            return false
                        }
                    case .missing:
                        guard retryDeleteAndConfirm(account: stageAccount, certifiedRead: certifiedRead, write: write) else {
                            return false
                        }
                    case .failure, .value:
                        return false
                    }
                }
            }
            if let manifest = stageManifestAccount(baseAccounts: baseAccounts, pointer: pointer) {
                switch certifiedRead(manifest) {
                case .value:
                    break
                case .missing:
                    switch recoveryRead(manifest) {
                    case .value:
                        guard retryDeleteAndConfirm(account: manifest, certifiedRead: certifiedRead, write: write) else {
                            return false
                        }
                    case .missing:
                        break
                    case .failure:
                        return false
                    }
                case .failure:
                    switch recoveryRead(manifest) {
                    case .value, .missing:
                        guard retryDeleteAndConfirm(account: manifest, certifiedRead: certifiedRead, write: write) else {
                            return false
                        }
                    case .failure:
                        return false
                    }
                }
            }
        }

        for account in [candidateMarker, cleanupMarker, activePointer] {
            guard let identity = uncertainMarkers.first(where: { $0.account == account }) else { continue }
            guard certifyRecoveredValue(
                identity.rawValue,
                account: identity.account,
                certifiedRead: certifiedRead,
                write: write
            ) else { return false }
        }

        // Clear does not need to certify a mirror or outbox value: it must remove it. If certification is
        // uncertain, use raw only to distinguish a stale byte from confirmed absence, then delete and certify
        // the absence before the normal exact cleanup proceeds.
        for account in baseAccounts + extraAccounts {
            switch certifiedRead(account) {
            case .value:
                break
            case .missing, .failure:
                switch recoveryRead(account) {
                case .value, .missing:
                    guard retryDeleteAndConfirm(account: account, certifiedRead: certifiedRead, write: write) else {
                        return false
                    }
                case .failure:
                    return false
                }
            }
        }
        return true
    }

    /// Run the bounded dual-read recovery pass before a production entry point interprets a certified
    /// pointer or publication failure. Recovery bytes can repair persisted evidence, but the caller must
    /// perform a fresh certified authority read before selecting or publishing a tuple.
    static func recoverUncertainState(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String,
        candidateMarker: String,
        publicationMarker: String? = nil,
        certifiedRead: (String) -> CredentialDurableReadResult,
        recoveryRead: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        recoverUncertainStateImpl(
            baseAccounts: baseAccounts,
            activePointer: activePointer,
            cleanupMarker: cleanupMarker,
            candidateMarker: candidateMarker,
            publicationMarker: publicationMarker,
            candidateValues: [],
            certifiedRead: certifiedRead,
            recoveryRead: recoveryRead,
            write: write
        )
    }

    /// Recover only identities whose certified read is uncertain. Raw bytes are evidence for discovering the
    /// exact marker/stage account, never authority: every recovered value is rewritten and accepted only after
    /// a certified read-back succeeds. This lets a failed-after-persist Keychain mutation heal on retry without
    /// allowing the raw backend to publish a pointer or outbox value directly.
    private static func recoverUncertainStateImpl(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String,
        candidateMarker: String,
        publicationMarker: String?,
        candidateValues: [String],
        certifiedRead: (String) -> CredentialDurableReadResult,
        recoveryRead: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        var pointers = Set<String>()
        var uncertainMarkers: [MarkerIdentity] = []
        var stageRecoveryNeeded = false
        var candidatePointer: String?
        var certifiedActivePointer: String?
        let markerAccounts = [candidateMarker, cleanupMarker, activePointer]

        func pointer(for account: String, raw: String) -> String? {
            if account == activePointer { return canonicalPointer(raw) }
            if account == candidateMarker { return markerPointer(raw, prefix: "candidate:") }
            guard account == cleanupMarker, let phase = cleanupPhase(raw) else { return nil }
            switch phase {
            case let .preLegacy(value), let .preExisting(value), let .post(value):
                return value
            case .preUnknown:
                return nil
            }
        }

        for account in markerAccounts {
            switch certifiedRead(account) {
            case let .value(raw):
                guard let pointer = pointer(for: account, raw: raw) else { return false }
                pointers.insert(pointer)
                if account == candidateMarker {
                    candidatePointer = pointer
                    // A certified candidate identifies an in-flight tuple whose complete stage set must be
                    // inspected, even though the marker itself is healthy.
                    stageRecoveryNeeded = true
                } else if account == activePointer {
                    certifiedActivePointer = pointer
                }
            case .missing:
                switch recoveryRead(account) {
                case let .value(raw):
                    guard let pointer = pointer(for: account, raw: raw) else { return false }
                    pointers.insert(pointer)
                    stageRecoveryNeeded = true
                    if account == candidateMarker {
                        candidatePointer = pointer
                    } else if account == activePointer {
                        certifiedActivePointer = pointer
                    }
                    uncertainMarkers.append(MarkerIdentity(account: account, rawValue: raw))
                case .missing:
                    break
                case .failure:
                    return false
                }
            case .failure:
                switch recoveryRead(account) {
                case let .value(raw):
                    guard let pointer = pointer(for: account, raw: raw) else { return false }
                    pointers.insert(pointer)
                    stageRecoveryNeeded = true
                    if account == candidateMarker {
                        candidatePointer = pointer
                    } else if account == activePointer {
                        certifiedActivePointer = pointer
                    }
                    uncertainMarkers.append(MarkerIdentity(account: account, rawValue: raw))
                case .missing:
                    guard retryDeleteAndConfirm(account: account, certifiedRead: certifiedRead, write: write) else {
                        return false
                    }
                case .failure:
                    return false
                }
            }
        }

        if let publicationMarker {
            switch certifiedRead(publicationMarker) {
            case let .value(raw):
                guard validPublicationRaw(raw) else { return false }
            case .missing:
                switch recoveryRead(publicationMarker) {
                case let .value(raw):
                    guard validPublicationRaw(raw) else { return false }
                    uncertainMarkers.append(MarkerIdentity(account: publicationMarker, rawValue: raw))
                case .missing:
                    break
                case .failure:
                    return false
                }
            case .failure:
                switch recoveryRead(publicationMarker) {
                case let .value(raw):
                    guard validPublicationRaw(raw) else { return false }
                    uncertainMarkers.append(MarkerIdentity(account: publicationMarker, rawValue: raw))
                case .missing:
                    guard retryDeleteAndConfirm(account: publicationMarker, certifiedRead: certifiedRead, write: write) else {
                        return false
                    }
                case .failure:
                    return false
                }
            }
        }

        // Repair stages before an uncertain marker's identity. Raw stage bytes are recoverable only when an
        // independently certified manifest, or the exact unselected candidate supplied by this transition,
        // binds every value in the tuple. Treating raw values as their own proof would let a corrupted
        // same-session candidate become authority during provider preflight, where candidateValues is empty.
        if stageRecoveryNeeded {
            for pointer in pointers.sorted() {
                let observations = baseAccounts.map { account -> (
                    account: String,
                    certified: CredentialDurableReadResult,
                    recovery: CredentialDurableReadResult?
                ) in
                    let account = stageAccount(account, pointer: pointer)
                    let certified = certifiedRead(account)
                    switch certified {
                    case .value:
                        return (account, certified, nil)
                    case .missing, .failure:
                        return (account, certified, recoveryRead(account))
                    }
                }
                let hasRawStageEvidence = observations.contains { observation in
                    guard case let .value(raw)? = observation.recovery else { return false }
                    return !raw.isEmpty
                }
                let exactCandidateValues: [String]? = pointer == candidatePointer
                    && pointer != certifiedActivePointer
                    && candidateValues.count == baseAccounts.count
                    ? candidateValues
                    : nil
                let expectedValues: [String]?
                if hasRawStageEvidence {
                    let resolved = recoverStageManifest(
                        baseAccounts: baseAccounts,
                        pointer: pointer,
                        exactCandidateValues: exactCandidateValues,
                        certifiedRead: certifiedRead,
                        recoveryRead: recoveryRead,
                        write: write
                    )
                    guard resolved.valid, let values = resolved.values else { return false }
                    expectedValues = values
                } else {
                    expectedValues = nil
                }

                for (index, observation) in observations.enumerated() {
                    let expectedValue = expectedValues?[index]
                    switch observation.certified {
                    case let .value(existing):
                        if let expectedValue {
                            guard existing == expectedValue else { return false }
                        }
                    case .missing:
                        switch observation.recovery {
                        case let .value(raw) where !raw.isEmpty:
                            guard let expectedValue, raw == expectedValue else { return false }
                            guard certifyRecoveredValue(
                                raw,
                                account: observation.account,
                                certifiedRead: certifiedRead,
                                write: write
                            ) else { return false }
                        case .missing?:
                            break
                        case .failure?, .value?, nil:
                            return false
                        }
                    case .failure:
                        switch observation.recovery {
                        case let .value(raw) where !raw.isEmpty:
                            guard let expectedValue, raw == expectedValue else { return false }
                            guard certifyRecoveredValue(
                                raw,
                                account: observation.account,
                                certifiedRead: certifiedRead,
                                write: write
                            ) else { return false }
                        case .missing?:
                            guard retryDeleteAndConfirm(
                                account: observation.account,
                                certifiedRead: certifiedRead,
                                write: write
                            ) else {
                                return false
                            }
                        case .failure?, .value?, nil:
                            return false
                        }
                    }
                }
            }
        }

        // Repair marker identities after their evidence stages, and the active pointer last. The certified
        // transaction below is then the only code path allowed to select/publish the repaired tuple.
        for account in [candidateMarker, cleanupMarker, activePointer, publicationMarker].compactMap({ $0 }) {
            guard let identity = uncertainMarkers.first(where: { $0.account == account }) else { continue }
            guard certifyRecoveredValue(
                identity.rawValue,
                account: identity.account,
                certifiedRead: certifiedRead,
                write: write
            ) else { return false }
        }
        return true
    }

    private static func validPublicationRaw(_ raw: String) -> Bool {
        switch CredentialPublicationOutbox.state(account: "recovery", read: { _ in .value(raw) }) {
        case .pending, .acknowledged:
            return true
        case .missing, .dispatching, .failure:
            return false
        }
    }

    private static func retryDeleteAndConfirm(
        account: String,
        certifiedRead: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        guard write(nil, account) == .success else { return false }
        guard case .missing = certifiedRead(account) else { return false }
        return true
    }

    private static func certifyRecoveredValue(
        _ rawValue: String,
        account: String,
        certifiedRead: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        guard write(rawValue, account) == .success else { return false }
        guard case let .value(readBack) = certifiedRead(account) else { return false }
        return readBack == rawValue
    }

    /// Resolve the independently certified identity for one staged tuple. Raw manifest bytes are never
    /// self-authenticating: only an exact caller-supplied, unselected candidate may certify or create one.
    /// A selected candidate can therefore recover raw stages only from a manifest that was already certified
    /// before its first stage write.
    private static func recoverStageManifest(
        baseAccounts: [String],
        pointer: String,
        exactCandidateValues: [String]?,
        certifiedRead: (String) -> CredentialDurableReadResult,
        recoveryRead: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> (valid: Bool, values: [String]?) {
        guard let account = stageManifestAccount(baseAccounts: baseAccounts, pointer: pointer) else {
            return (false, nil)
        }
        let exactRaw = exactCandidateValues.flatMap(stageManifestRaw)
        func acceptCertified(_ raw: String) -> (Bool, [String]?) {
            guard let values = stageManifestValues(raw, expectedCount: baseAccounts.count) else {
                return (false, nil)
            }
            if let exactCandidateValues, values != exactCandidateValues { return (false, nil) }
            return (true, values)
        }

        switch certifiedRead(account) {
        case let .value(raw):
            return acceptCertified(raw)
        case .missing:
            switch recoveryRead(account) {
            case let .value(raw):
                guard let exactRaw, raw == exactRaw,
                      certifyRecoveredValue(raw, account: account, certifiedRead: certifiedRead, write: write) else {
                    return (false, nil)
                }
                return (true, exactCandidateValues)
            case .missing:
                guard let exactRaw,
                      writeExact(exactRaw, account: account, read: certifiedRead, write: write) else {
                    return (false, nil)
                }
                return (true, exactCandidateValues)
            case .failure:
                return (false, nil)
            }
        case .failure:
            switch recoveryRead(account) {
            case let .value(raw):
                guard let exactRaw, raw == exactRaw,
                      certifyRecoveredValue(raw, account: account, certifiedRead: certifiedRead, write: write) else {
                    return (false, nil)
                }
                return (true, exactCandidateValues)
            case .missing:
                guard retryDeleteAndConfirm(account: account, certifiedRead: certifiedRead, write: write),
                      let exactRaw,
                      writeExact(exactRaw, account: account, read: certifiedRead, write: write) else {
                    return (false, nil)
                }
                return (true, exactCandidateValues)
            case .failure:
                return (false, nil)
            }
        }
    }

    private static func stage(
        baseAccounts: [String],
        pointer: String,
        values: [String],
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        guard let manifestAccount = stageManifestAccount(baseAccounts: baseAccounts, pointer: pointer),
              let manifest = stageManifestRaw(values),
              writeExact(manifest, account: manifestAccount, read: read, write: write) else {
            return false
        }
        var complete = true
        for (account, value) in zip(baseAccounts, values) {
            if !writeExact(value, account: stageAccount(account, pointer: pointer), read: read, write: write) {
                complete = false
            }
        }
        return complete
    }

    private static func ensureMirror(
        baseAccounts: [String],
        values: [String],
        read: (String) -> CredentialDurableReadResult,
        recoveryRead: ((String) -> CredentialDurableReadResult)? = nil,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        for (account, value) in zip(baseAccounts, values) {
            switch read(account) {
            case let .value(existing) where existing == value:
                continue
            case .value:
                guard writeExact(value, account: account, read: read, write: write) else { return false }
            case .missing:
                guard let recoveryRead else {
                    guard writeExact(value, account: account, read: read, write: write) else { return false }
                    continue
                }
                switch recoveryRead(account) {
                case let .value(raw) where raw == value:
                    guard certifyRecoveredValue(raw, account: account, certifiedRead: read, write: write) else {
                        return false
                    }
                case .missing:
                    guard writeExact(value, account: account, read: read, write: write) else { return false }
                case .failure, .value:
                    return false
                }
            case .failure:
                guard let recoveryRead else { return false }
                switch recoveryRead(account) {
                case let .value(raw) where raw == value:
                    guard certifyRecoveredValue(raw, account: account, certifiedRead: read, write: write) else {
                        return false
                    }
                case .missing:
                    guard retryDeleteAndConfirm(account: account, certifiedRead: read, write: write),
                          writeExact(value, account: account, read: read, write: write) else {
                        return false
                    }
                case .failure, .value:
                    return false
                }
            }
        }
        return true
    }

    private static func restoreMirror(
        baseAccounts: [String],
        values: [String],
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) {
        for (account, value) in zip(baseAccounts, values) {
            _ = writeExact(value, account: account, read: read, write: write)
        }
    }

    private static func classifyPointerFailure(
        expectedOld: CredentialTupleAuthority?,
        expectedOldPointer: String?,
        candidatePointer: String,
        candidateValues: [String],
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String,
        candidateMarker: String,
        read: (String) -> CredentialDurableReadResult
    ) -> PointerOutcome {
        if case let .value(raw) = read(activePointer),
           let pointer = canonicalPointer(raw),
           pointer == candidatePointer {
            var values: [String] = []
            values.reserveCapacity(baseAccounts.count)
            for account in baseAccounts {
                guard case let .value(value) = read(stageAccount(account, pointer: pointer)) else {
                    return .unknown
                }
                values.append(value)
            }
            return values == candidateValues ? .candidate : .unknown
        }
        switch readAuthority(
            baseAccounts: baseAccounts,
            activePointer: activePointer,
            cleanupMarker: cleanupMarker,
            candidateMarker: candidateMarker,
            read: read
        ) {
        case let .authority(authority):
            if authority.pointer == candidatePointer,
               authority.values == candidateValues {
                return .candidate
            }
            if let expectedOld,
               authority.values == expectedOld.values,
               (authority.pointer == expectedOld.pointer
                    || authority.pointer == expectedOldPointer
                    || authority.pointer == nil) {
                return .old
            }
            return .unknown
        case .none:
            return expectedOld == nil && expectedOldPointer == nil ? .old : .unknown
        case .failure:
            return .unknown
        }
    }

    private static func removeBaseMirror(
        baseAccounts: [String],
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        for account in baseAccounts {
            switch read(account) {
            case .missing:
                continue
            case .failure:
                return false
            case .value:
                guard deleteExact(account, read: read, write: write) else { return false }
            }
        }
        return true
    }

    private static func resolvePendingCleanup(
        baseAccounts: [String],
        activePointer: String,
        cleanupMarker: String,
        current: CredentialTupleAuthority?,
        retainProvenance: Bool = false,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        let pending: CleanupPhase?
        let pendingRaw: String?
        switch read(cleanupMarker) {
        case .missing:
            pending = nil
            pendingRaw = nil
        case .failure:
            return false
        case let .value(raw):
            pendingRaw = raw
            guard let phase = cleanupPhase(raw) else { return false }
            pending = phase
        }

        guard let pending else { return true }
        switch pending {
        case let .preLegacy(pointer), let .preExisting(pointer):
            if current?.pointer == pointer {
                return retainProvenance || deleteExact(cleanupMarker, read: read, write: write)
            }
            if current?.pointer == nil {
                guard case .preLegacy = pending else { return false }
                guard cleanupStage(baseAccounts: baseAccounts, pointer: pointer, read: read, write: write) else {
                    return false
                }
                guard retainProvenance || deleteExact(cleanupMarker, read: read, write: write) else {
                    return false
                }
                return true
            }
            guard writeExact(
                cleanupMarkerValue(
                    prefix: "post",
                    pointer: pointer,
                    session: pendingRaw.flatMap(cleanupPriorSession)
                ),
                account: cleanupMarker,
                read: read,
                write: write
            ),
                  cleanupStage(baseAccounts: baseAccounts, pointer: pointer, read: read, write: write) else {
                return false
            }
            guard retainProvenance || deleteExact(cleanupMarker, read: read, write: write) else {
                return false
            }
            return true
        case .preUnknown:
            return false
        case let .post(pointer):
            // Never delete the tuple currently selected by the active pointer. A pre-marker is allowed to
            // survive a crash between the pointer write and its phase update; the current pointer decides.
            guard current?.pointer != pointer else {
                return retainProvenance || deleteExact(cleanupMarker, read: read, write: write)
            }
            guard cleanupStage(baseAccounts: baseAccounts, pointer: pointer, read: read, write: write) else {
                return false
            }
            guard retainProvenance || deleteExact(cleanupMarker, read: read, write: write) else {
                return false
            }
            return true
        }
    }

    private static func writeExact(
        _ value: String,
        account: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        guard write(value, account) == .success else { return false }
        if case let .value(readBack) = read(account) { return readBack == value }
        return false
    }

    private static func deleteExact(
        _ account: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        guard write(nil, account) == .success else { return false }
        if case .missing = read(account) { return true }
        return false
    }

    private static func retainMarkerIdentity(
        _ identity: MarkerIdentity,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        switch read(identity.account) {
        case let .value(existing) where existing == identity.rawValue:
            return true
        case .value:
            return false
        case .missing, .failure:
            guard write(identity.rawValue, identity.account) == .success else { return false }
            guard case let .value(restored) = read(identity.account) else { return false }
            return restored == identity.rawValue
        }
    }

    private static func cleanupStage(
        baseAccounts: [String],
        pointer: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        var safe = true
        for account in baseAccounts {
            let stage = stageAccount(account, pointer: pointer)
            switch read(stage) {
            case .missing:
                continue
            case .failure:
                safe = false
            case .value:
                if !deleteExact(stage, read: read, write: write) { safe = false }
            }
        }
        if let manifest = stageManifestAccount(baseAccounts: baseAccounts, pointer: pointer) {
            switch read(manifest) {
            case .missing:
                break
            case .failure:
                // The manifest is proof metadata, never tuple authority. Once every sibling stage has
                // been deleted or confirmed absent, an unselected manifest may be deleted directly and
                // certified absent; its raw bytes must not be rewritten as evidence for a new tuple.
                if !deleteExact(manifest, read: read, write: write) { safe = false }
            case .value:
                if !deleteExact(manifest, read: read, write: write) { safe = false }
            }
        }
        return safe
    }

    private static func cleanupCandidate(
        baseAccounts: [String],
        pointer: String,
        candidateMarker: String,
        read: (String) -> CredentialDurableReadResult,
        write: (String?, String) -> CredentialMutationResult
    ) -> Bool {
        guard cleanupStage(baseAccounts: baseAccounts, pointer: pointer, read: read, write: write) else {
            return false
        }
        return deleteExact(candidateMarker, read: read, write: write)
    }

    private static func failureResult(for current: CredentialTupleAuthority?) -> CredentialTupleTransitionResult {
        guard let current, current.pointer != nil else { return .failedBeforeActivation }
        return .cleanupPending(current)
    }

    private static func stageAccount(_ account: String, pointer: String) -> String {
        account + ".stage." + pointer
    }

    private static func stageManifestAccount(baseAccounts: [String], pointer: String) -> String? {
        guard let first = baseAccounts.first else { return nil }
        return first + ".manifest." + pointer
    }

    private static func stageManifestRaw(_ values: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(values) else { return nil }
        return "v1:" + String(decoding: data, as: UTF8.self)
    }

    private static func stageManifestValues(_ raw: String, expectedCount: Int) -> [String]? {
        guard raw.hasPrefix("v1:"),
              let data = String(raw.dropFirst("v1:".count)).data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data),
              values.count == expectedCount else { return nil }
        return values
    }

    /// Transaction identities are generated from UUIDs and are persisted as canonical lowercase text.
    /// Rejecting every other spelling prevents a corrupt pointer from addressing an arbitrary account
    /// suffix and turning an untrusted staged value into authority.
    static func canonicalPointer(_ raw: String) -> String? {
        guard let uuid = UUID(uuidString: raw),
              raw == uuid.uuidString.lowercased() else { return nil }
        return raw
    }

    private static func cleanupMarkerValue(
        prefix: String,
        pointer: String,
        session: String?
    ) -> String {
        guard let session, !session.isEmpty else { return "\(prefix):\(pointer)" }
        return "\(prefix):\(pointer):\(session)"
    }

    /// The prior session is advisory recovery evidence only. It is written as part of the cleanup marker
    /// before a pointer flip and is accepted only to distinguish a same-session refresh from a new-session
    /// adoption; staged tuple reads and the certified active pointer remain the sole authority.
    static func cleanupPriorSession(_ raw: String) -> String? {
        let prefixes = ["pre:legacy:", "pre:existing:", "post:"]
        guard let prefix = prefixes.first(where: { raw.hasPrefix($0) }) else { return nil }
        let remainder = String(raw.dropFirst(prefix.count))
        let parts = remainder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              canonicalPointer(String(parts[0])) != nil,
              !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    private static func cleanupPhase(_ raw: String) -> CleanupPhase? {
        if let pointer = cleanupPointer(raw, prefix: "pre:legacy:") {
            return .preLegacy(pointer)
        }
        if let pointer = cleanupPointer(raw, prefix: "pre:existing:") {
            return .preExisting(pointer)
        }
        if let pointer = cleanupPointer(raw, prefix: "post:") {
            return .post(pointer)
        }
        // Preserve the identity of an older ambiguous pre marker so every reader can fail closed without
        // guessing whether its stage belongs to a legacy mirror or an already-authoritative pointer.
        if let pointer = cleanupPointer(raw, prefix: "pre:") {
            return .preUnknown(pointer)
        }
        return nil
    }

    private static func cleanupPointer(_ raw: String, prefix: String) -> String? {
        guard raw.hasPrefix(prefix) else { return nil }
        let remainder = String(raw.dropFirst(prefix.count))
        let pointer = remainder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let pointer else { return nil }
        return canonicalPointer(String(pointer))
    }

    private static func markerPointer(_ raw: String, prefix: String) -> String? {
        guard raw.hasPrefix(prefix) else { return nil }
        return canonicalPointer(String(raw.dropFirst(prefix.count)))
    }
}

/// The owner identity used by every Apple credential store.
///
/// Remote account identifiers are worker-issued lowercase UUIDs. Foundation accepts several textual
/// spellings for the same UUID, so accepting anything other than the canonical lowercase spelling would
/// let two account strings address one credential namespace. Invalid input is deliberately unrepresentable.
enum CredentialScope: Equatable, Hashable, Sendable {
    case signedOutDevice
    case account(UUID)

    init?(canonicalRemoteAccountID rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue),
              rawValue == uuid.uuidString.lowercased() else {
            return nil
        }
        self = .account(uuid)
    }

    var storageNamespace: String {
        switch self {
        case .signedOutDevice:
            return "signed-out-device"
        case .account(let id):
            return "account.\(id.uuidString.lowercased())"
        }
    }

    /// Existing beta account slots use the raw UUID (and "local" for signed-out storage). Keeping this
    /// spelling preserves already-scoped credentials while the type above prevents callers from supplying
    /// arbitrary owner strings.
    var keychainOwnerID: String {
        switch self {
        case .signedOutDevice:
            return "local"
        case .account(let id):
            return id.uuidString.lowercased()
        }
    }
}

/// Process-wide owner authority shared by the VortX account session and all named credential stores.
///
/// A capture is an epoch, not merely an account string: binding the same account again still invalidates
/// work from the previous session. Readers are synchronous and lock-backed so auth actors can capture the
/// owner before their first await. Writers are main-actor isolated and are called in the same turn as the
/// VortX account transition.
final class CredentialScopeRegistry: @unchecked Sendable {
    static let shared = CredentialScopeRegistry()

    struct Capture: Equatable, Sendable {
        let scope: CredentialScope
        let generation: UInt64

        var namespace: String { scope.storageNamespace }
    }

    private let lock = NSLock()
    private var scope: CredentialScope
    private var generation: UInt64
    /// Only an authenticated VortX account transition may consume a global legacy credential. A raw bind is
    /// intentionally not proof: signed-out state and a caller-supplied first account must leave migration
    /// available until the account session has been established.
    private var establishedGeneration: UInt64?

    init(initialScope: CredentialScope = .signedOutDevice) {
        scope = initialScope
        generation = 0
        establishedGeneration = nil
    }

    func capture() -> Capture {
        lock.lock()
        defer { lock.unlock() }
        return Capture(scope: scope, generation: generation)
    }

    func currentNamespace() -> String {
        capture().namespace
    }

    func isCurrent(_ capture: Capture) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return scope == capture.scope && generation == capture.generation
    }

    func isMigrationEligible(_ capture: Capture) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard scope == capture.scope,
              generation == capture.generation,
              establishedGeneration == capture.generation else { return false }
        if case .account = capture.scope { return true }
        return false
    }

    @MainActor
    func tryBind(_ newScope: CredentialScope) -> Capture? {
        tryBind(newScope, certifying: { .success })
    }

    /// A cross-store owner transition may carry one synchronous durable certification while the publication
    /// boundary is held. A failed certification leaves the current scope and generation unchanged.
    @MainActor
    func tryBind(
        _ newScope: CredentialScope,
        certifying: @MainActor () -> CredentialMutationResult
    ) -> Capture? {
        // Main-actor owner changes must never wait on a publication callback: an observer can need that
        // executor to return and release its dispatch lease. The optional result is the required composition
        // boundary: callers must not apply a cross-store owner change unless the exact new capture is present
        // and any required durable candidate has been certified.
        guard CredentialPublicationOutbox.acquireBoundary() == .acquired else {
            return nil
        }
        defer { CredentialPublicationOutbox.endBoundary() }
        guard certifying() == .success else { return nil }
        lock.lock()
        scope = newScope
        generation &+= 1
        establishedGeneration = nil
        let capture = Capture(scope: newScope, generation: generation)
        lock.unlock()
        return capture
    }

    /// Compatibility surface for existing synchronous callers. It never flips scope/generation on a busy or
    /// reentrant boundary, but it cannot express the failure; all cross-store composition must use `tryBind`.
    @MainActor
    @discardableResult
    func bind(_ newScope: CredentialScope) -> Capture {
        tryBind(newScope) ?? capture()
    }

    /// Mark a just-bound account as authenticated by the VortX session layer. The caller must present the
    /// exact capture returned by `bind`; an arbitrary account string can never establish migration authority.
    @MainActor
    @discardableResult
    func establishAuthenticatedOwner(_ capture: Capture) -> Capture? {
        lock.lock()
        guard scope == capture.scope,
              generation == capture.generation,
              case .account = capture.scope else {
            lock.unlock()
            return nil
        }
        establishedGeneration = generation
        lock.unlock()
        return capture
    }

    /// Semantic alias used at account/session transition call sites.
    @MainActor
    @discardableResult
    func transition(to newScope: CredentialScope) -> Capture {
        bind(newScope)
    }
}

/// Claim migration for a legacy global Keychain slot.
///
/// The marker is written and read back before the source is touched. The destination is written and verified
/// before the source is deleted. A failed source deletion therefore leaves a verified destination that a later
/// invocation can finish, while a failed destination write leaves the source available for retry.
enum CredentialLegacyClaim {
    struct Marker: Codable, Equatable {
        static let currentFormat = 1

        let format: Int
        let ownerNamespace: String
        let sourceAccount: String

        init(ownerNamespace: String, sourceAccount: String) {
            format = Self.currentFormat
            self.ownerNamespace = ownerNamespace
            self.sourceAccount = sourceAccount
        }
    }

    enum Result: Equatable {
        case noSource
        case targetPresent
        case migrated
        case durableReadFailed
        case claimWriteFailed
        case claimConflict
        case claimedByOtherOwner
        case sourceLostAfterClaim
        case sourceDeleteFailed
        case targetReadbackMismatch
    }

    private static func encode(_ marker: Marker) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(marker) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ raw: String) -> Marker? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    @discardableResult
    static func claimGlobalSlot(
        sourceAccount: String,
        destinationAccount: String,
        claimMarkerAccount: String,
        ownerNamespace: String,
        write: (String?, String) -> CredentialMutationResult,
        durableRead: @escaping (String) -> CredentialDurableReadResult,
        sourceRead: ((String) -> CredentialDurableReadResult)? = nil,
        provenanceTag: String? = nil
    ) -> Result {
        _ = provenanceTag
        let legacySourceRead = sourceRead ?? durableRead
        let expected = Marker(ownerNamespace: ownerNamespace, sourceAccount: sourceAccount)
        switch durableRead(claimMarkerAccount) {
        case let .value(rawMarker):
            guard let existing = decode(rawMarker), existing.format == Marker.currentFormat else {
                return .claimConflict
            }
            guard existing.ownerNamespace == ownerNamespace else { return .claimedByOtherOwner }
            guard existing == expected else { return .claimConflict }
        case .failure:
            return .durableReadFailed
        case .missing:
            switch durableRead(sourceAccount) {
            case let .value(source) where !source.isEmpty:
                guard let encoded = encode(expected) else { return .claimWriteFailed }
                guard write(encoded, claimMarkerAccount) == .success else { return .claimWriteFailed }
                switch durableRead(claimMarkerAccount) {
                case .value(encoded):
                    break
                case .failure:
                    return .durableReadFailed
                case .missing, .value:
                    return .claimWriteFailed
                }
            case .failure:
                return .durableReadFailed
            case .missing, .value:
                return .noSource
            }
        }

        let destination: String?
        switch durableRead(destinationAccount) {
        case let .value(value) where !value.isEmpty:
            destination = value
        case .missing, .value(""):
            destination = nil
        case .failure:
            return .durableReadFailed
        case .value:
            destination = nil
        }

            if let destination {
            switch legacySourceRead(sourceAccount) {
            case let .value(source) where !source.isEmpty:
                guard source == destination else { return .targetReadbackMismatch }
                return deleteSourceIfExact(
                    sourceAccount: sourceAccount,
                    expectedValue: destination,
                    rollbackDestinationAccount: nil,
                    successResult: .targetPresent,
                    write: write,
                    durableRead: durableRead,
                    sourceRead: legacySourceRead
                )
            case .missing, .value:
                break
            case .failure:
                return .durableReadFailed
            }
            return .targetPresent
        }

        let source: String
        switch legacySourceRead(sourceAccount) {
        case let .value(value) where !value.isEmpty:
            source = value
        case .failure:
            return .durableReadFailed
        case .missing, .value:
            return .sourceLostAfterClaim
        }

        guard write(source, destinationAccount) == .success else {
            return .targetReadbackMismatch
        }
        switch durableRead(destinationAccount) {
        case let .value(value) where value == source:
            break
        case .failure:
            guard rollbackDestinations([destinationAccount], write: write, durableRead: durableRead) else {
                return .claimWriteFailed
            }
            return .durableReadFailed
        case .missing, .value:
            guard rollbackDestinations([destinationAccount], write: write, durableRead: durableRead) else {
                return .claimWriteFailed
            }
            return .targetReadbackMismatch
        }

        return deleteSourceIfExact(
            sourceAccount: sourceAccount,
            expectedValue: source,
            rollbackDestinationAccount: destinationAccount,
            successResult: .migrated,
            write: write,
            durableRead: durableRead,
            sourceRead: legacySourceRead
        )
    }

    private static func deleteSourceIfExact(
        sourceAccount: String,
        expectedValue: String,
        rollbackDestinationAccount: String?,
        successResult: Result,
        write: (String?, String) -> CredentialMutationResult,
        durableRead: @escaping (String) -> CredentialDurableReadResult,
        sourceRead: (String) -> CredentialDurableReadResult
    ) -> Result {
        switch sourceRead(sourceAccount) {
        case let .value(actual) where actual == expectedValue:
            break
        case .failure:
            if let rollbackDestinationAccount {
                guard rollbackDestinations([rollbackDestinationAccount], write: write, durableRead: durableRead) else {
                    return .claimWriteFailed
                }
            }
            return .durableReadFailed
        case .missing:
            if let rollbackDestinationAccount {
                guard rollbackDestinations([rollbackDestinationAccount], write: write, durableRead: durableRead) else {
                    return .claimWriteFailed
                }
            }
            return .sourceLostAfterClaim
        case .value:
            if let rollbackDestinationAccount {
                guard rollbackDestinations([rollbackDestinationAccount], write: write, durableRead: durableRead) else {
                    return .claimWriteFailed
                }
            }
            return .targetReadbackMismatch
        }
        guard write(nil, sourceAccount) == .success else { return .sourceDeleteFailed }
        switch sourceRead(sourceAccount) {
        case .missing:
            return successResult
        case .failure:
            return .durableReadFailed
        case .value:
            return .sourceDeleteFailed
        }
    }

    /// The same protocol for a credential set with multiple slots. The marker is shared by the set and
    /// every destination is verified before any legacy source is deleted. Partial progress is deliberately
    /// resumable: a later call accepts only destination values that agree with their still-present sources.
    @discardableResult
    static func claimGlobalSlotSet(
        slots: [(source: String, destination: String)],
        claimMarkerAccount: String,
        ownerNamespace: String,
        write: (String?, String) -> CredentialMutationResult,
        durableRead: @escaping (String) -> CredentialDurableReadResult,
        sourceRead: ((String) -> CredentialDurableReadResult)? = nil,
        provenanceTag: String? = nil
    ) -> Result {
        _ = provenanceTag
        let legacySourceRead = sourceRead ?? durableRead
        guard !slots.isEmpty else { return .noSource }
        let expected = Marker(ownerNamespace: ownerNamespace, sourceAccount: slots[0].source)
        switch durableRead(claimMarkerAccount) {
        case let .value(rawMarker):
            guard let existing = decode(rawMarker), existing.format == Marker.currentFormat else { return .claimConflict }
            guard existing.ownerNamespace == ownerNamespace else { return .claimedByOtherOwner }
            guard existing == expected else { return .claimConflict }
        case .failure:
            return .durableReadFailed
        case .missing:
            var foundSource = false
            for slot in slots {
                switch durableRead(slot.source) {
                case let .value(value) where !value.isEmpty:
                    foundSource = true
                case .failure:
                    return .durableReadFailed
                case .missing, .value:
                    break
                }
            }
            guard foundSource else { return .noSource }
            guard let encoded = encode(expected) else { return .claimWriteFailed }
            guard write(encoded, claimMarkerAccount) == .success else { return .claimWriteFailed }
            switch durableRead(claimMarkerAccount) {
            case .value(encoded):
                break
            case .failure:
                return .durableReadFailed
            case .missing, .value:
                return .claimWriteFailed
            }
        }

        let sourceValues = slots.map { legacySourceRead($0.source) }
        let destinationValues = slots.map { durableRead($0.destination) }
        for (index, _) in slots.enumerated() {
            let source = sourceValues[index]
            let destination = destinationValues[index]
            switch destination {
            case .failure:
                return .durableReadFailed
            case let .value(destination) where !destination.isEmpty:
                switch source {
                case let .value(source) where !source.isEmpty && source != destination:
                    return .targetReadbackMismatch
                case .failure:
                    return .durableReadFailed
                case .missing, .value:
                    break
                }
            case .missing, .value:
                switch source {
                case .failure:
                    return .durableReadFailed
                case .missing, .value(""):
                    return .sourceLostAfterClaim
                case .value:
                    break
                }
            }
        }

        var newlyWritten: [(slot: (source: String, destination: String), value: String)] = []
        for (index, slot) in slots.enumerated() {
            let destinationIsEmpty: Bool
            switch destinationValues[index] {
            case .missing, .value(""): destinationIsEmpty = true
            case .value: destinationIsEmpty = false
            case .failure: return .durableReadFailed
            }
            guard destinationIsEmpty else { continue }
            guard case let .value(value) = sourceValues[index], !value.isEmpty else { return .sourceLostAfterClaim }
            guard write(value, slot.destination) == .success else {
                guard rollbackDestinations(
                    newlyWritten.map(\.slot.destination),
                    write: write,
                    durableRead: durableRead
                ) else { return .claimWriteFailed }
                return .targetReadbackMismatch
            }
            switch durableRead(slot.destination) {
            case let .value(actual) where actual == value:
                break
            case .failure:
                guard rollbackDestinations(
                    newlyWritten.map(\.slot.destination) + [slot.destination],
                    write: write,
                    durableRead: durableRead
                ) else { return .claimWriteFailed }
                return .durableReadFailed
            case .missing, .value:
                guard rollbackDestinations(
                    newlyWritten.map(\.slot.destination) + [slot.destination],
                    write: write,
                    durableRead: durableRead
                ) else { return .claimWriteFailed }
                return .targetReadbackMismatch
            }
            newlyWritten.append((slot, value))
        }

        for (index, slot) in slots.enumerated() {
            guard case let .value(value) = sourceValues[index], !value.isEmpty else { continue }
            switch legacySourceRead(slot.source) {
            case let .value(actual) where actual == value:
                break
            case .failure:
                return .durableReadFailed
            case .missing, .value:
                return .sourceDeleteFailed
            }
            guard write(nil, slot.source) == .success else { return .sourceDeleteFailed }
            switch legacySourceRead(slot.source) {
            case .missing:
                break
            case .failure:
                return .durableReadFailed
            case .value:
                return .sourceDeleteFailed
            }
        }
        return newlyWritten.isEmpty ? .targetPresent : .migrated
    }

    /// Roll back only destinations written by this invocation. A cleanup mutation is part of the durable
    /// protocol: ignoring its result would let a failed cleanup masquerade as a retry-safe migration.
    private static func rollbackDestinations(
        _ accounts: [String],
        write: (String?, String) -> CredentialMutationResult,
        durableRead: (String) -> CredentialDurableReadResult
    ) -> Bool {
        var succeeded = true
        for account in accounts {
            guard write(nil, account) == .success else {
                succeeded = false
                continue
            }
            switch durableRead(account) {
            case .missing:
                break
            case .failure, .value:
                succeeded = false
            }
        }
        return succeeded
    }
}

/// A monotonic revision ledger used by resolver reloads. Older snapshots are ignored even when they
/// arrive after a newer owner snapshot; the value and revision are one actor-serialized state.
actor LatestCredentialReload<Value: Sendable> {
    private var latestRevision: UInt64 = 0
    private var latestValue: Value?

    @discardableResult
    func submit(_ value: Value, revision: UInt64) -> Bool {
        guard revision > latestRevision else { return false }
        latestRevision = revision
        latestValue = value
        return true
    }

    func current() -> (revision: UInt64, value: Value?) {
        (latestRevision, latestValue)
    }
}

/// Exact owner/revision leases for provider work that may outlive a resolver call's first await.
///
/// The coordinator cannot safely solve an account switch by only dropping resolver references: a provider
/// task already holding the old actor can continue its network/poll sequence. This registry gives every
/// provider task a cancellable lease, blocks new admissions during authority transfer, and makes reload
/// await all cancelled work before the new authority is published. The closures erase heterogeneous task
/// result types without erasing cancellation or the exact owner/capture/revision metadata.
actor DebridProviderTaskRegistry {
    struct Lease: Equatable, Sendable {
        let id: UUID
        let owner: CredentialScope
        let capture: CredentialScopeRegistry.Capture
        let revision: UInt64
    }

    struct StartedTask<Value: Sendable>: Sendable {
        let lease: Lease
        let task: Task<Value, Error>
    }

    struct Transition: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private struct Entry: Sendable {
        let lease: Lease
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private struct PublishedAuthority: Equatable, Sendable {
        let owner: CredentialScope
        let capture: CredentialScopeRegistry.Capture
        let revision: UInt64
    }

    private var active: [UUID: Entry] = [:]
    private var transfer: Transition?
    private var transferWaiters: [CheckedContinuation<Void, Never>] = []
    private var publishedAuthority: PublishedAuthority?

    /// A new provider task is admitted only for the exact authority currently published by the coordinator.
    /// Before the first reload, the current registry capture is accepted so the initial warm can proceed.
    ///
    /// Admit and create the physical provider task in one actor-isolated operation. Creating the task
    /// outside the registry would leave a small unregistered window in which an authority transfer could
    /// finish without cancelling/awaiting work that had already started.
    func start<Value: Sendable>(
        owner: CredentialScope,
        capture: CredentialScopeRegistry.Capture,
        revision: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) -> StartedTask<Value>? {
        guard transfer == nil,
              owner == capture.scope,
              CredentialScopeRegistry.shared.isCurrent(capture) else { return nil }
        if let publishedAuthority,
           (publishedAuthority.owner != owner
                || publishedAuthority.capture != capture
                || publishedAuthority.revision != revision) {
            return nil
        }
        let task = Task.detached(priority: .userInitiated) {
            try await operation()
        }
        let lease = Lease(id: UUID(), owner: owner, capture: capture, revision: revision)
        active[lease.id] = Entry(
            lease: lease,
            cancel: { task.cancel() },
            wait: { _ = await task.result }
        )
        return StartedTask(lease: lease, task: task)
    }

    /// Retire only the exact task that acquired this lease. A stale completion cannot remove a newer task
    /// even if it happens to run after an account transition and receives the same provider slot.
    func finish(_ lease: Lease) {
        guard active[lease.id]?.lease == lease else { return }
        active.removeValue(forKey: lease.id)
    }

    func contains(_ lease: Lease?) -> Bool {
        guard let lease else { return false }
        return active[lease.id]?.lease == lease
    }

    /// Begin one serialized transfer. Concurrent reloads wait for the earlier transfer's explicit finish,
    /// rather than starting a second transition that could publish an owner while old work is still draining.
    /// The first caller receives a token after all cancelled provider tasks have actually retired.
    func beginTransition() async -> Transition {
        if transfer != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                transferWaiters.append(continuation)
            }
            return await beginTransition()
        }

        let transition = Transition(id: UUID())
        transfer = transition
        let entries = Array(active.values)
        active.removeAll(keepingCapacity: true)
        for entry in entries { entry.cancel() }

        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { await entry.wait() }
            }
            await group.waitForAll()
        }
        return transition
    }

    /// Publish the new authority only after `beginTransition()` has drained the old provider tasks. The
    /// optional authority is omitted for a rejected/stale reload, which still releases blocked admissions
    /// without allowing that stale snapshot to become current.
    func finishTransition(
        _ transition: Transition,
        owner: CredentialScope? = nil,
        capture: CredentialScopeRegistry.Capture? = nil,
        revision: UInt64? = nil
    ) {
        guard transfer == transition else { return }
        if let owner, let capture, let revision {
            publishedAuthority = PublishedAuthority(owner: owner, capture: capture, revision: revision)
        }
        transfer = nil
        let waiters = transferWaiters
        transferWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    var isTransitionInProgress: Bool { transfer != nil }
    var activeCount: Int { active.count }
}
