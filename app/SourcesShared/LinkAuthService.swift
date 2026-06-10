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

    static func create() async throws -> LinkCode {
        let response: APIResponse<LinkCodeDTO> = try await get("create?type=Create")
        guard let result = response.result else {
            throw LinkAuthError.server(response.error?.message ?? "Could not create a sign-in code.")
        }
        return LinkCode(code: result.code, link: result.link, qrcode: result.qrcode)
    }

    /// Returns nil while the user has not completed the browser/QR flow yet.
    static func read(code: String) async throws -> String? {
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
            return nil
        }
        return try? JSONDecoder().decode(APIResponse<LinkDataDTO>.self, from: data).result?.authKey
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
    }

    private struct LinkCodeDTO: Decodable {
        let code: String
        let link: String
        let qrcode: String
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
