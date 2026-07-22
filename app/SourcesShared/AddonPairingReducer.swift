import Foundation

/// The pure decision core behind `AddonPairingView` (Install by QR / pair once, add many).
///
/// WHY THIS EXISTS: the add-then-Done install-loss race and the "marked installed on dispatch, not on confirm"
/// bug both live in the ROW LIFECYCLE, not in SwiftUI. Extracting that lifecycle into a value type with no
/// SwiftUI / engine / network dependency lets the tests exercise the REAL production logic directly (compile
/// this file alone) instead of a re-implemented mirror state machine (the mirror-test anti-pattern that blocked
/// the prior attempt). `AddonPairingView` owns an instance of this reducer, feeds it events, and performs the
/// side effects it asks for (resolve / install / ack / release).
///
/// THE INVARIANTS THIS ENFORCES:
///  - A delivery is identified by a DURABLE delivery id (relay-minted, stable across session-token rotation) and
///    a canonical URL, never the raw pasted string or the rotating session token alone. Duplicates collapse.
///  - A row is marked `.installed` ONLY on a CONFIRMED install outcome (the engine holds it), never on dispatch.
///  - Closing a session (phone Done) NEVER discards an in-flight install: a token is released for rotation only
///    once none of its deliveries are still resolving or installing (drain-before-release).
///  - Install results carry an attempt number; a stale result (superseded by a newer attempt) is ignored, so a
///    late retry cannot double-apply or resurrect a released session.
///  - Acks are idempotent and a confirmed install is never downgraded.

// MARK: - Transient-failure classification

/// The manifest-fetch rejection reasons, mirrored from `AddonURLGuard.Rejection` but kept dependency-free so the
/// retryable rule is testable without the networking stack. `AddonPairingView` maps the real rejection onto this.
public enum AddonFetchRejectionKind: Equatable {
    case invalidScheme
    case privateAddress
    case unresolvable
    case tooManyRedirects
}

/// Only an `unresolvable` (transport / DNS blip) is transient and worth a retry. A bad scheme, a private-address
/// SSRF block, or a redirect loop is TERMINAL: retrying re-fails identically, so it must never be presented as a
/// retryable (or, worse, an eventually-succeeding) outcome.
public func addonFetchIsRetryable(_ kind: AddonFetchRejectionKind) -> Bool {
    kind == .unresolvable
}

// MARK: - Outcomes crossing the reducer boundary

/// The CONFIRMED outcome of an install attempt, returned by `CoreBridge.installAddonConfirmed`. `installed` means
/// the engine actually holds the add-on now (polled, not merely dispatched); `alreadyInstalled` is a success, not
/// an error; `failed` carries whether a retry could plausibly succeed.
public enum AddonInstallOutcome: Equatable {
    case installed
    case alreadyInstalled
    case failed(retryable: Bool, message: String)
}

/// The outcome of validating a manifest WITHOUT installing it (`CoreBridge.previewAddonManifest`).
public enum AddonPreviewOutcome: Equatable {
    case ready(name: String)
    case alreadyInstalled(name: String)
    /// Validation / fetch failed. `retryable` is true only for a transient fetch failure.
    case rejected(retryable: Bool, message: String)
}

// MARK: - Model

/// One delivery from the phone, bound to its durable id + canonical identity + originating session token.
public struct AddonDelivery: Equatable {
    public let id: String            // durable delivery id minted by the relay (stable across token rotation)
    public let canonicalURL: String  // normalized identity used for de-duplication
    public let rawURL: String        // the string the phone pasted (the fetch input + display fallback)
    public let token: String         // the session token that carried this delivery (the ack target)

    public init(id: String, canonicalURL: String, rawURL: String, token: String) {
        self.id = id
        self.canonicalURL = canonicalURL
        self.rawURL = rawURL
        self.token = token
    }
}

/// Where a delivery is in its lifecycle ON THIS device.
public enum AddonRowState: Equatable {
    case resolving                              // fetching + validating the manifest
    case ready                                  // valid, awaiting the user's Install tap
    case installing                             // dispatched to the engine, awaiting CONFIRMATION
    case installed                              // confirmed present in the engine
    case failed(retryable: Bool, message: String)
}

/// One row: a delivery, its resolved name, its state, the current install attempt, and the last status acked
/// back to the relay (so the phone's Done can show the truth).
public struct AddonRow: Equatable, Identifiable {
    public let delivery: AddonDelivery
    public var name: String?
    public var state: AddonRowState
    public var attempt: Int
    public var acked: AddonAckStatus?
    public var id: String { delivery.id }
}

/// The terminal status the TV acknowledges back to the relay for a delivery.
public enum AddonAckStatus: String, Equatable {
    case installed
    case failed
}

/// A side effect the reducer asks `AddonPairingView` to perform. The reducer itself stays pure.
public enum AddonPairingEffect: Equatable {
    case resolve(AddonDelivery)                 // fetch + validate this manifest
    case install(AddonDelivery, attempt: Int)   // run the confirmed install for this delivery
    case ack(AddonDelivery, AddonAckStatus)     // report the confirmed terminal status to the relay
    case releaseToken(String)                   // this closed session has drained; safe to stop polling / rotate
}

// MARK: - Reducer

public struct AddonPairingReducer {
    public private(set) var rows: [AddonRow] = []

    // Tokens the phone has closed (Done seen) but which may still have in-flight installs to drain.
    private var closedTokens: Set<String> = []
    // Tokens already released for rotation. Sticky: once released, a late/stale action can't resurrect the
    // session (it will not be re-polled), which is the "attempt authority so a stale retry can't resurrect a
    // closed session" guarantee.
    private var releasedTokens: Set<String> = []

    public init() {}

    // MARK: Ingest the relay's live delivery list

    /// Merge the relay's list: append any delivery we do not already track (by durable id OR canonical URL) as a
    /// `.resolving` row and ask the caller to resolve it. Never removes or downgrades a row the user has acted on.
    /// De-duplication here is what makes a delivery install EXACTLY ONCE even if it arrives on several polls.
    public mutating func ingest(_ deliveries: [AddonDelivery]) -> [AddonPairingEffect] {
        var effects: [AddonPairingEffect] = []
        for delivery in deliveries {
            if rows.contains(where: { $0.delivery.id == delivery.id }) { continue }
            if rows.contains(where: { $0.delivery.canonicalURL == delivery.canonicalURL }) { continue }
            rows.append(AddonRow(delivery: delivery, name: nil, state: .resolving, attempt: 0, acked: nil))
            effects.append(.resolve(delivery))
        }
        return effects
    }

    // MARK: Resolution (preview) result

    public mutating func resolved(id: String, outcome: AddonPreviewOutcome) -> [AddonPairingEffect] {
        guard let i = index(id) else { return [] }
        switch outcome {
        case .ready(let name):
            rows[i].name = name
            rows[i].state = .ready
            // Finishing resolution moves the row out of the in-flight set, which can make a closed session
            // drainable (a URL added in the same window as Done, resolved but not installed).
            return maybeRelease()
        case .alreadyInstalled(let name):
            rows[i].name = name
            rows[i].state = .installed
            var effects = ackEffect(i, .installed)
            effects += maybeRelease()
            return effects
        case .rejected(let retryable, let message):
            rows[i].state = .failed(retryable: retryable, message: message)
            return maybeRelease()
        }
    }

    // MARK: Install lifecycle

    /// The user tapped Install (or Install all / Retry). Only a `.ready` row or a RETRYABLE-failed row is
    /// installable. Bumps the attempt and moves to `.installing`; the row is NOT marked installed here. Install
    /// stays allowed even after the session is released (installing is a pure engine op that needs no token),
    /// which keeps the Install button working as manual recovery.
    public mutating func install(id: String) -> [AddonPairingEffect] {
        guard let i = index(id) else { return [] }
        let installable: Bool
        switch rows[i].state {
        case .ready:
            installable = true
        case .failed(let retryable, _):
            installable = retryable
        default:
            installable = false
        }
        guard installable else { return [] }
        rows[i].attempt += 1
        rows[i].state = .installing
        return [.install(rows[i].delivery, attempt: rows[i].attempt)]
    }

    /// The user tapped Retry on a RETRYABLE-failed row. If the row never validated (no name -> the transient
    /// failure happened during resolve), re-resolve it; otherwise re-run the install. A terminal (non-retryable)
    /// failure has no Retry, so this is a no-op for it.
    public mutating func retry(id: String) -> [AddonPairingEffect] {
        guard let i = index(id) else { return [] }
        guard case .failed(let retryable, _) = rows[i].state, retryable else { return [] }
        if rows[i].name == nil {
            rows[i].state = .resolving
            return [.resolve(rows[i].delivery)]
        }
        return install(id: id)
    }

    /// Install every row currently `.ready` (the "Install all" button).
    public mutating func installAllReady() -> [AddonPairingEffect] {
        var effects: [AddonPairingEffect] = []
        for row in rows where row.state == .ready {
            effects += install(id: row.delivery.id)
        }
        return effects
    }

    /// A CONFIRMED install result for a delivery. Ignored unless it matches the row's current attempt and the row
    /// is still `.installing` (a stale or duplicate result is dropped -> exactly-once application). On success the
    /// row becomes `.installed` and the relay is acked `installed`; a terminal failure acks `failed` (truthful
    /// phone Done); a retryable failure stays actionable and is NOT acked (still pending on the relay).
    public mutating func installed(id: String, attempt: Int, outcome: AddonInstallOutcome) -> [AddonPairingEffect] {
        guard let i = index(id), rows[i].attempt == attempt, rows[i].state == .installing else { return [] }
        switch outcome {
        case .installed, .alreadyInstalled:
            rows[i].state = .installed
            var effects = ackEffect(i, .installed)
            effects += maybeRelease()
            return effects
        case .failed(let retryable, let message):
            rows[i].state = .failed(retryable: retryable, message: message)
            var effects: [AddonPairingEffect] = []
            if !retryable { effects += ackEffect(i, .failed) }
            effects += maybeRelease()
            return effects
        }
    }

    // MARK: Session close / drain

    /// The poll saw `closed == true` for a token (phone tapped Done). Records the close and drains: the token is
    /// released for rotation ONLY once none of its deliveries are still in flight, so an install dispatched just
    /// before Done is completed (and acked) before the session is abandoned. Idempotent.
    public mutating func closeSeen(token: String) -> [AddonPairingEffect] {
        closedTokens.insert(token)
        return maybeRelease()
    }

    /// True while any delivery for `token` is still resolving or installing (a dispatched-but-unconfirmed install
    /// counts as in flight). The poll loop uses this to keep a closed session alive until it drains.
    public func isInFlight(token: String) -> Bool {
        rows.contains { $0.delivery.token == token && ($0.state == .resolving || $0.state == .installing) }
    }

    /// True once the closed `token` has been released for rotation.
    public func isReleased(_ token: String) -> Bool { releasedTokens.contains(token) }

    // MARK: - Private

    private func index(_ id: String) -> Int? {
        rows.firstIndex(where: { $0.delivery.id == id })
    }

    /// Emit an ack effect for row `i`, unless the same status was already acked (idempotent, exactly-once ack).
    private mutating func ackEffect(_ i: Int, _ status: AddonAckStatus) -> [AddonPairingEffect] {
        if rows[i].acked == status { return [] }
        rows[i].acked = status
        return [.ack(rows[i].delivery, status)]
    }

    /// Release any closed token whose deliveries have finished draining (nothing resolving / installing).
    private mutating func maybeRelease() -> [AddonPairingEffect] {
        var effects: [AddonPairingEffect] = []
        for token in closedTokens where !releasedTokens.contains(token) {
            if !isInFlight(token: token) {
                releasedTokens.insert(token)
                effects.append(.releaseToken(token))
            }
        }
        return effects
    }
}
