import Foundation

// Owner-scoped SIMKL Keychain slots. Legacy global entries are migration sources only; all new reads and
// writes use the namespace captured from the shared credential authority.
enum SIMKLTokenSlots {
    static let legacyAccess = "vortx.simkl.accessToken"
    static let legacyExpiry = "vortx.simkl.expiresAt"
    static let legacySession = "vortx.simkl.sessionID"
    static let claimMarker = "vortx.simkl.migration.global.owner"

    static func access(_ namespace: String) -> String { legacyAccess + "." + namespace }
    static func expiry(_ namespace: String) -> String { legacyExpiry + "." + namespace }
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
            slots: [(legacyAccess, access(ns)), (legacyExpiry, expiry(ns))],
            claimMarkerAccount: claimMarker,
            ownerNamespace: ns,
            write: { value, account in Keychain.set(value, for: account) },
            durableRead: Keychain.confirmedString,
            sourceRead: Keychain.durableString,
            provenanceTag: "simkl-token-pair"
        )
        guard primary == .migrated || primary == .targetPresent else { return primary }
        let sessionResult = CredentialLegacyClaim.claimGlobalSlot(
            sourceAccount: legacySession,
            destinationAccount: session(ns),
            claimMarkerAccount: claimMarker + ".session",
            ownerNamespace: ns,
            write: { value, account in Keychain.set(value, for: account) },
            durableRead: Keychain.confirmedString,
            sourceRead: Keychain.durableString,
            provenanceTag: "simkl-session"
        )
        switch sessionResult {
        case .noSource, .targetPresent, .migrated:
            return primary
        case .durableReadFailed, .claimWriteFailed, .claimConflict, .claimedByOtherOwner,
             .sourceLostAfterClaim, .sourceDeleteFailed, .targetReadbackMismatch:
            return sessionResult
        }
    }
}

struct SIMKLCredentialStore: Sendable {
    let certifiedRead: @Sendable (String) -> CredentialDurableReadResult
    let recoveryRead: @Sendable (String) -> CredentialDurableReadResult
    let write: @Sendable (String?, String) -> CredentialMutationResult

    static let keychain = SIMKLCredentialStore(
        certifiedRead: { Keychain.confirmedString($0) },
        recoveryRead: { Keychain.durableString($0) },
        write: { value, account in Keychain.set(value, for: account) }
    )
}

/// OAuth endpoint configuration. Production reads the bundled credential, while the standalone
/// transaction suite injects a protocol-backed endpoint without changing global process state.
struct SIMKLAuthConfiguration: Sendable {
    let clientID: String
    let apiBase: String
    let allowedAPIHosts: Set<String>

    static var production: SIMKLAuthConfiguration {
        SIMKLAuthConfiguration(
            clientID: SIMKLAuth.clientID,
            apiBase: SIMKLAuth.apiBase,
            allowedAPIHosts: ["api.simkl.com"]
        )
    }
}

/// Random identity for one locally installed SIMKL credential set.
struct SIMKLSessionID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func random() -> SIMKLSessionID {
        SIMKLSessionID(rawValue: UUID().uuidString)
    }
}

/// Owns one PIN login attempt at a time. A replacement attempt or credential boundary invalidates every
/// older PIN, so a delayed poll response cannot overwrite the account the user chose afterwards.
struct SIMKLLoginAttemptAuthority {
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

/// Synchronous account-boundary signal for SIMKL-owned caches and queued intents.
enum SIMKLAuthBoundary {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var observers: [String: @Sendable (SIMKLSessionID?) -> Void] = [:]
    }

    private static let state = State()

    static func observe(
        key: String,
        _ observer: @escaping @Sendable (SIMKLSessionID?) -> Void
    ) {
        state.lock.lock()
        state.observers[key] = observer
        state.lock.unlock()
    }

    static func removeObserver(key: String) {
        state.lock.lock()
        state.observers.removeValue(forKey: key)
        state.lock.unlock()
    }

    static func publish(_ sessionID: SIMKLSessionID?) {
        state.lock.lock()
        let observers = Array(state.observers.values)
        state.lock.unlock()
        for observer in observers {
            observer(sessionID)
        }
    }
}

/// SIMKL PIN/device auth plus Keychain-backed token storage. Mirrors `TraktAuth`'s shape but for
/// SIMKL's simpler model: a PIN flow (request a code, poll until the user authorizes) that yields a
/// LONG-LIVED access token with NO refresh rotation. A missing/zero expiry is therefore treated as
/// "valid" rather than "expired" (do NOT copy `TraktToken`'s 24h-leeway refresh, which SIMKL lacks).
///
/// Credentials come from the public build-time client ID seam: the Info.plist `SIMKLClientId` key,
/// substituted from `$(SIMKL_CLIENT_ID)` (empty default). The PIN flow never needs a client secret, and
/// no secret is read or shipped. `isConfigured` gates the whole feature so an unprovisioned build stays
/// dormant.
actor SIMKLAuth {
    static let shared = SIMKLAuth()

    // MARK: - Configuration (build-time; empty ships a dormant, invisible feature)

    /// SIMKL application client id (https://simkl.com/settings/developer/), read at runtime from the
    /// Info.plist `SIMKLClientId` key ($(SIMKL_CLIENT_ID); empty default). "" when absent.
    static let clientID = SIMKLAuth.infoValue("SIMKLClientId")

    /// API base. SIMKL serves OAuth off the same host as the data API.
    static let apiBase = "https://api.simkl.com"

    /// True once a non-empty client id is present. Everything no-ops until then.
    static var isConfigured: Bool { !clientID.isEmpty }

    /// App marketing version (CFBundleShortVersionString), e.g. "0.3.14"; "1" when the plist key is absent
    /// (mirrors the MediaServerAuth precedent). SIMKL requires an `app-version` on every request.
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1"
    }

    /// Descriptive User-Agent SIMKL wants on every request. A blank/default UA risks their abuse filters,
    /// which can suspend the API key (S-5).
    static var userAgent: String { "VortX/\(appVersion) (Apple tvOS/iOS/macOS; +https://vortx.tv)" }

    /// The `client_id` / `app-name` / `app-version` query items SIMKL requires on EVERY request (S-4).
    /// Appended alongside whatever query items an endpoint already carries.
    static var requiredQueryItems: [URLQueryItem] {
        [URLQueryItem(name: "client_id", value: clientID),
         URLQueryItem(name: "app-name", value: "VortX"),
         URLQueryItem(name: "app-version", value: appVersion)]
    }

    private static func infoValue(_ key: String) -> String {
        ((Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Keychain accounts (token lives here, nowhere else)

    private static let accessAccount = SIMKLTokenSlots.legacyAccess
    private static let expiryAccount = SIMKLTokenSlots.legacyExpiry
    private static let sessionAccount = SIMKLTokenSlots.legacySession

    private let transport: AuthenticatedHTTPTransport
    private let credentials: SIMKLCredentialStore
    private let configuration: SIMKLAuthConfiguration
    /// Inert-by-default scheduling probe for deterministic standalone drain-race contracts. Tests capture
    /// only their continuation, never this actor, so the seam adds no production work or retain cycle.
    private let sessionWriteDrainObserver: (@Sendable () -> Void)?
    private var activeSessionWrites = 0
    private var sessionWriteDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingCredentialBoundaries = 0
    private var credentialBoundaryActive = false
    private var credentialBoundaryWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginAttempts = SIMKLLoginAttemptAuthority()

    init(
        transport: AuthenticatedHTTPTransport = .shared,
        credentials: SIMKLCredentialStore = .keychain,
        configuration: SIMKLAuthConfiguration = .production,
        sessionWriteDrainObserver: (@Sendable () -> Void)? = nil
    ) {
        self.transport = transport
        self.credentials = credentials
        self.configuration = configuration
        self.sessionWriteDrainObserver = sessionWriteDrainObserver
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
            slot(Self.expiryAccount, ownerNamespace: namespace),
            slot(Self.sessionAccount, ownerNamespace: namespace)
        ]
    }

    private nonisolated static func recoverCredentialAuthority(
        credentials: SIMKLCredentialStore,
        ownerNamespace namespace: String
    ) -> Bool {
        CredentialTupleTransaction.recoverUncertainState(
            baseAccounts: [
                SIMKLTokenSlots.access(namespace),
                SIMKLTokenSlots.expiry(namespace),
                SIMKLTokenSlots.session(namespace)
            ],
            activePointer: SIMKLTokenSlots.active(namespace),
            cleanupMarker: SIMKLTokenSlots.cleanup(namespace),
            candidateMarker: SIMKLTokenSlots.candidate(namespace),
            publicationMarker: SIMKLTokenSlots.publication(namespace),
            certifiedRead: credentials.certifiedRead,
            recoveryRead: credentials.recoveryRead,
            write: credentials.write
        )
    }

    private func recoverCredentialAuthority(ownerNamespace namespace: String) -> Bool {
        Self.recoverCredentialAuthority(credentials: credentials, ownerNamespace: namespace)
    }

    private func readCredentialTuple(ownerNamespace namespace: String) -> CredentialTupleReadResult {
        return CredentialTupleTransaction.readAuthority(
            baseAccounts: tupleAccounts(ownerNamespace: namespace),
            activePointer: SIMKLTokenSlots.active(namespace),
            cleanupMarker: SIMKLTokenSlots.cleanup(namespace),
            candidateMarker: SIMKLTokenSlots.candidate(namespace),
            certifiedRead: credentials.certifiedRead
        )
    }

    private func readCredentialTupleForMutation(ownerNamespace namespace: String) -> CredentialTupleReadResult {
        guard recoverCredentialAuthority(ownerNamespace: namespace) else { return .failure }
        return CredentialTupleTransaction.readAuthority(
            baseAccounts: tupleAccounts(ownerNamespace: namespace),
            activePointer: SIMKLTokenSlots.active(namespace),
            certifiedRead: credentials.certifiedRead
        )
    }

    /// Complete an in-flight candidate before a mutation-capable token/session read. A missing publication
    /// intent is accepted only when the durable cleanup marker proves the candidate kept the prior session;
    /// first-login and changed-session candidates remain closed even when their pointer already won.
    private func recoverMutationState(ownerCapture capture: CredentialScopeRegistry.Capture) -> Bool {
        guard let mutationLease = CredentialPublicationOutbox.beginMutation() else { return false }
        defer { CredentialPublicationOutbox.endMutation(mutationLease) }
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
        let namespace = capture.namespace
        guard recoverCredentialAuthority(ownerNamespace: namespace) else { return false }
        let activePointer = SIMKLTokenSlots.active(namespace)
        let cleanupMarker = SIMKLTokenSlots.cleanup(namespace)
        let candidateMarker = SIMKLTokenSlots.candidate(namespace)
        let publicationMarker = SIMKLTokenSlots.publication(namespace)
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
                      active.values.count == 3,
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
            candidate.values.count == 3,
            !candidate.values[0].isEmpty,
            Int(candidate.values[1]) != nil,
            !candidate.values[2].isEmpty else { return false }

            let publicationValue: String?
            switch CredentialPublicationOutbox.state(account: publicationMarker, read: credentials.certifiedRead) {
            case .missing:
                guard priorSessionID(candidatePointer: pointer, activePointerValue: activePointerValue)
                        == candidate.values.last else { return false }
                publicationValue = nil
            case let .pending(session), let .acknowledged(session):
                guard candidate.values.last == session else { return false }
                publicationValue = session
            case .dispatching, .failure:
                return false
            }

            let transition = CredentialTupleTransaction.transition(
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
            switch transition {
            case .activated, .alreadyActive:
                guard publicationValue != nil else { return true }
                return Self.replayPublicationOutbox(credentials: credentials, ownerNamespace: namespace)
            case .cleanupPending, .failedBeforeActivation, .activationStateUnknown:
                return false
            }
        }

        func finalizeSelectedCleanupWithoutCandidate() -> Bool {
            guard case let .authority(active) = CredentialTupleTransaction.readAuthority(
                baseAccounts: baseAccounts,
                activePointer: activePointer,
                certifiedRead: credentials.certifiedRead
            ), active.values.count == 3,
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

        switch credentials.certifiedRead(activePointer) {
        case .missing:
            switch credentials.certifiedRead(candidateMarker) {
            case .missing:
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
            guard let activeRaw = canonicalPointer(raw) else { return false }
            switch credentials.certifiedRead(candidateMarker) {
            case .missing:
                return finalizeSelectedCleanupWithoutCandidate()
            case .failure:
                return false
            case let .value(candidateRaw):
                guard candidateRaw.hasPrefix("candidate:"),
                      let pointer = canonicalPointer(String(candidateRaw.dropFirst("candidate:".count))) else {
                    return false
                }
                return promoteCandidate(pointer: pointer, activePointerValue: activeRaw)
            }
        }
    }

    // MARK: - Public state

    /// Certified passive session surface. It never repairs credentials or drains the publication outbox.
    nonisolated static var storedSessionID: SIMKLSessionID? {
        let authority = CredentialScopeRegistry.shared
        let capture = authority.capture()
        let namespace = capture.namespace
        let baseAccounts = [
            SIMKLTokenSlots.access(namespace),
            SIMKLTokenSlots.expiry(namespace),
            SIMKLTokenSlots.session(namespace)
        ]
        let read = {
            CredentialTupleTransaction.readAuthority(
                baseAccounts: baseAccounts,
                activePointer: SIMKLTokenSlots.active(namespace),
                cleanupMarker: SIMKLTokenSlots.cleanup(namespace),
                candidateMarker: SIMKLTokenSlots.candidate(namespace),
                certifiedRead: Keychain.confirmedString
            )
        }
        guard authority.isCurrent(capture),
              case let .authority(active) = read(),
              active.values.count == 3,
              !active.values[0].isEmpty,
              Int(active.values[1]) != nil,
              !active.values[2].isEmpty,
              CredentialPublicationOutbox.permitsPassiveRead(
                  account: SIMKLTokenSlots.publication(namespace),
                  sessionID: active.values[2],
                  read: Keychain.confirmedString
              ),
              authority.isCurrent(capture) else { return nil }
        return SIMKLSessionID(rawValue: active.values[2])
    }

    var sessionID: SIMKLSessionID? {
        let capture = ownerCapture()
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              let sessionID = currentSessionID(ownerNamespace: capture.namespace),
              CredentialScopeRegistry.shared.isCurrent(capture) else { return nil }
        return sessionID
    }
    var isSignedIn: Bool { sessionID != nil }
    var isCredentialBoundaryPending: Bool { pendingCredentialBoundaries > 0 }

    /// Drop the stored token (the user disconnected). Does not revoke server-side.
    @discardableResult
    func signOut() async -> Bool {
        let capture = ownerCapture()
        loginAttempts.invalidate()
        return await performCredentialBoundary {
            guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
            return await clearCredentialsAndPublishBoundary(ownerCapture: capture)
        }
    }

    @discardableResult
    func signOut(ifCurrent expectedSession: SIMKLSessionID) async -> Bool {
        let capture = ownerCapture()
        guard currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { return false }
        loginAttempts.invalidate()
        return await performCredentialBoundary {
            guard CredentialScopeRegistry.shared.isCurrent(capture),
                  currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { return false }
            return await clearCredentialsAndPublishBoundary(ownerCapture: capture)
        }
    }

    /// A live access token, or throws `.notSignedIn`. SIMKL tokens are long-lived and do not refresh, so
    /// a stored token is returned as-is; a recorded expiry in the past (rare, only if a future SIMKL
    /// change adds one) throws so the UI can re-prompt.
    func validToken() throws -> String {
        let capture = ownerCapture()
        return try validToken(ownerCapture: capture)
    }

    func validToken(for expectedSession: SIMKLSessionID) throws -> String {
        let capture = ownerCapture()
        guard pendingCredentialBoundaries == 0,
              CredentialScopeRegistry.shared.isCurrent(capture),
              recoverMutationState(ownerCapture: capture),
              CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw SIMKLError.sessionChanged }
        let token = try validToken(ownerCapture: capture)
        guard pendingCredentialBoundaries == 0,
              CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw SIMKLError.sessionChanged }
        return token
    }

    private func validToken(ownerCapture capture: CredentialScopeRegistry.Capture) throws -> String {
        guard CredentialScopeRegistry.shared.isCurrent(capture),
              recoverMutationState(ownerCapture: capture),
              CredentialScopeRegistry.shared.isCurrent(capture),
              case let .authority(active) = readCredentialTuple(ownerNamespace: capture.namespace),
              active.values.count == 3,
              let token = active.values.first, !token.isEmpty,
              let rawExpiry = active.values.dropFirst().first,
              let session = active.values.last,
              !session.isEmpty,
              CredentialPublicationOutbox.permitsPassiveRead(
                  account: SIMKLTokenSlots.publication(capture.namespace),
                  sessionID: session,
                  read: credentials.certifiedRead
              ),
              CredentialScopeRegistry.shared.isCurrent(capture) else {
            throw SIMKLError.notSignedIn
        }
        if let expiry = Int(rawExpiry), expiry > 0,
           Date().timeIntervalSince1970 >= Double(expiry) {
            throw SIMKLError.notSignedIn
        }
        return token
    }

    /// Hold the current credential set across one provider write.
    func performSessionBoundWrite<Result: Sendable>(
        expectedSession: SIMKLSessionID,
        _ operation: @escaping @Sendable (String) async throws -> Result
    ) async throws -> Result {
        let capture = ownerCapture()
        guard pendingCredentialBoundaries == 0,
              CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw SIMKLError.sessionChanged }
        let token = try validToken(for: expectedSession)
        guard pendingCredentialBoundaries == 0,
              CredentialScopeRegistry.shared.isCurrent(capture),
              currentSessionID(ownerNamespace: capture.namespace) == expectedSession else { throw SIMKLError.sessionChanged }
        activeSessionWrites += 1
        defer { finishSessionWrite() }
        let result = try await operation(token)
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw SIMKLError.sessionChanged }
        return result
    }

    // MARK: - Cross-device adoption / sync mirror

    /// Adopt a token that arrived from ANOTHER device over the E2E `doc.apiKeys` sync channel. Writes the
    /// Keychain directly (no network). Ignores an empty token so a partial doc never clears a live session.
    @discardableResult
    func adoptTokens(
        access: String,
        expiryUnix: Int,
        ownerCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil
    ) async -> CredentialMutationResult {
        guard !access.isEmpty else { return .failure }
        let capture = suppliedCapture ?? ownerCapture()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { return .failure }
        let namespace = capture.namespace
        loginAttempts.invalidate()
        var result: CredentialMutationResult = .failure
        let installed = await performCredentialBoundary {
            guard CredentialScopeRegistry.shared.isCurrent(capture) else { return false }
            result = replaceCredentialsWithNewSession(
                access: access,
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
            func requiredSnapshot() -> (access: String, expiry: Int)? {
                guard case let .value(access) = credentials.certifiedRead(SIMKLTokenSlots.access(namespace)),
                      !access.isEmpty,
                      case let .value(rawExpiry) = credentials.certifiedRead(SIMKLTokenSlots.expiry(namespace)),
                      let expiry = Int(rawExpiry) else { return nil }
                return (access, expiry)
            }
            var snapshot = requiredSnapshot()
            if snapshot == nil {
                guard recoverMutationState(ownerCapture: capture),
                      CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return false }
                snapshot = requiredSnapshot()
            }
            guard let snapshot else { return false }

            let sessionAccount = SIMKLTokenSlots.session(namespace)
            let publicationAccount = SIMKLTokenSlots.publication(namespace)
            let sessionID: SIMKLSessionID
            switch credentials.certifiedRead(SIMKLTokenSlots.session(namespace)) {
            case let .value(value) where !value.isEmpty:
                sessionID = SIMKLSessionID(rawValue: value)
            case .missing, .value:
                guard case .missing = credentials.certifiedRead(SIMKLTokenSlots.active(namespace)),
                      case .missing = credentials.certifiedRead(SIMKLTokenSlots.cleanup(namespace)),
                      case .missing = credentials.certifiedRead(SIMKLTokenSlots.candidate(namespace)),
                      CredentialPublicationOutbox.recoverIfUncertain(
                          account: publicationAccount,
                          certifiedRead: credentials.certifiedRead,
                          recoveryRead: credentials.recoveryRead,
                          write: credentials.write
                      ) else { return false }
                let planned: SIMKLSessionID
                switch CredentialPublicationOutbox.state(
                    account: publicationAccount,
                    read: credentials.certifiedRead
                ) {
                case .missing:
                    planned = SIMKLSessionID.random()
                    guard CredentialPublicationOutbox.prepare(
                        sessionID: planned.rawValue,
                        account: publicationAccount,
                        read: credentials.certifiedRead,
                        write: credentials.write
                    ) else { return false }
                case let .pending(raw) where !raw.isEmpty:
                    planned = SIMKLSessionID(rawValue: raw)
                case let .acknowledged(raw) where !raw.isEmpty:
                    planned = SIMKLSessionID(rawValue: raw)
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
                guard case .missing = credentials.certifiedRead(SIMKLTokenSlots.active(namespace)),
                      case .missing = credentials.certifiedRead(SIMKLTokenSlots.cleanup(namespace)),
                      case .missing = credentials.certifiedRead(SIMKLTokenSlots.candidate(namespace)),
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
                sessionID = SIMKLSessionID(rawValue: prepared)
            }
            guard CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return false }
            result = replaceCredentialsWithNewSession(
                access: snapshot.access,
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

    /// The stored token for the sync PUSH side (access, absolute unix expiry or 0), or nil when not
    /// signed in. Read-only; the sync manager sends these only when a local session exists and NEVER
    /// deletes them from the doc when absent (mirrors the debrid guard).
    func syncableTokens(
        ownerCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
        ownerNamespace suppliedNamespace: String? = nil
    ) -> (access: String, expiryUnix: Int)? {
        let capture = suppliedCapture ?? ownerCapture()
        let namespace = suppliedNamespace ?? capture.namespace
        guard capture.namespace == namespace,
              CredentialScopeRegistry.shared.isCurrent(capture),
              case let .authority(active) = readCredentialTuple(ownerNamespace: namespace),
              active.values.count == 3,
              !active.values[0].isEmpty,
              let expiry = Int(active.values[1]),
              !active.values[2].isEmpty,
              CredentialPublicationOutbox.permitsPassiveRead(
                  account: SIMKLTokenSlots.publication(namespace),
                  sessionID: active.values[2],
                  read: credentials.certifiedRead
              ),
              CredentialScopeRegistry.shared.isCurrent(capture) else { return nil }
        return (active.values[0], expiry)
    }

    // MARK: - Step 1: request a PIN

    /// Begin the PIN flow. Returns the code + polling schedule to drive the UI and step 2.
    func requestPin() async throws -> SIMKLPin {
        try ensureConfigured()
        let capture = ownerCapture()
        let loginGeneration = loginAttempts.begin()
        guard var components = URLComponents(string: configuration.apiBase + "/oauth/pin") else { throw SIMKLError.badURL }
        components.queryItems = requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        let (data, status) = try await send(makeGET(url))
        try Task.checkCancellation()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw SIMKLError.sessionChanged }
        guard status == 200 else { throw SIMKLError.server(status: status) }
        let pin = try decode(SIMKLPin.self, from: data)
        guard loginAttempts.isCurrent(generation: loginGeneration) else {
            throw SIMKLError.sessionChanged
        }
        loginAttempts.register(code: pin.userCode, generation: loginGeneration)
        return pin
    }

    // MARK: - Step 2: poll for the token

    enum PollResult: Sendable {
        case authorized(String)   // access token
        case pending
    }

    /// One poll of `GET /oauth/pin/{user_code}`.
    func poll(userCode: String) async throws -> PollResult {
        let capture = ownerCapture()
        guard let loginGeneration = loginAttempts.generation(for: userCode) else {
            throw SIMKLError.sessionChanged
        }
        return try await poll(userCode: userCode, loginGeneration: loginGeneration, ownerCapture: capture)
    }

    private func poll(
        userCode: String,
        loginGeneration: UInt64,
        ownerCapture capture: CredentialScopeRegistry.Capture
    ) async throws -> PollResult {
        try ensureConfigured()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw SIMKLError.sessionChanged }
        guard loginAttempts.owns(code: userCode, generation: loginGeneration) else {
            throw SIMKLError.sessionChanged
        }
        guard var components = URLComponents(string: configuration.apiBase + "/oauth/pin/\(userCode)") else { throw SIMKLError.badURL }
        components.queryItems = requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        let (data, status) = try await send(makeGET(url))
        try Task.checkCancellation()
        guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw SIMKLError.sessionChanged }
        guard loginAttempts.owns(code: userCode, generation: loginGeneration) else {
            throw SIMKLError.sessionChanged
        }
        guard status == 200 else { throw SIMKLError.server(status: status) }
        let poll = try decode(SIMKLPinPoll.self, from: data)
        if poll.result.uppercased() == "OK", let token = poll.accessToken, !token.isEmpty {
            var persisted = false
            let installed = await performCredentialBoundary(
                expectedLoginGeneration: loginGeneration
            ) {
                // This is the credential commit linearization point. Once the synchronous durable
                // transaction succeeds, task cancellation cannot turn the installed identity into a
                // cancellation result.
                guard !Task.isCancelled,
                      CredentialScopeRegistry.shared.isCurrent(capture),
                      loginAttempts.owns(code: userCode, generation: loginGeneration) else { return false }
                persisted = replaceCredentialsWithNewSession(
                    access: token,
                    expiryUnix: 0,
                    ownerCapture: capture,
                    ownerNamespace: capture.namespace
                ) == .success
                if persisted { loginAttempts.invalidate() }
                return persisted
            }
            guard installed, persisted else {
                try Task.checkCancellation()
                throw SIMKLError.transport("SIMKL credential persistence failed")
            }
            return .authorized(token)
        }
        return .pending
    }

    /// Run the full polling loop until the user authorizes or the code expires. On success the token is
    /// already stored; the return value is the same token.
    @discardableResult
    func pollForToken(userCode: String, interval: Int, expiresIn: Int) async throws -> String {
        let capture = ownerCapture()
        guard let loginGeneration = loginAttempts.generation(for: userCode) else {
            throw SIMKLError.sessionChanged
        }
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        let waitSeconds = max(interval, 1)
        while Date() < deadline {
            guard CredentialScopeRegistry.shared.isCurrent(capture) else { throw SIMKLError.sessionChanged }
            try await sleep(seconds: waitSeconds)
            try Task.checkCancellation()
            let result = try await poll(
                userCode: userCode,
                loginGeneration: loginGeneration,
                ownerCapture: capture
            )
            if case .authorized(let token) = result { return token }
            try Task.checkCancellation()
        }
        throw SIMKLError.expired
    }

    /// Stop the currently displayed PIN flow without affecting an already authenticated account.
    func cancelLoginAttempt() {
        loginAttempts.invalidate()
    }

    // MARK: - Persistence + HTTP plumbing

    private func currentSessionID(ownerNamespace namespace: String? = nil) -> SIMKLSessionID? {
        let resolvedNamespace = namespace ?? ownerCapture().namespace
        guard let sessionID = currentSessionIDWithoutRepair(ownerNamespace: resolvedNamespace),
              CredentialPublicationOutbox.permitsPassiveRead(
            account: SIMKLTokenSlots.publication(resolvedNamespace),
            sessionID: sessionID.rawValue,
            read: credentials.certifiedRead
        ) else { return nil }
        return sessionID
    }

    private nonisolated static func replayPublicationOutbox(
        credentials: SIMKLCredentialStore,
        ownerNamespace namespace: String,
        promoteLegacyMirror: Bool = false
    ) -> Bool {
        let account = SIMKLTokenSlots.publication(namespace)
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
            SIMKLTokenSlots.access(namespace),
            SIMKLTokenSlots.expiry(namespace),
            SIMKLTokenSlots.session(namespace)
        ]
        let selected = CredentialTupleTransaction.readAuthority(
            baseAccounts: baseAccounts,
            activePointer: SIMKLTokenSlots.active(namespace),
            certifiedRead: credentials.certifiedRead
        )
        let authority: CredentialTupleAuthority
        switch selected {
        case let .authority(active) where active.values.count == 3 && active.values.last == sessionRaw:
            authority = active
        case let .authority(active) where active.values.count == 3:
            guard case let .value(rawCandidate) = credentials.certifiedRead(SIMKLTokenSlots.candidate(namespace)),
                  rawCandidate.hasPrefix("candidate:"),
                  let candidatePointer = CredentialTupleTransaction.canonicalPointer(
                      String(rawCandidate.dropFirst("candidate:".count))
                  ),
                  case let .authority(candidate) = CredentialTupleTransaction.readStagedAuthority(
                      baseAccounts: baseAccounts,
                      pointer: candidatePointer,
                      certifiedRead: credentials.certifiedRead
                  ),
                  candidate.values.count == 3,
                  candidate.values.last == sessionRaw,
                  active.values.last != sessionRaw else { return false }
            authority = candidate
        default:
            return false
        }
        let recovery = CredentialTupleTransaction.transition(
            baseAccounts: baseAccounts,
            activePointer: SIMKLTokenSlots.active(namespace),
            cleanupMarker: SIMKLTokenSlots.cleanup(namespace),
            candidateMarker: SIMKLTokenSlots.candidate(namespace),
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
            activePointer: SIMKLTokenSlots.active(namespace),
            certifiedRead: credentials.certifiedRead
        )
        guard case let .authority(recoveredAuthority) = recovered,
              recoveredAuthority.values == authority.values,
              case .missing = credentials.certifiedRead(SIMKLTokenSlots.cleanup(namespace)),
              case .missing = credentials.certifiedRead(SIMKLTokenSlots.candidate(namespace)) else {
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
                    SIMKLAuthBoundary.publish(SIMKLSessionID(rawValue: sessionRaw))
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
        switch credentials.certifiedRead(SIMKLTokenSlots.candidate(namespace)) {
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

    private func currentSessionIDWithoutRepair(ownerNamespace namespace: String) -> SIMKLSessionID? {
        guard case let .authority(active) = readCredentialTuple(ownerNamespace: namespace),
              active.values.count == 3,
              !active.values[0].isEmpty,
              Int(active.values[1]) != nil,
              !active.values[2].isEmpty else { return nil }
        return SIMKLSessionID(rawValue: active.values[2])
    }

    @discardableResult
    private func replaceCredentialsWithNewSession(
        access: String,
        expiryUnix: Int,
        ownerCapture capture: CredentialScopeRegistry.Capture,
        ownerNamespace namespace: String? = nil,
        sessionID suppliedSessionID: SIMKLSessionID? = nil,
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
        if case .missing = credentials.certifiedRead(SIMKLTokenSlots.active(resolvedNamespace)),
           case let .value(rawCandidate) = credentials.certifiedRead(SIMKLTokenSlots.candidate(resolvedNamespace)),
           rawCandidate.hasPrefix("candidate:"),
           let pointer = CredentialTupleTransaction.canonicalPointer(
               String(rawCandidate.dropFirst("candidate:".count))
           ),
           case let .authority(candidate) = CredentialTupleTransaction.readStagedAuthority(
               baseAccounts: tupleAccounts(ownerNamespace: resolvedNamespace),
               pointer: pointer,
               certifiedRead: credentials.certifiedRead
           ),
           candidate.values.count == 3,
           candidate.values[0] == access,
           candidate.values[1] == String(expiryUnix),
           !candidate.values[2].isEmpty,
           suppliedSessionID == nil || suppliedSessionID?.rawValue == candidate.values[2] {
            let state = CredentialPublicationOutbox.state(
                account: SIMKLTokenSlots.publication(resolvedNamespace),
                read: credentials.certifiedRead
            )
            let intentMatches: Bool
            switch state {
            case let .pending(session), let .acknowledged(session):
                guard session == candidate.values[2] else { return .failure }
                intentMatches = true
            case .missing:
                intentMatches = false
            case .dispatching, .failure:
                return .failure
            }
            if intentMatches {
                switch CredentialTupleTransaction.transition(
                    baseAccounts: tupleAccounts(ownerNamespace: resolvedNamespace),
                    activePointer: SIMKLTokenSlots.active(resolvedNamespace),
                    cleanupMarker: SIMKLTokenSlots.cleanup(resolvedNamespace),
                    candidateMarker: SIMKLTokenSlots.candidate(resolvedNamespace),
                    candidateValues: candidate.values,
                    publicationMarker: SIMKLTokenSlots.publication(resolvedNamespace),
                    publicationValue: candidate.values[2],
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
        let existingSession: SIMKLSessionID?
        if case let .authority(active) = current,
           active.values.count == 3,
           active.values[0] == access,
           active.values[1] == String(expiryUnix),
           !active.values[2].isEmpty {
            existingSession = SIMKLSessionID(rawValue: active.values[2])
        } else {
            existingSession = nil
        }
        let sessionID = suppliedSessionID ?? existingSession ?? SIMKLSessionID.random()
        let transition = CredentialTupleTransaction.transition(
            baseAccounts: tupleAccounts(ownerNamespace: resolvedNamespace),
            activePointer: SIMKLTokenSlots.active(resolvedNamespace),
            cleanupMarker: SIMKLTokenSlots.cleanup(resolvedNamespace),
            candidateMarker: SIMKLTokenSlots.candidate(resolvedNamespace),
            candidateValues: [access, String(expiryUnix), sessionID.rawValue],
            publicationMarker: publishSession ? SIMKLTokenSlots.publication(resolvedNamespace) : nil,
            publicationValue: publishSession ? sessionID.rawValue : nil,
            promoteLegacyMirror: promoteLegacyMirror,
            certifiedRead: credentials.certifiedRead,
            recoveryRead: credentials.recoveryRead,
            write: credentials.write
        )
        switch transition {
        case .activated:
            return publishSession && !Self.replayPublicationOutbox(credentials: credentials, ownerNamespace: resolvedNamespace)
                ? .failure
                : .success
        case .alreadyActive:
            return publishSession && !Self.replayPublicationOutbox(credentials: credentials, ownerNamespace: resolvedNamespace)
                ? .failure
                : .success
        case .cleanupPending:
            return .failure
        case .failedBeforeActivation, .activationStateUnknown:
            return .failure
        }
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
            activePointer: SIMKLTokenSlots.active(resolvedNamespace),
            cleanupMarker: SIMKLTokenSlots.cleanup(resolvedNamespace),
            candidateMarker: SIMKLTokenSlots.candidate(resolvedNamespace),
            extraAccounts: [SIMKLTokenSlots.publication(resolvedNamespace)],
            certifiedRead: credentials.certifiedRead,
            recoveryRead: credentials.recoveryRead,
            write: credentials.write
        ) else { return false }
        SIMKLAuthBoundary.publish(nil)
        return true
    }

    private func acquirePublicationBoundary() async -> Bool {
        await CredentialPublicationOutbox.waitForBoundary() == .acquired
    }

    @discardableResult
    private func performCredentialBoundary(
        expectedLoginGeneration: UInt64? = nil,
        _ mutation: () async -> Bool
    ) async -> Bool {
        pendingCredentialBoundaries += 1
        defer { pendingCredentialBoundaries -= 1 }
        await acquireCredentialBoundary()
        defer { releaseCredentialBoundary() }
        while activeSessionWrites > 0 {
            await withCheckedContinuation { continuation in
                sessionWriteDrainWaiters.append(continuation)
                sessionWriteDrainObserver?()
            }
        }
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
        credentialBoundaryWaiters.removeFirst().resume()
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

    private func ensureConfigured() throws {
        guard !configuration.clientID.isEmpty else { throw SIMKLError.notConfigured }
    }

    private var requiredQueryItems: [URLQueryItem] {
        [URLQueryItem(name: "client_id", value: configuration.clientID),
         URLQueryItem(name: "app-name", value: "VortX"),
         URLQueryItem(name: "app-version", value: Self.appVersion)]
    }

    private func makeGET(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.clientID, forHTTPHeaderField: "simkl-api-key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let response = try await transport.send(
                request,
                allowedHosts: configuration.allowedAPIHosts,
                maxResponseBytes: AuthenticatedHTTPTransport.controlResponseLimit
            )
            return (response.data, response.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SIMKLError.transport("SIMKL request failed.")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try AuthenticatedHTTPTransport.decodeJSON(type, from: data) }
        catch { throw SIMKLError.decoding }
    }

    private func sleep(seconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0)) * 1_000_000_000)
    }
}
