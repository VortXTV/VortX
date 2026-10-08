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
        remuxAttachTimeout: Double
    ) -> AwaitingMountDecision {
        guard ownerCurrent else { return .cancel }
        if remuxMounted { return .monitorRemux }
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
    static func hasStarted(positionSeconds: Double, avPlayerRenderedFrame: Bool) -> Bool {
        positionSeconds.isFinite && positionSeconds >= 0
            && (positionSeconds > 0 || avPlayerRenderedFrame)
    }

    static func shouldIgnoreIssuedAdvanceTick(
        positionSeconds: Double,
        avPlayerRenderedFrame: Bool
    ) -> Bool {
        !positionSeconds.isFinite || positionSeconds < 0
            || (positionSeconds == 0 && !avPlayerRenderedFrame)
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
