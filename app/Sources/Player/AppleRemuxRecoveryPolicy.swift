import Foundation

/// The remux producer's `failed` receipt is terminal. It must never be treated as a
/// progress-watch sample: waiting for the ordinary stall window leaves a dead AV item
/// mounted while a stale watchdog can later touch a replacement episode.
///
/// This is deliberately independent of AVFoundation and the UI so both Apple surfaces
/// use the same bounded decision and can exercise it in a tiny harness.
enum AppleRemuxRecoveryPolicy {
    enum Decision: Equatable {
        case cancel
        case hopSource
        case demoteEngine
    }

    static func terminalDecision(
        failed: Bool,
        inputProvablyDead: Bool,
        ownerCurrent: Bool,
        hasStartedPlaying: Bool
    ) -> Decision {
        guard ownerCurrent, !hasStartedPlaying, failed else { return .cancel }
        return inputProvablyDead ? .hopSource : .demoteEngine
    }

    /// A delayed incomplete-evidence callback may only mutate state when it still names the parked advance.
    /// An old committed token is not a valid owner once a pending advance exists.
    static func canAcceptDeferredEvidence(
        ownerCurrent: Bool,
        pendingAdvanceExists: Bool,
        callbackMatchesPending: Bool
    ) -> Bool {
        ownerCurrent && (!pendingAdvanceExists || callbackMatchesPending)
    }
}
