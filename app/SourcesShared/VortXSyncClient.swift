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

    // MARK: Plumbing

    private func request<Body: Encodable>(_ path: String, method: String, account: String? = nil, body: Body) throws -> URLRequest {
        var req = try baseRequest(path, method: method, account: account)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    private func request(_ path: String, method: String, account: String? = nil) throws -> URLRequest {
        try baseRequest(path, method: method, account: account)
    }

    private func baseRequest(_ path: String, method: String, account: String?) throws -> URLRequest {
        guard let baseURL, let url = URL(string: path, relativeTo: baseURL) else { throw SyncError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let account { req.setValue(account, forHTTPHeaderField: "X-VortX-Account") }
        return req
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}
