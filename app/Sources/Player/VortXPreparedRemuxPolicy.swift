#if os(iOS) || os(tvOS) || os(macOS)
import Foundation

enum VortXPreparedRemuxMode: String, Hashable, Sendable {
    case dolbyVision
    case plain
}

struct VortXPreparedRemuxOwnerIdentity: Hashable, Sendable {
    let mediaID: String
    let generation: UInt64
    let sourceSignature: String

    init(mediaID: String, generation: UInt64, sourceSignature: String) {
        self.mediaID = mediaID
        self.generation = generation
        self.sourceSignature = sourceSignature
    }
}

struct VortXPreparedRemuxIdentity: Hashable, Sendable {
    struct Header: Hashable, Sendable {
        let name: String
        let value: String
    }

    let owner: VortXPreparedRemuxOwnerIdentity
    let inputURL: String
    let headers: [Header]
    let mode: VortXPreparedRemuxMode
    let startAtSeconds: Double
    let selectedAudioStreamIndex: Int?
    let preferredAudioLanguages: [String]?
    let audioRejectTerms: [String]?

    init(owner: VortXPreparedRemuxOwnerIdentity,
         input: URL,
         headers: [String: String]?,
         mode: VortXPreparedRemuxMode,
         startAtSeconds: Double,
         selectedAudioStreamIndex: Int?,
         preferredAudioLanguages: [String]?,
         audioRejectTerms: [String]?) {
        self.owner = owner
        self.inputURL = input.absoluteString
        self.headers = (headers ?? [:]).map {
            Header(name: $0.key.lowercased(), value: $0.value)
        }.sorted {
            $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name
        }
        self.mode = mode
        self.startAtSeconds = startAtSeconds.isFinite && startAtSeconds > 0
            ? startAtSeconds : 0
        self.selectedAudioStreamIndex = selectedAudioStreamIndex
        self.preferredAudioLanguages = preferredAudioLanguages
        self.audioRejectTerms = audioRejectTerms
    }
}

struct VortXPreparedRemuxAdoptionState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case available
        case adopted
        case retired
    }

    enum Rejection: Equatable, Sendable {
        case identityMismatch
        case notReady
        case alreadyConsumed
    }

    enum Decision: Equatable, Sendable {
        case adopt
        case coldLoad(reason: Rejection, cleanup: Bool)
    }

    private(set) var phase: Phase = .available

    mutating func consume(expected: VortXPreparedRemuxIdentity,
                          actual: VortXPreparedRemuxIdentity,
                          ready: Bool) -> Decision {
        guard phase == .available else {
            return .coldLoad(reason: .alreadyConsumed, cleanup: false)
        }
        guard expected == actual else {
            phase = .retired
            return .coldLoad(reason: .identityMismatch, cleanup: true)
        }
        guard ready else {
            phase = .retired
            return .coldLoad(reason: .notReady, cleanup: true)
        }
        phase = .adopted
        return .adopt
    }

    mutating func retire() -> Bool {
        guard phase == .available else { return false }
        phase = .retired
        return true
    }
}

struct VortXRemuxProducerArbitration: Equatable, Sendable {
    enum Purpose: Equatable, Sendable {
        case playback
        case preparation
    }

    struct Request: Equatable, Sendable {
        let id: UInt64
        let purpose: Purpose
    }

    enum Action: Equatable, Sendable {
        case start(UInt64)
        case preempt(UInt64)
        case reject(UInt64)
    }

    private(set) var active: Request?
    private(set) var pending: Request?
    private var activePreemptRequested = false

    mutating func submit(id: UInt64, purpose: Purpose) -> [Action] {
        let request = Request(id: id, purpose: purpose)
        guard let current = active else {
            active = request
            activePreemptRequested = false
            return [.start(id)]
        }

        var actions: [Action] = []
        if let waiting = pending {
            actions.append(.reject(waiting.id))
        }
        pending = request

        if current.purpose == .preparation, !activePreemptRequested {
            activePreemptRequested = true
            actions.append(.preempt(current.id))
        }
        return actions
    }

    mutating func cancel(id: UInt64) -> [Action] {
        if active?.id == id {
            guard !activePreemptRequested else { return [] }
            activePreemptRequested = true
            return [.preempt(id)]
        }
        if pending?.id == id {
            pending = nil
            return [.reject(id)]
        }
        return []
    }

    mutating func producerDidUnwind(id: UInt64) -> [Action] {
        guard active?.id == id else { return [] }
        active = nil
        activePreemptRequested = false
        guard let waiting = pending else { return [] }
        pending = nil
        active = waiting
        return [.start(waiting.id)]
    }
}

struct VortXRemuxProducerTerminalState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case running
        case terminal
    }

    private(set) var phase: Phase = .idle

    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .running
        return true
    }

    mutating func cancelBeforeStart() -> Bool {
        guard phase == .idle else { return false }
        phase = .terminal
        return true
    }

    mutating func producerDidUnwind() -> Bool {
        guard phase == .running else { return false }
        phase = .terminal
        return true
    }
}

final class VortXRemuxProducerTerminalRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var handler: (@Sendable () -> Void)?

    var hasFired: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }

    func install(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if fired {
            lock.unlock()
            handler()
            return
        }
        self.handler = handler
        lock.unlock()
    }

    func fire() {
        let callback: (@Sendable () -> Void)?
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        callback = handler
        handler = nil
        lock.unlock()
        callback?()
    }
}

/// A cancellation request is not proof that a remux has released its input connection and producer slot.
/// The fallback surface holds this receipt until the producer's one real terminal edge fires.
final class VortXRemuxQuiescenceReceipt: @unchecked Sendable {
    private let terminal: VortXRemuxProducerTerminalRelay?

    init(terminal: VortXRemuxProducerTerminalRelay?) {
        self.terminal = terminal
    }

    var isAcknowledged: Bool { terminal?.hasFired ?? true }

    func wait(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isAcknowledged, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return isAcknowledged
    }
}

/// Pure handoff gates. A replacement mpv mount is permitted only after the outgoing producer has unwound;
/// preparation is forbidden once the route has left AVFoundation.
enum VortXRemuxHandoffPolicy {
    static func canMountMPV(routeStillCurrent: Bool, producerQuiescent: Bool) -> Bool {
        routeStillCurrent && producerQuiescent
    }

    static func canRetainPreparedTransport(
        avRouteActive: Bool,
        handoffPending: Bool,
        taskCancelled: Bool
    ) -> Bool {
        avRouteActive && !handoffPending && !taskCancelled
    }
}

/// Parks the one remux thread only at a caller-declared closed-segment boundary. The producer keeps its
/// arbitration ticket while waiting. Adoption resumes that same thread; cancellation wakes it so its normal
/// run defer remains the only authoritative producer-terminal edge.
final class VortXRemuxPreparationGate: @unchecked Sendable {
    enum BoundaryOutcome: Equatable, Sendable {
        case continued
        case resumed
        case cancelled
    }

    private let condition = NSCondition()
    private var parkRequested = false
    private var parked = false
    private var released = false
    private var cancelled = false

    @discardableResult
    func requestParkAfterBoundary() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !released, !cancelled else { return false }
        parkRequested = true
        return true
    }

    func waitAtClosedSegmentBoundary() -> BoundaryOutcome {
        condition.lock()
        guard parkRequested, !released, !cancelled else {
            let outcome: BoundaryOutcome = cancelled ? .cancelled : .continued
            condition.unlock()
            return outcome
        }
        parked = true
        condition.broadcast()
        while parkRequested, !released, !cancelled {
            condition.wait()
        }
        parked = false
        let outcome: BoundaryOutcome = cancelled ? .cancelled : .resumed
        condition.broadcast()
        condition.unlock()
        return outcome
    }

    func resume() {
        condition.lock()
        guard !released, !cancelled else {
            condition.unlock()
            return
        }
        released = true
        parkRequested = false
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            return
        }
        cancelled = true
        parkRequested = false
        condition.broadcast()
        condition.unlock()
    }

    var isParked: Bool {
        condition.lock(); defer { condition.unlock() }
        return parked
    }

    func waitUntilParked(timeoutSeconds: Double) -> Bool {
        let bounded = timeoutSeconds.isFinite ? max(0, timeoutSeconds) : 0
        let deadline = Date(timeIntervalSinceNow: bounded)
        condition.lock(); defer { condition.unlock() }
        while !parked, !cancelled, !released {
            guard condition.wait(until: deadline) else { break }
        }
        return parked
    }
}

final class VortXRemuxProducerTicket: @unchecked Sendable {
    let id: UInt64
    fileprivate weak var coordinator: VortXRemuxProducerCoordinator?

    fileprivate init(id: UInt64, coordinator: VortXRemuxProducerCoordinator) {
        self.id = id
        self.coordinator = coordinator
    }

    func cancel() {
        coordinator?.cancel(id: id)
    }

    func producerDidUnwind() {
        coordinator?.producerDidUnwind(id: id)
    }
}

final class VortXRemuxProducerCoordinator: @unchecked Sendable {
    static let shared = VortXRemuxProducerCoordinator()

    private struct Callbacks: Sendable {
        let start: @Sendable (VortXRemuxProducerTicket) -> Void
        let preempt: @Sendable () -> Void
        let reject: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var arbitration = VortXRemuxProducerArbitration()
    private var callbacks: [UInt64: Callbacks] = [:]
    private var tickets: [UInt64: VortXRemuxProducerTicket] = [:]

    func submit(
        purpose: VortXRemuxProducerArbitration.Purpose,
        start: @escaping @Sendable (VortXRemuxProducerTicket) -> Void,
        preempt: @escaping @Sendable () -> Void,
        reject: @escaping @Sendable () -> Void
    ) -> VortXRemuxProducerTicket {
        lock.lock()
        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        let ticket = VortXRemuxProducerTicket(id: id, coordinator: self)
        tickets[id] = ticket
        callbacks[id] = Callbacks(start: start, preempt: preempt, reject: reject)
        let actions = arbitration.submit(id: id, purpose: purpose)
        let work = workForActionsLocked(actions)
        lock.unlock()
        work.forEach { $0() }
        return ticket
    }

    fileprivate func cancel(id: UInt64) {
        lock.lock()
        let actions = arbitration.cancel(id: id)
        let work = workForActionsLocked(actions)
        lock.unlock()
        work.forEach { $0() }
    }

    fileprivate func producerDidUnwind(id: UInt64) {
        lock.lock()
        callbacks.removeValue(forKey: id)
        tickets.removeValue(forKey: id)
        let actions = arbitration.producerDidUnwind(id: id)
        let work = workForActionsLocked(actions)
        lock.unlock()
        work.forEach { $0() }
    }

    private func workForActionsLocked(
        _ actions: [VortXRemuxProducerArbitration.Action]
    ) -> [@Sendable () -> Void] {
        var work: [@Sendable () -> Void] = []
        for action in actions {
            switch action {
            case .start(let id):
                if let callback = callbacks[id]?.start, let ticket = tickets[id] {
                    work.append { callback(ticket) }
                }
            case .preempt(let id):
                if let callback = callbacks[id]?.preempt {
                    work.append(callback)
                }
            case .reject(let id):
                let callback = callbacks.removeValue(forKey: id)?.reject
                tickets.removeValue(forKey: id)
                if let callback { work.append(callback) }
            }
        }
        return work
    }
}

/// Caller-side gate for the retained next-episode transport. The producer implementation owns byte and
/// listener safety; this policy owns whether a background candidate is allowed to spend that producer slot
/// and whether the exact retained owner may be offered to the next AVPlayer load.
enum VortXPreparedRemuxCallerPolicy {
    enum Admission: Equatable, Sendable {
        case configure
        case abandonAndColdLoad
    }

    enum LoadPath: Equatable, Sendable {
        case prepared
        case coldLoad
    }

    enum TransportWarmPath: Equatable, Sendable {
        case preparedRemux
        case prefixRange
    }

    static func mode(
        avPlayerActive: Bool,
        mountIsOnDevice: Bool,
        rawTorrent: Bool,
        dolbyVision: Bool,
        dolbyVisionRemuxEligible: Bool,
        plainRemuxEligible: Bool
    ) -> VortXPreparedRemuxMode? {
        guard avPlayerActive, mountIsOnDevice, !rawTorrent else { return nil }
        if dolbyVision, dolbyVisionRemuxEligible { return .dolbyVision }
        if !dolbyVision, plainRemuxEligible { return .plain }
        return nil
    }

    static func admission(
        actualOwner: VortXPreparedRemuxOwnerIdentity,
        expectedOwner: VortXPreparedRemuxOwnerIdentity,
        avPlayerActive: Bool,
        mountIsOnDevice: Bool
    ) -> Admission {
        guard avPlayerActive, mountIsOnDevice, actualOwner == expectedOwner else {
            return .abandonAndColdLoad
        }
        return .configure
    }

    static func loadPath(
        hasPreparedHandle: Bool,
        admission: Admission
    ) -> LoadPath {
        hasPreparedHandle && admission == .configure ? .prepared : .coldLoad
    }

    /// A remux transport already reads and freezes the exact startup cohort, so also issuing a ranged prefix
    /// GET spends bandwidth without improving admission. Ordinary direct files and raw torrents keep the
    /// bounded prefix path.
    static func transportWarmPath(preparedMode: VortXPreparedRemuxMode?) -> TransportWarmPath {
        preparedMode == nil ? .prefixRange : .preparedRemux
    }
}
#endif
