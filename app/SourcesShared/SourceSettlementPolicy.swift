import Foundation

/// Generation-scoped completion state for one source contributor. A contributor is inactive only when its
/// feature is not registered for the current page. Registered work remains pending until it publishes a result
/// (including an empty result) or reaches a terminal failure.
enum SourceContributorSettlement: String, Equatable, Sendable {
    case inactive
    case pending
    case terminal
}

/// The one settlement decision shared by source-list ranking and auto-pick. Partial availability never counts
/// as completion: either every registered contributor is terminal, or the bounded page deadline expires.
enum SourceSettlementDecision: Equatable, Sendable {
    case waiting
    case settledAll
    case settledDeadline

    var isSettled: Bool {
        self != .waiting
    }
}

enum SourceSettlementPolicy {
    /// Long enough for the measured 9-12 second aggregator tail, while still bounding a hung contributor.
    static let maximumWait: TimeInterval = 20

    static func decide(
        raw: SourceContributorSettlement,
        auxiliary: [SourceContributorSettlement],
        deadlineExpired: Bool
    ) -> SourceSettlementDecision {
        if !([raw] + auxiliary).contains(.pending) { return .settledAll }
        return deadlineExpired ? .settledDeadline : .waiting
    }

    /// Only a previously complete generation can become a new same-identity generation. A deadline receipt
    /// with contributors still pending remains final for that generation; unrelated rebuild events must not
    /// restart the deadline forever.
    static func shouldRearmDeadline(
        previous: SourceSettlementDecision,
        hasPendingContributor: Bool,
        deadlineTaskActive: Bool
    ) -> Bool {
        previous == .settledAll && hasPendingContributor && !deadlineTaskActive
    }
}

/// Exact identity fence for contributor task completions. Clearing or replacing an owner invalidates both
/// tokens before cancellation; a late task can therefore neither publish rows nor mutate terminal state.
enum SourceContributorCompletionOwnership {
    static func accepts(
        completedKey: String,
        shownKey: String?,
        inFlightKey: String?,
        canceled: Bool
    ) -> Bool {
        !canceled && shownKey == completedKey && inFlightKey == completedKey
    }
}
