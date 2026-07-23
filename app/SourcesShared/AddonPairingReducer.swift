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

// MARK: - Shared canonical identity + safe numeric coercion (dependency-free, so the harness tests them)

/// The ONE query/fragment-safe canonical identity rule for an add-on manifest URL, shared by the QR install
/// path (`CoreBridge.normalizedAddonURL`) and the reorder canonical rule (H4 / reorder H3 = one implementation).
///
/// It lowercases the scheme + host, DROPS the fragment (never part of identity), PRESERVES the query (a
/// configured add-on carries its token/config there, so two configs of the same add-on are distinct identities),
/// and ensures the PATH — never the whole absolute string — ends in `/manifest.json`. That path-based check is
/// what fixes the two defects the review found:
///   - `.../manifest.json?token=AbC` is NOT corrupted into `.../manifest.json/manifest.json?token=AbC`
///     (the old `absoluteString.hasSuffix("manifest.json")` was false because the string ends in the query);
///   - `.../addon?next=manifest.json` is correctly treated as a NON-manifest path and suffixed (the old check
///     wrongly accepted it because the absolute string ended in `manifest.json` via the query).
/// Returns nil for a non-http(s) URL or one with no host.
public func canonicalAddonIdentity(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var comps = URLComponents(string: trimmed),
          let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = comps.host, !host.isEmpty else { return nil }
    comps.scheme = scheme
    comps.host = host.lowercased()
    comps.fragment = nil
    var path = comps.path
    if !path.lowercased().hasSuffix("/manifest.json") {
        if path.isEmpty {
            path = "/manifest.json"
        } else if path.hasSuffix("/") {
            path += "manifest.json"
        } else {
            path += "/manifest.json"
        }
    }
    comps.path = path
    return comps.url?.absoluteString
}

/// Coerce a possibly-hostile remote numeric (a JSON `Double` that may be NaN / ±inf / far past `Int.max`) into a
/// bounded, non-negative `Int` WITHOUT trapping. `Int(Double.nan)` and `Int(1e30)` both crash (the reproduced
/// exit 133 for the worker `rev`); this clamps instead. Missing / non-finite / negative -> 0; anything at or
/// above `Int.max` clamps to `Int.max`. Used for the worker revision so a poisoned `rev` can never crash the app.
public func safeRevision(_ value: Double?) -> Int {
    guard let value, value.isFinite, value > 0 else { return 0 }
    if value >= Double(Int.max) { return Int.max }
    return Int(value)
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
    case resolve(AddonDelivery)                              // fetch + validate this manifest
    case install(AddonDelivery, attempt: Int)               // run the confirmed install for this delivery
    /// Report the confirmed terminal status to the relay. Carries the local install `attempt` so the ack asserts
    /// which attempt produced it (H3 attempt authority): a stale ack from a superseded attempt is distinguishable
    /// by the worker and cannot overwrite a newer one. `attempt` is 0 for an already-installed dedupe ack (no
    /// local install ran).
    case ack(AddonDelivery, AddonAckStatus, attempt: Int)
    case releaseToken(String)                               // this closed session has drained; safe to rotate
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

    // H7 cross-session dedupe: a NEW delivery id (a fresh session/token re-delivering a URL we already hold)
    // collapses onto the existing row instead of adding a duplicate, but the worker minted a distinct delivery
    // for it and is waiting for an ack on THAT id. `dedupeAckedIds` makes the already-installed ack for such a
    // duplicate fire EXACTLY ONCE; `pendingDedupe` stashes duplicates that arrive while the canonical row is
    // still resolving/installing, so they are acked the instant it confirms installed.
    private var dedupeAckedIds: Set<String> = []
    private var pendingDedupe: [String: [AddonDelivery]] = [:]   // canonicalURL -> deliveries awaiting confirm

    public init() {}

    // MARK: Ingest the relay's live delivery list

    /// Merge the relay's list: append any delivery we do not already track (by durable id OR canonical URL) as a
    /// `.resolving` row and ask the caller to resolve it. Never removes or downgrades a row the user has acted on.
    /// De-duplication here is what makes a delivery install EXACTLY ONCE even if it arrives on several polls.
    public mutating func ingest(_ deliveries: [AddonDelivery]) -> [AddonPairingEffect] {
        var effects: [AddonPairingEffect] = []
        for delivery in deliveries {
            if rows.contains(where: { $0.delivery.id == delivery.id }) { continue }
            if let existing = rows.first(where: { $0.delivery.canonicalURL == delivery.canonicalURL }) {
                // H7: a DIFFERENT delivery id for a canonical URL we already track (a new session re-delivering
                // the same add-on). Never add a duplicate row, but do NOT silently drop it: if the canonical row
                // is already CONFIRMED installed, ack THIS delivery installed now (once); otherwise stash it so
                // it is acked the moment the canonical row confirms.
                if dedupeAckedIds.contains(delivery.id) { continue }
                if existing.state == .installed {
                    dedupeAckedIds.insert(delivery.id)
                    effects.append(.ack(delivery, .installed, attempt: 0))
                } else {
                    var list = pendingDedupe[delivery.canonicalURL] ?? []
                    if !list.contains(where: { $0.id == delivery.id }) { list.append(delivery) }
                    pendingDedupe[delivery.canonicalURL] = list
                }
                continue
            }
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
            // C1 AUTO-INSTALL (the CEO's core requirement): a validated delivery installs itself on arrival — no
            // second tap. Move straight to `.installing` and EMIT the install effect. The on-screen Install
            // button is now recovery-only (it re-drives a `.ready` row or retries a retryable failure). Because
            // the row is now in flight, a session closed in this same window keeps draining until the auto-install
            // CONFIRMS (outliving-coordinator / drain-before-release: a dispatched-unconfirmed install is never
            // dropped by Done or rotation).
            return autoInstall(i)
        case .alreadyInstalled(let name):
            rows[i].name = name
            rows[i].state = .installed
            var effects = ackEffect(i, .installed)
            effects += flushDedupe(rows[i].delivery.canonicalURL)
            effects += maybeRelease()
            return effects
        case .rejected(let retryable, let message):
            rows[i].state = .failed(retryable: retryable, message: message)
            var effects: [AddonPairingEffect] = []
            // H1: a TERMINAL (non-retryable) preview rejection is a final outcome — ack it `failed` so the worker
            // and the phone's Done never wait forever. A retryable rejection stays actionable and un-acked (still
            // genuinely pending), and its Retry re-resolves.
            if !retryable { effects += ackEffect(i, .failed) }
            effects += maybeRelease()
            return effects
        }
    }

    /// C1: emit the install effect for a freshly-validated row WITHOUT a user tap. Bumps the attempt and moves to
    /// `.installing`; the row is NOT marked installed here (only a CONFIRMED `installed(...)` result does that).
    private mutating func autoInstall(_ i: Int) -> [AddonPairingEffect] {
        rows[i].attempt += 1
        rows[i].state = .installing
        return [.install(rows[i].delivery, attempt: rows[i].attempt)]
    }

    // MARK: Install lifecycle

    /// RECOVERY install trigger. Auto-install (`resolved(.ready)`) is the primary path, so this is the manual
    /// fallback: it re-drives a row that is still `.ready` (e.g. a future non-auto path) or a RETRYABLE-failed
    /// row. Only those two states are installable. Bumps the attempt and moves to `.installing`; the row is NOT
    /// marked installed here. Install stays allowed even after the session is released (installing is a pure
    /// engine op that needs no token), which keeps the recovery button working after Done.
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
            effects += flushDedupe(rows[i].delivery.canonicalURL)
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
    /// Carries the row's current install `attempt` so the worker can reject a stale ack (H3 attempt authority).
    private mutating func ackEffect(_ i: Int, _ status: AddonAckStatus) -> [AddonPairingEffect] {
        if rows[i].acked == status { return [] }
        rows[i].acked = status
        return [.ack(rows[i].delivery, status, attempt: rows[i].attempt)]
    }

    /// H7: once a canonical row is CONFIRMED installed, ack every duplicate delivery (a different id/token from a
    /// separate session for the same URL) that arrived while it was still resolving/installing. Exactly-once per
    /// duplicate id.
    private mutating func flushDedupe(_ canonicalURL: String) -> [AddonPairingEffect] {
        guard let list = pendingDedupe[canonicalURL] else { return [] }
        pendingDedupe[canonicalURL] = nil
        var effects: [AddonPairingEffect] = []
        for duplicate in list where !dedupeAckedIds.contains(duplicate.id) {
            dedupeAckedIds.insert(duplicate.id)
            effects.append(.ack(duplicate, .installed, attempt: 0))
        }
        return effects
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
