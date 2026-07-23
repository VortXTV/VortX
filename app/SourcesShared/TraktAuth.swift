import Foundation

/// Trakt.tv OAuth device-code flow plus Keychain-backed token storage.
///
/// The flow is the standard Trakt device path (https://trakt.docs.apiary.io/reference/authentication-devices):
///
///   1. `requestDeviceCode()` -> show `userCode` + `verificationURL` to the user.
///   2. `pollForToken(deviceCode:)` -> loop on `POST /oauth/device/token` at the server-given
///      `interval` until the user authorizes (200), denies (418), or the codes expire (410).
///   3. Tokens are stored in the Keychain via `Keychain.swift` (never UserDefaults, never backups).
///   4. `validToken()` returns a live access token, transparently refreshing when near expiry.
///
/// The config constants `clientID` / `clientSecret` are placeholders. A Trakt app must be registered
/// at https://trakt.tv/oauth/applications and the values filled in (or, preferably, injected from a
/// build-time secret) before the flow can run. `isConfigured` gates the whole feature so the app
/// ships safely with the values blank.
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

    // MARK: - Keychain accounts (token set lives here, nowhere else)

    private static let accessAccount = "vortx.trakt.accessToken"
    private static let refreshAccount = "vortx.trakt.refreshToken"
    private static let expiryAccount = "vortx.trakt.expiresAt"   // unix epoch seconds, stored as a string
    /// Unix epoch seconds when the token was ISSUED, stored as a string. Fourth slot: it lets
    /// `currentToken()` rebuild the token with its ORIGINAL lifetime so the 30-minute early-refresh
    /// leeway actually fires (see `TraktToken.defaultLeeway`). May be absent on installs whose token
    /// was stored before this slot existed; `currentToken()` degrades gracefully to hard-expiry-only.
    private static let createdAtAccount = "vortx.trakt.createdAt"
    private static let migrationGroup = "trakt"

    private let session: URLSession
    nonisolated private let tokenStorage: CredentialTokenStorage
    private let onBeforeCommit: (@Sendable () async -> Void)?

    /// The single in-flight refresh, if one is running. Concurrent `validToken()` callers (scrobbleStart,
    /// TraktSyncEngine.pullWatched, a rail fetch) await THIS task instead of each firing their own refresh
    /// POST. Trakt rotates the refresh token on every refresh, so two independent refreshes would race:
    /// the loser 401s on an already-spent refresh token and would drop the whole session. Single-flight
    /// collapses them into one, so only one rotation happens and everyone gets the same fresh token.
    private struct RefreshFlight {
        let id: UUID
        let operation: CredentialOperationStamp
        let task: Task<TraktToken, Error>
    }
    private var inFlightRefresh: RefreshFlight?
    private var pendingDeviceOperations: [String: CredentialOperationStamp] = [:]

    /// Injected at app startup (by `VortXSyncManager`): returns the freshest cross-device Trakt token
    /// triple from the synced `doc.apiKeys` mirror, or nil. Lets the refresh-401 path re-adopt a token a
    /// SIBLING device rotated and pushed, instead of signing this device out. A seam (not a direct import)
    /// so `TraktAuth` stays free of a `VortXSyncManager` dependency.
    private var syncedTokenProvider: (@Sendable () async -> (access: String, refresh: String, expiryUnix: Int)?)?

    init(
        session: URLSession = .shared,
        tokenStorage: CredentialTokenStorage = .keychain,
        onBeforeCommit: (@Sendable () async -> Void)? = nil
    ) {
        self.session = session
        self.tokenStorage = tokenStorage
        self.onBeforeCommit = onBeforeCommit
    }

    /// Wire the cross-device synced-token lookup used by the refresh-401 recovery path (T-2). Called once
    /// at startup from `VortXSyncManager`; a nil provider simply disables cross-device recovery.
    func setSyncedTokenProvider(_ provider: @escaping @Sendable () async -> (access: String, refresh: String, expiryUnix: Int)?) {
        syncedTokenProvider = provider
    }

    // MARK: - Public state

    /// True when a token set is stored (the user has connected Trakt). Does not check expiry.
    var isSignedIn: Bool {
        let scope = CredentialScopeSnapshotStore.shared.load().scope
        return string(Self.accessAccount, scope: scope)?.isEmpty == false
    }

    /// Drop all stored Trakt tokens (the user disconnected). Does not revoke server-side.
    func signOut() async {
        let operation = await beginOperation(.traktDisconnect)
        let committed = await commitIfCurrent(CredentialCommitStamp(operation: operation)) { scope in
            self.clearTokens(scope: scope)
        }
        if committed {
            inFlightRefresh?.task.cancel()
            inFlightRefresh = nil
            pendingDeviceOperations.removeAll(keepingCapacity: true)
        }
    }

    /// Adopt a token set that arrived from ANOTHER device over the E2E `doc.apiKeys` sync channel, so
    /// a Trakt connection made on one device follows the account to the rest. Writes the Keychain
    /// slots directly (no network). `expiryUnix` is absolute unix-epoch seconds (what `store` persists
    /// and `syncUp` mirrors). Ignores an empty access/refresh pair so a partial doc never clears a live
    /// local session. Idempotent: adopting the same tokens twice is a harmless overwrite.
    func adoptTokens(
        access: String,
        refresh: String,
        expiryUnix: Int,
        credentialStamp suppliedStamp: CredentialCommitStamp? = nil
    ) async {
        guard !access.isEmpty, !refresh.isEmpty else { return }
        let stamp: CredentialCommitStamp
        if let suppliedStamp {
            stamp = suppliedStamp
        } else {
            stamp = await currentCommitStamp()
        }
        let adoptedAt = Int(Date().timeIntervalSince1970)
        _ = await commitIfCurrent(stamp) { scope in
            self.writeTokens(
                access: access,
                refresh: refresh,
                expiryUnix: expiryUnix,
                createdAt: adoptedAt,
                scope: scope
            )
        }
    }

    /// The stored token triple for the sync PUSH side (access, refresh, absolute unix expiry), or nil
    /// when not signed in. Read-only mirror of `currentToken`; the sync manager sends these only when a
    /// local session exists and NEVER deletes them from the doc when absent (mirrors the debrid guard).
    func syncableTokens() -> (access: String, refresh: String, expiryUnix: Int)? {
        let scope = CredentialScopeSnapshotStore.shared.load().scope
        guard let access = string(Self.accessAccount, scope: scope), !access.isEmpty,
              let refresh = string(Self.refreshAccount, scope: scope), !refresh.isEmpty,
              let expiryString = string(Self.expiryAccount, scope: scope), let expiry = Int(expiryString)
        else { return nil }
        return (access, refresh, expiry)
    }

    // MARK: - Step 1: request a device code

    /// Begin the device flow. Returns the codes and polling schedule to drive the UI and step 2.
    func requestDeviceCode() async throws -> TraktDeviceCode {
        try ensureConfigured()
        let operation = await beginOperation(.traktDevicePoll)
        let stamp = CredentialCommitStamp(operation: operation)
        guard await isCurrent(stamp) else { throw TraktAuthError.superseded }
        struct Body: Encodable { let client_id: String }
        let request = try makeRequest(
            path: "/oauth/device/code",
            method: "POST",
            body: Body(client_id: Self.clientID),
            authorized: false
        )
        let (data, status) = try await send(request)
        guard await isCurrent(stamp) else { throw TraktAuthError.superseded }
        DiagnosticsLog.log("trakt-auth", "device/code -> HTTP \(status)")
        guard status == 200 else {
            // A 401 at the CODE step means the shipped client_id is not a valid Trakt app key. Surface it
            // distinctly from a transient server fault so a provisioning problem is unambiguous.
            if status == 401 { throw TraktAuthError.invalidClient }
            throw TraktAuthError.server(status: status)
        }
        let code = try decode(TraktDeviceCode.self, from: data)
        pendingDeviceOperations[code.deviceCode] = operation
        return code
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
        let operation: CredentialOperationStamp
        if let pending = pendingDeviceOperations[deviceCode] {
            operation = pending
        } else {
            operation = await beginOperation(.traktDevicePoll)
            pendingDeviceOperations[deviceCode] = operation
        }
        return try await poll(deviceCode: deviceCode, operation: operation)
    }

    private func poll(
        deviceCode: String,
        operation: CredentialOperationStamp
    ) async throws -> PollResult {
        try ensureConfigured()
        let stamp = CredentialCommitStamp(operation: operation)
        guard await isCurrent(stamp) else { throw TraktAuthError.superseded }
        struct Body: Encodable { let code: String; let client_id: String; let client_secret: String }
        let request = try makeRequest(
            path: "/oauth/device/token",
            method: "POST",
            body: Body(code: deviceCode, client_id: Self.clientID, client_secret: Self.clientSecret),
            authorized: false
        )
        let (data, status) = try await send(request)
        guard await isCurrent(stamp) else { throw TraktAuthError.superseded }
        switch status {
        case 200:
            let token = try decode(TraktToken.self, from: data)
            guard await store(token, credentialStamp: stamp) else {
                throw TraktAuthError.superseded
            }
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
    @discardableResult
    func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> TraktToken {
        let operation: CredentialOperationStamp
        if let pending = pendingDeviceOperations[deviceCode] {
            operation = pending
        } else {
            operation = await beginOperation(.traktDevicePoll)
            pendingDeviceOperations[deviceCode] = operation
        }
        defer {
            if pendingDeviceOperations[deviceCode] == operation {
                pendingDeviceOperations.removeValue(forKey: deviceCode)
            }
        }
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        let baseInterval = max(interval, 1)
        var waitSeconds = baseInterval
        DiagnosticsLog.log("trakt-auth", "poll start interval=\(baseInterval)s expiresIn=\(expiresIn)s")
        while Date() < deadline {
            try await sleep(seconds: waitSeconds)
            try Task.checkCancellation()
            switch try await poll(deviceCode: deviceCode, operation: operation) {
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

    /// A live access token, refreshing first if the stored one is near expiry. Throws
    /// `.notSignedIn` when no token is stored.
    func validToken() async throws -> String {
        guard let token = currentToken() else { throw TraktAuthError.notSignedIn }
        if token.isExpired() {
            return try await refresh(using: token.refreshToken).accessToken
        }
        return token.accessToken
    }

    /// Exchange the refresh token for a fresh set via `POST /oauth/token`, SINGLE-FLIGHT: if a refresh is
    /// already running, await it instead of starting a second one (Trakt rotates the refresh token, so a
    /// second concurrent refresh would spend an already-rotated token and 401). Stores and returns the set.
    @discardableResult
    func refresh(using refreshToken: String) async throws -> TraktToken {
        while true {
            if let flight = inFlightRefresh {
                let current = await isCurrent(CredentialCommitStamp(operation: flight.operation))
                if current, inFlightRefresh?.id == flight.id {
                    return try await finish(flight)
                }
                if inFlightRefresh?.id == flight.id {
                    flight.task.cancel()
                    inFlightRefresh = nil
                }
                continue
            }

            let operation = await beginOperation(.traktRefresh)
            let stamp = CredentialCommitStamp(operation: operation)

            // A second caller can enter while beginOperation hops to MainActor.
            // If it reserved the flight first, join that newest current flight.
            if let flight = inFlightRefresh {
                if await isCurrent(CredentialCommitStamp(operation: flight.operation)) {
                    return try await finish(flight)
                }
                continue
            }
            guard await isCurrent(stamp) else { continue }

            // A refresh that completed moments ago may have stored a fresh token.
            // Read the owner captured by this operation, never the process's newer scope.
            if let fresh = currentToken(scope: operation.scope.scope), !fresh.isExpired() {
                return fresh
            }

            let id = UUID()
            let task = Task<TraktToken, Error> { [weak self] in
                guard let self else { throw TraktAuthError.notSignedIn }
                return try await self.performRefresh(using: refreshToken, credentialStamp: stamp)
            }
            let flight = RefreshFlight(id: id, operation: operation, task: task)
            inFlightRefresh = flight
            return try await finish(flight)
        }
    }

    private func finish(_ flight: RefreshFlight) async throws -> TraktToken {
        do {
            let token = try await flight.task.value
            if inFlightRefresh?.id == flight.id { inFlightRefresh = nil }
            return token
        } catch {
            if inFlightRefresh?.id == flight.id { inFlightRefresh = nil }
            throw error
        }
    }

    /// The actual `POST /oauth/token` refresh network call. Only ever invoked from inside the single-flight
    /// `refresh(using:)`, so at most one runs at a time.
    private func performRefresh(
        using refreshToken: String,
        credentialStamp: CredentialCommitStamp
    ) async throws -> TraktToken {
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
        guard await isCurrent(credentialStamp) else { throw TraktAuthError.superseded }
        let (data, status) = try await send(request)
        guard await isCurrent(credentialStamp) else { throw TraktAuthError.superseded }
        guard status == 200 else {
            // A rejected refresh token USUALLY means the session is dead, but a concurrent winner (this
            // device pre single-flight, or a SIBLING device over sync) may already have rotated a NEWER
            // token. Only sign out when no fresher token exists anywhere; otherwise adopt it and keep going.
            if status == 401 {
                if let recovered = await recoverAfterRefreshFailure(
                    deadRefreshToken: refreshToken,
                    credentialStamp: credentialStamp
                ) {
                    return recovered
                }
                // Terminal-wipe guard: the recovery path above SUSPENDS (it awaits the synced-token
                // provider), so another actor turn (a syncDown `adoptTokens`, a device-code poll storing
                // a brand-new set) may have landed a live token during that await. Re-check the Keychain
                // with NO suspension between this read and the wipe: a stored refresh token DIFFERENT
                // from the one this refresh just spent is that winner's live session, so return it
                // instead of wiping. Only when the stored set still carries the exact spent refresh
                // token (or nothing is stored) is the session truly dead.
                let terminal = await terminalRefreshFailure(
                    deadRefreshToken: refreshToken,
                    credentialStamp: credentialStamp
                )
                guard terminal.committed else { throw TraktAuthError.superseded }
                if let stored = terminal.replacement { return stored }
            }
            throw TraktAuthError.server(status: status)
        }
        let token = try decode(TraktToken.self, from: data)
        guard await store(token, credentialStamp: credentialStamp) else {
            throw TraktAuthError.superseded
        }
        return token
    }

    /// A refresh POST got a 401. Before signing out, look for a fresher token a concurrent winner already
    /// minted: (T-1c) re-read the Keychain in case a local refresh rotated it, then (T-2) consult the
    /// cross-device synced mirror in case a SIBLING device rotated and pushed one. Returns the token to
    /// adopt, or nil when nothing fresher exists (the caller then signs out).
    private func recoverAfterRefreshFailure(
        deadRefreshToken: String,
        credentialStamp: CredentialCommitStamp
    ) async -> TraktToken? {
        guard await isCurrent(credentialStamp) else { return nil }
        let scope = credentialStamp.scope.scope
        // (T-1c) A local winner rotated the token while this refresh was in flight. A Trakt rotation always
        // changes the refresh token, so a stored refresh token different from the one we just spent means a
        // winner already stored a rotated set; adopt it REGARDLESS of the access token's age (even an aged
        // set carries a live refresh token the next `validToken()` will spend), rather than wiping the
        // session over a token that merely needs its own refresh.
        if let local = currentToken(scope: scope), local.refreshToken != deadRefreshToken {
            return local
        }
        // (T-2) A sibling device rotated + pushed a newer token over the synced `doc.apiKeys` mirror. A
        // synced refresh token different from the one we spent is that sibling's fresher set; adopt it into
        // the Keychain and use it. Same-token or absent means nothing fresher exists remotely.
        if let synced = await syncedTokenProvider?(),
           !synced.access.isEmpty, !synced.refresh.isEmpty, synced.refresh != deadRefreshToken {
            guard await isCurrent(credentialStamp) else { return nil }
            let adoptedAt = Int(Date().timeIntervalSince1970)
            guard await commitIfCurrent(credentialStamp, { scope in
                self.writeTokens(
                    access: synced.access,
                    refresh: synced.refresh,
                    expiryUnix: synced.expiryUnix,
                    createdAt: adoptedAt,
                    scope: scope
                )
            }) else { return nil }
            return self.currentToken(scope: scope)
        }
        return nil
    }

    // MARK: - Keychain persistence

    /// The stored token set, reconstructed from the Keychain entries, or nil if not signed in.
    private func currentToken() -> TraktToken? {
        currentToken(scope: CredentialScopeSnapshotStore.shared.load().scope)
    }

    nonisolated private func currentToken(scope: CredentialScope) -> TraktToken? {
        guard let access = string(Self.accessAccount, scope: scope), !access.isEmpty,
              let refresh = string(Self.refreshAccount, scope: scope), !refresh.isEmpty,
              let expiryString = string(Self.expiryAccount, scope: scope),
              let expiry = Int(expiryString) else { return nil }
        // Rebuild with the ORIGINAL issue time when the fourth slot has it, so `expiresIn` is the
        // original lifetime and `defaultLeeway` gives a real 30-minute early refresh. (A rebuild from
        // the REMAINING lifetime makes `remaining <= min(1800, remaining/2)` unsatisfiable, so the
        // early refresh silently never fires and a data call can carry a token that expires in flight.)
        if let createdAtString = string(Self.createdAtAccount, scope: scope),
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

    @discardableResult
    private func store(
        _ token: TraktToken,
        credentialStamp: CredentialCommitStamp
    ) async -> Bool {
        await commitIfCurrent(credentialStamp) { scope in
            self.writeTokens(
                access: token.accessToken,
                refresh: token.refreshToken,
                expiryUnix: Int(token.expiresAt.timeIntervalSince1970),
                createdAt: token.createdAt,
                scope: scope
            )
        }
    }

    nonisolated private func string(_ account: String, scope: CredentialScope) -> String? {
        tokenStorage.read(account, Self.migrationGroup, scope)
    }

    nonisolated private func writeTokens(
        access: String,
        refresh: String,
        expiryUnix: Int,
        createdAt: Int,
        scope: CredentialScope
    ) {
        _ = tokenStorage.write(access, Self.accessAccount, scope)
        _ = tokenStorage.write(refresh, Self.refreshAccount, scope)
        _ = tokenStorage.write(String(expiryUnix), Self.expiryAccount, scope)
        _ = tokenStorage.write(String(createdAt), Self.createdAtAccount, scope)
    }

    nonisolated private func clearTokens(scope: CredentialScope) {
        _ = tokenStorage.write(nil, Self.accessAccount, scope)
        _ = tokenStorage.write(nil, Self.refreshAccount, scope)
        _ = tokenStorage.write(nil, Self.expiryAccount, scope)
        _ = tokenStorage.write(nil, Self.createdAtAccount, scope)
    }

    private func beginOperation(_ domain: CredentialOperationDomain) async -> CredentialOperationStamp {
        await MainActor.run { CredentialScopeAuthority.shared.beginOperation(domain) }
    }

    private func currentCommitStamp() async -> CredentialCommitStamp {
        await MainActor.run { CredentialScopeAuthority.shared.commitStamp() }
    }

    private func isCurrent(_ stamp: CredentialCommitStamp) async -> Bool {
        await MainActor.run { CredentialScopeAuthority.shared.isCurrent(stamp) }
    }

    @discardableResult
    private func commitIfCurrent(
        _ stamp: CredentialCommitStamp,
        _ mutation: @escaping @Sendable (CredentialScope) -> Void
    ) async -> Bool {
        if let onBeforeCommit { await onBeforeCommit() }
        return await MainActor.run {
            CredentialScopeAuthority.shared.commitIfCurrent(stamp) {
                mutation(stamp.scope.scope)
                return true
            } ?? false
        }
    }

    private func terminalRefreshFailure(
        deadRefreshToken: String,
        credentialStamp: CredentialCommitStamp
    ) async -> (committed: Bool, replacement: TraktToken?) {
        await MainActor.run {
            CredentialScopeAuthority.shared.commitIfCurrent(credentialStamp) {
                let scope = credentialStamp.scope.scope
                if let stored = self.currentToken(scope: scope),
                   stored.refreshToken != deadRefreshToken {
                    return (true, stored)
                }
                self.clearTokens(scope: scope)
                return (true, nil)
            } ?? (false, nil)
        }
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
    case superseded
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
        case .superseded: return "A newer account or Trakt operation replaced this request."
        case .server(let status): return "Trakt returned an error (HTTP \(status))."
        case .transport(let message): return message
        case .decoding: return "Could not read the response from Trakt."
        }
    }
}
