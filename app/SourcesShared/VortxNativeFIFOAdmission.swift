import Foundation

/// Admission/ownership only: the Facade still schedules its existing native_state task chain.
/// Uses that Facade's lock so read consumption and task installation are one transaction.
/// No identity, credential, native receipt or durable success is manufactured here.
final class VortxNativeFIFOAdmission: @unchecked Sendable {
    private let lock: NSRecursiveLock
    private var generation = UUID()
    private var pending: [UUID] = []
    private var running: UUID?
    private var closed = false
    private var uncertain = false
    init(lock: NSRecursiveLock) { self.lock = lock }

    final class ReadCapability: VortxMutationAuthority, @unchecked Sendable {
        fileprivate enum Phase { case reading(UUID), admitted(UUID), finished }
        fileprivate let owner: VortxNativeFIFOAdmission
        fileprivate let source: any VortxMutationAuthority
        fileprivate let validate: @Sendable () throws -> Void
        fileprivate var phase: Phase
        fileprivate var cancelled = false
        fileprivate init(owner: VortxNativeFIFOAdmission, generation: UUID,
                         source: any VortxMutationAuthority, validate: @escaping @Sendable () throws -> Void) {
            self.owner = owner; self.source = source; self.validate = validate
            phase = .reading(generation)
        }
        /// Same original source and same object before/after handoff. Queued is not running.
        func withActive(_ operation: () throws -> Void) throws {
            try source.withActive { try owner.withCapability(self, operation) }
        }
        /// Coordinator's queue seam, without recursively taking its original source locks.
        var queueAuthority: any VortxMutationAuthority { QueueAuthority(read: self) }
        /// Same retained source/member, but a read or merely queued capability cannot commit.
        var runningAuthority: any VortxMutationAuthority { RunningAuthority(read: self) }
        func cancel() { owner.lock.withLock { cancelled = true } }
    }
    private struct RunningAuthority: VortxMutationAuthority {
        let read: ReadCapability
        func withActive(_ operation: () throws -> Void) throws {
            try read.source.withActive {
                try read.owner.withCapability(read) {
                    guard case .admitted(let id) = read.phase,
                          read.owner.running == id, read.owner.pending.first == id else {
                        throw VortxNativeError.superseded
                    }
                    try operation()
                }
            }
        }
    }
    private struct QueueAuthority: VortxMutationAuthority {
        let read: ReadCapability
        func withActive(_ operation: () throws -> Void) throws {
            try read.owner.withCapability(read, operation)
        }
    }
    final class Member: @unchecked Sendable {
        fileprivate let owner: VortxNativeFIFOAdmission
        fileprivate let id = UUID()
        fileprivate let read: ReadCapability?
        fileprivate var began = false
        fileprivate var finished = false
        fileprivate init(owner: VortxNativeFIFOAdmission, read: ReadCapability?) {
            self.owner = owner; self.read = read
        }
        func begin() throws { try owner.begin(self) }
        /// Queue-only original running member; the caller separately encloses its REAL
        /// source authority. Never recursively reacquire a captured nonrecursive source.
        var runningAuthority: any VortxMutationAuthority { MemberAuthority(member: self) }
        /// Called by the task's defer, after its predecessor and all ACK publication/completion.
        func finish() { owner.finish(self) }
    }

    private struct MemberAuthority: VortxMutationAuthority {
        let member: Member
        func withActive(_ operation: () throws -> Void) throws {
            try member.owner.lock.withLock {
                try member.owner.requireAvailable()
                guard member.began, !member.finished,
                      member.owner.running == member.id, member.owner.pending.first == member.id else {
                    throw VortxNativeError.superseded
                }
                try operation()
            }
        }
    }

    /// Source lock precedes Facade lock. validate is the original acknowledged context check,
    /// called only under that lock; it must not acquire provider/Bridge locks or perform I/O.
    func capture(source: any VortxMutationAuthority,
                 validate: @escaping @Sendable () throws -> Void) throws -> ReadCapability {
        var captured: ReadCapability?
        try source.withActive {
            try lock.withLock {
                try requireAvailable()
                guard pending.isEmpty, running == nil else { throw VortxNativeError.superseded }
                try validate()
                captured = ReadCapability(owner: self, generation: generation, source: source, validate: validate)
            }
        }
        guard let captured else { throw VortxNativeError.superseded }
        return captured
    }

    /// Every real ordinary admission, including progress flush, retires old reads. A dropped
    /// duplicate progress tick must return before calling this method.
    func admit() throws -> Member {
        try lock.withLock { try requireAvailable(); return append(read: nil) }
    }

    /// Consumes exactly once and installs the actual FIFO task while source+Facade locks remain
    /// held. If an authority throws AFTER installation, the queued task owns completion; retire
    /// this capability, never report a second pre-enqueue failure or retry the admission.
    func admit(_ read: ReadCapability, install: (Member) -> Void) throws {
        guard read.owner === self else { throw VortxNativeError.superseded }
        var installed = false
        do {
            try read.source.withActive {
                try lock.withLock {
                    try requireReading(read)
                    let member = append(read: read)
                    read.phase = .admitted(member.id)
                    installed = true
                    install(member)
                }
            }
        } catch {
            if installed { read.cancel(); return }
            throw error
        }
    }
    /// The Facade obtains the retained original authority FROM the admitted member, never
    /// from another caller-supplied source argument beside that member.
    func capturedAuthority(for member: Member) throws -> ReadCapability {
        try lock.withLock {
            try requireAvailable()
            guard member.owner === self, !member.began, !member.finished,
                  pending.contains(member.id), let read = member.read else { throw VortxNativeError.superseded }
            return read
        }
    }
    func close() { lock.withLock { closed = true; generation = UUID() } }
    func markUncertain() { lock.withLock { uncertain = true; generation = UUID() } }

    private func requireAvailable() throws {
        guard !closed else { throw VortxNativeError.closed }
        guard !uncertain else { throw VortxNativeError.checkpointUncertain }
    }
    private func requireReading(_ read: ReadCapability) throws {
        try requireAvailable()
        guard read.owner === self, !read.cancelled, pending.isEmpty, running == nil,
              case .reading(let expected) = read.phase, expected == generation else {
            throw VortxNativeError.superseded
        }
        try read.validate()
    }
    private func append(read: ReadCapability?) -> Member {
        let member = Member(owner: self, read: read)
        generation = UUID(); pending.append(member.id)
        return member
    }
    private func withCapability(_ read: ReadCapability, _ operation: () throws -> Void) throws {
        try lock.withLock {
            try requireAvailable()
            guard read.owner === self, !read.cancelled else { throw VortxNativeError.superseded }
            switch read.phase {
            case .reading:
                try requireReading(read)
            case .admitted(let id):
                guard running == id, pending.first == id else { throw VortxNativeError.superseded }
                try read.validate()
            case .finished: throw VortxNativeError.superseded
            }
            try operation()
        }
    }
    private func begin(_ member: Member) throws {
        try lock.withLock {
            try requireAvailable()
            guard member.owner === self, !member.began, !member.finished,
                  pending.first == member.id, running == nil else { throw VortxNativeError.superseded }
            if let read = member.read {
                guard !read.cancelled, case .admitted(let id) = read.phase, id == member.id else {
                    throw VortxNativeError.superseded
                }
                try read.validate()
            }
            member.began = true; running = member.id
        }
    }
    private func finish(_ member: Member) {
        lock.withLock {
            guard member.owner === self, !member.finished else { return }
            // A task may fail/cancel before begin. It still settles only AFTER its predecessor.
            guard pending.first == member.id else {
                uncertain = true; generation = UUID(); return
            }
            if running == member.id { running = nil }
            pending.removeFirst(); member.finished = true
            member.read?.phase = .finished
        }
    }
}
