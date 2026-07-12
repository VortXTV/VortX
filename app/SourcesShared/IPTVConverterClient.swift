import Foundation

/// Client for the hosted IPTV converter at `iptv.vortx.tv`. It registers a user's M3U playlist or Xtream Codes
/// login with the worker, which stores the (encrypted) credentials server-side and returns an opaque slug; the
/// app then installs `https://iptv.vortx.tv/c/<slug>/manifest.json` as a normal Stremio add-on so the channels
/// flow through the existing Live tab engine-side. Removing a playlist calls /revoke so the slug is destroyed.
///
/// GATING: `iptv.vortx.tv` is in `VortXEdgeAuth.gatedHosts`, so every request here is HMAC-signed. Signing is a
/// safe no-op without a provisioned secret (the worker runs the gate in OBSERVE mode), so this works today and
/// tightens later without a client change.
enum IPTVConverterClient {

    /// A user-facing error from a register / revoke attempt.
    enum ClientError: LocalizedError {
        case badResponse
        case xtreamAuthFailed
        case server(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badResponse: return String(localized: "The IPTV service returned an unexpected response.")
            case .xtreamAuthFailed: return String(localized: "Those Xtream details did not sign in. Check the server, username, and password.")
            case .server(let code): return String(localized: "The IPTV service could not add this playlist (\(code)).")
            case .network(let msg): return msg
            }
        }
    }

    /// A successful registration: the worker slug and the manifest URL to install.
    struct Registration {
        let slug: String
        let manifestURL: String
    }

    /// The base URL of the converter worker.
    private static var baseURL: URL { URL(string: "https://iptv.vortx.tv")! }

    // MARK: - Register

    /// Register an M3U playlist. `xmltvURL` is an optional separate EPG source.
    static func registerM3U(url: String, xmltvURL: String?, name: String?) async -> Result<Registration, ClientError> {
        var body: [String: Any] = ["m3u_url": url]
        if let xmltvURL, !xmltvURL.isEmpty { body["xmltv_url"] = xmltvURL }
        if let name, !name.isEmpty { body["name"] = name }
        return await register(body: body)
    }

    /// Register an Xtream Codes login. The worker validates the credentials before returning a slug.
    static func registerXtream(host: String, user: String, pass: String, xmltvURL: String?, name: String?) async -> Result<Registration, ClientError> {
        var body: [String: Any] = ["xtream": ["host": host, "user": user, "pass": pass]]
        if let xmltvURL, !xmltvURL.isEmpty { body["xmltv_url"] = xmltvURL }
        if let name, !name.isEmpty { body["name"] = name }
        return await register(body: body)
    }

    private static func register(body: [String: Any]) async -> Result<Registration, ClientError> {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.badResponse)
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("register"), timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        VortXEdgeAuth.sign(&req)

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failure(.badResponse) }
            let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
            if (200..<300).contains(http.statusCode) {
                guard let obj, let slug = obj["slug"] as? String, let manifestURL = obj["manifest_url"] as? String else {
                    return .failure(.badResponse)
                }
                return .success(Registration(slug: slug, manifestURL: manifestURL))
            }
            // Non-2xx: surface the worker's error code, mapping the known auth failure to a friendly message.
            let code = (obj?["error"] as? String) ?? String(http.statusCode)
            if code == "xtream_auth_failed" { return .failure(.xtreamAuthFailed) }
            return .failure(.server(code))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: - Revoke

    /// Revoke a slug server-side so its playlist can no longer be served. Fail-soft: a failure here is logged
    /// but does not block local removal (the add-on is uninstalled either way). Returns true on a clean revoke.
    @discardableResult
    static func revoke(slug: String) async -> Bool {
        guard !slug.isEmpty else { return false }
        var req = URLRequest(url: baseURL.appendingPathComponent("c").appendingPathComponent(slug).appendingPathComponent("revoke"),
                             timeoutInterval: 12)
        req.httpMethod = "POST"
        VortXEdgeAuth.sign(&req)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }
}
