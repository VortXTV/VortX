import Foundation

/// A high-drop playback interval can temporarily defer local trickplay capture,
/// but ordinary isolated VO drops must never disable previews. The next low-drop
/// receipt after the bounded interval records the exit transition.
struct TrickplayCapturePressurePolicy: Equatable {
    enum Transition: String, Equatable {
        case unchanged
        case entered
        case extended
        case exited
    }

    static let highDropThreshold = 30
    static let backoffSeconds: TimeInterval = 60

    private(set) var suppressedUntil: TimeInterval = 0

    mutating func observe(
        droppedFrames: Int,
        now: TimeInterval
    ) -> Transition {
        let wasSuppressed = isSuppressed(at: now)
        if droppedFrames >= Self.highDropThreshold {
            suppressedUntil = max(
                suppressedUntil,
                now + Self.backoffSeconds
            )
            return wasSuppressed ? .extended : .entered
        }
        if suppressedUntil > 0, !wasSuppressed {
            suppressedUntil = 0
            return .exited
        }
        return .unchanged
    }

    func isSuppressed(at now: TimeInterval) -> Bool {
        now < suppressedUntil
    }
}

/// One shared cancellation predicate for every expensive stage of an owned
/// community-upload task. The task that owns the policy is the same task that
/// composes, encodes, and posts, so cancellation remains observable throughout.
enum TrickplayOwnedWorkGate {
    static func permitsStage(taskIsCancelled: Bool) -> Bool {
        !taskIsCancelled
    }
}

/// Small state machine that keeps community trickplay useful without rebuilding the
/// full sprite sheet every minute. Each exact content key gets one progressive
/// attempt once its capture is storable, plus at most one teardown attempt after a
/// failure or material coverage growth. A deliberate decline and a stored teardown
/// response are final for that key.
struct TrickplayUploadPolicy {
    enum Kind: Equatable, Sendable {
        case progressive
        case final
    }

    enum Outcome: Equatable, Sendable {
        case stored
        case rejected
        case failed
    }

    struct Claim: Equatable, Hashable, Sendable {
        let key: String
        let sequence: UInt64
        let kind: Kind
        let frameCount: Int
    }

    enum Admission: Equatable, Sendable {
        case start(Claim)
        case deferred(Claim)
    }

    struct Completion: Equatable, Sendable {
        let applied: Bool
        let nextClaim: Claim?
    }

    private struct KeyState {
        var isTerminal = false
        var progressiveAttempted = false
        var finalAttempted = false
        var progressiveStoredFrameCount: Int?
    }

    private(set) var key: String?
    private(set) var inFlight: Claim?
    private(set) var deferredFinals: [Claim] = []
    private var states: [String: KeyState] = [:]
    private var nextSequence: UInt64 = 1
    private static let maxDeferredFinals = 2

    var isTerminal: Bool {
        guard let key else { return false }
        return states[key]?.isTerminal ?? false
    }

    var progressiveAttempted: Bool {
        guard let key else { return false }
        return states[key]?.progressiveAttempted ?? false
    }

    var finalAttempted: Bool {
        guard let key else { return false }
        return states[key]?.finalAttempted ?? false
    }

    var progressiveStoredFrameCount: Int? {
        guard let key else { return nil }
        return states[key]?.progressiveStoredFrameCount
    }

    /// Selects the current capture key without destroying admitted work from the
    /// previous key. At most one upload runs and at most two final snapshots wait,
    /// so rapid title changes cannot create an unbounded queue.
    mutating func reset(for key: String?) {
        guard self.key != key else { return }
        self.key = key
        if let key, states[key] == nil {
            states[key] = KeyState()
        }
        pruneRetiredStates()
    }

    mutating func request(
        key: String,
        kind: Kind,
        frameCount: Int,
        existingFrameCount: Int,
        coverageReady: Bool
    ) -> Admission? {
        if self.key != key { reset(for: key) }
        var state = states[key] ?? KeyState()
        guard !state.isTerminal,
              frameCount >= 2,
              frameCount > existingFrameCount,
              coverageReady else { return nil }

        switch kind {
        case .progressive:
            guard inFlight == nil,
                  !state.progressiveAttempted else { return nil }
            state.progressiveAttempted = true
        case .final:
            guard !state.finalAttempted else { return nil }
            if let stored = state.progressiveStoredFrameCount {
                let materialGrowth = max(6, stored / 4)
                guard frameCount >= stored + materialGrowth else { return nil }
            }
            if inFlight != nil,
               deferredFinals.count >= Self.maxDeferredFinals {
                return nil
            }
            state.finalAttempted = true
        }
        states[key] = state

        let claim = Claim(
            key: key,
            sequence: nextSequence,
            kind: kind,
            frameCount: frameCount
        )
        nextSequence &+= 1
        if inFlight != nil {
            deferredFinals.append(claim)
            return .deferred(claim)
        }
        inFlight = claim
        return .start(claim)
    }

    /// Retires the selected content key in one transition. The final reservation
    /// is made before selection moves to the next content, so callers can snapshot
    /// the old frames without manually racing a separate final request and reset.
    mutating func retireCurrent(
        frameCount: Int,
        existingFrameCount: Int,
        coverageReady: Bool,
        selecting nextKey: String?
    ) -> Admission? {
        guard let retiringKey = key else {
            reset(for: nextKey)
            return nil
        }
        let admission = request(
            key: retiringKey,
            kind: .final,
            frameCount: frameCount,
            existingFrameCount: existingFrameCount,
            coverageReady: coverageReady
        )
        reset(for: nextKey)
        return admission
    }

    /// Applies only the exact active claim. A completion may belong to a retired
    /// key, because admitted old-key work survives a title change. It can start at
    /// most one eligible deferred final; duplicates and superseded completions do
    /// not mutate the current key.
    mutating func complete(_ claim: Claim, outcome: Outcome) -> Completion {
        guard inFlight == claim else {
            return Completion(applied: false, nextClaim: nil)
        }
        inFlight = nil
        var state = states[claim.key] ?? KeyState()
        switch outcome {
        case .stored:
            if claim.kind == .progressive {
                state.progressiveStoredFrameCount = claim.frameCount
            } else {
                state.isTerminal = true
            }
        case .rejected:
            state.isTerminal = true
        case .failed:
            break
        }
        states[claim.key] = state

        let next = dequeueEligibleFinal()
        inFlight = next
        pruneRetiredStates()
        return Completion(applied: true, nextClaim: next)
    }

    private mutating func dequeueEligibleFinal() -> Claim? {
        while !deferredFinals.isEmpty {
            let candidate = deferredFinals.removeFirst()
            guard let state = states[candidate.key],
                  !state.isTerminal else { continue }
            if let stored = state.progressiveStoredFrameCount {
                let materialGrowth = max(6, stored / 4)
                guard candidate.frameCount >= stored + materialGrowth else {
                    continue
                }
            }
            return candidate
        }
        return nil
    }

    private mutating func pruneRetiredStates() {
        let retained = Set(
            [key, inFlight?.key].compactMap { $0 }
                + deferredFinals.map(\.key)
        )
        states = states.filter { retained.contains($0.key) }
    }
}
