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

    /// Seek-nudge tier (Beta 26 workstream B2): before spending a reload, a stall whose demuxer still
    /// holds a real cushion gets a tiny same-item seek to re-kick the decode pipeline.
    static let nudgeMinimumStallSeconds: Double = 6
    static let nudgeBufferedAheadThresholdSeconds: Double = 2
    static let maxSeekNudgesPerStallEpisode = 2

    static func shouldSeekNudge(
        stallOpenSeconds: Double,
        bufferedAheadSeconds: Double,
        nudgesIssued: Int
    ) -> Bool {
        guard nudgesIssued < maxSeekNudgesPerStallEpisode else { return false }
        return stallOpenSeconds >= nudgeMinimumStallSeconds
            && bufferedAheadSeconds > nudgeBufferedAheadThresholdSeconds
    }

    /// Buffered-retirement gate (workstream B3): an engine retirement with at least this much media
    /// still loaded prefers one same-engine reload at the playhead over an immediate demote/hop.
    static let bufferedReloadThresholdSeconds: Double = 10

    static func prefersBufferedReloadBeforeRetirement(bufferedAheadSeconds: Double) -> Bool {
        bufferedAheadSeconds >= bufferedReloadThresholdSeconds
    }
}
