import Foundation

// CREDENTIAL_TRAKT_SLOTS_BEGIN
/// Owner-scoped Keychain slot names for the Trakt token set (M3, INS-260722-06R v2: PER-ACCOUNT scope).
///
/// Nonisolated on purpose: BOTH the `TraktAuth` actor (device flow, refresh) and the @MainActor synchronous
/// sync-adoption path (`adoptSyncedTokens`, the H2 fix) write these slots, so the names must be derivable
/// without an actor hop. The pre-scoping global names remain only as a one-owner claim source (REQ-23
/// delete-source-first, via `CredentialLegacyClaim`); they are never written again.
enum TraktTokenSlots {
    static let legacyAccess = "vortx.trakt.accessToken"
    static let legacyRefresh = "vortx.trakt.refreshToken"
    static let legacyExpiry = "vortx.trakt.expiresAt"
    static let legacyCreatedAt = "vortx.trakt.createdAt"
    /// One-owner claim marker for the legacy global token set (no credential value inside).
    static let claimMarker = "vortx.trakt.migration.global.owner"

    static func access(_ ns: String) -> String { legacyAccess + "." + ns }
    static func refresh(_ ns: String) -> String { legacyRefresh + "." + ns }
    static func expiry(_ ns: String) -> String { legacyExpiry + "." + ns }
    static func createdAt(_ ns: String) -> String { legacyCreatedAt + "." + ns }

    /// Claim the unowned global legacy token set for `ns` (first explicit bind wins, permanently), moving
    /// it into the owner's scoped slots delete-source-first. Synchronous; called from the main-actor scope
    /// bind in `VortXSyncManager`.
    static func claimLegacyGlobal(ownerNamespace ns: String) {
        CredentialLegacyClaim.claimGlobalSlotSet(
            slots: [
                (source: legacyAccess, destination: access(ns)),
                (source: legacyRefresh, destination: refresh(ns)),
                (source: legacyExpiry, destination: expiry(ns)),
                (source: legacyCreatedAt, destination: createdAt(ns)),
            ],
            claimMarkerAccount: claimMarker,
            ownerNamespace: ns,
            provenanceTag: "trakt-token-set"
        )
    }

    /// H2 (INS-260722-06R v2): adopt a synced Trakt token set with ALL Keychain writes in ONE synchronous
    /// closure, no await between the caller's session validation and these writes. The caller (`syncDown`'s
    /// apply region) is @MainActor and validates the credential session in the SAME turn; the actor hop the
    /// old `adoptTokens` await performed is exactly the guard-to-Keychain gap this replaces. Writes target
    /// the CALLER-CAPTURED owner namespace, never "whatever is current at write time".
    static func adoptSyncedTokens(access: String, refresh: String, expiryUnix: Int, ownerNamespace ns: String) {
        guard !access.isEmpty, !refresh.isEmpty else { return }
        Keychain.set(access, for: Self.access(ns))
        Keychain.set(refresh, for: Self.refresh(ns))
        Keychain.set(String(expiryUnix), for: Self.expiry(ns))
        // The synced mirror carries no issue time, so stamp adoption time. The rebuilt "lifetime" is
        // then the REMAINING lifetime at adoption, whose half-life leeway is always strictly less than
        // the remaining time itself, so a just-adopted token is never instantly read as expired.
        Keychain.set(String(Int(Date().timeIntervalSince1970)), for: Self.createdAt(ns))
    }
}
// CREDENTIAL_TRAKT_SLOTS_END

/// Trakt.tv OAuth device-code flow plus Keychain-backed token storage.
///
/// The flow is the standard Trakt device path (https://trakt.docs.apiary.io/reference/authentication-devices):
///
///   1. `requestDeviceCode()` -> show `userCode` + `verificationURL` to the user.
///   2. `pollForToken(deviceCode:)` -> loop on `POST /oauth/device/token` at the server-given
///      `interval` until the user authorizes (200), denies (418), or the codes expire (410).
///   3. Tokens are stored in the Keychain via `Keychain.swift` (never UserDefaults, never backups),
///      SCOPED TO THE OWNER (VortX account or the signed-out device) that started the operation.
///   4. `validToken()` returns a live access token, transparently refreshing when near expiry.
///
/// OWNER CAPTURE RULE (M3): every public entry point captures the CURRENT owner namespace ONCE, before its
/// first suspension, and every Keychain slot it touches is derived from that capture. A VortX account switch
/// mid-operation therefore files results under the owner that STARTED the operation (whose scope they belong
/// to) and can never write into the switched-in owner's scope.
actor TraktAuth {
    static let shared = TraktAuth()

    // MARK: - Configuration (build-time credentials; empty ships a dormant, invisible feature)

    /// Trakt application client id (https://trakt.tv/oauth/applications), read at runtime from the
    /// Info.plist `TraktClientId` key, which Xcode substitutes from the `$(TRAKT_CLIENT_ID)` build
    /// setting (gitignored Config/ExternalSync.xcconfig or a CI secret; EMPTY default). Falls back to
    /// "" when absent, so a fresh/public build has no credentials and `isConfigured` stays false.
    static let clientID = TraktAuth.infoValue("TraktClientId")
    /// Trakt application client secret, same seam as `clientID` (Info.plist `TraktClientSecret` <-
    /// `$(TRAKT_CLIENT_SECRET)`). Never committed; the repo is public.
    static let clientSecret = TraktAuth.infoValue("TraktClientSecret")

    /// Read an Info.plist string, trimmed, with a "" fallback. `$(VAR)` substitution leaves the key
    /// as an empty string (not the literal token) when the build setting is empty, so a blank value
    /// reads as "" here. Never crashes.
    private static func infoValue(_ key: String) -> String {
        ((Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// API base for OAuth endpoints. Trakt serves OAuth off the same host as the data API.
    static let apiBase = "https://api.trakt.tv"

    /// The OAuth redirect URI registered for this app at https://trakt.tv/oauth/applications. Trakt
    /// requires it on the `refresh_token` grant and it MUST byte-for-byte equal the registered value,
    /// or the refresh 401s and the session is silently dropped (which presents to the user as "Trakt
    /// stopped working" after the first successful sign-in). This is the documented out-of-band value
    /// for a device/no-callback client; it is a PUBLIC constant (not a secret), so it is hardcoded here
    /// rather than plumbed through xcconfig/Info.plist. NOTE: the DEVICE token exchange
    /// (`POST /oauth/device/token`) does NOT send a redirect_uri; Trakt's device flow does not expect
    /// one, and sending a stray value there can get the exchange rejected. Only `performRefresh` uses it.
    static let registeredRedirectURI = "urn:ietf:wg:oauth:2.0:oob"

    /// True once a non-empty client id/secret pair is present. Everything no-ops until then.
    static var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    private let session: URLSession

    /// The single in-flight refresh for ONE owner namespace, if one is running. Concurrent `validToken()`
    /// callers under the same owner await THIS task instead of each firing their own refresh POST. Trakt
    /// rotates the refresh token on every refresh, so two independent refreshes would race: the loser 401s
    /// on an already-spent refresh token and would drop the whole session. Single-flight collapses them into
    /// one. Keyed by the owner namespace so a caller under a DIFFERENT owner never joins (and never
    /// receives) another owner's refresh.
    private var inFlightRefresh: (ns: String, task: Task<TraktToken, Error>)?

    /// Injected at app startup (by `VortXSyncManager`): returns the freshest cross-device Trakt token
    /// triple from the synced `doc.apiKeys` mirror, or nil. Lets the refresh-401 path re-adopt a token a
    /// SIBLING device rotated and pushed, instead of signing this device out. A seam (not a direct import)
    /// so `TraktAuth` stays free of a `VortXSyncManager` dependency. The provider validates ITS OWN
    /// credential session across its pull, so a mid-pull account switch yields nil, never another
    /// account's mirror.
    private var syncedTokenProvider: (@Sendable () async -> (access: String, refresh: String, expiryUnix: Int)?)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Wire the cross-device synced-token lookup used by the refresh-401 recovery path (T-2). Called once
    /// at startup from `VortXSyncManager`; a nil provider simply disables cross-device recovery.
    func setSyncedTokenProvider(_ provider: @escaping @Sendable () async -> (access: String, refresh: String, expiryUnix: Int)?) {
        syncedTokenProvider = provider
    }

    /// The owner namespace captured at operation entry (see the OWNER CAPTURE RULE above).
    private nonisolated func currentOwnerNamespace() -> String {
        CredentialScopeRegistry.shared.currentNamespace()
    }

    // MARK: - Public state

    /// True when a token set is stored for the CURRENT owner (the user has connected Trakt). Does not
    /// check expiry.
    var isSignedIn: Bool {
        Keychain.string(TraktTokenSlots.access(currentOwnerNamespace()))?.isEmpty == false
    }

    /// Drop the CURRENT owner's stored Trakt tokens (the user disconnected). Does not revoke server-side.
    /// H5: the token clear records provenance at commit time, in the same synchronous run as the writes.
    func signOut() {
        let ns = currentOwnerNamespace()
        Keychain.set(nil, for: TraktTokenSlots.access(ns))
        Keychain.set(nil, for: TraktTokenSlots.refresh(ns))
        Keychain.set(nil, for: TraktTokenSlots.expiry(ns))
        Keychain.set(nil, for: TraktTokenSlots.createdAt(ns))
        CredentialProvenance.record(event: "token-clear.trakt", ownerNamespace: ns)
    }

    /// The stored token triple for the sync PUSH side (access, refresh, absolute unix expiry), or nil
    /// when not signed in, read from the CALLER-CAPTURED owner scope so a mid-merge account switch can
    /// never mirror the previous owner's connection into the next owner's doc. The sync manager sends
    /// these only when a local session exists and NEVER deletes them from the doc when absent (mirrors
    /// the debrid guard).
    nonisolated static func syncableTokens(ownerNamespace ns: String) -> (access: String, refresh: String, expiryUnix: Int)? {
        guard let access = Keychain.string(TraktTokenSlots.access(ns)), !access.isEmpty,
              let refresh = Keychain.string(TraktTokenSlots.refresh(ns)), !refresh.isEmpty,
              let expiryString = Keychain.string(TraktTokenSlots.expiry(ns)), let expiry = Int(expiryString)
        else { return nil }
        return (access, refresh, expiry)
    }

    // MARK: - Step 1: request a device code

    /// Begin the device flow. Returns the codes and polling schedule to drive the UI and step 2.
    func requestDeviceCode() async throws -> TraktDeviceCode {
        try ensureConfigured()
        struct Body: Encodable { let client_id: String }
        let request = try makeRequest(
            path: "/oauth/device/code",
            method: "POST",
            body: Body(client_id: Self.clientID),
            authorized: false
        )
        let (data, status) = try await send(request)
        DiagnosticsLog.log("trakt-auth", "device/code -> HTTP \(status)")
        guard status == 200 else {
            // A 401 at the CODE step means the shipped client_id is not a valid Trakt app key. Surface it
            // distinctly from a transient server fault so a provisioning problem is unambiguous.
            if status == 401 { throw TraktAuthError.invalidClient }
            throw TraktAuthError.server(status: status)
        }
        return try decode(TraktDeviceCode.self, from: data)
    }

    // MARK: - Step 2: poll for the token

    /// One poll of `POST /oauth/device/token`. `.pending` and `.slowDown` are the keep-polling
    /// signals; `.authorized` returns the token; terminal failures throw. Most callers should use
    /// `pollForToken(deviceCode:interval:expiresIn:)` which runs the whole loop.
    enum PollResult: Sendable {
        case authorized(TraktToken)
        case pending
        case slowDown
    }

    func poll(deviceCode: String) async throws -> PollResult {
        try await poll(deviceCode: deviceCode, ownerNamespace: currentOwnerNamespace())
    }

    private func poll(deviceCode: String, ownerNamespace ns: String) async throws -> PollResult {
        try ensureConfigured()
        struct Body: Encodable { let code: String; let client_id: String; let client_secret: String }
        let request = try makeRequest(
            path: "/oauth/device/token",
            method: "POST",
            body: Body(code: deviceCode, client_id: Self.clientID, client_secret: Self.clientSecret),
            authorized: false
        )
        let (data, status) = try await send(request)
        switch status {
        case 200:
            let token = try decode(TraktToken.self, from: data)
            store(token, ownerNamespace: ns)
            DiagnosticsLog.log("trakt-auth", "device/token -> 200 authorized")
            return .authorized(token)
        case 400:
            // Pending: the user has not finished authorizing yet. Keep polling. Trakt sends a bare 400
            // with no OAuth error body for pending; a rejected client is a distinct status (401 below),
            // so this stays a clean keep-polling signal and is intentionally NOT logged (it repeats every
            // `interval` seconds and would flood the capped diagnostics log).
            return .pending
        case 401:
            // The client_id/client_secret PAIR was rejected. `device/code` needs only the id (so a user
            // code was still minted and shown), but this token exchange also needs the secret; a wrong or
            // mismatched TRAKT_CLIENT_SECRET fails ONLY here. This is exactly the SIMKL-works / Trakt-fails
            // asymmetry the tester saw: SIMKL's PIN flow authenticates with the client_id alone and never
            // sends a secret, so a bad Trakt secret is invisible to it. Surfaced as a terminal, actionable
            // error instead of spinning until the code expires.
            DiagnosticsLog.log("trakt-auth", "device/token -> 401 invalid_client (verify TRAKT_CLIENT_SECRET matches the app)")
            throw TraktAuthError.invalidClient
        case 429:
            // Slow down: the app polled faster than `interval`. Back off, then keep polling.
            DiagnosticsLog.log("trakt-auth", "device/token -> 429 slow_down")
            return .slowDown
        case 404:
            throw TraktAuthError.invalidDeviceCode
        case 409:
            throw TraktAuthError.codeAlreadyUsed
        case 410:
            throw TraktAuthError.expired
        case 418:
            throw TraktAuthError.denied
        default:
            DiagnosticsLog.log("trakt-auth", "device/token -> HTTP \(status) (unexpected)")
            throw TraktAuthError.server(status: status)
        }
    }

    /// Run the full polling loop until the user authorizes, denies, or the codes expire. Honors the
    /// server `interval`, backs off an extra second on a 429, and stops once `expiresIn` elapses.
    /// On success the token is already stored in the Keychain; the return value is the same token.
    /// The owner is captured ONCE, at entry: the connection the user initiated belongs to the owner who
    /// initiated it, even if the VortX session changes while the poll loop runs.
    @discardableResult
    func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> TraktToken {
        let ns = currentOwnerNamespace()
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        let baseInterval = max(interval, 1)
        var waitSeconds = baseInterval
        DiagnosticsLog.log("trakt-auth", "poll start interval=\(baseInterval)s expiresIn=\(expiresIn)s")
        while Date() < deadline {
            try await sleep(seconds: waitSeconds)
            try Task.checkCancellation()
            switch try await poll(deviceCode: deviceCode, ownerNamespace: ns) {
            case .authorized(let token):
                return token
            case .pending:
                waitSeconds = baseInterval
            case .slowDown:
                // Escalate on REPEATED 429s (Trakt raises the required interval each time it slows you
                // down); a flat `interval + 1` never grows and keeps tripping the limit. Reset to the base
                // happens on the next successful pending. Capped so a persistent 429 cannot stretch a
                // single poll unbounded.
                waitSeconds = min(waitSeconds + 1, baseInterval + 10)
            }
        }
        DiagnosticsLog.log("trakt-auth", "poll deadline reached without authorization (expired)")
        throw TraktAuthError.expired
    }

    // MARK: - Token access + refresh

    /// A live access token for the CURRENT owner, refreshing first if the stored one is near expiry.
    /// Throws `.notSignedIn` when no token is stored. The owner is captured once, before any suspension.
    func validToken() async throws -> String {
        let ns = currentOwnerNamespace()
        guard let token = currentToken(ownerNamespace: ns) else { throw TraktAuthError.notSignedIn }
        if token.isExpired() {
            return try await refresh(using: token.refreshToken, ownerNamespace: ns).accessToken
        }
        return token.accessToken
    }

    /// Exchange the refresh token for a fresh set via `POST /oauth/token`, SINGLE-FLIGHT per owner: if a
    /// refresh for the SAME owner is already running, await it instead of starting a second one (Trakt
    /// rotates the refresh token, so a second concurrent refresh would spend an already-rotated token and
    /// 401). Stores and returns the set.
    @discardableResult
    func refresh(using refreshToken: String) async throws -> TraktToken {
        try await refresh(using: refreshToken, ownerNamespace: currentOwnerNamespace())
    }

    private func refresh(using refreshToken: String, ownerNamespace ns: String) async throws -> TraktToken {
        // Join an in-flight refresh rather than starting a competing one, but ONLY within the same owner:
        // another owner's refresh is another owner's token set.
        if let existing = inFlightRefresh, existing.ns == ns {
            return try await existing.task.value
        }
        // A refresh that completed moments ago (whose defer already cleared `inFlightRefresh`) may have
        // stored a fresh token. A caller that just missed the in-flight window must not refresh again with
        // the now-rotated refresh token, so re-check synchronously (no await) before starting a new one.
        if let fresh = currentToken(ownerNamespace: ns), !fresh.isExpired() {
            return fresh
        }
        let task = Task<TraktToken, Error> { [weak self] in
            guard let self else { throw TraktAuthError.notSignedIn }
            return try await self.performRefresh(using: refreshToken, ownerNamespace: ns)
        }
        inFlightRefresh = (ns, task)
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    /// The actual `POST /oauth/token` refresh network call. Only ever invoked from inside the single-flight
    /// `refresh(using:ownerNamespace:)`, so at most one runs at a time.
    private func performRefresh(using refreshToken: String, ownerNamespace ns: String) async throws -> TraktToken {
        try ensureConfigured()
        struct Body: Encodable {
            let refresh_token: String
            let client_id: String
            let client_secret: String
            // Trakt requires a redirect_uri on the refresh grant, and it must equal the app's registered
            // value exactly (see `registeredRedirectURI`). The device token exchange, by contrast, sends
            // no redirect_uri at all.
            let redirect_uri: String
            let grant_type: String
        }
        let body = Body(
            refresh_token: refreshToken,
            client_id: Self.clientID,
            client_secret: Self.clientSecret,
            redirect_uri: Self.registeredRedirectURI,
            grant_type: "refresh_token"
        )
        let request = try makeRequest(path: "/oauth/token", method: "POST", body: body, authorized: false)
        let (data, status) = try await send(request)
        guard status == 200 else {
            // A rejected refresh token USUALLY means the session is dead, but a concurrent winner (this
            // device pre single-flight, or a SIBLING device over sync) may already have rotated a NEWER
            // token. Only sign out when no fresher token exists anywhere; otherwise adopt it and keep going.
            if status == 401 {
                if let recovered = await recoverAfterRefreshFailure(deadRefreshToken: refreshToken, ownerNamespace: ns) {
                    return recovered
                }
                // Terminal-wipe guard: the recovery path above SUSPENDS (it awaits the synced-token
                // provider), so another actor turn (a syncDown adoption, a device-code poll storing
                // a brand-new set) may have landed a live token during that await. Re-check the Keychain
                // with NO suspension between this read and the wipe: a stored refresh token DIFFERENT
                // from the one this refresh just spent is that winner's live session, so return it
                // instead of wiping. Only when the stored set still carries the exact spent refresh
                // token (or nothing is stored) is the session truly dead. The wipe targets ONLY the
                // captured owner's scope.
                if let stored = currentToken(ownerNamespace: ns), stored.refreshToken != refreshToken {
                    return stored
                }
                Keychain.set(nil, for: TraktTokenSlots.access(ns))
                Keychain.set(nil, for: TraktTokenSlots.refresh(ns))
                Keychain.set(nil, for: TraktTokenSlots.expiry(ns))
                Keychain.set(nil, for: TraktTokenSlots.createdAt(ns))
                CredentialProvenance.record(event: "token-clear.trakt.refresh-401", ownerNamespace: ns)
            }
            throw TraktAuthError.server(status: status)
        }
        let token = try decode(TraktToken.self, from: data)
        store(token, ownerNamespace: ns)
        return token
    }

    /// A refresh POST got a 401. Before signing out, look for a fresher token a concurrent winner already
    /// minted: (T-1c) re-read the Keychain in case a local refresh rotated it, then (T-2) consult the
    /// cross-device synced mirror in case a SIBLING device rotated and pushed one. Returns the token to
    /// adopt, or nil when nothing fresher exists (the caller then signs out).
    private func recoverAfterRefreshFailure(deadRefreshToken: String, ownerNamespace ns: String) async -> TraktToken? {
        // (T-1c) A local winner rotated the token while this refresh was in flight. A Trakt rotation always
        // changes the refresh token, so a stored refresh token different from the one we just spent means a
        // winner already stored a rotated set; adopt it REGARDLESS of the access token's age (even an aged
        // set carries a live refresh token the next `validToken()` will spend), rather than wiping the
        // session over a token that merely needs its own refresh.
        if let local = currentToken(ownerNamespace: ns), local.refreshToken != deadRefreshToken {
            return local
        }
        // (T-2) A sibling device rotated + pushed a newer token over the synced `doc.apiKeys` mirror. A
        // synced refresh token different from the one we spent is that sibling's fresher set; adopt it into
        // the Keychain and use it. Same-token or absent means nothing fresher exists remotely.
        //
        // OWNER RE-CHECK (M3): the provider suspends, and its result is the CURRENT VortX account's doc.
        // Adopt it only when the owner that started this refresh is still the current owner (the provider
        // additionally discards its own pull on a mid-pull session change), so one owner's synced mirror
        // can never be filed under another owner's scope.
        if let synced = await syncedTokenProvider?(),
           !synced.access.isEmpty, !synced.refresh.isEmpty, synced.refresh != deadRefreshToken,
           currentOwnerNamespace() == ns {
            TraktTokenSlots.adoptSyncedTokens(
                access: synced.access, refresh: synced.refresh, expiryUnix: synced.expiryUnix,
                ownerNamespace: ns
            )
            return currentToken(ownerNamespace: ns)
        }
        return nil
    }

    // MARK: - Keychain persistence

    /// The stored token set for an owner, reconstructed from the Keychain entries, or nil if not signed in.
    private func currentToken(ownerNamespace ns: String) -> TraktToken? {
        guard let access = Keychain.string(TraktTokenSlots.access(ns)), !access.isEmpty,
              let refresh = Keychain.string(TraktTokenSlots.refresh(ns)), !refresh.isEmpty,
              let expiryString = Keychain.string(TraktTokenSlots.expiry(ns)),
              let expiry = Int(expiryString) else { return nil }
        // Rebuild with the ORIGINAL issue time when the fourth slot has it, so `expiresIn` is the
        // original lifetime and `defaultLeeway` gives a real 30-minute early refresh. (A rebuild from
        // the REMAINING lifetime makes `remaining <= min(1800, remaining/2)` unsatisfiable, so the
        // early refresh silently never fires and a data call can carry a token that expires in flight.)
        if let createdAtString = Keychain.string(TraktTokenSlots.createdAt(ns)),
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

    private func store(_ token: TraktToken, ownerNamespace ns: String) {
        Keychain.set(token.accessToken, for: TraktTokenSlots.access(ns))
        Keychain.set(token.refreshToken, for: TraktTokenSlots.refresh(ns))
        Keychain.set(String(Int(token.expiresAt.timeIntervalSince1970)), for: TraktTokenSlots.expiry(ns))
        Keychain.set(String(token.createdAt), for: TraktTokenSlots.createdAt(ns))
    }

    // MARK: - HTTP plumbing

    private func ensureConfigured() throws {
        guard Self.isConfigured else { throw TraktAuthError.notConfigured }
    }

    private func makeRequest<Body: Encodable>(
        path: String, method: String, body: Body, authorized: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: Self.apiBase + path) else { throw TraktAuthError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The API key header is required on every Trakt call, even unauthenticated ones.
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(Self.clientID, forHTTPHeaderField: "trakt-api-key")
        request.httpBody = try JSONEncoder().encode(body)
        _ = authorized   // OAuth endpoints never carry a bearer; flag kept for call-site symmetry.
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw TraktAuthError.transport(error.localizedDescription)
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

/// Typed errors for the Trakt auth flow. `.notConfigured` is the pre-credentials state; the rest map
/// to the documented device/token status codes plus transport/decode faults.
enum TraktAuthError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case notSignedIn
    case badURL
    case invalidDeviceCode
    case codeAlreadyUsed
    case expired
    case denied
    /// The Trakt app credentials (client_id/client_secret pair) were rejected by the OAuth endpoint
    /// (HTTP 401). Distinct from a transient `.server` fault: it means the shipped credentials do not
    /// match a valid, enabled Trakt application, so retrying will not help until they are fixed.
    case invalidClient
    case server(status: Int)
    case transport(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Trakt is not configured in this build."
        case .notSignedIn: return "You are not connected to Trakt."
        case .badURL: return "The Trakt service URL is invalid."
        case .invalidDeviceCode: return "This Trakt sign-in code is not valid."
        case .codeAlreadyUsed: return "This Trakt sign-in code was already used."
        case .expired: return "The Trakt sign-in code expired. Please try again."
        case .denied: return "Trakt access was denied."
        case .invalidClient: return "Trakt did not accept this app's credentials. Please report this if it continues."
        case .server(let status): return "Trakt returned an error (HTTP \(status))."
        case .transport(let message): return message
        case .decoding: return "Could not read the response from Trakt."
        }
    }
}
