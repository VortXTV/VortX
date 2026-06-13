import Foundation

/// Direct client for Stremio's device-link sign-in flow.
/// The link API only returns an auth key; the caller still finalizes the session through StremioAccount.
enum LinkAuthService {
    struct LinkCode: Equatable {
        let code: String
        let link: String
        let qrcode: String
    }

    private static let base = "https://link.stremio.com/api/v2"

    /// The link `read` endpoint answers HTTP 200 with `{"error":{"code":101,...}}` for the entire
    /// window before the user finishes the browser/QR step. That is the *pending* signal, not a
    /// failure — only this code may be polled past. Any other error (or a transport fault) is real
    /// and must be surfaced, otherwise the panel spins on "Waiting for sign-in…" forever.
    private static let pendingErrorCode = 101

    /// Outcome of one poll: still waiting, or the auth key arrived. Genuine failures `throw` instead.
    enum ReadResult {
        case pending
        case authKey(String)
    }

    /// The main account API (api.strem.io). `link.stremio.com` only hands back a session key; it is
    /// the main API that actually owns the session, so a key must be validated against it before the
    /// app commits to a signed-in state. A revoked/expired token answers HTTP 200 with
    /// `{"error":{"code":1,"message":"Session does not exist"}}`, NOT a transport failure — so the
    /// JSON error must be inspected, not just the status code.
    private static let accountAPI = "https://api.strem.io/api"

    static func create() async throws -> LinkCode {
        let response: APIResponse<LinkCodeDTO> = try await get("create?type=Create")
        if let result = response.result {
            return LinkCode(code: result.code, link: result.link, qrcode: result.qrcode)
        }
        throw LinkAuthError.server(response.error?.message ?? "Could not create a sign-in code.")
    }

    /// One poll of the link `read` endpoint. Returns `.pending` while the user has not completed the
    /// browser/QR flow yet, `.authKey` once Stremio hands back the session key, and throws for any
    /// genuine server or transport error so the caller can show it instead of polling silently.
    static func read(code: String) async throws -> ReadResult {
        let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        guard let url = URL(string: "\(base)/read?type=Read&code=\(encoded)") else {
            throw LinkAuthError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LinkAuthError.server("Link service returned HTTP \(http.statusCode).")
        }
        let decoded = try JSONDecoder().decode(APIResponse<LinkDataDTO>.self, from: data)
        if let authKey = decoded.result?.authKey, !authKey.isEmpty {
            return .authKey(authKey)
        }
        if let error = decoded.error {
            // The code-not-yet-linked sentinel is expected; everything else is a real failure.
            if error.code == pendingErrorCode { return .pending }
            throw LinkAuthError.server(error.message ?? "Sign-in could not be completed.")
        }
        // No key and no error => still pending (defensive; the API uses the 101 error above).
        return .pending
    }

    /// Validates a freshly-linked auth key against the main account API and returns the account email.
    ///
    /// This is the gate that stops a REJECTED/expired link token from masquerading as a signed-in
    /// session: `link.stremio.com` can return a key that `api.strem.io` no longer recognises, in
    /// which case `getUser` answers `{"error":{"code":1,...}}` ("Session does not exist"). Throwing
    /// here keeps the caller from flipping the account to signed-in with an empty add-on list. The
    /// returned email is informational only (it may be `nil` for accounts without one); a non-throw
    /// is the success signal.
    @discardableResult
    static func validate(authKey: String) async throws -> String? {
        struct Req: Encodable { let authKey: String }
        guard let url = URL(string: "\(accountAPI)/getUser") else { throw LinkAuthError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Req(authKey: authKey))
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LinkAuthError.server("Account service returned HTTP \(http.statusCode).")
        }
        let decoded = try JSONDecoder().decode(APIResponse<UserDTO>.self, from: data)
        if let error = decoded.error {
            // A rejected/expired key surfaces here as a real error rather than being swallowed.
            throw LinkAuthError.server(error.message ?? "This sign-in code is no longer valid.")
        }
        guard decoded.result != nil else {
            throw LinkAuthError.server("This sign-in code is no longer valid.")
        }
        return decoded.result?.email
    }

    private static func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "\(base)/\(path)") else { throw LinkAuthError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LinkAuthError.server("Link service returned HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct APIResponse<T: Decodable>: Decodable {
        let result: T?
        let error: APIError?
    }

    private struct APIError: Decodable {
        let message: String?
        let code: Int?
    }

    private struct LinkCodeDTO: Decodable {
        let code: String
        let link: String
        let qrcode: String
    }

    private struct UserDTO: Decodable {
        let email: String?
    }

    private struct LinkDataDTO: Decodable {
        let authKey: String?

        enum CodingKeys: String, CodingKey {
            case authKey
            case auth_key
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            authKey = try c.decodeIfPresent(String.self, forKey: .authKey)
                ?? c.decodeIfPresent(String.self, forKey: .auth_key)
        }
    }

    enum LinkAuthError: LocalizedError {
        case badURL
        case server(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "The sign-in service URL is invalid."
            case .server(let message): return message
            }
        }
    }
}
