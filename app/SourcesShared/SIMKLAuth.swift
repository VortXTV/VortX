import Foundation

// CREDENTIAL_SIMKL_SLOTS_BEGIN
/// Owner-scoped Keychain slot names for the SIMKL token pair (M3, INS-260722-06R v2: PER-ACCOUNT scope).
/// Mirrors `TraktTokenSlots`: nonisolated so both the `SIMKLAuth` actor and the @MainActor synchronous
/// sync-adoption path (H2) derive the same names without an actor hop. The pre-scoping global names remain
/// only as a one-owner claim source (REQ-23 delete-source-first); they are never written again.
enum SIMKLTokenSlots {
    static let legacyAccess = "vortx.simkl.accessToken"
    static let legacyExpiry = "vortx.simkl.expiresAt"
    /// One-owner claim marker for the legacy global token pair (no credential value inside).
    static let claimMarker = "vortx.simkl.migration.global.owner"

    static func access(_ ns: String) -> String { legacyAccess + "." + ns }
    static func expiry(_ ns: String) -> String { legacyExpiry + "." + ns }

    /// Claim the unowned global legacy token pair for `ns` (first explicit bind wins, permanently),
    /// delete-source-first. Synchronous; called from the main-actor scope bind in `VortXSyncManager`.
    static func claimLegacyGlobal(ownerNamespace ns: String) {
        CredentialLegacyClaim.claimGlobalSlotSet(
            slots: [
                (source: legacyAccess, destination: access(ns)),
                (source: legacyExpiry, destination: expiry(ns)),
            ],
            claimMarkerAccount: claimMarker,
            ownerNamespace: ns,
            provenanceTag: "simkl-token-pair"
        )
    }

    /// H2 (INS-260722-06R v2): adopt a synced SIMKL token with ALL Keychain writes in ONE synchronous
    /// closure, no await between the caller's session validation and these writes (see
    /// `TraktTokenSlots.adoptSyncedTokens`). Writes target the CALLER-CAPTURED owner namespace.
    static func adoptSyncedTokens(access: String, expiryUnix: Int, ownerNamespace ns: String) {
        guard !access.isEmpty else { return }
        Keychain.set(access, for: Self.access(ns))
        Keychain.set(String(expiryUnix), for: Self.expiry(ns))
    }
}
// CREDENTIAL_SIMKL_SLOTS_END

/// SIMKL PIN/device auth plus Keychain-backed token storage. Mirrors `TraktAuth`'s shape but for
/// SIMKL's simpler model: a PIN flow (request a code, poll until the user authorizes) that yields a
/// LONG-LIVED access token with NO refresh rotation. A missing/zero expiry is therefore treated as
/// "valid" rather than "expired" (do NOT copy `TraktToken`'s 24h-leeway refresh, which SIMKL lacks).
///
/// Credentials come from the same build-time seam as Trakt: the Info.plist `SIMKLClientId` /
/// `SIMKLClientSecret` keys, substituted from `$(SIMKL_CLIENT_ID)` / `$(SIMKL_CLIENT_SECRET)` (empty
/// default). `isConfigured` gates the whole feature so the app ships safely with the values blank.
///
/// OWNER CAPTURE RULE (M3): every public entry point captures the CURRENT owner namespace once, before
/// its first suspension; every Keychain slot it touches derives from that capture (see `TraktAuth`).
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

    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// The owner namespace captured at operation entry (see the OWNER CAPTURE RULE above).
    private nonisolated func currentOwnerNamespace() -> String {
        CredentialScopeRegistry.shared.currentNamespace()
    }

    // MARK: - Public state

    /// True when an access token is stored for the CURRENT owner (the user has connected SIMKL).
    var isSignedIn: Bool {
        Keychain.string(SIMKLTokenSlots.access(currentOwnerNamespace()))?.isEmpty == false
    }

    /// Drop the CURRENT owner's stored token (the user disconnected). Does not revoke server-side.
    /// H5: the token clear records provenance at commit time, in the same synchronous run as the writes.
    func signOut() {
        let ns = currentOwnerNamespace()
        Keychain.set(nil, for: SIMKLTokenSlots.access(ns))
        Keychain.set(nil, for: SIMKLTokenSlots.expiry(ns))
        CredentialProvenance.record(event: "token-clear.simkl", ownerNamespace: ns)
    }

    /// A live access token for the CURRENT owner, or throws `.notSignedIn`. SIMKL tokens are long-lived
    /// and do not refresh, so a stored token is returned as-is; a recorded expiry in the past (rare, only
    /// if a future SIMKL change adds one) throws so the UI can re-prompt.
    func validToken() throws -> String {
        let ns = currentOwnerNamespace()
        guard let token = Keychain.string(SIMKLTokenSlots.access(ns)), !token.isEmpty else { throw SIMKLError.notSignedIn }
        if let expiryString = Keychain.string(SIMKLTokenSlots.expiry(ns)), let expiry = Int(expiryString), expiry > 0,
           Date().timeIntervalSince1970 >= Double(expiry) {
            throw SIMKLError.notSignedIn
        }
        return token
    }

    // MARK: - Cross-device adoption / sync mirror

    /// The stored token for the sync PUSH side (access, absolute unix expiry or 0), or nil when not
    /// signed in, read from the CALLER-CAPTURED owner scope (see `TraktAuth.syncableTokens`). Read-only;
    /// the sync manager sends these only when a local session exists and NEVER deletes them from the doc
    /// when absent (mirrors the debrid guard).
    nonisolated static func syncableTokens(ownerNamespace ns: String) -> (access: String, expiryUnix: Int)? {
        guard let access = Keychain.string(SIMKLTokenSlots.access(ns)), !access.isEmpty else { return nil }
        let expiry = Int(Keychain.string(SIMKLTokenSlots.expiry(ns)) ?? "0") ?? 0
        return (access, expiry)
    }

    // MARK: - Step 1: request a PIN

    /// Begin the PIN flow. Returns the code + polling schedule to drive the UI and step 2.
    func requestPin() async throws -> SIMKLPin {
        try ensureConfigured()
        guard var components = URLComponents(string: Self.apiBase + "/oauth/pin") else { throw SIMKLError.badURL }
        components.queryItems = Self.requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        let (data, status) = try await send(makeGET(url))
        guard status == 200 else { throw SIMKLError.server(status: status) }
        return try decode(SIMKLPin.self, from: data)
    }

    // MARK: - Step 2: poll for the token

    enum PollResult: Sendable {
        case authorized(String)   // access token
        case pending
    }

    /// One poll of `GET /oauth/pin/{user_code}`.
    func poll(userCode: String) async throws -> PollResult {
        try await poll(userCode: userCode, ownerNamespace: currentOwnerNamespace())
    }

    private func poll(userCode: String, ownerNamespace ns: String) async throws -> PollResult {
        try ensureConfigured()
        guard var components = URLComponents(string: Self.apiBase + "/oauth/pin/\(userCode)") else { throw SIMKLError.badURL }
        components.queryItems = Self.requiredQueryItems
        guard let url = components.url else { throw SIMKLError.badURL }
        let (data, status) = try await send(makeGET(url))
        guard status == 200 else { throw SIMKLError.server(status: status) }
        let poll = try decode(SIMKLPinPoll.self, from: data)
        if poll.result.uppercased() == "OK", let token = poll.accessToken, !token.isEmpty {
            store(accessToken: token, ownerNamespace: ns)
            return .authorized(token)
        }
        return .pending
    }

    /// Run the full polling loop until the user authorizes or the code expires. On success the token is
    /// already stored; the return value is the same token. The owner is captured ONCE, at entry: the
    /// connection belongs to the owner who initiated it, even if the VortX session changes mid-poll.
    @discardableResult
    func pollForToken(userCode: String, interval: Int, expiresIn: Int) async throws -> String {
        let ns = currentOwnerNamespace()
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        let waitSeconds = max(interval, 1)
        while Date() < deadline {
            try await sleep(seconds: waitSeconds)
            try Task.checkCancellation()
            if case .authorized(let token) = try await poll(userCode: userCode, ownerNamespace: ns) { return token }
        }
        throw SIMKLError.expired
    }

    // MARK: - Persistence + HTTP plumbing

    /// Store a fresh access token under an owner. SIMKL tokens do not expire, so the expiry slot is "0".
    private func store(accessToken: String, ownerNamespace ns: String) {
        Keychain.set(accessToken, for: SIMKLTokenSlots.access(ns))
        Keychain.set("0", for: SIMKLTokenSlots.expiry(ns))
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
