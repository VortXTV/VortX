import Foundation

struct SIMKLCredentialStore: Sendable {
    let read: @Sendable (String) -> String?
    let write: @Sendable (String?, String) -> Void

    static let keychain = SIMKLCredentialStore(
        read: { Keychain.string($0) },
        write: { value, account in Keychain.set(value, for: account) }
    )
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
    private static let expiryAccount = "vortx.simkl.expiresAt"
    private static let sessionAccount = "vortx.simkl.sessionID"

    private let session: URLSession
    private let credentials: SIMKLCredentialStore
    private var activeSessionWrites = 0
    private var sessionWriteDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingCredentialBoundaries = 0
    private var credentialBoundaryActive = false
    private var credentialBoundaryWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginAttempts = SIMKLLoginAttemptAuthority()

    init(
        session: URLSession = .shared,
        credentials: SIMKLCredentialStore = .keychain
    ) {
        self.session = session
        self.credentials = credentials
        if credentials.read(Self.accessAccount)?.isEmpty == false,
           let expiry = credentials.read(Self.expiryAccount), Int(expiry) != nil,
           credentials.read(Self.sessionAccount)?.isEmpty != false {
            credentials.write(SIMKLSessionID.random().rawValue, Self.sessionAccount)
        }
    }

    // MARK: - Public state

    nonisolated static var storedSessionID: SIMKLSessionID? {
        guard Keychain.string(Self.accessAccount)?.isEmpty == false,
              let expiry = Keychain.string(Self.expiryAccount), Int(expiry) != nil,
              let raw = Keychain.string(Self.sessionAccount), !raw.isEmpty else { return nil }
        return SIMKLSessionID(rawValue: raw)
    }

    var sessionID: SIMKLSessionID? { currentSessionID() }
    var isSignedIn: Bool { currentSessionID() != nil }
    var isCredentialBoundaryPending: Bool { pendingCredentialBoundaries > 0 }

    /// Drop the stored token (the user disconnected). Does not revoke server-side.
    func signOut() async {
        loginAttempts.invalidate()
        await performCredentialBoundary {
            clearCredentialsAndPublishBoundary()
        }
    }

    func signOut(ifCurrent expectedSession: SIMKLSessionID) async {
        guard currentSessionID() == expectedSession else { return }
        loginAttempts.invalidate()
        await performCredentialBoundary {
            guard currentSessionID() == expectedSession else { return }
            clearCredentialsAndPublishBoundary()
        }
    }

    /// A live access token, or throws `.notSignedIn`. SIMKL tokens are long-lived and do not refresh, so
    /// a stored token is returned as-is; a recorded expiry in the past (rare, only if a future SIMKL
    /// change adds one) throws so the UI can re-prompt.
    func validToken() throws -> String {
        guard currentSessionID() != nil,
              let token = credentials.read(Self.accessAccount), !token.isEmpty else {
            throw SIMKLError.notSignedIn
        }
        if let expiryString = credentials.read(Self.expiryAccount), let expiry = Int(expiryString), expiry > 0,
           Date().timeIntervalSince1970 >= Double(expiry) {
            throw SIMKLError.notSignedIn
        }
        return token
    }

    func validToken(for expectedSession: SIMKLSessionID) throws -> String {
        guard pendingCredentialBoundaries == 0,
              currentSessionID() == expectedSession else { throw SIMKLError.sessionChanged }
        return try validToken()
    }

    /// Hold the current credential set across one provider write.
    func performSessionBoundWrite<Result: Sendable>(
        expectedSession: SIMKLSessionID,
        _ operation: @escaping @Sendable (String) async throws -> Result
    ) async throws -> Result {
        guard pendingCredentialBoundaries == 0,
              currentSessionID() == expectedSession else { throw SIMKLError.sessionChanged }
        let token = try validToken(for: expectedSession)
        guard pendingCredentialBoundaries == 0,
              currentSessionID() == expectedSession else { throw SIMKLError.sessionChanged }
        activeSessionWrites += 1
        do {
            let result = try await operation(token)
            finishSessionWrite()
            return result
        } catch {
            finishSessionWrite()
            throw error
        }
    }

    // MARK: - Cross-device adoption / sync mirror

    /// Adopt a token that arrived from ANOTHER device over the E2E `doc.apiKeys` sync channel. Writes the
    /// Keychain directly (no network). Ignores an empty token so a partial doc never clears a live session.
    func adoptTokens(access: String, expiryUnix: Int) async {
        guard !access.isEmpty else { return }
        if let current = syncableTokens(),
           current.access == access,
           current.expiryUnix == expiryUnix,
           currentSessionID() != nil {
            return
        }
        loginAttempts.invalidate()
        await performCredentialBoundary {
            if let current = syncableTokens(),
               current.access == access,
               current.expiryUnix == expiryUnix,
               currentSessionID() != nil {
                return
            }
            replaceCredentialsWithNewSession(access: access, expiryUnix: expiryUnix)
        }
    }

    /// The stored token for the sync PUSH side (access, absolute unix expiry or 0), or nil when not
    /// signed in. Read-only; the sync manager sends these only when a local session exists and NEVER
    /// deletes them from the doc when absent (mirrors the debrid guard).
    func syncableTokens() -> (access: String, expiryUnix: Int)? {
        guard currentSessionID() != nil,
              let access = credentials.read(Self.accessAccount), !access.isEmpty else { return nil }
        let expiry = Int(credentials.read(Self.expiryAccount) ?? "0") ?? 0
        return (access, expiry)
    }

    // MARK: - Step 1: request a PIN

    /// Begin the PIN flow. Returns the code + polling schedule to drive the UI and step 2.
    func requestPin() async throws -> SIMKLPin {
        try ensureConfigured()
        let loginGeneration = loginAttempts.begin()
        guard var components = URLComponents(string: Self.apiBase + "/oauth/pin") else { throw SIMKLError.badURL }
        components.queryItems = Self.requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        let (data, status) = try await send(makeGET(url))
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
        guard let loginGeneration = loginAttempts.generation(for: userCode) else {
            throw SIMKLError.sessionChanged
        }
        return try await poll(userCode: userCode, loginGeneration: loginGeneration)
    }

    private func poll(userCode: String, loginGeneration: UInt64) async throws -> PollResult {
        try ensureConfigured()
        guard loginAttempts.owns(code: userCode, generation: loginGeneration) else {
            throw SIMKLError.sessionChanged
        }
        guard var components = URLComponents(string: Self.apiBase + "/oauth/pin/\(userCode)") else { throw SIMKLError.badURL }
        components.queryItems = Self.requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        let (data, status) = try await send(makeGET(url))
        guard loginAttempts.owns(code: userCode, generation: loginGeneration) else {
            throw SIMKLError.sessionChanged
        }
        guard status == 200 else { throw SIMKLError.server(status: status) }
        let poll = try decode(SIMKLPinPoll.self, from: data)
        if poll.result.uppercased() == "OK", let token = poll.accessToken, !token.isEmpty {
            let installed = await performCredentialBoundary(
                expectedLoginGeneration: loginGeneration
            ) {
                guard loginAttempts.owns(code: userCode, generation: loginGeneration) else { return }
                replaceCredentialsWithNewSession(access: token, expiryUnix: 0)
                loginAttempts.invalidate()
            }
            guard installed else { throw SIMKLError.sessionChanged }
            return .authorized(token)
        }
        return .pending
    }

    /// Run the full polling loop until the user authorizes or the code expires. On success the token is
    /// already stored; the return value is the same token.
    @discardableResult
    func pollForToken(userCode: String, interval: Int, expiresIn: Int) async throws -> String {
        guard let loginGeneration = loginAttempts.generation(for: userCode) else {
            throw SIMKLError.sessionChanged
        }
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        let waitSeconds = max(interval, 1)
        while Date() < deadline {
            try await sleep(seconds: waitSeconds)
            try Task.checkCancellation()
            if case .authorized(let token) = try await poll(
                userCode: userCode,
                loginGeneration: loginGeneration
            ) { return token }
        }
        throw SIMKLError.expired
    }

    /// Stop the currently displayed PIN flow without affecting an already authenticated account.
    func cancelLoginAttempt() {
        loginAttempts.invalidate()
    }

    // MARK: - Persistence + HTTP plumbing

    private func currentSessionID() -> SIMKLSessionID? {
        guard credentials.read(Self.accessAccount)?.isEmpty == false,
              let expiry = credentials.read(Self.expiryAccount), Int(expiry) != nil,
              let raw = credentials.read(Self.sessionAccount), !raw.isEmpty else { return nil }
        return SIMKLSessionID(rawValue: raw)
    }

    private func replaceCredentialsWithNewSession(access: String, expiryUnix: Int) {
        clearCredentialsAndPublishBoundary()
        credentials.write(access, Self.accessAccount)
        credentials.write(String(expiryUnix), Self.expiryAccount)
        let sessionID = SIMKLSessionID.random()
        credentials.write(sessionID.rawValue, Self.sessionAccount)
        guard currentSessionID() == sessionID else {
            clearCredentialsAndPublishBoundary()
            DiagnosticsLog.log("simkl-auth", "credential session persistence failed")
            return
        }
        SIMKLAuthBoundary.publish(sessionID)
    }

    private func clearCredentialsAndPublishBoundary() {
        credentials.write(nil, Self.sessionAccount)
        SIMKLAuthBoundary.publish(nil)
        credentials.write(nil, Self.accessAccount)
        credentials.write(nil, Self.expiryAccount)
    }

    @discardableResult
    private func performCredentialBoundary(
        expectedLoginGeneration: UInt64? = nil,
        _ mutation: () -> Void
    ) async -> Bool {
        pendingCredentialBoundaries += 1
        defer { pendingCredentialBoundaries -= 1 }
        await acquireCredentialBoundary()
        defer { releaseCredentialBoundary() }
        while activeSessionWrites > 0 {
            await withCheckedContinuation { continuation in
                sessionWriteDrainWaiters.append(continuation)
            }
        }
        if let expectedLoginGeneration,
           !loginAttempts.isCurrent(generation: expectedLoginGeneration) {
            return false
        }
        mutation()
        return true
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
