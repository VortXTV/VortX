import Foundation

/// Pure admission and timing rules for the post-first-frame freeze watchdog. Buffering is deliberately
/// observable: AVPlayer can stay in its waiting state indefinitely, so treating that state as an exemption
/// leaves the visible spinner without any recovery owner.
enum PlayerMidPlaybackStallPolicy {
    static let pollIntervalSeconds: Double = 6
    static let ordinaryRecoveryTicks = 3
    static let bufferingRecoveryTicks = 5
    /// A recovery budget belongs to one source and must survive a brief restart. Only one full minute of
    /// continuously advancing playback earns a fresh budget, preventing reload loops that frame for one tick
    /// and then stall again forever.
    static let stableProgressTicksToResetRecoveryBudget = 10

    static func shouldObserve(
        hasStartedPlaying: Bool,
        isPaused: Bool,
        loadFailed: Bool,
        isLive: Bool,
        duration: Double,
        buffering _: Bool
    ) -> Bool {
        hasStartedPlaying
            && !isPaused
            && !loadFailed
            && !isLive
            && duration.isFinite
            && duration > 0
    }

    static func recoveryTickThreshold(buffering: Bool) -> Int {
        buffering ? bufferingRecoveryTicks : ordinaryRecoveryTicks
    }

    static func shouldResetRecoveryBudget(
        recoveries: Int,
        stableProgressTicks: Int
    ) -> Bool {
        recoveries > 0
            && stableProgressTicks >= stableProgressTicksToResetRecoveryBudget
    }
}
