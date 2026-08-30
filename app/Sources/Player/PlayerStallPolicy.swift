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

/// Detects the rapid cache-empty loop that a coarse playhead watchdog cannot see: mpv can briefly advance
/// between rebuffer events, resetting a "frozen for N polls" counter while remaining unwatchable. The caller
/// supplies only eligible buffering-start transitions, keeping startup, live playback, seeks and user pauses
/// outside this policy.
struct PlayerRapidBufferingRecoveryState: Equatable {
    enum Action: Equatable {
        case none
        case reloadSameSource
        case hopSource
    }

    static let requiredStarts = 6
    static let windowSeconds: TimeInterval = 12

    static func suppressionDeadline(from now: TimeInterval) -> TimeInterval {
        now + windowSeconds
    }

    static func isSuppressed(now: TimeInterval, until deadline: TimeInterval) -> Bool {
        now < deadline
    }

    private(set) var bufferingStarts: [TimeInterval] = []
    private(set) var hasRecoveredInCurrentProgressBudget = false

    mutating func recordBufferingStart(at now: TimeInterval) -> Action {
        bufferingStarts.removeAll { now - $0 > Self.windowSeconds }
        guard bufferingStarts.last != now else { return .none }
        bufferingStarts.append(now)
        guard bufferingStarts.count >= Self.requiredStarts else { return .none }

        bufferingStarts.removeAll()
        if hasRecoveredInCurrentProgressBudget {
            return .hopSource
        }
        hasRecoveredInCurrentProgressBudget = true
        return .reloadSameSource
    }

    /// A new title, source, episode, engine, explicit user interruption or terminal exit gets no inherited
    /// history. `preservingProgressBudget` is used only immediately after the first automatic reload: a second
    /// rapid loop on that source must escalate instead of reloading forever.
    mutating func reset(preservingProgressBudget: Bool = false) {
        bufferingStarts.removeAll()
        if !preservingProgressBudget {
            hasRecoveredInCurrentProgressBudget = false
        }
    }

    /// Mirrors the existing one-minute stable-progress budget. Only sustained playback earns a fresh same-source
    /// recovery after an earlier rapid-starvation episode.
    mutating func resetAfterStableProgress() {
        reset()
    }
}

/// Semantic audio intent carried only across an automatic replacement of the same title. Engine track IDs are
/// mount-local, so recovery resolves an exact normalized language/title pair first, then a language-only match.
struct PlayerRecoveryAudioChoice: Equatable {
    struct Candidate: Equatable {
        let id: Int
        let language: String
        let title: String
        let selectable: Bool
    }

    let language: String
    let title: String

    static func matchingID(for choice: PlayerRecoveryAudioChoice, in candidates: [Candidate]) -> Int? {
        let language = normalized(choice.language)
        let title = normalized(choice.title)
        if let exact = candidates.first(where: {
            $0.selectable
                && normalized($0.language) == language
                && normalized($0.title) == title
        }) {
            return exact.id
        }
        return candidates.first(where: {
            $0.selectable && normalized($0.language) == language
        })?.id
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
