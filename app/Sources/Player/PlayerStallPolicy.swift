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

/// The engine-side admission contract for a post-first-frame AVPlayer replacement.  A replacement is much
/// more invasive than a seek nudge: it tears down AVFoundation's item-local decoder, media selections and
/// display route.  It is therefore available only for a proven surface freeze on a healthy *local* HLS mount
/// which still has enough published media to make a new item useful. Producer activity is ordinary rebuffer
/// evidence at first, but becomes affirmative consumer-wedge evidence if AVPlayer's own media clock stays
/// frozen for the bounded recovery window.
enum AVPlayerMidPlaybackRecoveryPolicy {
    enum TerminalProof: Equatable {
        case none
        case producerEnded
        case producerFailed
        case itemFailed
        case sustainedSurfaceStall
    }

    enum RetainReason: Equatable {
        case staleOwnership
        case userPaused
        case nonLocalRemux
        case missingProgressEvidence
        case producerProgress
        case inputInFlight
        case playlistProgress
        case noSurfaceStall
        case insufficientPublishedTail
        case replacementAlreadyUsed
    }

    enum Action: Equatable {
        case retain(RetainReason)
        case replaceFreshItem
        case terminal(TerminalProof)
    }

    struct Evidence: Equatable {
        let generation: UInt64
        let ownershipMatches: Bool
        let playbackRequested: Bool
        let isLocalRemux: Bool
        let hasPreviousProgressSample: Bool
        let producerProgressed: Bool
        let inputOpenInFlight: Bool
        let playlistProgressed: Bool
        let surfaceStalled: Bool
        let surfaceStallElapsedSeconds: TimeInterval
        let publishedAheadSeconds: Double
        let terminalProof: TerminalProof

        init(
            generation: UInt64,
            ownershipMatches: Bool,
            playbackRequested: Bool,
            isLocalRemux: Bool,
            hasPreviousProgressSample: Bool,
            producerProgressed: Bool,
            inputOpenInFlight: Bool,
            playlistProgressed: Bool,
            surfaceStalled: Bool,
            surfaceStallElapsedSeconds: TimeInterval,
            publishedAheadSeconds: Double,
            terminalProof: TerminalProof
        ) {
            self.generation = generation
            self.ownershipMatches = ownershipMatches
            self.playbackRequested = playbackRequested
            self.isLocalRemux = isLocalRemux
            self.hasPreviousProgressSample = hasPreviousProgressSample
            self.producerProgressed = producerProgressed
            self.inputOpenInFlight = inputOpenInFlight
            self.playlistProgressed = playlistProgressed
            self.surfaceStalled = surfaceStalled
            self.surfaceStallElapsedSeconds = surfaceStallElapsedSeconds
            self.publishedAheadSeconds = publishedAheadSeconds
            self.terminalProof = terminalProof
        }
    }

    /// One replacement may be spent by an exact remux mount/source. A new item on that same mount retains the
    /// spent budget, while a new mount starts fresh. One minute of monotonic, positive media-clock progress
    /// demonstrates that a previously replaced item
    /// really recovered rather than merely framed once before freezing again. Observer cadence is deliberately
    /// irrelevant: a 0.25 s callback must not turn ten samples into a fake minute of healthy playback.
    struct RecoveryBudget: Equatable {
        static let sustainedProgressSecondsToReset: TimeInterval = 60

        private(set) var mountIdentity: UInt64?
        private(set) var replacementUsed = false
        private(set) var stableProgressSinceUptime: TimeInterval?
        private var lastMediaPosition: Double?

        mutating func reset(for mountIdentity: UInt64) {
            guard self.mountIdentity != mountIdentity else { return }
            self.mountIdentity = mountIdentity
            replacementUsed = false
            stableProgressSinceUptime = nil
            lastMediaPosition = nil
        }

        mutating func recordReplacement(for mountIdentity: UInt64) {
            reset(for: mountIdentity)
            replacementUsed = true
            stableProgressSinceUptime = nil
        }

        /// Returns true only for a real positive media-clock receipt. The engine uses that edge to reset the
        /// active hard-stall timer; stable replacement-budget renewal additionally requires a full minute.
        @discardableResult
        mutating func recordMediaPosition(
            _ position: Double,
            mountIdentity: UInt64,
            now: TimeInterval
        ) -> Bool {
            reset(for: mountIdentity)
            guard position.isFinite, now.isFinite else { return false }
            defer { lastMediaPosition = position }
            guard let lastMediaPosition else { return false }
            guard position > lastMediaPosition else {
                stableProgressSinceUptime = nil
                return false
            }
            if stableProgressSinceUptime == nil { stableProgressSinceUptime = now }
            if replacementUsed,
               let stableProgressSinceUptime,
               now >= stableProgressSinceUptime,
               now - stableProgressSinceUptime >= Self.sustainedProgressSecondsToReset {
                replacementUsed = false
                self.stableProgressSinceUptime = nil
            }
            return true
        }
    }

    /// Generation-owned monotonic origin for only an *uninterrupted* hard surface stall. Any contrary health
    /// evidence clears the origin, so the escalation window cannot accumulate across a producer's ordinary
    /// rebuffering progress. Invalid clocks fail open to a fresh zero-duration observation.
    struct HardStallTimer: Equatable {
        private(set) var generation: UInt64?
        private(set) var sinceUptime: TimeInterval?

        mutating func elapsed(
            generation: UInt64,
            hardStallObserved: Bool,
            now: TimeInterval
        ) -> TimeInterval {
            guard hardStallObserved, now.isFinite else {
                reset()
                return 0
            }
            guard self.generation == generation, let sinceUptime else {
                self.generation = generation
                self.sinceUptime = now
                return 0
            }
            guard now >= sinceUptime else { return 0 }
            return now - sinceUptime
        }

        mutating func reset() {
            generation = nil
            sinceUptime = nil
        }
    }

    /// A frozen AVPlayer clock despite a moving producer or a useful already-published HLS window is a consumer
    /// wedge, not ordinary source starvation. Give AVFoundation twelve seconds to settle before one fresh item is
    /// admitted. The same threshold deliberately applies to an already-rich published window: a byte-budget
    /// parked producer need not manufacture a new segment merely to prove that the current mount is useful.
    static let consumerWedgeRecoverySeconds: TimeInterval = 12

    /// After this much uninterrupted frozen-surface evidence with no producer/input/playlist activity, keeping
    /// the item is no longer an ordinary rebuffer decision. The caller maps this terminal proof to its existing
    /// source-hop/error path. The value is intentionally longer than the outer 30-second first recovery so a
    /// slow healthy remux has multiple chances to publish progress before it is abandoned.
    static let sustainedSurfaceStallEscalationSeconds: TimeInterval = 60

    static func action(
        evidence: Evidence,
        replacementAlreadyUsed: Bool
    ) -> Action {
        // A user pause is an absolute intent boundary. Terminal delivery is deferred by the engine until Play,
        // so a background end/failure cannot turn a deliberate pause into a replacement or autoplay.
        guard evidence.ownershipMatches else { return .retain(.staleOwnership) }
        guard evidence.playbackRequested else { return .retain(.userPaused) }
        guard evidence.terminalProof == .none else { return .terminal(evidence.terminalProof) }
        guard !evidence.inputOpenInFlight else { return .retain(.inputInFlight) }
        guard evidence.surfaceStalled else { return .retain(.noSurfaceStall) }
        let hasUsefulPublishedTail = PlayerMidPlaybackStallPolicy.prefersBufferedReloadBeforeRetirement(
            bufferedAheadSeconds: evidence.publishedAheadSeconds)
        let shouldEscalate = evidence.surfaceStallElapsedSeconds.isFinite
            && evidence.surfaceStallElapsedSeconds >= sustainedSurfaceStallEscalationSeconds
        if shouldEscalate,
           !evidence.producerProgressed,
           !evidence.playlistProgressed,
           (!evidence.isLocalRemux || !hasUsefulPublishedTail || replacementAlreadyUsed) {
            return .terminal(.sustainedSurfaceStall)
        }
        if replacementAlreadyUsed, evidence.producerProgressed {
            return .retain(.producerProgress)
        }
        if replacementAlreadyUsed, evidence.playlistProgressed {
            return .retain(.playlistProgress)
        }
        let sustainedConsumerWedge = evidence.surfaceStallElapsedSeconds.isFinite
            && evidence.surfaceStallElapsedSeconds >= consumerWedgeRecoverySeconds
            && (evidence.producerProgressed || evidence.playlistProgressed || hasUsefulPublishedTail)
        if sustainedConsumerWedge, evidence.isLocalRemux {
            guard !replacementAlreadyUsed else { return .retain(.replacementAlreadyUsed) }
            return .replaceFreshItem
        }
        guard !evidence.producerProgressed else { return .retain(.producerProgress) }
        guard !evidence.playlistProgressed else { return .retain(.playlistProgress) }
        if shouldEscalate,
           (!evidence.isLocalRemux
                || !PlayerMidPlaybackStallPolicy.prefersBufferedReloadBeforeRetirement(
                    bufferedAheadSeconds: evidence.publishedAheadSeconds)
                || replacementAlreadyUsed) {
            return .terminal(.sustainedSurfaceStall)
        }
        guard evidence.isLocalRemux else { return .retain(.nonLocalRemux) }
        guard evidence.hasPreviousProgressSample else { return .retain(.missingProgressEvidence) }
        guard hasUsefulPublishedTail else { return .retain(.insufficientPublishedTail) }
        guard !replacementAlreadyUsed else { return .retain(.replacementAlreadyUsed) }
        return .replaceFreshItem
    }
}

/// Item-end and CoreMedia failure recovery own an event-local producer receipt.  They must not reuse the
/// surface-stall watchdog's baseline because a healthy title may reach a growing playlist edge without ever
/// opening that watchdog.  This pure seam makes the required post-event advancement explicit.
enum AVPlayerEventRecoveryPolicy {
    static let observationPollInterval: Duration = .milliseconds(250)
    static let observationWindowSeconds: TimeInterval = 6
    static let usefulPublishedWindowSeconds: Double = 10

    struct ProducerReceipt: Equatable {
        let producedBytes: Int
        let inputBytesRead: Int64?
        let segmentCount: Int
        let initPublished: Bool
        let signalingPublished: Bool
    }

    static func producerAdvanced(from previous: ProducerReceipt, to current: ProducerReceipt) -> Bool {
        current.producedBytes > previous.producedBytes
            || (current.inputBytesRead ?? -1) > (previous.inputBytesRead ?? -1)
            || current.segmentCount > previous.segmentCount
            || (!previous.initPublished && current.initPublished)
            || (!previous.signalingPublished && current.signalingPublished)
    }

    /// A `-1008`/item-end replacement reloads the HLS playlist, so immediate admission needs a newly closed
    /// playlist segment, not merely producer bytes still accumulating in an open segment. Init/signalling and
    /// byte receipts remain useful diagnostics, but cannot prove a fresh AVPlayerItem sees different media.
    static func playlistAdvanced(from previous: ProducerReceipt, to current: ProducerReceipt) -> Bool {
        current.segmentCount > previous.segmentCount
    }

    /// A fresh HLS item is useful either after a producer advancement observed *after* the event, or when the
    /// same healthy mount still exposes enough existing player-window media. The latter covers a byte-budget
    /// parked producer without treating source starvation (no advance and no useful window) as a reload case.
    static func admitsFreshItem(
        producerAdvanced: Bool,
        inputOpenInFlight: Bool,
        publishedAheadSeconds: Double,
        publishedWindowSeconds: Double
    ) -> Bool {
        guard !inputOpenInFlight else { return false }
        guard producerAdvanced else {
            return publishedAheadSeconds >= usefulPublishedWindowSeconds
                || publishedWindowSeconds >= usefulPublishedWindowSeconds
        }
        return true
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
