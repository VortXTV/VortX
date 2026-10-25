import Foundation

/// A deliberate preview Play owns at most one resolver and one player handoff.
/// Cancellation is terminal: an old async completion cannot borrow a later request.
struct RandomPickPlayPolicy {
    enum State: Equatable { case pending, resolving(UUID), consumed, revoked }
    private(set) var state: State = .pending

    mutating func claim(enabled: Bool, current: Bool) -> UUID? {
        guard enabled, state == .pending else { return nil }
        guard current else { revoke(); return nil }
        let claim = UUID()
        state = .resolving(claim)
        return claim
    }

    mutating func accepts(_ claim: UUID, current: Bool) -> Bool {
        guard state == .resolving(claim) else { return false }
        guard current else { revoke(); return false }
        return true
    }

    mutating func consume(_ claim: UUID, current: Bool) -> Bool {
        guard accepts(claim, current: current) else { return false }
        state = .consumed
        return true
    }

    mutating func revoke() {
        // Page disappearance after handoff does not revoke an admitted player session.
        if state != .consumed { state = .revoked }
    }
}
