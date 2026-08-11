import Foundation

// Owner-scoped Keychain slots. The old global names remain only as a one-owner migration source; all new
// reads and writes append the typed authority namespace. Slot derivation is synchronous so a caller can
// capture an owner before its first await and never hop actors to decide where a credential belongs.
enum TraktTokenSlots {
    static let legacyAccess = "vortx.trakt.accessToken"
    static let legacyRefresh = "vortx.trakt.refreshToken"
    static let legacyExpiry = "vortx.trakt.expiresAt"
    static let legacyCreatedAt = "vortx.trakt.createdAt"
    static let legacySession = "vortx.trakt.sessionID"
    static let claimMarker = "vortx.trakt.migration.global.owner"

    static func access(_ namespace: String) -> String { legacyAccess + "." + namespace }
    static func refresh(_ namespace: String) -> String { legacyRefresh + "." + namespace }
    static func expiry(_ namespace: String) -> String { legacyExpiry + "." + namespace }
    static func createdAt(_ namespace: String) -> String { legacyCreatedAt + "." + namespace }
    static func session(_ namespace: String) -> String { legacySession + "." + namespace }
    static func active(_ namespace: String) -> String { legacyAccess + ".active." + namespace }
    static func cleanup(_ namespace: String) -> String { legacyAccess + ".cleanup." + namespace }
    static func candidate(_ namespace: String) -> String { legacyAccess + ".candidate." + namespace }
    static func publication(_ namespace: String) -> String { legacyAccess + ".publication." + namespace }

    @discardableResult
    static func claimLegacyGlobal(
        owner: CredentialScope,
        capture: CredentialScopeRegistry.Capture
    ) -> CredentialLegacyClaim.Result {
        guard capture.scope == owner,
              CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return .noSource }
        let ns = owner.storageNamespace
        let primary = CredentialLegacyClaim.claimGlobalSlotSet(
            slots: [
                (legacyAccess, access(ns)),
                (legacyRefresh, refresh(ns)),
                (legacyExpiry, expiry(ns)),
            ],
            claimMarkerAccount: claimMarker,
            ownerNamespace: ns,
            write: { value, account in Keychain.set(value, for: account) },
            durableRead: Keychain.confirmedString,
            sourceRead: Keychain.durableString,
            provenanceTag: "trakt-token-set"
        )
        // `createdAt` and `sessionID` were added after the original token triple. Migrate them with
        // independent claim markers when present; requiring either optional slot in the primary set would
        // strand an older but otherwise valid token set behind a half-written marker.
        guard primary == .migrated || primary == .targetPresent else { return primary }
        let createdAtResult = CredentialLegacyClaim.claimGlobalSlot(
            sourceAccount: legacyCreatedAt,
            destinationAccount: createdAt(ns),
            claimMarkerAccount: claimMarker + ".createdAt",
            ownerNamespace: ns,
            write: { value, account in Keychain.set(value, for: account) },
            durableRead: Keychain.confirmedString,
            sourceRead: Keychain.durableString,
            provenanceTag: "trakt-created-at"
        )
        switch createdAtResult {
        case .noSource, .targetPresent, .migrated:
            break
        case .durableReadFailed, .claimWriteFailed, .claimConflict, .claimedByOtherOwner,
             .sourceLostAfterClaim, .sourceDeleteFailed, .targetReadbackMismatch:
            return createdAtResult
        }
        let sessionResult = CredentialLegacyClaim.claimGlobalSlot(
            sourceAccount: legacySession,
            destinationAccount: session(ns),
            claimMarkerAccount: claimMarker + ".session",
            ownerNamespace: ns,
            write: { value, account in Keychain.set(value, for: account) },
            durableRead: Keychain.confirmedString,
            sourceRead: Keychain.durableString,
            provenanceTag: "trakt-session"
        )
        switch sessionResult {
        case .noSource, .targetPresent, .migrated:
            break
        case .durableReadFailed, .claimWriteFailed, .claimConflict, .claimedByOtherOwner,
             .sourceLostAfterClaim, .sourceDeleteFailed, .targetReadbackMismatch:
            return sessionResult
        }
        return primary
    }
}

/// Injectable credential persistence used by the auth actor and its security tests.
struct TraktCredentialStore: Sendable {
    let certifiedRead: @Sendable (String) -> CredentialDurableReadResult
    let recoveryRead: @Sendable (String) -> CredentialDurableReadResult
    let write: @Sendable (String?, String) -> CredentialMutationResult

    static let keychain = TraktCredentialStore(
        certifiedRead: { Keychain.confirmedString($0) },
        recoveryRead: { Keychain.durableString($0) },
        write: { value, account in Keychain.set(value, for: account) }
    )
}

/// OAuth endpoint configuration. Production keeps only the public Trakt client ID and the fixed VortX
/// broker base. Tests can use a local protocol-backed URLSession without changing global credentials.
struct TraktAuthConfiguration: Sendable {
    let clientID: String
    let apiBase: String
    let brokerBase: String

    static var production: TraktAuthConfiguration {
        TraktAuthConfiguration(
            clientID: TraktAuth.clientID,
            apiBase: TraktAuth.apiBase,
            brokerBase: TraktAuth.brokerBase
        )
    }
}

/// Owns one device-login attempt at a time. A replacement attempt or credential boundary invalidates
/// every older code, so a delayed OAuth response cannot install credentials after the user moved on.
struct TraktLoginAttemptAuthority {
    private var generation: UInt64 = 0
    private var codeGenerations: [String: UInt64] = [:]

    mutating func begin() -> UInt64 {
        generation &+= 1
        codeGenerations.removeAll(keepingCapacity: true)
        return generation
    }

    mutating func register(code: String, generation expectedGeneration: UInt64) {
        guard isCurrent(generation: expectedGeneration) else { return }
        codeGenerations = [code: expectedGeneration]
    }

    func generation(for code: String) -> UInt64? {
        guard let codeGeneration = codeGenerations[code],
              isCurrent(generation: codeGeneration) else { return nil }
        return codeGeneration
    }

    func owns(code: String, generation expectedGeneration: UInt64) -> Bool {
        codeGenerations[code] == expectedGeneration
            && isCurrent(generation: expectedGeneration)
    }

    func isCurrent(generation expectedGeneration: UInt64) -> Bool {
        expectedGeneration != 0 && generation == expectedGeneration
    }

    mutating func invalidate() {
        generation &+= 1
        codeGenerations.removeAll(keepingCapacity: true)
    }
}

/// Trakt.tv OAuth device-code flow plus Keychain-backed token storage.
///
/// The exchange, refresh, and revoke legs run through the authenticated VortX broker. The app receives
/// only an opaque broker session and never receives Trakt's device credential. Trakt data-plane calls
/// remain direct and continue to use the public client ID.
actor TraktAuth {
    static let shared = TraktAuth()

    // MARK: - Configuration (public client ID; empty ships a dormant, invisible feature)

    /// Trakt application client id (https://trakt.tv/oauth/applications), read at runtime from the
    /// Info.plist `TraktClientId` key, which Xcode substitutes from the `$(TRAKT_CLIENT_ID)` build
    /// setting (gitignored Config/ExternalSync.xcconfig or a CI secret; EMPTY default). Falls back to
    /// "" when absent, so a fresh/public build has no credentials and `isConfigured` stays false.
    static let clientID = TraktAuth.infoValue("TraktClientId")

    /// Fixed authenticated VortX broker. Its exact host is validated before every broker request so a
    /// malformed build or accidental endpoint substitution fails closed rather than making an arbitrary
    /// network request.
    static let brokerBase = "https://oauth.vortx.tv"
    static let brokerSourceID = "vortx-oauth-v2"

    /// Read an Info.plist string, trimmed, with a "" fallback. `$(VAR)` substitution leaves the key
    /// as an empty string (not the literal token) when the build setting is empty, so a blank value
    /// reads as "" here. Never crashes.
    private static func infoValue(_ key: String) -> String {
        ((Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// API base for the Trakt data plane. OAuth exchange and refresh never use this host.
    static let apiBase = "https://api.trakt.tv"

    /// True once a non-empty public client ID is present. Broker configuration and signing capability are
    /// validated at request time, so this remains an offline-safe local dormancy predicate.
    static var isConfigured: Bool { !clientID.isEmpty }

    // MARK: - Keychain accounts (token set lives here, nowhere else)

    private static let accessAccount = TraktTokenSlots.legacyAccess
    private static let refreshAccount = TraktTokenSlots.legacyRefresh
    private static let expiryAccount = TraktTokenSlots.legacyExpiry   // unix epoch seconds, stored as a string
    /// Unix epoch seconds when the token was ISSUED, stored as a string. Fourth slot: it lets
    /// `currentToken()` rebuild the token with its ORIGINAL lifetime so the 30-minute early-refresh
    /// leeway actually fires (see `TraktToken.defaultLeeway`). May be absent on installs whose token
    /// was stored before this slot existed; `currentToken()` degrades gracefully to hard-expiry-only.
    private static let createdAtAccount = TraktTokenSlots.legacyCreatedAt
    /// Random identity of the currently installed credential set. This is intentionally separate from
    /// OAuth tokens so a normal token refresh does not invalidate queued work or private snapshots.
    private static let sessionAccount = TraktTokenSlots.legacySession

    private let sessionConfiguration: URLSessionConfiguration
    private let credentials: TraktCredentialStore
    private let configuration: TraktAuthConfiguration
    /// Test-only transport seam. Production leaves this nil and must use the masked VortX edge signer;
    /// fixture tests may return the same request without provisioning or embedding a real edge secret.
    private let oauthRequestSigner: (@Sendable (URLRequest, Data) -> URLRequest?)?
    /// Inert-by-default scheduling probes for deterministic standalone race contracts. Test callbacks
    /// capture only their continuations, never this actor, so they add no production work or retain cycle.
    private let refreshJoinObserver: (@Sendable () -> Void)?
    private let sessionWriteDrainObserver: (@Sendable () -> Void)?

    /// Number of session-bound provider writes currently holding a credential lease. Auth boundaries
    /// wait for these operations to finish, so credentials cannot switch after final validation but before
    /// the network write. The actor may re-enter while the network awaits, and this explicit lease closes
    /// that reentrancy window.
    private var activeSessionWrites = 0
    private var sessionWriteDrainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Number of credential-boundary operations that have announced intent but have not finished.
    /// This is incremented before the first suspension in every boundary path. Session-bound writes
    /// reject while it is non-zero, so no write can enter after a boundary begins draining leases.
    private var pendingCredentialBoundaries = 0
    /// Credential replacements are serialized. Without this turnstile, two boundaries can both finish
    /// draining and then interleave their clear/install sequences across actor suspension points.
    private var credentialBoundaryActive = false
    private var credentialBoundaryWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginAttempts = TraktLoginAttemptAuthority()

    /// A refresh may be shared only by callers holding the exact owner epoch and account session that
    /// created it. A changed account cancels/replaces the old flight instead of joining its result.
    private struct TraktRefreshFlight {
        let id: UUID
        let ownerCapture: CredentialScopeRegistry.Capture
        let sessionID: TraktSessionID
        let task: Task<TraktToken, Error>
    }
    private var inFlightRefresh: TraktRefreshFlight?

    /// Injected at app startup (by `VortXSyncManager`): returns the freshest cross-device Trakt token
    /// triple from the synced `doc.apiKeys` mirror, or nil. Lets invalid-grant recovery re-adopt a token a
    /// SIBLING device rotated and pushed, instead of signing this device out. A seam (not a direct import)
    /// so `TraktAuth` stays free of a `VortXSyncManager` dependency.
    private var syncedTokenProvider: (@Sendable () async -> (access: String, refresh: String, expiryUnix: Int)?)?

    init(
        sessionConfiguration: URLSessionConfiguration = TraktAuth.defaultSessionConfiguration(),
        credentials: TraktCredentialStore = .keychain,
        configuration: TraktAuthConfiguration = .production,
        oauthRequestSigner: (@Sendable (URLRequest, Data) -> URLRequest?)? = nil,
        refreshJoinObserver: (@Sendable () -> Void)? = nil,
        sessionWriteDrainObserver: (@Sendable () -> Void)? = nil
    ) {
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.sessionConfiguration = sessionConfiguration
        self.credentials = credentials
        self.configuration = configuration
        self.oauthRequestSigner = oauthRequestSigner
        self.refreshJoinObserver = refreshJoinObserver
        self.sessionWriteDrainObserver = sessionWriteDrainObserver
    }

    /// Wire the cross-device synced-token lookup used by invalid-grant recovery (T-2). Called once
    /// at startup from `VortXSyncManager`; a nil provider simply disables cross-device recovery.
    func setSyncedTokenProvider(_ provider: @escaping @Sendable () async -> (access: String, refresh: String, expiryUnix: Int)?) {
        syncedTokenProvider = provider
    }

    private nonisolated func ownerCapture() -> CredentialScopeRegistry.Capture {
        CredentialScopeRegistry.shared.capture()
    }

    private nonisolated func slot(_ legacy: String, ownerNamespace: String) -> String {
        legacy + "." + ownerNamespace
    }

    private func tupleAccounts(ownerNamespace namespace: String) -> [String] {
        [
            slot(Self.accessAccount, ownerNamespace: namespace),
            slot(Self.refreshAccount, ownerNamespace: namespace),
            slot(Self.expiryAccount, ownerNamespace: namespace),
            slot(Self.sessionAccount, ownerNamespace: namespace)
        ]
    }

    private nonisolated static func recoverCredentialAuthority(
        credentials: TraktCredentialStore,
        ownerNamespace namespace: String
    ) -> Bool {
        CredentialTupleTransaction.recoverUncertainState(
            baseAccounts: [
                TraktTokenSlots.access(namespace),
                TraktTokenSlots.refresh(namespace),
                TraktTokenSlots.expiry(namespace),
                TraktTokenSlots.session(namespace)
            ],
            activePointer: TraktTokenSlots.active(namespace),
            cleanupMarker: TraktTokenSlots.cleanup(namespace),
            candidateMarker: TraktTokenSlots.candidate(namespace),
            publicationMarker: TraktTokenSlots.publication(namespace),
            certifiedRead: credentials.certifiedRead,
            recoveryRead: credentials.recoveryRead,
            write: credentials.write
        )
    }

    private func recoverCredentialAuthority(ownerNamespace namespace: String) -> Bool {
        Self.recoverCredentialAuthority(credentials: credentials, ownerNamespace: namespace)
    }

    /// Complete an active candidate transaction before a mutation-capable token/session read. Passive
    /// readers intentionally remain gated by a discoverable candidate marker; this helper resolves that
    /// marker only after the dual-read evidence pass and a fresh certified staged-tuple read.
    private func recoverMutationState(ownerCapture capture: CredentialScopeRegistry.Capture) -> Bool {
        guard let mutationLease = CredentialPublicationOutbox.beginMutation() else { return false }
        defer { CredentialPublicationOutbox.endMutation(mutationLease) }
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
        let namespace = capture.namespace
        guard recoverCredentialAuthority(ownerNamespace: namespace) else { return false }
        let activePointer = TraktTokenSlots.active(namespace)
        let cleanupMarker = TraktTokenSlots.cleanup(namespace)
        let candidateMarker = TraktTokenSlots.candidate(namespace)
        let publicationMarker = TraktTokenSlots.publication(namespace)
        let baseAccounts = tupleAccounts(ownerNamespace: namespace)

        func canonicalPointer(_ raw: String) -> String? {
            guard let uuid = UUID(uuidString: raw) else { return nil }
            return uuid.uuidString.lowercased()
        }

        func priorSessionID(candidatePointer: String, activePointerValue: String?) -> String? {
            if activePointerValue != candidatePointer {
                guard let activePointerValue,
                      case let .authority(active) = CredentialTupleTransaction.readStagedAuthority(
                          baseAccounts: baseAccounts,
                          pointer: activePointerValue,
                          certifiedRead: credentials.certifiedRead
                      ),
                      active.values.count == 4,
                      let session = active.values.last,
                      !session.isEmpty else { return nil }
                return session
            }
            guard case let .value(raw) = credentials.certifiedRead(cleanupMarker) else { return nil }
            return CredentialTupleTransaction.cleanupPriorSession(raw)
        }

        func promoteCandidate(pointer: String, activePointerValue: String?) -> Bool {
            guard case let .authority(candidate) = CredentialTupleTransaction.readStagedAuthority(
                baseAccounts: baseAccounts,
                pointer: pointer,
                certifiedRead: credentials.certifiedRead
            ),
            candidate.values.count == 4,
            !candidate.values[0].isEmpty,
            !candidate.values[1].isEmpty,
            Int(candidate.values[2]) != nil,
            !candidate.values[3].isEmpty else { return false }

            let publicationValue: String?
            switch CredentialPublicationOutbox.state(account: publicationMarker, read: credentials.certifiedRead) {
            case .missing:
                // A missing outbox is valid only for a same-session refresh candidate. A candidate with
                // no active session or a changed session is a new account boundary; do not let a mutation
                // read silently activate it without a durable publication intent.
                guard priorSessionID(candidatePointer: pointer, activePointerValue: activePointerValue)
                        == candidate.values.last else { return false }
                publicationValue = nil
            case let .pending(session), let .acknowledged(session):
                guard candidate.values.last == session else { return false }
                publicationValue = session
            case .dispatching:
                return false
            case .failure:
                return false
            }

            let promoted = CredentialTupleTransaction.transition(
                baseAccounts: baseAccounts,
                activePointer: activePointer,
                cleanupMarker: cleanupMarker,
                candidateMarker: candidateMarker,
                candidateValues: candidate.values,
                publicationMarker: publicationValue == nil ? nil : publicationMarker,
                publicationValue: publicationValue,
                certifiedRead: credentials.certifiedRead,
                recoveryRead: credentials.recoveryRead,
                write: credentials.write
            )
            switch promoted {
            case .activated, .alreadyActive:
                guard publicationValue != nil else { return true }
                return Self.replayPublicationOutbox(credentials: credentials, ownerNamespace: namespace)
            case .cleanupPending, .failedBeforeActivation, .activationStateUnknown:
                return false
            }
        }

        /// A final candidate-delete fault can leave B selected with its cleanup provenance but with the
        /// candidate marker now certified absent after recovery. Finish that exact cleanup before exposing
        /// B. A missing outbox is permitted only when the retained provenance proves this was a same-session
        /// refresh; a changed-session B stays closed until its own durable publication record exists.
        func finalizeSelectedCleanupWithoutCandidate() -> Bool {
            guard case let .authority(active) = CredentialTupleTransaction.readAuthority(
                baseAccounts: baseAccounts,
                activePointer: activePointer,
                certifiedRead: credentials.certifiedRead
            ), active.values.count == 4,
               let sessionID = active.values.last,
               !sessionID.isEmpty else { return false }
            let cleanupRaw: String
            switch credentials.certifiedRead(cleanupMarker) {
            case .missing:
                return Self.replayPublicationOutbox(credentials: credentials, ownerNamespace: namespace)
            case .failure:
                return false
            case let .value(raw):
                cleanupRaw = raw
            }
            let publicationValue: String?
            switch CredentialPublicationOutbox.state(account: publicationMarker, read: credentials.certifiedRead) {
            case .missing:
                guard CredentialTupleTransaction.cleanupPriorSession(cleanupRaw) == sessionID else {
                    return false
                }
                publicationValue = nil
            case let .pending(existing), let .acknowledged(existing):
                guard existing == sessionID else { return false }
                publicationValue = existing
            case .dispatching, .failure:
                return false
            }
            switch CredentialTupleTransaction.transition(
                baseAccounts: baseAccounts,
                activePointer: activePointer,
                cleanupMarker: cleanupMarker,
                candidateMarker: candidateMarker,
                candidateValues: active.values,
                publicationMarker: publicationValue == nil ? nil : publicationMarker,
                publicationValue: publicationValue,
                certifiedRead: credentials.certifiedRead,
                recoveryRead: credentials.recoveryRead,
                write: credentials.write
            ) {
            case .activated, .alreadyActive:
                return Self.replayPublicationOutbox(credentials: credentials, ownerNamespace: namespace)
            case .cleanupPending, .failedBeforeActivation, .activationStateUnknown:
                return false
            }
        }

        let activeRaw: String
        switch credentials.certifiedRead(activePointer) {
        case .missing:
            switch credentials.certifiedRead(candidateMarker) {
            case .missing:
                // A mutation-capable read may drain a durable pending boundary, but it must propagate a
                // dispatch failure instead of treating an active tuple with no candidate marker as settled.
                return Self.replayPublicationOutbox(credentials: credentials, ownerNamespace: namespace)
            case .failure:
                return false
            case let .value(raw):
                guard raw.hasPrefix("candidate:"),
                      let pointer = canonicalPointer(String(raw.dropFirst("candidate:".count))) else {
                    return false
                }
                return promoteCandidate(pointer: pointer, activePointerValue: nil)
            }
        case .failure:
            return false
        case let .value(raw):
            guard let pointer = canonicalPointer(raw) else { return false }
            activeRaw = pointer
        }

        switch credentials.certifiedRead(candidateMarker) {
        case .missing:
            return finalizeSelectedCleanupWithoutCandidate()
        case .failure:
            return false
        case let .value(raw):
            guard raw.hasPrefix("candidate:"),
                  let pointer = canonicalPointer(String(raw.dropFirst("candidate:".count))) else { return false }
            if pointer != activeRaw {
                return promoteCandidate(pointer: pointer, activePointerValue: activeRaw)
            }
            return promoteCandidate(pointer: pointer, activePointerValue: activeRaw)
        }
    }

    private func readCredentialTuple(ownerNamespace namespace: String) -> CredentialTupleReadResult {
        return CredentialTupleTransaction.readAuthority(
            baseAccounts: tupleAccounts(ownerNamespace: namespace),
            activePointer: TraktTokenSlots.active(namespace),
            cleanupMarker: TraktTokenSlots.cleanup(namespace),
            candidateMarker: TraktTokenSlots.candidate(namespace),
            certifiedRead: credentials.certifiedRead
        )
    }

    private func readCredentialTupleForMutation(ownerNamespace namespace: String) -> CredentialTupleReadResult {
        guard recoverCredentialAuthority(ownerNamespace: namespace) else { return .failure }
        return CredentialTupleTransaction.readAuthority(
            baseAccounts: tupleAccounts(ownerNamespace: namespace),
            activePointer: TraktTokenSlots.active(namespace),
            certifiedRead: credentials.certifiedRead
        )
    }

    // MARK: - Public state

    /// The production session visible to synchronous read paths and enqueue sites. This is a certified
    /// passive read: partial tuples and pending/dispatching publications remain invisible here, and repair
    /// or replay is reserved for mutation-capable paths that can propagate a failure.
    nonisolated static var storedSessionID: TraktSessionID? {
        let authority = CredentialScopeRegistry.shared
        let capture = authority.capture()
        let namespace = capture.namespace
        let baseAccounts = [
            TraktTokenSlots.access(namespace),
            TraktTokenSlots.refresh(namespace),
            TraktTokenSlots.expiry(namespace),
            TraktTokenSlots.session(namespace)
        ]
        let read = {
            CredentialTupleTransaction.readAuthority(
                baseAccounts: baseAccounts,
                activePointer: TraktTokenSlots.active(namespace),
                cleanupMarker: TraktTokenSlots.cleanup(namespace),
                candidateMarker: TraktTokenSlots.candidate(namespace),
                certifiedRead: Keychain.confirmedString
            )
        }
        guard authority.isCurrent(capture),
              case let .authority(active) = read(),
              active.values.count == 4,
              !active.values[0].isEmpty,
              !active.values[1].isEmpty,
              Int(active.values[2]) != nil,
              !active.values[3].isEmpty,
              CredentialPublicationOutbox.permitsPassiveRead(
                  account: TraktTokenSlots.publication(namespace),
                  sessionID: active.values[3],
                  read: Keychain.confirmedString
              ),
              authority.isCurrent(capture) else { return nil }
        // The selected tuple is read exactly once. No separate slot read can be
        // combined with a different pointer generation and accidentally form a mixed token/session view.
        return TraktSessionID(rawValue: active.values[3])
    }

    /// The session in this actor's credential store. Tests use an isolated store, while production uses
    /// the same Keychain slots as `storedSessionID`.
    var sessionID: TraktSessionID? {
        let capture = ownerCapture()
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              let sessionID = currentSessionID(ownerNamespace: capture.namespace),
              CredentialScopeRegistry.shared.isCurrent(capture) else { return nil }
        return sessionID
    }

    /// Test seam proving that a boundary has announced intent before its active write finishes.
    var isCredentialBoundaryPending: Bool { pendingCredentialBoundaries > 0 }

    /// True only when a complete token set and its session identity are stored.
    var isSignedIn: Bool { sessionID != nil }

    /// Drop all stored Trakt credentials after any already-authorized provider write finishes.
    @discardableResult
    func signOut() async -> Bool {
        let capture = ownerCapture()
        loginAttempts.invalidate()
        return await performCredentialBoundary {
            guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
            return await clearCredentialsAndPublishBoundary(ownerCapture: capture)
        }
    }

    /// Automatic auth-loss path. A stale invalid-grant verdict cannot sign out a newer account.
    @discardableResult
    func signOut(ifCurrent expectedSession: TraktSessionID) async -> Bool {
        let capture = ownerCapture()
        return await signOut(ifCurrent: expectedSession, ownerCapture: capture)
    }

    @discardableResult
    private func signOut(
        ifCurrent expectedSession: TraktSessionID,
        ownerCapture capture: CredentialScopeRegistry.Capture
    ) async -> Bool {
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { return false }
        loginAttempts.invalidate()
        return await performCredentialBoundary {
            guard CredentialScopeRegistry.shared.isCurrent(capture),
                  currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { return false }
            return await clearCredentialsAndPublishBoundary(ownerCapture: capture)
        }
    }

    /// Revoke a user-requested disconnect through the broker, then clear only the owner and session that
    /// initiated it. Broker failures are not auth verdicts and must not prevent local disconnect. An owner or
    /// account replacement that wins during the network await remains untouched by both fences.
    @discardableResult
    func revokeAndSignOut() async -> Bool {
        let capture = ownerCapture()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
        guard let expectedSession = currentSessionID(ownerNamespace: capture.namespace),
              let token = currentToken(ownerNamespace: capture.namespace) else {
            loginAttempts.invalidate()
            return await performCredentialBoundary {
                guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
                return await clearCredentialsAndPublishBoundary(ownerCapture: capture)
            }
        }
        do {
            struct Body: Encodable { let access_token: String }
            let request = try makeBrokerRequest(
                path: "/v1/oauth/trakt/revoke",
                body: Body(access_token: token.accessToken)
            )
            let (_, status) = try await send(request)
            DiagnosticsLog.log("trakt-auth", "broker revoke -> HTTP \(status)")
        } catch {
            DiagnosticsLog.log("trakt-auth", "broker revoke failed; disconnecting locally")
        }
        return await signOut(ifCurrent: expectedSession, ownerCapture: capture)
    }

    /// Adopt a token set that arrived from ANOTHER device over the E2E `doc.apiKeys` sync channel, so
    /// a Trakt connection made on one device follows the account to the rest. Writes the Keychain
    /// slots directly (no network). `expiryUnix` is absolute unix-epoch seconds (what token persistence
    /// and `syncUp` mirror). Ignores an empty access/refresh pair so a partial doc never clears a live
    /// local session. An identical replay is a no-op. A changed adoption is an account boundary.
    @discardableResult
    func adoptTokens(
        access: String,
        refresh: String,
        expiryUnix: Int,
        ownerCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil
    ) async -> CredentialMutationResult {
        guard !access.isEmpty, !refresh.isEmpty else { return .failure }
        let capture = suppliedCapture ?? ownerCapture()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return .failure }
        let namespace = capture.namespace
        loginAttempts.invalidate()
        var result: CredentialMutationResult = .failure
        let installed = await performCredentialBoundary {
            guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
            // Re-check inside the serialized turn. A competing adoption may have installed this exact
            // triple while this caller waited for the boundary turnstile.
            result = replaceCredentialsWithNewSession(
                access: access,
                refresh: refresh,
                expiryUnix: expiryUnix,
                ownerCapture: capture,
                ownerNamespace: namespace
            )
            return result == .success
        }
        return installed ? result : .failure
    }

    /// Finish a legacy claim only after the account layer has established the exact owner capture. This is
    /// deliberately mutation-only: passive session/token surfaces never manufacture identity or publish.
    /// The optional migrated session is preserved; a missing session is generated by the tuple transaction
    /// and is reused by recovery once any durable candidate or publication intent exists.
    @discardableResult
    func finalizeLegacyMigration(
        ownerCapture capture: CredentialScopeRegistry.Capture
    ) async -> CredentialMutationResult {
        guard CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return .failure }
        loginAttempts.invalidate()
        var result: CredentialMutationResult = .failure
        let finalized = await performCredentialBoundary {
            guard let mutationLease = CredentialPublicationOutbox.beginMutation() else { return false }
            defer { CredentialPublicationOutbox.endMutation(mutationLease) }
            guard CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return false }
            let namespace = capture.namespace
            func requiredSnapshot() -> (access: String, refresh: String, expiry: Int)? {
                guard case let .value(access) = credentials.certifiedRead(TraktTokenSlots.access(namespace)),
                      !access.isEmpty,
                      case let .value(refresh) = credentials.certifiedRead(TraktTokenSlots.refresh(namespace)),
                      !refresh.isEmpty,
                      case let .value(rawExpiry) = credentials.certifiedRead(TraktTokenSlots.expiry(namespace)),
                      let expiry = Int(rawExpiry) else { return nil }
                return (access, refresh, expiry)
            }
            var snapshot = requiredSnapshot()
            if snapshot == nil {
                guard recoverMutationState(ownerCapture: capture),
                      CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return false }
                snapshot = requiredSnapshot()
            }
            guard let snapshot else { return false }

            let sessionAccount = TraktTokenSlots.session(namespace)
            let publicationAccount = TraktTokenSlots.publication(namespace)
            let sessionID: TraktSessionID
            switch credentials.certifiedRead(TraktTokenSlots.session(namespace)) {
            case let .value(value) where !value.isEmpty:
                sessionID = TraktSessionID(rawValue: value)
            case .missing, .value:
                guard case .missing = credentials.certifiedRead(TraktTokenSlots.active(namespace)),
                      case .missing = credentials.certifiedRead(TraktTokenSlots.cleanup(namespace)),
                      case .missing = credentials.certifiedRead(TraktTokenSlots.candidate(namespace)),
                      CredentialPublicationOutbox.recoverIfUncertain(
                          account: publicationAccount,
                          certifiedRead: credentials.certifiedRead,
                          recoveryRead: credentials.recoveryRead,
                          write: credentials.write
                      ) else { return false }
                let planned: TraktSessionID
                switch CredentialPublicationOutbox.state(
                    account: publicationAccount,
                    read: credentials.certifiedRead
                ) {
                case .missing:
                    planned = TraktSessionID.random()
                    guard CredentialPublicationOutbox.prepare(
                        sessionID: planned.rawValue,
                        account: publicationAccount,
                        read: credentials.certifiedRead,
                        write: credentials.write
                    ) else { return false }
                case let .pending(raw) where !raw.isEmpty:
                    planned = TraktSessionID(rawValue: raw)
                case let .acknowledged(raw) where !raw.isEmpty:
                    planned = TraktSessionID(rawValue: raw)
                case .pending, .dispatching, .acknowledged, .failure:
                    return false
                }
                switch credentials.certifiedRead(sessionAccount) {
                case let .value(existing) where existing == planned.rawValue:
                    break
                case .missing, .value:
                    guard credentials.write(planned.rawValue, sessionAccount) == .success,
                          credentials.certifiedRead(sessionAccount) == .value(planned.rawValue) else {
                        return false
                    }
                case .failure:
                    switch credentials.recoveryRead(sessionAccount) {
                    case let .value(raw) where raw == planned.rawValue:
                        guard credentials.write(planned.rawValue, sessionAccount) == .success,
                              credentials.certifiedRead(sessionAccount) == .value(planned.rawValue) else {
                            return false
                        }
                    case .missing:
                        guard credentials.write(planned.rawValue, sessionAccount) == .success,
                              credentials.certifiedRead(sessionAccount) == .value(planned.rawValue) else {
                            return false
                        }
                    case .value, .failure:
                        return false
                    }
                }
                sessionID = planned
            case .failure:
                guard case .missing = credentials.certifiedRead(TraktTokenSlots.active(namespace)),
                      case .missing = credentials.certifiedRead(TraktTokenSlots.cleanup(namespace)),
                      case .missing = credentials.certifiedRead(TraktTokenSlots.candidate(namespace)),
                      case let .pending(prepared) = CredentialPublicationOutbox.state(
                          account: publicationAccount,
                          read: credentials.certifiedRead
                      ),
                      !prepared.isEmpty else {
                    return false
                }
                let recoveredSession = credentials.recoveryRead(sessionAccount)
                guard recoveredSession == .missing || recoveredSession == .value(prepared) else {
                    return false
                }
                guard credentials.write(prepared, sessionAccount) == .success,
                      credentials.certifiedRead(sessionAccount) == .value(prepared) else {
                    return false
                }
                sessionID = TraktSessionID(rawValue: prepared)
            }
            guard CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return false }
            result = replaceCredentialsWithNewSession(
                access: snapshot.access,
                refresh: snapshot.refresh,
                expiryUnix: snapshot.expiry,
                ownerCapture: capture,
                ownerNamespace: namespace,
                sessionID: sessionID,
                promoteLegacyMirror: true
            )
            return result == .success
        }
        return finalized ? result : .failure
    }

    /// The stored token triple for the sync PUSH side (access, refresh, absolute unix expiry), or nil
    /// when not signed in. Read-only mirror of `currentToken`; the sync manager sends these only when a
    /// local session exists and NEVER deletes them from the doc when absent (mirrors the debrid guard).
    func syncableTokens(
        ownerCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
        ownerNamespace suppliedNamespace: String? = nil
    ) -> (access: String, refresh: String, expiryUnix: Int)? {
        let capture = suppliedCapture ?? ownerCapture()
        let namespace = suppliedNamespace ?? capture.namespace
        guard capture.namespace == namespace,
              CredentialScopeRegistry.shared.isCurrent(capture),
              case let .authority(active) = readCredentialTuple(ownerNamespace: namespace),
              active.values.count == 4,
              !active.values[0].isEmpty,
              !active.values[1].isEmpty,
              let expiry = Int(active.values[2]),
              !active.values[3].isEmpty,
              CredentialPublicationOutbox.permitsPassiveRead(
                  account: TraktTokenSlots.publication(namespace),
                  sessionID: active.values[3],
                  read: credentials.certifiedRead
              ),
              CredentialScopeRegistry.shared.isCurrent(capture) else { return nil }
        return (active.values[0], active.values[1], expiry)
    }

    // MARK: - Step 1: request a device code

    /// Begin the device flow through the VortX broker. Trakt's device credential never enters this app.
    func requestDeviceCode() async throws -> TraktDeviceCode {
        try ensureConfigured()
        let capture = ownerCapture()
        let loginGeneration = loginAttempts.begin()
        let request = try makeBrokerRequest(
            path: "/v1/oauth/trakt/device/start",
            body: EmptyBody()
        )
        let (data, status) = try await send(request)
        try Task.checkCancellation()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else {
            throw TraktAuthError.sessionChanged
        }
        DiagnosticsLog.log("trakt-auth", "broker device/start -> HTTP \(status)")
        guard status == 200 else { throw Self.brokerFault(status: status) }
        let code = try decode(TraktDeviceCode.self, from: data)
        guard !code.session.isEmpty, !code.userCode.isEmpty,
              Self.validateVerificationURL(code.verificationURL),
              code.expiresIn > 0, code.interval > 0 else { throw TraktAuthError.decoding }
        guard loginAttempts.isCurrent(generation: loginGeneration) else {
            throw TraktAuthError.sessionChanged
        }
        loginAttempts.register(code: code.session, generation: loginGeneration)
        return code
    }

    // MARK: - Step 2: poll for the token

    /// One poll of the broker's `/device/poll`. `.pending` and `.slowDown` are the keep-polling
    /// signals; `.authorized` returns the token; terminal failures throw.
    enum PollResult: Sendable {
        case authorized(TraktToken)
        case pending
        case slowDown
    }

    private struct BrokerPollResponse: Decodable {
        let status: String
        let token: TraktToken?
    }

    func poll(session: String) async throws -> PollResult {
        let capture = ownerCapture()
        guard let loginGeneration = loginAttempts.generation(for: session) else {
            throw TraktAuthError.sessionChanged
        }
        return try await poll(
            session: session,
            loginGeneration: loginGeneration,
            ownerCapture: capture
        )
    }

    private func poll(
        session: String,
        loginGeneration: UInt64,
        ownerCapture capture: CredentialScopeRegistry.Capture
    ) async throws -> PollResult {
        try ensureConfigured()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else {
            throw TraktAuthError.sessionChanged
        }
        guard loginAttempts.owns(code: session, generation: loginGeneration) else {
            throw TraktAuthError.sessionChanged
        }
        struct Body: Encodable { let session: String }
        let request = try makeBrokerRequest(
            path: "/v1/oauth/trakt/device/poll",
            body: Body(session: session)
        )
        let (data, status) = try await send(request)
        try Task.checkCancellation()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else {
            throw TraktAuthError.sessionChanged
        }
        guard loginAttempts.owns(code: session, generation: loginGeneration) else {
            throw TraktAuthError.sessionChanged
        }
        guard status == 200 else { throw Self.brokerFault(status: status) }
        let response = try decode(BrokerPollResponse.self, from: data)
        switch response.status {
        case "authorized":
            guard let token = response.token,
                  !token.accessToken.isEmpty, !token.refreshToken.isEmpty,
                  token.expiresIn > 0 else { throw TraktAuthError.decoding }
            var persisted = false
            var mutationAttempted = false
            let installed = await performCredentialBoundary(
                expectedLoginGeneration: loginGeneration
            ) {
                // This is the credential commit linearization point. Once the synchronous durable
                // transaction succeeds, task cancellation cannot turn the installed identity into a
                // cancellation result.
                guard !Task.isCancelled,
                      CredentialScopeRegistry.shared.isCurrent(capture),
                      loginAttempts.owns(code: session, generation: loginGeneration) else { return false }
                mutationAttempted = true
                persisted = replaceCredentialsWithNewSession(
                    access: token.accessToken,
                    refresh: token.refreshToken,
                    expiryUnix: Int(token.expiresAt.timeIntervalSince1970),
                    ownerCapture: capture,
                    ownerNamespace: capture.namespace
                ) == .success
                if persisted { loginAttempts.invalidate() }
                return persisted
            }
            guard installed, persisted else {
                try Task.checkCancellation()
                throw mutationAttempted ? TraktAuthError.persistenceFailure : TraktAuthError.sessionChanged
            }
            DiagnosticsLog.log("trakt-auth", "broker device/poll -> authorized")
            return .authorized(token)
        case "pending":
            return .pending
        case "slow_down":
            DiagnosticsLog.log("trakt-auth", "broker device/poll -> slow_down")
            return .slowDown
        case "invalid":
            throw TraktAuthError.invalidDeviceCode
        case "already_used":
            throw TraktAuthError.codeAlreadyUsed
        case "expired":
            throw TraktAuthError.expired
        case "denied":
            throw TraktAuthError.denied
        default:
            DiagnosticsLog.log("trakt-auth", "broker device/poll -> unknown status")
            throw TraktAuthError.brokerUnavailable(status: 200)
        }
    }

    /// Run the full polling loop until the user authorizes, denies, or the codes expire. Honors the
    /// server `interval`, backs off an extra second on a 429, and stops once `expiresIn` elapses.
    /// On success the token is already stored in the Keychain; the return value is the same token.
    @discardableResult
    func pollForToken(session: String, interval: Int, expiresIn: Int) async throws -> TraktToken {
        let capture = ownerCapture()
        guard let loginGeneration = loginAttempts.generation(for: session) else {
            throw TraktAuthError.sessionChanged
        }
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        let baseInterval = max(interval, 1)
        var waitSeconds = baseInterval
        var lastTransient: TraktAuthError?
        DiagnosticsLog.log("trakt-auth", "poll start interval=\(baseInterval)s expiresIn=\(expiresIn)s")
        while Date() < deadline {
            guard CredentialScopeRegistry.shared.isCurrent(capture),
                  loginAttempts.owns(code: session, generation: loginGeneration) else {
                throw TraktAuthError.sessionChanged
            }
            try await sleep(seconds: waitSeconds)
            try Task.checkCancellation()
            let result: PollResult
            do {
                result = try await poll(
                    session: session,
                    loginGeneration: loginGeneration,
                    ownerCapture: capture
                )
            } catch let error as TraktAuthError where error.isTransient {
                try Task.checkCancellation()
                guard CredentialScopeRegistry.shared.isCurrent(capture),
                      loginAttempts.owns(code: session, generation: loginGeneration) else {
                    throw TraktAuthError.sessionChanged
                }
                lastTransient = error
                waitSeconds = min(waitSeconds + 1, baseInterval + 10)
                continue
            }
            lastTransient = nil
            switch result {
            case .authorized(let token):
                return token
            case .pending:
                try Task.checkCancellation()
                waitSeconds = baseInterval
            case .slowDown:
                try Task.checkCancellation()
                // Escalate on REPEATED 429s (Trakt raises the required interval each time it slows you
                // down); a flat `interval + 1` never grows and keeps tripping the limit. Reset to the base
                // happens on the next successful pending. Capped so a persistent 429 cannot stretch a
                // single poll unbounded.
                waitSeconds = min(waitSeconds + 1, baseInterval + 10)
            }
        }
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              loginAttempts.owns(code: session, generation: loginGeneration) else {
            throw TraktAuthError.sessionChanged
        }
        if let lastTransient { throw lastTransient }
        DiagnosticsLog.log("trakt-auth", "poll deadline reached without authorization (expired)")
        throw TraktAuthError.expired
    }

    /// Stop the currently displayed device flow without affecting an already authenticated account.
    func cancelLoginAttempt() {
        loginAttempts.invalidate()
    }

    // MARK: - Token access + refresh

    /// A live access token, refreshing first if the stored one is near expiry. Throws
    /// `.notSignedIn` when no token is stored.
    func validToken(ownerCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil) async throws -> String {
        let capture = suppliedCapture ?? ownerCapture()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.sessionChanged }
        guard recoverMutationState(ownerCapture: capture),
              CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.notSignedIn }
        guard let token = currentToken(ownerNamespace: capture.namespace),
              let expectedSession = currentSessionID(ownerNamespace: capture.namespace),
              CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.notSignedIn }
        if token.isExpired() {
            do {
                return try await refresh(using: token.refreshToken, ownerCapture: capture).accessToken
            } catch let error as TraktAuthError where error.isTransient && !token.isExpired(leeway: 0) {
                guard pendingCredentialBoundaries == 0,
                      CredentialScopeRegistry.shared.isCurrent(capture),
                      currentSessionID(ownerNamespace: capture.namespace) == expectedSession else {
                    throw TraktAuthError.sessionChanged
                }
                DiagnosticsLog.log("trakt-auth", "refresh deferred; using stored token")
                return token.accessToken
            }
        }
        return token.accessToken
    }

    /// A live token proven to belong to `expectedSession` both before and after any refresh await.
    /// Read-only callers use this to ensure an old account task never adopts a newer account's token.
    func validToken(for expectedSession: TraktSessionID) async throws -> String {
        let capture = ownerCapture()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.sessionChanged }
        guard recoverMutationState(ownerCapture: capture),
              CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.sessionChanged }
        guard pendingCredentialBoundaries == 0,
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw TraktAuthError.sessionChanged }
        let token = try await validToken(ownerCapture: capture)
        guard pendingCredentialBoundaries == 0,
              CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw TraktAuthError.sessionChanged }
        return token
    }

    /// Run one provider write with a credential that cannot be replaced until the operation completes.
    ///
    /// The expected session is checked before token resolution and again after any refresh. Only then is
    /// the lease counted. Sign-out and account replacement wait for the count to reach zero, closing the
    /// final validation to network-use race without relying on cancellation.
    func performSessionBoundWrite<Result: Sendable>(
        expectedSession: TraktSessionID,
        _ operation: @escaping @Sendable (String) async throws -> Result
    ) async throws -> Result {
        let capture = ownerCapture()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.sessionChanged }
        guard recoverMutationState(ownerCapture: capture),
              CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.sessionChanged }
        guard pendingCredentialBoundaries == 0,
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw TraktAuthError.sessionChanged }
        let token = try await validToken(ownerCapture: capture)
        guard pendingCredentialBoundaries == 0,
              CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw TraktAuthError.sessionChanged }

        activeSessionWrites += 1
        defer { finishSessionWrite() }
        let result = try await operation(token)
        guard CredentialScopeRegistry.shared.isCurrent(capture) else {
            throw TraktAuthError.sessionChanged
        }
        return result
    }

    /// Exchange the refresh token through the broker, SINGLE-FLIGHT: if a refresh is
    /// already running, await it instead of starting a second one (Trakt rotates the refresh token, so a
    /// second concurrent refresh would spend an already-rotated token and fail). Stores and returns the set.
    @discardableResult
    func refresh(
        using refreshToken: String,
        ownerCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil
    ) async throws -> TraktToken {
        let capture = suppliedCapture ?? ownerCapture()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.sessionChanged }
        guard recoverMutationState(ownerCapture: capture),
              CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.notSignedIn }
        guard let expectedSession = currentSessionID(ownerNamespace: capture.namespace) else { throw TraktAuthError.notSignedIn }
        // Join only an exact authority match. A flight from another owner epoch or account session may
        // still be unwinding after an adoption/sign-out and must never supply its result to this caller.
        if let existing = inFlightRefresh {
            if existing.ownerCapture == capture, existing.sessionID == expectedSession {
                refreshJoinObserver?()
                let token = try await existing.task.value
                try Task.checkCancellation()
                guard CredentialScopeRegistry.shared.isCurrent(capture),
                      currentSessionID(ownerNamespace: capture.namespace) == expectedSession else {
                    throw TraktAuthError.sessionChanged
                }
                return token
            }
            existing.task.cancel()
            inFlightRefresh = nil
        }
        // A refresh that completed moments ago (whose owner already cleared `inFlightRefresh`) may have
        // stored a fresh token. A caller that just missed the in-flight window must not refresh again with
        // the now-rotated refresh token, so re-check synchronously (no await) before starting a new one.
        if let fresh = currentToken(ownerNamespace: capture.namespace), !fresh.isExpired() {
            return fresh
        }
        let flightID = UUID()
        let task = Task<TraktToken, Error> { [weak self] in
            guard let self else { throw TraktAuthError.notSignedIn }
            return try await self.performRefresh(
                using: refreshToken,
                expectedSession: expectedSession,
                ownerCapture: capture
            )
        }
        inFlightRefresh = TraktRefreshFlight(
            id: flightID,
            ownerCapture: capture,
            sessionID: expectedSession,
            task: task
        )
        defer {
            if inFlightRefresh?.id == flightID {
                inFlightRefresh = nil
            }
        }
        let token = try await task.value
        try Task.checkCancellation()
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw TraktAuthError.sessionChanged }
        return token
    }

    /// The broker refresh call. Only ever invoked from inside the single-flight `refresh(using:)`, so at
    /// most one rotation runs at a time.
    private struct BrokerRefreshResponse: Decodable {
        let status: String
        let token: TraktToken?
    }

    private func performRefresh(
        using refreshToken: String,
        expectedSession: TraktSessionID,
        ownerCapture capture: CredentialScopeRegistry.Capture
    ) async throws -> TraktToken {
        try ensureConfigured()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw TraktAuthError.sessionChanged }
        struct Body: Encodable { let refresh_token: String }
        let request = try makeBrokerRequest(
            path: "/v1/oauth/trakt/refresh",
            body: Body(refresh_token: refreshToken)
        )
        let (data, status) = try await send(request)
        try Task.checkCancellation()
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw TraktAuthError.sessionChanged }
        guard status == 200 else { throw TraktAuthError.brokerUnavailable(status: status) }
        let response = try decode(BrokerRefreshResponse.self, from: data)
        if response.status == "ok" {
            guard let token = response.token,
                  !token.accessToken.isEmpty, !token.refreshToken.isEmpty,
                  token.expiresIn > 0 else { throw TraktAuthError.decoding }
            // A normal refresh rotates tokens inside the same authenticated account. Never rotate the local
            // session identity here: queued work and snapshots captured before refresh remain valid.
            guard CredentialScopeRegistry.shared.isCurrent(capture),
                  currentSessionID(ownerNamespace: capture.namespace) == expectedSession else {
                throw TraktAuthError.sessionChanged
            }
            try Task.checkCancellation()
            guard storeRefreshedToken(token, ownerCapture: capture) else {
                throw TraktAuthError.persistenceFailure
            }
            return token
        }
        guard response.status == "invalid_grant" else {
            DiagnosticsLog.log("trakt-auth", "broker refresh -> unknown status")
            throw TraktAuthError.brokerUnavailable(status: 200)
        }
        // Only the broker's explicit invalid_grant verdict may end the session. Before clearing it, look for
        // a concurrent local or cross-device refresh winner exactly as the pre-broker durable flow did.
        let recovered = await recoverAfterRefreshFailure(
            deadRefreshToken: refreshToken,
            expectedSession: expectedSession,
            ownerCapture: capture
        )
        try Task.checkCancellation()
        if let recovered {
            return recovered
        }
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw TraktAuthError.sessionChanged }
        // The recovery path suspends. A winning refresh may have landed during that await, so re-read without
        // another suspension and preserve any set whose rotated refresh token differs from the spent token.
        if let stored = currentToken(ownerNamespace: capture.namespace),
           stored.refreshToken != refreshToken {
            return stored
        }
        _ = await signOut(ifCurrent: expectedSession, ownerCapture: capture)
        throw TraktAuthError.notSignedIn
    }

    /// A broker refresh returned invalid_grant. Before signing out, look for a fresher token a winner already
    /// minted: (T-1c) re-read the Keychain in case a local refresh rotated it, then (T-2) consult the
    /// cross-device synced mirror in case a SIBLING device rotated and pushed one. Returns the token to
    /// adopt, or nil when nothing fresher exists (the caller then signs out).
    private func recoverAfterRefreshFailure(
        deadRefreshToken: String,
        expectedSession: TraktSessionID,
        ownerCapture capture: CredentialScopeRegistry.Capture
    ) async -> TraktToken? {
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { return nil }
        // (T-1c) A local winner rotated the token while this refresh was in flight. A Trakt rotation always
        // changes the refresh token, so a stored refresh token different from the one we just spent means a
        // winner already stored a rotated set; adopt it REGARDLESS of the access token's age (even an aged
        // set carries a live refresh token the next `validToken()` will spend), rather than wiping the
        // session over a token that merely needs its own refresh.
        if let local = currentToken(ownerNamespace: capture.namespace), local.refreshToken != deadRefreshToken {
            return local
        }
        // (T-2) A sibling device rotated + pushed a newer token over the synced `doc.apiKeys` mirror. A
        // synced refresh token different from the one we spent is that sibling's fresher set; adopt it into
        // the Keychain and use it. Same-token or absent means nothing fresher exists remotely.
        let synced = await syncedTokenProvider?()
        guard !Task.isCancelled else { return nil }
        if let synced,
           !synced.access.isEmpty, !synced.refresh.isEmpty, synced.refresh != deadRefreshToken {
            guard CredentialScopeRegistry.shared.isCurrent(capture),
                  currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { return nil }
            // The synced token document carries no account fingerprint. A different refresh token may
            // therefore belong to another account, not merely a sibling-device rotation. Treat it as
            // a credential boundary unless a future protocol adds explicit same-account proof.
            var adoptionResult: CredentialMutationResult = .failure
            let boundaryInstalled = await performCredentialBoundary {
                guard !Task.isCancelled,
                      CredentialScopeRegistry.shared.isCurrent(capture),
                      currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { return false }
                adoptionResult = replaceCredentialsWithNewSession(
                    access: synced.access,
                    refresh: synced.refresh,
                    expiryUnix: synced.expiryUnix,
                    ownerCapture: capture,
                    ownerNamespace: capture.namespace
                )
                return adoptionResult == .success
            }
            guard boundaryInstalled, adoptionResult == .success,
                  let adopted = currentToken(ownerNamespace: capture.namespace),
                  adopted.refreshToken != deadRefreshToken else { return nil }
            return adopted
        }
        return nil
    }

    // MARK: - Keychain persistence

    /// The stored token set, reconstructed from the Keychain entries, or nil if not signed in.
    private func currentToken(ownerNamespace namespace: String? = nil) -> TraktToken? {
        let resolvedNamespace = namespace ?? ownerCapture().namespace
        guard case let .authority(active) = readCredentialTuple(ownerNamespace: resolvedNamespace),
              active.values.count == 4,
              let access = active.values.first, !access.isEmpty,
              let refresh = active.values.dropFirst().first, !refresh.isEmpty,
              let expiryString = active.values.dropFirst(2).first,
              let expiry = Int(expiryString),
              let rawSession = active.values.dropFirst(3).first,
              !rawSession.isEmpty,
              CredentialPublicationOutbox.permitsPassiveRead(
                  account: TraktTokenSlots.publication(resolvedNamespace),
                  sessionID: rawSession,
                  read: credentials.certifiedRead
              ) else { return nil }
        // Rebuild with the ORIGINAL issue time when the fourth slot has it, so `expiresIn` is the
        // original lifetime and `defaultLeeway` gives a real 30-minute early refresh. (A rebuild from
        // the REMAINING lifetime makes `remaining <= min(1800, remaining/2)` unsatisfiable, so the
        // early refresh silently never fires and a data call can carry a token that expires in flight.)
        if case let .value(createdAtString) = credentials.certifiedRead(slot(Self.createdAtAccount, ownerNamespace: resolvedNamespace)),
           let createdAt = Int(createdAtString), createdAt < expiry {
            return TraktToken(accessToken: access, refreshToken: refresh,
                              expiresIn: expiry - createdAt, createdAt: createdAt)
        }
        // Migration: a token stored before the createdAt slot existed (or a corrupt slot). Fall back
        // to createdAt = now, i.e. exactly the pre-slot behavior: the token only reads expired at hard
        // expiry. Never a false expiry, never a forced signout; the next natural refresh (or adopt)
        // writes the slot and upgrades the token to the early-refresh path.
        let now = Int(Date().timeIntervalSince1970)
        return TraktToken(accessToken: access, refreshToken: refresh,
                          expiresIn: expiry - now, createdAt: now)
    }

    private func storeRefreshedToken(
        _ token: TraktToken,
        ownerCapture capture: CredentialScopeRegistry.Capture
    ) -> Bool {
        guard let mutationLease = CredentialPublicationOutbox.beginMutation() else { return false }
        defer { CredentialPublicationOutbox.endMutation(mutationLease) }
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
        let resolvedNamespace = capture.namespace
        guard case let .authority(active) = readCredentialTupleForMutation(ownerNamespace: resolvedNamespace),
              active.values.count == 4,
              let rawSession = active.values.last,
              !rawSession.isEmpty else { return false }
        let result = CredentialTupleTransaction.transition(
            baseAccounts: tupleAccounts(ownerNamespace: resolvedNamespace),
            activePointer: TraktTokenSlots.active(resolvedNamespace),
            cleanupMarker: TraktTokenSlots.cleanup(resolvedNamespace),
            candidateMarker: TraktTokenSlots.candidate(resolvedNamespace),
            candidateValues: [
                token.accessToken,
                token.refreshToken,
                String(Int(token.expiresAt.timeIntervalSince1970)),
                rawSession
            ],
            certifiedRead: credentials.certifiedRead,
            recoveryRead: credentials.recoveryRead,
            write: credentials.write
        )
        switch result {
        case .activated, .alreadyActive:
            // createdAt is optional legacy metadata, not part of the authoritative four-slot tuple. A
            // failed best-effort mirror must not turn an already-activated access/refresh/expiry/session
            // tuple into a reported persistence failure or make the selected B tuple appear mixed.
            _ = persistCreatedAt(token.createdAt, ownerNamespace: resolvedNamespace)
            return true
        case .cleanupPending, .failedBeforeActivation, .activationStateUnknown:
            return false
        }
    }

    @discardableResult
    private func replaceCredentialsWithNewSession(
        access: String,
        refresh: String,
        expiryUnix: Int,
        ownerCapture capture: CredentialScopeRegistry.Capture,
        ownerNamespace namespace: String? = nil,
        sessionID suppliedSessionID: TraktSessionID? = nil,
        publishSession: Bool = true,
        promoteLegacyMirror: Bool = false
    ) -> CredentialMutationResult {
        let resolvedNamespace = namespace ?? ownerCapture().namespace
        guard capture.namespace == resolvedNamespace,
              let mutationLease = CredentialPublicationOutbox.beginMutation() else { return .failure }
        defer { CredentialPublicationOutbox.endMutation(mutationLease) }
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return .failure }
        guard Self.recoverCredentialAuthority(credentials: credentials, ownerNamespace: resolvedNamespace) else {
            return .failure
        }
        // A crash can leave a complete first-login candidate and its exact pending publication intent while
        // the active-pointer write is confirmed absent. Replay cannot run until a tuple is selected, so let
        // the certified transaction promote only the candidate matching this public retry before draining it.
        if case .missing = credentials.certifiedRead(TraktTokenSlots.active(resolvedNamespace)),
           case let .value(rawCandidate) = credentials.certifiedRead(TraktTokenSlots.candidate(resolvedNamespace)),
           rawCandidate.hasPrefix("candidate:"),
           let pointer = CredentialTupleTransaction.canonicalPointer(
               String(rawCandidate.dropFirst("candidate:".count))
           ),
           case let .authority(candidate) = CredentialTupleTransaction.readStagedAuthority(
               baseAccounts: tupleAccounts(ownerNamespace: resolvedNamespace),
               pointer: pointer,
               certifiedRead: credentials.certifiedRead
           ),
           candidate.values.count == 4,
           candidate.values[0] == access,
           candidate.values[1] == refresh,
           candidate.values[2] == String(expiryUnix),
           !candidate.values[3].isEmpty,
           suppliedSessionID == nil || suppliedSessionID?.rawValue == candidate.values[3] {
            let state = CredentialPublicationOutbox.state(
                account: TraktTokenSlots.publication(resolvedNamespace),
                read: credentials.certifiedRead
            )
            let intentMatches: Bool
            switch state {
            case let .pending(session), let .acknowledged(session):
                guard session == candidate.values[3] else { return .failure }
                intentMatches = true
            case .missing:
                intentMatches = false
            case .dispatching, .failure:
                return .failure
            }
            if intentMatches {
                switch CredentialTupleTransaction.transition(
                    baseAccounts: tupleAccounts(ownerNamespace: resolvedNamespace),
                    activePointer: TraktTokenSlots.active(resolvedNamespace),
                    cleanupMarker: TraktTokenSlots.cleanup(resolvedNamespace),
                    candidateMarker: TraktTokenSlots.candidate(resolvedNamespace),
                    candidateValues: candidate.values,
                    publicationMarker: TraktTokenSlots.publication(resolvedNamespace),
                    publicationValue: candidate.values[3],
                    certifiedRead: credentials.certifiedRead,
                    recoveryRead: credentials.recoveryRead,
                    write: credentials.write
                ) {
                case .activated, .alreadyActive:
                    break
                case .cleanupPending, .failedBeforeActivation, .activationStateUnknown:
                    return .failure
                }
            }
        }
        guard Self.replayPublicationOutbox(
            credentials: credentials,
            ownerNamespace: resolvedNamespace,
            promoteLegacyMirror: promoteLegacyMirror
        ) else {
            return .failure
        }
        let current = readCredentialTupleForMutation(ownerNamespace: resolvedNamespace)
        guard current != .failure else { return .failure }
        let existingSession: TraktSessionID?
        if case let .authority(active) = current,
           active.values.count == 4,
           active.values[0] == access,
           active.values[1] == refresh,
           active.values[2] == String(expiryUnix),
           !active.values[3].isEmpty {
            existingSession = TraktSessionID(rawValue: active.values[3])
        } else {
            existingSession = nil
        }
        let sessionID = suppliedSessionID ?? existingSession ?? TraktSessionID.random()
        let transition = CredentialTupleTransaction.transition(
            baseAccounts: tupleAccounts(ownerNamespace: resolvedNamespace),
            activePointer: TraktTokenSlots.active(resolvedNamespace),
            cleanupMarker: TraktTokenSlots.cleanup(resolvedNamespace),
            candidateMarker: TraktTokenSlots.candidate(resolvedNamespace),
            candidateValues: [access, refresh, String(expiryUnix), sessionID.rawValue],
            publicationMarker: publishSession ? TraktTokenSlots.publication(resolvedNamespace) : nil,
            publicationValue: publishSession ? sessionID.rawValue : nil,
            promoteLegacyMirror: promoteLegacyMirror,
            certifiedRead: credentials.certifiedRead,
            recoveryRead: credentials.recoveryRead,
            write: credentials.write
        )
        switch transition {
        case .activated:
            _ = persistCreatedAt(Int(Date().timeIntervalSince1970), ownerNamespace: resolvedNamespace)
            return publishSession && !Self.replayPublicationOutbox(credentials: credentials, ownerNamespace: resolvedNamespace)
                ? .failure
                : .success
        case .alreadyActive:
            _ = persistCreatedAt(Int(Date().timeIntervalSince1970), ownerNamespace: resolvedNamespace)
            return publishSession && !Self.replayPublicationOutbox(credentials: credentials, ownerNamespace: resolvedNamespace)
                ? .failure
                : .success
        case .cleanupPending:
            return .failure
        case .failedBeforeActivation, .activationStateUnknown:
            return .failure
        }
    }

    private func persistCreatedAt(_ createdAt: Int, ownerNamespace namespace: String) -> Bool {
        let value = String(createdAt)
        let account = slot(Self.createdAtAccount, ownerNamespace: namespace)
        guard credentials.write(value, account) == .success else { return false }
        guard case let .value(readBack) = credentials.certifiedRead(account) else { return false }
        return readBack == value
    }

    private func currentSessionID(ownerNamespace namespace: String? = nil) -> TraktSessionID? {
        let resolvedNamespace = namespace ?? ownerCapture().namespace
        guard case let .authority(active) = readCredentialTuple(ownerNamespace: resolvedNamespace),
              active.values.count == 4,
              !active.values[0].isEmpty,
              !active.values[1].isEmpty,
              Int(active.values[2]) != nil,
              !active.values[3].isEmpty,
              CredentialPublicationOutbox.permitsPassiveRead(
                  account: TraktTokenSlots.publication(resolvedNamespace),
                  sessionID: active.values[3],
                  read: credentials.certifiedRead
              ) else { return nil }
        return TraktSessionID(rawValue: active.values[3])
    }

    private nonisolated static func replayPublicationOutbox(
        credentials: TraktCredentialStore,
        ownerNamespace namespace: String,
        promoteLegacyMirror: Bool = false
    ) -> Bool {
        let account = TraktTokenSlots.publication(namespace)
        guard CredentialPublicationOutbox.recoverIfUncertain(
            account: account,
            certifiedRead: credentials.certifiedRead,
            recoveryRead: credentials.recoveryRead,
            write: credentials.write
        ) else { return false }
        let state = CredentialPublicationOutbox.state(account: account, read: credentials.certifiedRead)
        let sessionRaw: String
        switch state {
        case .missing:
            return true
        case .failure:
            return false
        case .dispatching:
            return false
        case let .pending(value), let .acknowledged(value):
            sessionRaw = value
        }
        let baseAccounts = [
            TraktTokenSlots.access(namespace),
            TraktTokenSlots.refresh(namespace),
            TraktTokenSlots.expiry(namespace),
            TraktTokenSlots.session(namespace)
        ]
        let selected = CredentialTupleTransaction.readAuthority(
            baseAccounts: baseAccounts,
            activePointer: TraktTokenSlots.active(namespace),
            certifiedRead: credentials.certifiedRead
        )
        let authority: CredentialTupleAuthority
        switch selected {
        case let .authority(active) where active.values.count == 4 && active.values.last == sessionRaw:
            authority = active
        case let .authority(active) where active.values.count == 4:
            guard case let .value(rawCandidate) = credentials.certifiedRead(TraktTokenSlots.candidate(namespace)),
                  rawCandidate.hasPrefix("candidate:"),
                  let candidatePointer = CredentialTupleTransaction.canonicalPointer(
                      String(rawCandidate.dropFirst("candidate:".count))
                  ),
                  case let .authority(candidate) = CredentialTupleTransaction.readStagedAuthority(
                      baseAccounts: baseAccounts,
                      pointer: candidatePointer,
                      certifiedRead: credentials.certifiedRead
                  ),
                  candidate.values.count == 4,
                  candidate.values.last == sessionRaw,
                  active.values.last != sessionRaw else { return false }
            authority = candidate
        default:
            return false
        }
        let recovery = CredentialTupleTransaction.transition(
            baseAccounts: baseAccounts,
            activePointer: TraktTokenSlots.active(namespace),
            cleanupMarker: TraktTokenSlots.cleanup(namespace),
            candidateMarker: TraktTokenSlots.candidate(namespace),
            candidateValues: authority.values,
            publicationMarker: account,
            publicationValue: sessionRaw,
            promoteLegacyMirror: promoteLegacyMirror,
            certifiedRead: credentials.certifiedRead,
            recoveryRead: credentials.recoveryRead,
            write: credentials.write
        )
        switch recovery {
        case .activated, .alreadyActive:
            break
        case .cleanupPending, .failedBeforeActivation, .activationStateUnknown:
            return false
        }
        let recovered = CredentialTupleTransaction.readAuthority(
            baseAccounts: baseAccounts,
            activePointer: TraktTokenSlots.active(namespace),
            certifiedRead: credentials.certifiedRead
        )
        guard case let .authority(recoveredAuthority) = recovered,
              recoveredAuthority.values == authority.values,
              case .missing = credentials.certifiedRead(TraktTokenSlots.cleanup(namespace)),
              case .missing = credentials.certifiedRead(TraktTokenSlots.candidate(namespace)) else {
            return false
        }
        if case .pending = state {
            if let lease = CredentialPublicationOutbox.beginDispatch(
                sessionID: sessionRaw,
                account: account,
                read: credentials.certifiedRead,
                write: credentials.write
            ) {
                defer { CredentialPublicationOutbox.endDispatch(lease) }
                CredentialPublicationOutbox.withCallback(lease) {
                    TraktAuthBoundary.publish(TraktSessionID(rawValue: sessionRaw))
                }
                guard CredentialPublicationOutbox.acknowledge(
                    sessionID: sessionRaw,
                    account: account,
                    read: credentials.certifiedRead,
                    write: credentials.write
                ) else { return false }
            } else {
                switch CredentialPublicationOutbox.state(account: account, read: credentials.certifiedRead) {
                case .missing:
                    return true
                case let .acknowledged(existing) where existing == sessionRaw:
                    break
                case .pending, .dispatching, .acknowledged, .failure:
                    return false
                }
            }
        }
        switch credentials.certifiedRead(TraktTokenSlots.candidate(namespace)) {
        case .failure:
            return false
        case .value:
            return true
        case .missing:
            break
        }
        return CredentialPublicationOutbox.removeAcknowledged(
            sessionID: sessionRaw,
            account: account,
            read: credentials.certifiedRead,
            write: credentials.write
        )
    }

    private func clearCredentialsAndPublishBoundary(
        ownerCapture capture: CredentialScopeRegistry.Capture
    ) async -> Bool {
        let resolvedNamespace = capture.namespace
        guard await acquirePublicationBoundary() else { return false }
        defer { CredentialPublicationOutbox.endBoundary() }
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
        guard CredentialTupleTransaction.clear(
            baseAccounts: tupleAccounts(ownerNamespace: resolvedNamespace),
            activePointer: TraktTokenSlots.active(resolvedNamespace),
            cleanupMarker: TraktTokenSlots.cleanup(resolvedNamespace),
            candidateMarker: TraktTokenSlots.candidate(resolvedNamespace),
            extraAccounts: [
                slot(Self.createdAtAccount, ownerNamespace: resolvedNamespace),
                TraktTokenSlots.publication(resolvedNamespace)
            ],
            certifiedRead: credentials.certifiedRead,
            recoveryRead: credentials.recoveryRead,
            write: credentials.write
        ) else { return false }
        TraktAuthBoundary.publish(nil)
        return true
    }

    private func acquirePublicationBoundary() async -> Bool {
        await CredentialPublicationOutbox.waitForBoundary() == .acquired
    }

    private func waitForSessionWrites() async {
        while activeSessionWrites > 0 {
            await withCheckedContinuation { continuation in
                sessionWriteDrainWaiters.append(continuation)
                sessionWriteDrainObserver?()
            }
        }
    }

    /// Announce, serialize, drain, and perform one credential boundary. The pending count is raised
    /// synchronously before either the turnstile or write drain can suspend.
    @discardableResult
    private func performCredentialBoundary(
        expectedLoginGeneration: UInt64? = nil,
        _ mutation: () async -> Bool
    ) async -> Bool {
        pendingCredentialBoundaries += 1
        defer { pendingCredentialBoundaries -= 1 }
        await acquireCredentialBoundary()
        defer { releaseCredentialBoundary() }
        await waitForSessionWrites()
        if let expectedLoginGeneration,
           (expectedLoginGeneration == 0
                || !loginAttempts.isCurrent(generation: expectedLoginGeneration)) {
            return false
        }
        return await mutation()
    }

    private func acquireCredentialBoundary() async {
        if !credentialBoundaryActive {
            credentialBoundaryActive = true
            return
        }
        await withCheckedContinuation { continuation in
            credentialBoundaryWaiters.append(continuation)
        }
    }

    private func releaseCredentialBoundary() {
        if credentialBoundaryWaiters.isEmpty {
            credentialBoundaryActive = false
            return
        }
        let next = credentialBoundaryWaiters.removeFirst()
        next.resume()
    }

    private func finishSessionWrite() {
        precondition(activeSessionWrites > 0)
        activeSessionWrites -= 1
        guard activeSessionWrites == 0 else { return }
        let waiters = sessionWriteDrainWaiters
        sessionWriteDrainWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - HTTP plumbing

    private func ensureConfigured() throws {
        guard !configuration.clientID.isEmpty else { throw TraktAuthError.notConfigured }
        guard Self.validateBrokerBase(configuration.brokerBase) != nil else {
            throw TraktAuthError.brokerUnavailable(status: 0)
        }
        guard oauthRequestSigner != nil || VortXEdgeAuth.canSignOAuthV2 else {
            throw TraktAuthError.brokerUnavailable(status: 0)
        }
    }

    private static func defaultSessionConfiguration() -> URLSessionConfiguration {
        URLSessionConfiguration.ephemeral
    }

    private struct EmptyBody: Encodable {}

    /// Accept only the production broker origin and path shape. This prevents a malformed configuration
    /// from turning the OAuth client into an arbitrary request client.
    private static func validateBrokerBase(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              components.scheme == "https",
              components.host == "oauth.vortx.tv",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        return components.url
    }

    /// Accept only HTTPS verification pages on the exact trusted Trakt host set.
    private static func validateVerificationURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ["trakt.tv", "www.trakt.tv"].contains(host),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              !components.path.isEmpty else { return false }
        return true
    }

    private func makeBrokerRequest<Body: Encodable>(path: String, body: Body) throws -> URLRequest {
        let allowedPaths = Set([
            "/v1/oauth/trakt/device/start",
            "/v1/oauth/trakt/device/poll",
            "/v1/oauth/trakt/refresh",
            "/v1/oauth/trakt/revoke",
        ])
        guard allowedPaths.contains(path),
              let base = Self.validateBrokerBase(configuration.brokerBase),
              let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw TraktAuthError.brokerUnavailable(status: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyData = try JSONEncoder().encode(body)
        guard bodyData.count <= 16 * 1024 else {
            throw TraktAuthError.brokerUnavailable(status: 0)
        }
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.httpBody = bodyData
        if let oauthRequestSigner {
            guard let signed = oauthRequestSigner(request, bodyData) else {
                throw TraktAuthError.brokerUnavailable(status: 0)
            }
            request = signed
        } else {
            guard VortXEdgeAuth.signOAuthV2(&request, body: bodyData) else {
                throw TraktAuthError.brokerUnavailable(status: 0)
            }
        }
        guard request.url == url,
              request.httpMethod == "POST",
              request.httpBody == bodyData else {
            throw TraktAuthError.brokerUnavailable(status: 0)
        }
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        return request
    }

    private static func brokerFault(status: Int) -> TraktAuthError {
        .brokerUnavailable(status: status)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let delegate = TraktOAuthNoRedirectDelegate()
            let session = URLSession(
                configuration: sessionConfiguration,
                delegate: delegate,
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TraktAuthError.transport("The broker returned an invalid response.")
            }
            let expectedLength: Int?
            if let raw = http.value(forHTTPHeaderField: "Content-Length") {
                guard let length = Int(raw), length >= 0, length <= 64 * 1024 else {
                    throw TraktAuthError.transport("The broker response was invalid.")
                }
                expectedLength = length
            } else {
                expectedLength = nil
            }
            var data = Data()
            data.reserveCapacity(expectedLength ?? 1024)
            for try await byte in bytes {
                guard data.count < 64 * 1024 else {
                    throw TraktAuthError.transport("The broker response was too large.")
                }
                data.append(byte)
            }
            if let expectedLength, data.count != expectedLength {
                throw TraktAuthError.transport("The broker response was incomplete.")
            }
            return (data, http.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as TraktAuthError {
            throw error
        } catch {
            throw TraktAuthError.transport("Could not reach the VortX Trakt service.")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TraktAuthError.decoding }
    }

    private func sleep(seconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0)) * 1_000_000_000)
    }
}

/// OAuth broker transport never follows redirects. A redirect would otherwise move the signed POST and its
/// body to a host that was not covered by the v2 signature.
final class TraktOAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Typed errors for the Trakt auth flow. Broker faults are transient and never mean that the account
/// ended. Only an explicit broker `invalid_grant` response reaches the refresh sign-out branch.
enum TraktAuthError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case notSignedIn
    case sessionChanged
    case badURL
    case invalidDeviceCode
    case codeAlreadyUsed
    case expired
    case denied
    case brokerUnavailable(status: Int)
    case persistenceFailure
    case server(status: Int)
    case transport(String)
    case decoding

    var isTransient: Bool {
        switch self {
        case .brokerUnavailable, .transport: return true
        case .server(let status): return status >= 500
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Trakt is not configured in this build."
        case .notSignedIn: return "You are not connected to Trakt."
        case .sessionChanged: return "The Trakt account changed before this operation could finish."
        case .badURL: return "The Trakt service URL is invalid."
        case .invalidDeviceCode: return "This Trakt sign-in code is not valid."
        case .codeAlreadyUsed: return "This Trakt sign-in code was already used."
        case .expired: return "The Trakt sign-in code expired. Please try again."
        case .denied: return "Trakt access was denied."
        case .brokerUnavailable: return "Could not reach the VortX Trakt service. Please try again in a moment."
        case .persistenceFailure: return "Trakt could not durably save the new credentials."
        case .server(let status): return "Trakt returned an error (HTTP \(status))."
        case .transport(let message): return message
        case .decoding: return "Could not read the response from Trakt."
        }
    }
}
