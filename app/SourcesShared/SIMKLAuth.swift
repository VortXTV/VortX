import Foundation

/// SIMKL PIN/device auth plus Keychain-backed token storage. Mirrors `TraktAuth`'s shape but for
/// SIMKL's simpler model: a PIN flow (request a code, poll until the user authorizes) that yields a
/// LONG-LIVED access token with NO refresh rotation. A missing/zero expiry is therefore treated as
/// "valid" rather than "expired" (do NOT copy `TraktToken`'s 24h-leeway refresh, which SIMKL lacks).
///
/// Credentials come from the same build-time seam as Trakt: the Info.plist `SIMKLClientId` /
/// `SIMKLClientSecret` keys, substituted from `$(SIMKL_CLIENT_ID)` / `$(SIMKL_CLIENT_SECRET)` (empty
/// default). `isConfigured` gates the whole feature so the app ships safely with the values blank.
actor SIMKLAuth {
    static let shared = SIMKLAuth()

    // MARK: - Configuration (build-time; empty ships a dormant, invisible feature)

    /// SIMKL application client id (https://simkl.com/settings/developer/), read at runtime from the
    /// Info.plist `SIMKLClientId` key ($(SIMKL_CLIENT_ID); empty default). "" when absent.
    static let clientID = SIMKLAuth.infoValue("SIMKLClientId")
    /// SIMKL application client secret (Info.plist `SIMKLClientSecret` <- $(SIMKL_CLIENT_SECRET)). Not
    /// needed for the PIN flow itself, but read so `isConfigured` matches the Trakt precedent shape.
    static let clientSecret = SIMKLAuth.infoValue("SIMKLClientSecret")

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

    private static let accessAccount = "vortx.simkl.accessToken"
    private static let expiryAccount = "vortx.simkl.expiresAt"   // unix epoch seconds, or "0" for a non-expiring token
    private static let migrationGroup = "simkl"

    private let session: URLSession
    nonisolated private let tokenStorage: CredentialTokenStorage
    private let onBeforeCommit: (@Sendable () async -> Void)?
    private var pendingPinOperations: [String: CredentialOperationStamp] = [:]

    init(
        session: URLSession = .shared,
        tokenStorage: CredentialTokenStorage = .keychain,
        onBeforeCommit: (@Sendable () async -> Void)? = nil
    ) {
        self.session = session
        self.tokenStorage = tokenStorage
        self.onBeforeCommit = onBeforeCommit
    }

    // MARK: - Public state

    /// True when an access token is stored (the user has connected SIMKL).
    var isSignedIn: Bool {
        let scope = CredentialScopeSnapshotStore.shared.load().scope
        return string(Self.accessAccount, scope: scope)?.isEmpty == false
    }

    /// Drop the stored token (the user disconnected). Does not revoke server-side.
    func signOut() async {
        let operation = await beginOperation(.simklDisconnect)
        let committed = await commitIfCurrent(CredentialCommitStamp(operation: operation)) { scope in
            self.clearTokens(scope: scope)
        }
        if committed { pendingPinOperations.removeAll(keepingCapacity: true) }
    }

    /// A live access token, or throws `.notSignedIn`. SIMKL tokens are long-lived and do not refresh, so
    /// a stored token is returned as-is; a recorded expiry in the past (rare, only if a future SIMKL
    /// change adds one) throws so the UI can re-prompt.
    func validToken() throws -> String {
        let scope = CredentialScopeSnapshotStore.shared.load().scope
        guard let token = string(Self.accessAccount, scope: scope), !token.isEmpty else { throw SIMKLError.notSignedIn }
        if let expiryString = string(Self.expiryAccount, scope: scope), let expiry = Int(expiryString), expiry > 0,
           Date().timeIntervalSince1970 >= Double(expiry) {
            throw SIMKLError.notSignedIn
        }
        return token
    }

    // MARK: - Cross-device adoption / sync mirror

    /// Adopt a token that arrived from ANOTHER device over the E2E `doc.apiKeys` sync channel. Writes the
    /// Keychain directly (no network). Ignores an empty token so a partial doc never clears a live session.
    func adoptTokens(
        access: String,
        expiryUnix: Int,
        credentialStamp suppliedStamp: CredentialCommitStamp? = nil
    ) async {
        guard !access.isEmpty else { return }
        let stamp: CredentialCommitStamp
        if let suppliedStamp {
            stamp = suppliedStamp
        } else {
            stamp = await currentCommitStamp()
        }
        _ = await commitIfCurrent(stamp) { scope in
            self.writeTokens(access: access, expiryUnix: expiryUnix, scope: scope)
        }
    }

    /// The stored token for the sync PUSH side (access, absolute unix expiry or 0), or nil when not
    /// signed in. Read-only; the sync manager sends these only when a local session exists and NEVER
    /// deletes them from the doc when absent (mirrors the debrid guard).
    func syncableTokens() -> (access: String, expiryUnix: Int)? {
        let scope = CredentialScopeSnapshotStore.shared.load().scope
        guard let access = string(Self.accessAccount, scope: scope), !access.isEmpty else { return nil }
        let expiry = Int(string(Self.expiryAccount, scope: scope) ?? "0") ?? 0
        return (access, expiry)
    }

    // MARK: - Step 1: request a PIN

    /// Begin the PIN flow. Returns the code + polling schedule to drive the UI and step 2.
    func requestPin() async throws -> SIMKLPin {
        try ensureConfigured()
        let operation = await beginOperation(.simklPinPoll)
        let stamp = CredentialCommitStamp(operation: operation)
        guard await isCurrent(stamp) else { throw CancellationError() }
        guard var components = URLComponents(string: Self.apiBase + "/oauth/pin") else { throw SIMKLError.badURL }
        components.queryItems = Self.requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        let (data, status) = try await send(makeGET(url))
        guard await isCurrent(stamp) else { throw CancellationError() }
        guard status == 200 else { throw SIMKLError.server(status: status) }
        let pin = try decode(SIMKLPin.self, from: data)
        pendingPinOperations[pin.userCode] = operation
        return pin
    }

    // MARK: - Step 2: poll for the token

    enum PollResult: Sendable {
        case authorized(String)   // access token
        case pending
    }

    /// One poll of `GET /oauth/pin/{user_code}`.
    func poll(userCode: String) async throws -> PollResult {
        let operation: CredentialOperationStamp
        if let pending = pendingPinOperations[userCode] {
            operation = pending
        } else {
            operation = await beginOperation(.simklPinPoll)
            pendingPinOperations[userCode] = operation
        }
        return try await poll(userCode: userCode, operation: operation)
    }

    private func poll(
        userCode: String,
        operation: CredentialOperationStamp
    ) async throws -> PollResult {
        try ensureConfigured()
        let stamp = CredentialCommitStamp(operation: operation)
        guard await isCurrent(stamp) else { throw CancellationError() }
        guard var components = URLComponents(string: Self.apiBase + "/oauth/pin/\(userCode)") else { throw SIMKLError.badURL }
        components.queryItems = Self.requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        let (data, status) = try await send(makeGET(url))
        guard await isCurrent(stamp) else { throw CancellationError() }
        guard status == 200 else { throw SIMKLError.server(status: status) }
        let poll = try decode(SIMKLPinPoll.self, from: data)
        if poll.result.uppercased() == "OK", let token = poll.accessToken, !token.isEmpty {
            guard await store(accessToken: token, credentialStamp: stamp) else {
                throw CancellationError()
            }
            return .authorized(token)
        }
        return .pending
    }

    /// Run the full polling loop until the user authorizes or the code expires. On success the token is
    /// already stored; the return value is the same token.
    @discardableResult
    func pollForToken(userCode: String, interval: Int, expiresIn: Int) async throws -> String {
        let operation: CredentialOperationStamp
        if let pending = pendingPinOperations[userCode] {
            operation = pending
        } else {
            operation = await beginOperation(.simklPinPoll)
            pendingPinOperations[userCode] = operation
        }
        defer {
            if pendingPinOperations[userCode] == operation {
                pendingPinOperations.removeValue(forKey: userCode)
            }
        }
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        let waitSeconds = max(interval, 1)
        while Date() < deadline {
            try await sleep(seconds: waitSeconds)
            try Task.checkCancellation()
            if case .authorized(let token) = try await poll(userCode: userCode, operation: operation) { return token }
        }
        throw SIMKLError.expired
    }

    // MARK: - Persistence + HTTP plumbing

    /// Store a fresh access token. SIMKL tokens do not expire, so the expiry slot is "0" (non-expiring).
    @discardableResult
    private func store(
        accessToken: String,
        credentialStamp: CredentialCommitStamp
    ) async -> Bool {
        await commitIfCurrent(credentialStamp) { scope in
            self.writeTokens(access: accessToken, expiryUnix: 0, scope: scope)
        }
    }

    nonisolated private func string(_ account: String, scope: CredentialScope) -> String? {
        tokenStorage.read(account, Self.migrationGroup, scope)
    }

    nonisolated private func writeTokens(access: String, expiryUnix: Int, scope: CredentialScope) {
        _ = tokenStorage.write(access, Self.accessAccount, scope)
        _ = tokenStorage.write(String(expiryUnix), Self.expiryAccount, scope)
    }

    nonisolated private func clearTokens(scope: CredentialScope) {
        _ = tokenStorage.write(nil, Self.accessAccount, scope)
        _ = tokenStorage.write(nil, Self.expiryAccount, scope)
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

    private func ensureConfigured() throws {
        guard Self.isConfigured else { throw SIMKLError.notConfigured }
    }

    private func makeGET(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.clientID, forHTTPHeaderField: "simkl-api-key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw SIMKLError.transport(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SIMKLError.decoding }
    }

    private func sleep(seconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0)) * 1_000_000_000)
    }
}
