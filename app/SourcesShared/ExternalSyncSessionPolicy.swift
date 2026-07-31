/// Exact provider sessions owned by one player lifecycle.
///
/// A playback binds when its item key or per-player token changes. Authentication boundaries invalidate
/// only that provider's owner; a same-token recovery cannot silently adopt the replacement account.
struct PlaybackProviderSessionSnapshot<TraktSession: Equatable & Sendable,
                                       SIMKLSession: Equatable & Sendable>: Sendable {
    let traktSessionID: TraktSession?
    let simklSessionID: SIMKLSession?
}

struct PlaybackScrobbleSessionOwnership<TraktSession: Equatable & Sendable,
                                        SIMKLSession: Equatable & Sendable>: Sendable {
    private var itemKey = ""
    private var playbackToken = ""
    private var traktSessionID: TraktSession?
    private var simklSessionID: SIMKLSession?

    mutating func beginPlayback(
        itemKey nextItemKey: String,
        playbackToken nextPlaybackToken: String,
        traktSessionID nextTraktSessionID: TraktSession?,
        simklSessionID nextSIMKLSessionID: SIMKLSession?
    ) -> Bool {
        guard nextItemKey != itemKey || nextPlaybackToken != playbackToken else { return false }
        itemKey = nextItemKey
        playbackToken = nextPlaybackToken
        traktSessionID = nextTraktSessionID
        simklSessionID = nextSIMKLSessionID
        return true
    }

    /// Attach an event that arrived before `playbackStarted`. It opens a latch scope but owns no provider
    /// account until a real start supplies a playback token.
    mutating func attach(itemKey nextItemKey: String) -> Bool {
        guard nextItemKey != itemKey else { return false }
        itemKey = nextItemKey
        playbackToken = ""
        traktSessionID = nil
        simklSessionID = nil
        return true
    }

    mutating func invalidateTrakt() {
        traktSessionID = nil
    }

    mutating func invalidateSIMKL() {
        simklSessionID = nil
    }

    var snapshot: PlaybackProviderSessionSnapshot<TraktSession, SIMKLSession> {
        PlaybackProviderSessionSnapshot(
            traktSessionID: traktSessionID,
            simklSessionID: simklSessionID
        )
    }
}

/// One proposed playback offset plus the credential session that authorized it.
struct AccountBoundResumeProposal<Session: Equatable & Sendable>: Sendable {
    let seconds: Double?
    let expectedSessionID: Session?
    let consumesInitial: Bool
    let requiresUnconsumedInitial: Bool

    init(
        seconds: Double?,
        expectedSessionID: Session?,
        consumesInitial: Bool,
        requiresUnconsumedInitial: Bool = false
    ) {
        self.seconds = seconds
        self.expectedSessionID = expectedSessionID
        self.consumesInitial = consumesInitial
        self.requiresUnconsumedInitial = requiresUnconsumedInitial
    }
}

/// One displayed remote resume value paired with the exact credential session that produced it.
/// Keeping the pair atomic prevents a value rendered under account A from being rebound to account B
/// if the user changes accounts before tapping the suggestion.
struct AccountBoundResumeSuggestion<Session: Equatable & Sendable>: Sendable {
    let seconds: Double
    let sessionID: Session

    var proposal: AccountBoundResumeProposal<Session> {
        AccountBoundResumeProposal(
            seconds: seconds,
            expectedSessionID: sessionID,
            consumesInitial: true
        )
    }
}

struct AccountBoundResumeAdmission: Sendable {
    let seconds: Double?
}

/// Mutable one-shot admission gate. A rejected account-bound proposal does not consume the offset, so a
/// stale or failed launch cannot erase it before a later valid presentation.
struct OneShotResumeAdmissionGate<Session: Equatable & Sendable>: Sendable {
    private(set) var isConsumed = false

    mutating func admit(
        _ proposal: AccountBoundResumeProposal<Session>,
        currentSessionID: Session?
    ) -> AccountBoundResumeAdmission? {
        if proposal.requiresUnconsumedInitial, isConsumed {
            return nil
        }
        if let expectedSessionID = proposal.expectedSessionID,
           currentSessionID != expectedSessionID {
            return nil
        }
        if proposal.consumesInitial {
            isConsumed = true
        }
        return AccountBoundResumeAdmission(seconds: proposal.seconds)
    }
}

/// A rail fetch must distinguish a valid empty snapshot from transport/auth failure.
enum ExternalRailFetchOutcome<Value> {
    case success([Value])
    case failure
}

enum ExternalRailSnapshotPolicy {
    static func resolved<Value>(
        current: [Value],
        outcome: ExternalRailFetchOutcome<Value>
    ) -> [Value] {
        switch outcome {
        case .success(let items): return items
        case .failure: return current
        }
    }
}
