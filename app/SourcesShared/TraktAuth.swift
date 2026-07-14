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

    /// True once a non-empty client id/secret pair is present. Everything no-ops until then.
    static var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    // MARK: - Keychain accounts (token set lives here, nowhere else)

    private let accessAccount = "vortx.trakt.accessToken"
    private let refreshAccount = "vortx.trakt.refreshToken"
    private let expiryAccount = "vortx.trakt.expiresAt"   // unix epoch seconds, stored as a string

    private let session: URLSession

    /// The single in-flight refresh, if one is running. Concurrent `validToken()` callers (scrobbleStart,
    /// TraktSyncEngine.pullWatched, a rail fetch) await THIS task instead of each firing their own refresh
    /// POST. Trakt rotates the refresh token on every refresh, so two independent refreshes would race:
    /// the loser 401s on an already-spent refresh token and would drop the whole session. Single-flight
    /// collapses them into one, so only one rotation happens and everyone gets the same fresh token.
    private var inFlightRefresh: Task<TraktToken, Error>?

    /// Injected at app startup (by `VortXSyncManager`): returns the freshest cross-device Trakt token
    /// triple from the synced `doc.apiKeys` mirror, or nil. Lets the refresh-401 path re-adopt a token a
    /// SIBLING device rotated and pushed, instead of signing this device out. A seam (not a direct import)
    /// so `TraktAuth` stays free of a `VortXSyncManager` dependency.
    private var syncedTokenProvider: (@Sendable () async -> (access: String, refresh: String, expiryUnix: Int)?)?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Wire the cross-device synced-token lookup used by the refresh-401 recovery path (T-2). Called once
    /// at startup from `VortXSyncManager`; a nil provider simply disables cross-device recovery.
    func setSyncedTokenProvider(_ provider: @escaping @Sendable () async -> (access: String, refresh: String, expiryUnix: Int)?) {
        syncedTokenProvider = provider
    }

    // MARK: - Public state

    /// True when a token set is stored (the user has connected Trakt). Does not check expiry.
    var isSignedIn: Bool { Keychain.string(accessAccount)?.isEmpty == false }

    /// Drop all stored Trakt tokens (the user disconnected). Does not revoke server-side.
    func signOut() {
        Keychain.set(nil, for: accessAccount)
        Keychain.set(nil, for: refreshAccount)
        Keychain.set(nil, for: expiryAccount)
    }

    /// Adopt a token set that arrived from ANOTHER device over the E2E `doc.apiKeys` sync channel, so
    /// a Trakt connection made on one device follows the account to the rest. Writes the three Keychain
    /// slots directly (no network). `expiryUnix` is absolute unix-epoch seconds (what `store` persists
    /// and `syncUp` mirrors). Ignores an empty access/refresh pair so a partial doc never clears a live
    /// local session. Idempotent: adopting the same tokens twice is a harmless overwrite.
    func adoptTokens(access: String, refresh: String, expiryUnix: Int) {
        guard !access.isEmpty, !refresh.isEmpty else { return }
        Keychain.set(access, for: accessAccount)
        Keychain.set(refresh, for: refreshAccount)
        Keychain.set(String(expiryUnix), for: expiryAccount)
    }

    /// The stored token triple for the sync PUSH side (access, refresh, absolute unix expiry), or nil
    /// when not signed in. Read-only mirror of `currentToken`; the sync manager sends these only when a
    /// local session exists and NEVER deletes them from the doc when absent (mirrors the debrid guard).
    func syncableTokens() -> (access: String, refresh: String, expiryUnix: Int)? {
        guard let access = Keychain.string(accessAccount), !access.isEmpty,
              let refresh = Keychain.string(refreshAccount), !refresh.isEmpty,
              let expiryString = Keychain.string(expiryAccount), let expiry = Int(expiryString)
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
        guard status == 200 else { throw TraktAuthError.server(status: status) }
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
            store(token)
            return .authorized(token)
        case 400:
            // Pending: the user has not finished authorizing yet. Keep polling.
            return .pending
        case 429:
            // Slow down: the app polled faster than `interval`. Back off, then keep polling.
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
            throw TraktAuthError.server(status: status)
        }
    }

    /// Run the full polling loop until the user authorizes, denies, or the codes expire. Honors the
    /// server `interval`, backs off an extra second on a 429, and stops once `expiresIn` elapses.
    /// On success the token is already stored in the Keychain; the return value is the same token.
    @discardableResult
    func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> TraktToken {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var waitSeconds = max(interval, 1)
        while Date() < deadline {
            try await sleep(seconds: waitSeconds)
            try Task.checkCancellation()
            switch try await poll(deviceCode: deviceCode) {
            case .authorized(let token):
                return token
            case .pending:
                waitSeconds = max(interval, 1)
            case .slowDown:
                waitSeconds = max(interval, 1) + 1   // back off per Trakt guidance
            }
        }
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
        // Join an in-flight refresh rather than starting a competing one.
        if let existing = inFlightRefresh {
            return try await existing.value
        }
        // A refresh that completed moments ago (whose defer already cleared `inFlightRefresh`) may have
        // stored a fresh token. A caller that just missed the in-flight window must not refresh again with
        // the now-rotated refresh token, so re-check synchronously (no await) before starting a new one.
        if let fresh = currentToken(), !fresh.isExpired() {
            return fresh
        }
        let task = Task<TraktToken, Error> { [weak self] in
            guard let self else { throw TraktAuthError.notSignedIn }
            return try await self.performRefresh(using: refreshToken)
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    /// The actual `POST /oauth/token` refresh network call. Only ever invoked from inside the single-flight
    /// `refresh(using:)`, so at most one runs at a time.
    private func performRefresh(using refreshToken: String) async throws -> TraktToken {
        try ensureConfigured()
        struct Body: Encodable {
            let refresh_token: String
            let client_id: String
            let client_secret: String
            // Trakt requires a redirect_uri even on the refresh grant; the device flow uses the
            // documented out-of-band value.
            let redirect_uri: String
            let grant_type: String
        }
        let body = Body(
            refresh_token: refreshToken,
            client_id: Self.clientID,
            client_secret: Self.clientSecret,
            redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
            grant_type: "refresh_token"
        )
        let request = try makeRequest(path: "/oauth/token", method: "POST", body: body, authorized: false)
        let (data, status) = try await send(request)
        guard status == 200 else {
            // A rejected refresh token USUALLY means the session is dead, but a concurrent winner (this
            // device pre single-flight, or a SIBLING device over sync) may already have rotated a NEWER
            // token. Only sign out when no fresher token exists anywhere; otherwise adopt it and keep going.
            if status == 401, let recovered = await recoverAfterRefreshFailure(deadRefreshToken: refreshToken) {
                return recovered
            }
            if status == 401 { signOut() }
            throw TraktAuthError.server(status: status)
        }
        let token = try decode(TraktToken.self, from: data)
        store(token)
        return token
    }

    /// A refresh POST got a 401. Before signing out, look for a fresher token a concurrent winner already
    /// minted: (T-1c) re-read the Keychain in case a local refresh rotated it, then (T-2) consult the
    /// cross-device synced mirror in case a SIBLING device rotated and pushed one. Returns the token to
    /// adopt, or nil when nothing fresher exists (the caller then signs out).
    private func recoverAfterRefreshFailure(deadRefreshToken: String) async -> TraktToken? {
        // (T-1c) A local winner rotated the token while this refresh was in flight. A Trakt rotation always
        // changes the refresh token, so a stored refresh token different from the one we just spent means a
        // winner already stored a live set; adopt it rather than wiping the session.
        if let local = currentToken(), local.refreshToken != deadRefreshToken, !local.isExpired() {
            return local
        }
        // (T-2) A sibling device rotated + pushed a newer token over the synced `doc.apiKeys` mirror. A
        // synced refresh token different from the one we spent is that sibling's fresher set; adopt it into
        // the Keychain and use it. Same-token or absent means nothing fresher exists remotely.
        if let synced = await syncedTokenProvider?(),
           !synced.access.isEmpty, !synced.refresh.isEmpty, synced.refresh != deadRefreshToken {
            adoptTokens(access: synced.access, refresh: synced.refresh, expiryUnix: synced.expiryUnix)
            return currentToken()
        }
        return nil
    }

    // MARK: - Keychain persistence

    /// The stored token set, reconstructed from the three Keychain entries, or nil if not signed in.
    private func currentToken() -> TraktToken? {
        guard let access = Keychain.string(accessAccount), !access.isEmpty,
              let refresh = Keychain.string(refreshAccount), !refresh.isEmpty,
              let expiryString = Keychain.string(expiryAccount),
              let expiry = Int(expiryString) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        // Persist absolute expiry as createdAt=now + remaining lifetime; lifetime sign is derived back.
        return TraktToken(accessToken: access, refreshToken: refresh,
                          expiresIn: expiry - now, createdAt: now)
    }

    private func store(_ token: TraktToken) {
        Keychain.set(token.accessToken, for: accessAccount)
        Keychain.set(token.refreshToken, for: refreshAccount)
        Keychain.set(String(Int(token.expiresAt.timeIntervalSince1970)), for: expiryAccount)
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
        case .server(let status): return "Trakt returned an error (HTTP \(status))."
        case .transport(let message): return message
        case .decoding: return "Could not read the response from Trakt."
        }
    }
}
