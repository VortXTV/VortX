import Foundation

/// Talks to the VortX sync service (a Cloudflare Worker at `api.vortx.tv`).
///
/// The service is a BLIND RELAY. It stores only the end-to-end-encrypted backup blob keyed by an
/// opaque account id, plus short-lived pairing records used to hand an account from one device to
/// another. It can never read a user's data, because the AES key never leaves the user's devices
/// (see `BackupCrypto` / `VortXAccount`). Conflict policy is last-writer-wins by `version`
/// (epoch milliseconds): the newest push wins, and a pull only applies when the server is newer.
///
/// The client is inert until `baseURL` is set to the deployed Worker; every call throws
/// `SyncError.notConfigured` while it is nil, so the app ships safely before the backend exists.
///
/// Worker endpoints (implemented in `/cloudflare`):
///   POST /v1/pair/start          -> issues a pairing code for the joining device (Apple TV)
///   POST /v1/pair/claim          <- the device that holds the account hands it over (phone)
///   GET  /v1/pair/status?id=...  -> the joining device polls until the account arrives
///   PUT  /v1/backup              <- push the sealed blob   (header: X-VortX-Account)
///   GET  /v1/backup              -> pull the latest sealed blob
struct VortXSyncClient: Sendable {
    var baseURL: URL?
    var session: URLSession = .shared

    /// True once the Worker URL is configured.
    var isConfigured: Bool { baseURL != nil }

    enum SyncError: Error, Sendable {
        case notConfigured
        case http(Int)
        case decoding
        case pairingExpired
    }

    // MARK: Backup blob (the unit of sync = the SettingsBackup envelope, sealed)

    /// One stored revision of a user's backup. `ciphertext` is base64 of the sealed box.
    struct SealedBackup: Codable, Sendable {
        var ciphertext: String
        var version: Int64       // epoch ms; higher wins (last-writer-wins)
    }

    /// Push a freshly sealed blob for `account`. The server keeps it only if `version` is newest.
    func pushBackup(_ blob: SealedBackup, account id: String) async throws {
        let req = try request("/v1/backup", method: "PUT", account: id, body: blob)
        _ = try await send(req)
    }

    /// Pull the latest sealed blob for `account`, or nil if the server has none.
    func pullBackup(account id: String) async throws -> SealedBackup? {
        let req = try request("/v1/backup", method: "GET", account: id)
        let (data, status) = try await send(req)
        if status == 404 { return nil }
        guard status == 200 else { throw SyncError.http(status) }
        guard let blob = try? JSONDecoder().decode(SealedBackup.self, from: data) else {
            throw SyncError.decoding
        }
        return blob
    }

    // MARK: Pairing (Apple TV joins an account that lives on the phone)

    struct PairStartRequest: Codable, Sendable { var devicePublicKey: String }
    struct PairStartResponse: Codable, Sendable { var pairingID: String; var code: String; var expiresAt: Int64 }
    struct PairClaimRequest: Codable, Sendable { var pairingID: String; var claimPublicKey: String; var wrappedAccount: String }
    struct PairStatusResponse: Codable, Sendable { var claimPublicKey: String?; var wrappedAccount: String? }

    /// Apple TV begins pairing, publishing its ephemeral public key. Returns a short code to show.
    func pairStart(devicePublicKey: String) async throws -> PairStartResponse {
        let req = try request("/v1/pair/start", method: "POST", body: PairStartRequest(devicePublicKey: devicePublicKey))
        let (data, status) = try await send(req)
        guard status == 200 else { throw SyncError.http(status) }
        guard let res = try? JSONDecoder().decode(PairStartResponse.self, from: data) else { throw SyncError.decoding }
        return res
    }

    /// The phone hands the (ECDH-wrapped) account to the pairing record.
    func pairClaim(_ claim: PairClaimRequest) async throws {
        let req = try request("/v1/pair/claim", method: "POST", body: claim)
        _ = try await send(req)
    }

    /// Apple TV polls until the phone has claimed the pairing; nil fields mean still waiting.
    func pairStatus(pairingID: String) async throws -> PairStatusResponse {
        let req = try request("/v1/pair/status?id=\(pairingID)", method: "GET")
        let (data, status) = try await send(req)
        if status == 410 { throw SyncError.pairingExpired }
        guard status == 200 else { throw SyncError.http(status) }
        guard let res = try? JSONDecoder().decode(PairStatusResponse.self, from: data) else { throw SyncError.decoding }
        return res
    }

    // MARK: Household sharing (the household-scoped shared blob + the hhKey ECDH relay)
    //
    // Unlike backup/pairing (which key on the opaque X-VortX-Account handle), every household endpoint is
    // SESSION-authed with the account's bearer token, exactly like the rest of /v1/auth and /v1/family in
    // the Worker. The blob is the household's opaque shared ciphertext (LWW by version, just like
    // /v1/backup); the key relay mirrors /v1/pair but for the 32-byte hhKey instead of the account key.
    // The Worker NEVER sees hhKey or the blob plaintext, and never logs `wrappedHhKey`/`document`.

    struct HouseholdStatus: Codable, Sendable {
        var familyId: String
        var role: String                // "owner" | "member"
        var hasBlob: Bool
        var version: Int64
        var hhKeyVersion: Int
        var pendingRequests: Int
    }
    /// {household: {...}} when the caller is in a household, {household: null} otherwise.
    private struct HouseholdStatusEnvelope: Codable, Sendable { var household: HouseholdStatus? }

    struct HouseholdBlob: Codable, Sendable {
        var document: String            // base64(AES-GCM(sharedJSON, hhKey)) — opaque to the server
        var version: Int64              // epoch ms; higher wins (last-writer-wins)
        var hhKeyVersion: Int
    }
    private struct HouseholdBlobPutResponse: Codable, Sendable { var ok: Bool; var accepted: Bool }

    struct HouseholdKeyRequest: Codable, Sendable {
        var accountId: String
        var username: String
        var joinerPublicKey: String
        var createdAt: Int64
    }
    private struct HouseholdKeyRequestsEnvelope: Codable, Sendable { var requests: [HouseholdKeyRequest] }

    /// The member's view of its own pending hhKey request. `status` is one of
    /// "none" | "pending" | "expired" | "answered"; the owner's answer fields are present only on "answered".
    struct HouseholdKeyStatus: Codable, Sendable {
        var status: String
        var ownerPublicKey: String?
        var wrappedHhKey: String?
        var hhKeyVersion: Int?
    }

    /// GET /v1/household — the caller's sharing status, or nil when not in a household.
    func householdStatus(token: String) async throws -> HouseholdStatus? {
        let req = try request("/v1/household", method: "GET", token: token)
        let (data, status) = try await send(req)
        guard status == 200 else { throw SyncError.http(status) }
        guard let env = try? JSONDecoder().decode(HouseholdStatusEnvelope.self, from: data) else { throw SyncError.decoding }
        return env.household
    }

    /// GET /v1/household/blob — the shared ciphertext blob, or nil when the household has none yet.
    func householdBlobGet(token: String) async throws -> HouseholdBlob? {
        let req = try request("/v1/household/blob", method: "GET", token: token)
        let (data, status) = try await send(req)
        if status == 404 { return nil }
        guard status == 200 else { throw SyncError.http(status) }
        guard let blob = try? JSONDecoder().decode(HouseholdBlob.self, from: data) else { throw SyncError.decoding }
        return blob
    }

    /// PUT /v1/household/blob — store the shared blob (LWW). Returns `accepted = false` when a newer
    /// version already won, so the caller re-fetches, re-merges, and retries.
    @discardableResult
    func householdBlobPut(_ blob: HouseholdBlob, token: String) async throws -> Bool {
        let req = try request("/v1/household/blob", method: "PUT", token: token, body: blob)
        let (data, status) = try await send(req)
        guard status == 200 else { throw SyncError.http(status) }
        guard let res = try? JSONDecoder().decode(HouseholdBlobPutResponse.self, from: data) else { throw SyncError.decoding }
        return res.accepted
    }

    private struct KeyRequestBody: Codable, Sendable { var joinerPublicKey: String }
    /// POST /v1/household/key-request — a joining member publishes its ephemeral X25519 public key.
    func householdKeyRequest(joinerPublicKey: String, token: String) async throws {
        let req = try request("/v1/household/key-request", method: "POST", token: token, body: KeyRequestBody(joinerPublicKey: joinerPublicKey))
        let (_, status) = try await send(req)
        guard status == 200 else { throw SyncError.http(status) }
    }

    /// GET /v1/household/key-requests — the owner lists members' pending hhKey requests (owner only).
    func householdKeyRequests(token: String) async throws -> [HouseholdKeyRequest] {
        let req = try request("/v1/household/key-requests", method: "GET", token: token)
        let (data, status) = try await send(req)
        guard status == 200 else { throw SyncError.http(status) }
        guard let env = try? JSONDecoder().decode(HouseholdKeyRequestsEnvelope.self, from: data) else { throw SyncError.decoding }
        return env.requests
    }

    private struct KeyAnswerBody: Codable, Sendable { var accountId: String; var ownerPublicKey: String; var wrappedHhKey: String; var hhKeyVersion: Int }
    /// POST /v1/household/key-answer — the owner answers one request with its ephemeral public key and
    /// the ECDH-wrapped hhKey (owner only). The Worker relays opaque material to the member.
    func householdKeyAnswer(accountId: String, ownerPublicKey: String, wrappedHhKey: String, hhKeyVersion: Int, token: String) async throws {
        let body = KeyAnswerBody(accountId: accountId, ownerPublicKey: ownerPublicKey, wrappedHhKey: wrappedHhKey, hhKeyVersion: hhKeyVersion)
        let req = try request("/v1/household/key-answer", method: "POST", token: token, body: body)
        let (_, status) = try await send(req)
        guard status == 200 else { throw SyncError.http(status) }
    }

    /// GET /v1/household/key-status — the joining member polls for the owner's answer. On "answered" the
    /// Worker returns the wrapped key ONCE and consumes (deletes) the request.
    func householdKeyStatus(token: String) async throws -> HouseholdKeyStatus {
        let req = try request("/v1/household/key-status", method: "GET", token: token)
        let (data, status) = try await send(req)
        guard status == 200 else { throw SyncError.http(status) }
        guard let res = try? JSONDecoder().decode(HouseholdKeyStatus.self, from: data) else { throw SyncError.decoding }
        return res
    }

    // MARK: Family roster + leave (the household membership layer, reused by the Settings UX)
    //
    // The household sharing of /v1/household/* rides on top of the family relationship layer (/v1/family),
    // which predates it: a "household" IS a family that has set up a shared blob. The Settings UX renders
    // the roster from /v1/family and uses /v1/family/leave for Leave (self) / Remove (owner removes a member
    // by username). The Worker rotates / tears down the household rows on leave (Phase 1).

    struct FamilyMember: Codable, Sendable {
        var username: String
        var role: String        // "owner" | "member"
        var joinedAt: Int64
        var isMe: Bool
    }
    struct Family: Codable, Sendable {
        var id: String
        var name: String
        var role: String        // the caller's role
        var members: [FamilyMember]
    }
    private struct FamilyEnvelope: Codable, Sendable { var family: Family? }

    /// GET /v1/family — the caller's household roster, or nil when not in one.
    func familyGet(token: String) async throws -> Family? {
        let req = try request("/v1/family", method: "GET", token: token)
        let (data, status) = try await send(req)
        guard status == 200 else { throw SyncError.http(status) }
        guard let env = try? JSONDecoder().decode(FamilyEnvelope.self, from: data) else { throw SyncError.decoding }
        return env.family
    }

    private struct FamilyLeaveBody: Codable, Sendable { var username: String? }
    /// POST /v1/family/leave — leave the household (no `username`) or, as owner, remove a member by username.
    /// The Worker drops that member's pending household key-request; the household owner re-seals the shared
    /// blob under a fresh hhKey (rotation) client-side so a removed member cannot read FUTURE shared content.
    func familyLeave(username: String? = nil, token: String) async throws {
        let body = FamilyLeaveBody(username: username)
        let req = try request("/v1/family/leave", method: "POST", token: token, body: body)
        let (_, status) = try await send(req)
        guard status == 200 else { throw SyncError.http(status) }
    }

    // MARK: Plumbing

    private func request<Body: Encodable>(_ path: String, method: String, account: String? = nil, token: String? = nil, body: Body) throws -> URLRequest {
        var req = try baseRequest(path, method: method, account: account, token: token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    private func request(_ path: String, method: String, account: String? = nil, token: String? = nil) throws -> URLRequest {
        try baseRequest(path, method: method, account: account, token: token)
    }

    private func baseRequest(_ path: String, method: String, account: String?, token: String? = nil) throws -> URLRequest {
        guard let baseURL, let url = URL(string: path, relativeTo: baseURL) else { throw SyncError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let account { req.setValue(account, forHTTPHeaderField: "X-VortX-Account") }
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "authorization") }
        return req
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}
