import Foundation

/// One monotonic budget, minted before episode discovery and inherited through callback-based
/// resolvers. A nested local NNTP/cloud wait cannot silently start a new full request window.
struct EpisodeResolutionBudget: Equatable, Sendable {
    enum Origin: String, Sendable { case automatic, manual, languageRecovery }
    static let preferredUsenetSeconds: TimeInterval = 35
    static let fallbackSeconds: TimeInterval = 8
    static let admissionSeconds: TimeInterval = 2
    static let maximumDuration = SourceSettlementPolicy.maximumWait
        + preferredUsenetSeconds + fallbackSeconds + admissionSeconds
    @TaskLocal static var current: EpisodeResolutionBudget?

    let episodeID: String
    let origin: Origin
    let startedAt: TimeInterval
    let deadline: TimeInterval

    init(episodeID: String, origin: Origin, now: TimeInterval) {
        self.episodeID = episodeID
        self.origin = origin
        startedAt = now
        deadline = now + Self.maximumDuration
    }

    var candidateDeadline: TimeInterval { deadline - Self.admissionSeconds }
    var admissionDeadline: TimeInterval { deadline - 0.25 }
    func elapsed(at now: TimeInterval) -> TimeInterval { max(0, now - startedAt) }
    func canAdmit(at now: TimeInterval) -> Bool { now < admissionDeadline }

    static func protectsPendingResolution<Owner: Equatable>(deadlineScheduled: Bool,
        owner: Owner?, currentOwner: Owner?, admitted: Bool, exited: Bool) -> Bool {
        !exited && deadlineScheduled && owner != nil && owner == currentOwner && !admitted
    }

    /// Preserve the real 35s first local NNTP phase after 20s contributor settlement. When
    /// another candidate exists, reserve fallback time; every later leg uses only what remains.
    static func candidateLegDeadline(overallDeadline: TimeInterval, now: TimeInterval,
                                     isUsenet: Bool, remainingCandidates: Int) -> TimeInterval? {
        let remaining = overallDeadline - now
        guard remaining > 0, remaining.isFinite, remainingCandidates > 0 else { return nil }
        let reserve = remainingCandidates > 1 ? min(fallbackSeconds, remaining / 2) : 0
        return now + min(isUsenet ? preferredUsenetSeconds : 5, remaining - reserve)
    }
}
