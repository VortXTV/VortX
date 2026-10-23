import Foundation

/// The old controller can disappear before its replacement is constructed. Carry the exact
/// handoff context, but read Play/Pause at construction/admission so input during teardown wins.
struct AppleEngineSurfaceTransfer<Owner: Equatable, Context: Equatable> {
    let retiringOwner: Owner
    let context: Context

    func startsPaused(requestedPause: Bool, currentContext: Context, playbackExited: Bool) -> Bool {
        !playbackExited && requestedPause && context == currentContext
    }

    func accepts(observedOwner: Owner, activeOwner: Owner?, currentContext: Context) -> Bool {
        observedOwner != retiringOwner && observedOwner == activeOwner && context == currentContext
    }
}

/// Direct starts and asynchronously attached remuxes have distinct, bounded startup phases.
/// Keep polling the current mount so a healthy late attach cannot be demoted by a one-shot sample.
enum AppleAVStartWatchdogPolicy {
    static let remoteAttachSchedulingMarginSeconds: Double = 3
    static let nativePreflightTimeoutSeconds: Double = 10

    /// Native DV metadata is preparation, not decoding. Only the engine's successful exact-item attach
    /// moves this state forward; a timeout uses the existing no-criteria fail-soft attach, never guessed HDR.
    struct NativePreflightState {
        enum Phase: Equatable {
            case notRequired
            case preparing(generation: UInt64)
            case attached(generation: UInt64, uptime: Double)
            case retired
        }

        private(set) var phase: Phase = .notRequired

        mutating func begin(generation: UInt64) { phase = .preparing(generation: generation) }
        func isPreparing(generation: UInt64) -> Bool { phase == .preparing(generation: generation) }

        mutating func didAttach(generation: UInt64, uptime: Double) {
            guard isPreparing(generation: generation) else { return }
            phase = .attached(generation: generation, uptime: uptime)
        }

        mutating func retire() { phase = .retired }

        func currentPhase(generation: UInt64, terminal: Bool) -> Phase {
            guard !terminal else { return .retired }
            switch phase {
            case .preparing(let owner), .attached(let owner, _):
                return owner == generation ? phase : .retired
            case .notRequired, .retired:
                return phase
            }
        }
    }

    /// Charge only active time after the real attach. The first sample can straddle a viewer pause, for
    /// which the UI clock deliberately retains no history. Subtracting the entire pre-attach interval is
    /// conservative in that one sample: it may undercharge, but can never bill metadata or paused time as
    /// decoding. Normal 250ms polling is exact; subsequent samples cannot reset the accumulated budget.
    struct NativeDecodeClock {
        private var previousUptime: Double
        private var previousActiveTime: Double
        private var accumulated = 0.0

        init(uptime: Double, activeTime: Double) {
            previousUptime = uptime
            previousActiveTime = activeTime
        }

        mutating func elapsed(
            phase: NativePreflightState.Phase,
            uptime: Double,
            activeTime: Double
        ) -> Double? {
            defer {
                previousUptime = uptime
                previousActiveTime = activeTime
            }
            guard case .attached(_, let attachedAt) = phase else { return nil }
            let activeDelta = max(0, activeTime - previousActiveTime)
            let beforeAttach = max(0, attachedAt - previousUptime)
            accumulated += max(0, activeDelta - beforeAttach)
            return accumulated
        }
    }

    enum AwaitingMountDecision: Equatable {
        case cancel
        case keepWaiting
        case monitorRemux
        case demote
    }

    static func awaitingMountDecision(
        elapsed: Double,
        ownerCurrent: Bool,
        remuxMounted: Bool,
        remuxExpected: Bool,
        directTimeout: Double,
        remuxAttachTimeout: Double,
        nativePhase: NativePreflightState.Phase = .notRequired,
        nativeDecodeElapsed: Double? = nil
    ) -> AwaitingMountDecision {
        guard ownerCurrent else { return .cancel }
        if nativePhase == .retired { return .cancel }
        if remuxMounted { return .monitorRemux }
        switch nativePhase {
        case .preparing:
            // The independent engine deadline bounds preparation even if asset.load ignores cancellation.
            return .keepWaiting
        case .attached:
            return (nativeDecodeElapsed ?? 0) < directTimeout ? .keepWaiting : .demote
        case .notRequired, .retired:
            break
        }
        if elapsed < directTimeout { return .keepWaiting }
        if remuxExpected, elapsed < remuxAttachTimeout { return .keepWaiting }
        return .demote
    }

    static func remoteAttachTimeout(
        controlResourceTimeout: Double,
        signallingTimeout: Double
    ) -> Double {
        max(0, controlResourceTimeout) + max(0, signallingTimeout)
            + remoteAttachSchedulingMarginSeconds
    }
}

/// Startup and recovery rules shared by every Apple player surface. A timer belongs to the source
/// that armed it, and AVPlayer can prove its first rendered frame while its media clock is still zero.
enum ApplePlaybackStartPolicy {
    struct AVPlayerEvidence: Equatable {
        let requiresVideoFrame: Bool
        let renderedVideoFrame: Bool
        let settledNativeClockAdvanced: Bool
        var positionSettled = true
    }

    /// Native audio-only/HLS playback may never expose video tracks or a player-layer frame. Preserve that
    /// route with observed native-clock advancement, never an initial resume position or a seek target.
    /// Known video routes (DV and remux) still require the exact item's existing picture receipt.
    struct NativeClockProgress: Equatable {
        private var generation: UInt64?
        private var previousPosition: Double?
        private var advanced = false
        private var pendingSeekRequest: UInt64?

        mutating func reset(generation: UInt64?) {
            self.generation = generation
            previousPosition = nil
            advanced = false
            pendingSeekRequest = nil
        }

        mutating func beginSeek(generation: UInt64, requestID: UInt64) {
            guard self.generation == generation else { return }
            previousPosition = nil
            advanced = false
            pendingSeekRequest = requestID
        }

        mutating func finishSeek(generation: UInt64, requestID: UInt64) {
            guard self.generation == generation, pendingSeekRequest == requestID else { return }
            pendingSeekRequest = nil
            previousPosition = nil
        }

        func isSeekPending(generation: UInt64) -> Bool {
            self.generation == generation && pendingSeekRequest != nil
        }

        mutating func observe(generation: UInt64, playerSeconds: Double,
                              transportRunning: Bool, positionSettled: Bool) {
            guard self.generation == generation else { return }
            guard pendingSeekRequest == nil, playerSeconds.isFinite, playerSeconds >= 0,
                  transportRunning, positionSettled else {
                previousPosition = nil
                return
            }
            if let previousPosition, playerSeconds > previousPosition { advanced = true }
            previousPosition = playerSeconds
        }

        func hasAdvanced(generation: UInt64) -> Bool {
            self.generation == generation && advanced
        }
    }

    static func hasStarted(positionSeconds: Double, positionSettled: Bool = true,
                           avPlayerEvidence: AVPlayerEvidence? = nil) -> Bool {
        guard positionSeconds.isFinite, positionSeconds >= 0, positionSettled else { return false }
        guard let avPlayerEvidence else { return positionSeconds > 0 }
        guard avPlayerEvidence.positionSettled else { return false }
        return avPlayerEvidence.renderedVideoFrame
            || (!avPlayerEvidence.requiresVideoFrame && avPlayerEvidence.settledNativeClockAdvanced)
    }

    static func shouldIgnoreIssuedAdvanceTick(
        positionSeconds: Double,
        positionSettled: Bool = true,
        avPlayerEvidence: AVPlayerEvidence? = nil
    ) -> Bool {
        !hasStarted(positionSeconds: positionSeconds, positionSettled: positionSettled,
                    avPlayerEvidence: avPlayerEvidence)
    }

    static func genericLoadTimeoutDefersToRemuxWatchdog(
        avPlayerActive: Bool,
        remuxPendingOrMounted: Bool
    ) -> Bool {
        avPlayerActive && remuxPendingOrMounted
    }

    static func loadTimeoutOwnerIsCurrent<Token: Equatable>(
        capturedEpisodeGeneration: Int,
        currentEpisodeGeneration: Int,
        capturedSourceGeneration: Int,
        currentSourceGeneration: Int,
        capturedResumeGeneration: Int,
        currentResumeGeneration: Int,
        capturedLoadToken: Token?,
        currentLoadToken: Token?
    ) -> Bool {
        let loadOwnerCurrent = capturedLoadToken == nil || capturedLoadToken == currentLoadToken
        return capturedEpisodeGeneration == currentEpisodeGeneration
            && capturedSourceGeneration == currentSourceGeneration
            && capturedResumeGeneration == currentResumeGeneration
            && loadOwnerCurrent
    }
}

/// Track inventories arrive in stages. Keep explicit choices pending until their own media type
/// can act, rather than converting an early empty subtitle inventory into a permanent Off choice.
enum AppleTrackRecoveryPolicy {
    enum AudioAction: Equatable {
        case retain
        case reapply(Int)
        case automatic(Int)
    }

    enum SubtitleAction: Equatable {
        case retain
        case selectEmbedded(Int)
        case applyImmediately
    }

    static func audioAction(
        choice: PlayerRecoveryAudioChoice,
        tracks: [MPVTrack],
        automaticID: Int?
    ) -> AudioAction {
        let candidates = tracks.map {
            PlayerRecoveryAudioChoice.Candidate(
                id: $0.id, language: $0.lang, title: $0.title, selectable: $0.isSelectable)
        }
        guard candidates.contains(where: \.selectable) else { return .retain }
        if let id = PlayerRecoveryAudioChoice.matchingID(for: choice, in: candidates) {
            return .reapply(id)
        }
        return automaticID.map(AudioAction.automatic) ?? .retain
    }

    static func subtitleAction(
        choice: SubtitleChoice,
        tracks: [MPVTrack],
        pooledChoiceAvailable: Bool
    ) -> SubtitleAction {
        switch choice {
        case .off, .external:
            return .applyImmediately
        case .pooled:
            return pooledChoiceAvailable ? .applyImmediately : .retain
        case let .embedded(lang, title):
            let language = lang.lowercased()
            let title = title.lowercased()
            if let exact = tracks.first(where: {
                $0.isSelectable && $0.lang.lowercased() == language && $0.title.lowercased() == title
            }) {
                return .selectEmbedded(exact.id)
            }
            if let match = tracks.first(where: {
                $0.isSelectable && $0.lang.lowercased() == language
            }) {
                return .selectEmbedded(match.id)
            }
            return .retain
        }
    }
}
