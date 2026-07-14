import Foundation

/// Per-kind media-server AUTH flows (no UI): Plex PIN-link against plex.tv, Jellyfin Quick Connect with a
/// username/password fallback, and Emby username/password. Each flow ends by handing the caller a token plus
/// the metadata to build a `MediaServerRecord`; the settings view owns the on-screen code/QR and drives the
/// polling loops (mirroring the Trakt/SIMKL device-code cards). Small, stateless, `URLSession`-only.
///
/// Credential class: these tokens are account-wide, so they are fetched DIRECTLY by the client against the
/// user's own server / plex.tv and never transit VortX infrastructure. Passwords entered for the fallback are
/// used transiently for the one exchange and never stored.
enum MediaServerAuthError: Error, LocalizedError, Equatable {
    case badURL
    case network(String)
    case http(Int)
    case timedOut
    case cancelled
    case decode

    var errorDescription: String? {
        switch self {
        case .badURL:   return "That server address does not look valid."
        case .network(let m): return m
        case .http(let c): return "The server returned an error (HTTP \(c))."
        case .timedOut: return "Timed out waiting for you to authorize."
        case .cancelled: return "Cancelled."
        case .decode:   return "The server sent a response VortX could not read."
        }
    }
}

/// The result of a successful Jellyfin / Emby sign-in.
struct MediaServerAuthResult: Sendable, Equatable {
    let accessToken: String
    let userId: String
    let serverId: String?
    let serverName: String?
}

/// A Plex server discovered from plex.tv resources, with its own per-server access token and ordered,
/// reachability-probed connection URLs.
struct PlexServerCandidate: Sendable, Equatable, Identifiable {
    let machineId: String
    let name: String
    let accessToken: String
    let urls: [String]          // ordered: local -> remote -> relay, reachable first
    var id: String { machineId }
}

enum MediaServerAuth {

    // MARK: Shared helpers

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1"
    }

    /// The Jellyfin/Emby `MediaBrowser` authorization header value (no token: this is the pre-auth header the
    /// AuthenticateByName / QuickConnect endpoints require to identify the client).
    private static var embyAuthHeader: String {
        "MediaBrowser Client=\"VortX\", Device=\"VortX\", DeviceId=\"\(MediaServerStore.deviceId)\", Version=\"\(appVersion)\""
    }

    private static func session(timeout: TimeInterval = 15) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 15
        return URLSession(configuration: cfg)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MediaServerAuthError.decode }
    }

    // MARK: - Plex (PIN link against plex.tv)

    private static let plexPinsURL = "https://plex.tv/api/v2/pins"
    private static let plexResourcesURL = "https://plex.tv/api/v2/resources"

    struct PlexPin: Sendable, Equatable {
        let id: Int
        let code: String
        /// The URL the user visits to enter the code.
        var linkURL: String { "https://plex.tv/link" }
    }

    private static func plexHeaders() -> [String: String] {
        ["X-Plex-Product": "VortX",
         "X-Plex-Client-Identifier": MediaServerStore.plexClientIdentifier,
         "Accept": "application/json"]
    }

    /// Step 1: request a strong PIN. Returns the pin id + the code to display.
    static func plexRequestPin() async throws -> PlexPin {
        guard var comps = URLComponents(string: plexPinsURL) else { throw MediaServerAuthError.badURL }
        comps.queryItems = [URLQueryItem(name: "strong", value: "true")]
        guard let url = comps.url else { throw MediaServerAuthError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in plexHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        struct Resp: Decodable { let id: Int; let code: String }
        let (data, response) = try await run(req)
        try ensureOK(response)
        let r = try decode(Resp.self, from: data)
        return PlexPin(id: r.id, code: r.code)
    }

    /// Step 2: poll the PIN until it carries an `authToken` (the user entered the code) or it expires. Returns
    /// the plex.tv ACCOUNT token. Honors task cancellation.
    static func plexPollForToken(pin: PlexPin, interval: TimeInterval = 2, expiresIn: TimeInterval = 900) async throws -> String {
        let deadline = Date().addingTimeInterval(expiresIn)
        struct Resp: Decodable { let authToken: String? }
        while Date() < deadline {
            try Task.checkCancellation()
            guard let url = URL(string: "\(plexPinsURL)/\(pin.id)") else { throw MediaServerAuthError.badURL }
            var req = URLRequest(url: url)
            for (k, v) in plexHeaders() { req.setValue(v, forHTTPHeaderField: k) }
            if let (data, response) = try? await run(req), (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
               let r = try? JSONDecoder().decode(Resp.self, from: data), let token = r.authToken, !token.isEmpty {
                return token
            }
            try await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
        }
        throw MediaServerAuthError.timedOut
    }

    /// Step 3: discover the account's Plex Media Servers, each with its own access token and connections. The
    /// connection URLs are reachability-probed (`/identity`) and ordered local -> remote -> relay.
    static func plexDiscoverServers(accountToken: String) async throws -> [PlexServerCandidate] {
        guard var comps = URLComponents(string: plexResourcesURL) else { throw MediaServerAuthError.badURL }
        comps.queryItems = [URLQueryItem(name: "includeHttps", value: "1"),
                            URLQueryItem(name: "includeRelay", value: "1")]
        guard let url = comps.url else { throw MediaServerAuthError.badURL }
        var req = URLRequest(url: url)
        for (k, v) in plexHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(accountToken, forHTTPHeaderField: "X-Plex-Token")
        struct Resource: Decodable {
            let name: String?
            let clientIdentifier: String?
            let provides: String?
            let accessToken: String?
            let connections: [Conn]?
            struct Conn: Decodable { let uri: String?; let local: Bool?; let relay: Bool? }
        }
        let (data, response) = try await run(req)
        try ensureOK(response)
        let resources = try decode([Resource].self, from: data)
        var out: [PlexServerCandidate] = []
        for r in resources {
            guard (r.provides ?? "").split(separator: ",").map(String.init).contains("server"),
                  let machineId = r.clientIdentifier, let token = r.accessToken, !token.isEmpty else { continue }
            let conns = r.connections ?? []
            // Order local first, then non-relay remote, then relay.
            let ordered = conns.sorted { a, b in
                func rank(_ c: Resource.Conn) -> Int { (c.local == true) ? 0 : ((c.relay == true) ? 2 : 1) }
                return rank(a) < rank(b)
            }.compactMap { $0.uri }.filter { !$0.isEmpty }
            let reachable = await probeReachable(ordered, token: token)
            let urls = reachable.isEmpty ? ordered : reachable
            guard !urls.isEmpty else { continue }
            out.append(PlexServerCandidate(machineId: machineId, name: r.name ?? "Plex", accessToken: token, urls: urls))
        }
        return out
    }

    /// Probe each candidate `{uri}/identity` with a short timeout; return the reachable ones in the input
    /// order (fail-soft: an all-unreachable list yields empty and the caller keeps the unprobed order).
    private static func probeReachable(_ uris: [String], token: String) async -> [String] {
        var reachable: [String] = []
        for uri in uris {
            guard let url = URL(string: "\(uri)/identity") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (_, response) = try? await session(timeout: 4).data(for: req),
               (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true {
                reachable.append(uri)
            }
        }
        return reachable
    }

    // MARK: - Jellyfin (Quick Connect, username/password fallback)

    /// Is Quick Connect enabled on this server?
    static func jellyfinQuickConnectEnabled(base: String) async -> Bool {
        guard let root = MediaServerResolve.normalizedBase(base), let url = URL(string: "\(root)/QuickConnect/Enabled") else { return false }
        var req = URLRequest(url: url)
        req.setValue(embyAuthHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session().data(for: req),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true else { return false }
        // The endpoint returns a bare `true` / `false`.
        if let b = try? JSONDecoder().decode(Bool.self, from: data) { return b }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    struct QuickConnectInit: Sendable, Equatable { let secret: String; let code: String }

    /// Initiate Quick Connect: returns the secret (polled by the caller) and the 6-digit code the user enters
    /// in their Jellyfin app/web under Quick Connect.
    static func jellyfinInitiateQuickConnect(base: String) async throws -> QuickConnectInit {
        guard let root = MediaServerResolve.normalizedBase(base), let url = URL(string: "\(root)/QuickConnect/Initiate") else { throw MediaServerAuthError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(embyAuthHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Resp: Decodable { let secret: String; let code: String
            enum CodingKeys: String, CodingKey { case secret = "Secret", code = "Code" } }
        let (data, response) = try await run(req)
        try ensureOK(response)
        let r = try decode(Resp.self, from: data)
        return QuickConnectInit(secret: r.secret, code: r.code)
    }

    /// Poll Quick Connect until the user authorizes it, then exchange for an access token. Honors cancellation.
    static func jellyfinAwaitQuickConnect(base: String, secret: String, interval: TimeInterval = 3, expiresIn: TimeInterval = 300) async throws -> MediaServerAuthResult {
        guard let root = MediaServerResolve.normalizedBase(base) else { throw MediaServerAuthError.badURL }
        let deadline = Date().addingTimeInterval(expiresIn)
        struct ConnectResp: Decodable { let authenticated: Bool?
            enum CodingKeys: String, CodingKey { case authenticated = "Authenticated" } }
        while Date() < deadline {
            try Task.checkCancellation()
            guard var comps = URLComponents(string: "\(root)/QuickConnect/Connect") else { throw MediaServerAuthError.badURL }
            comps.queryItems = [URLQueryItem(name: "secret", value: secret)]
            if let url = comps.url {
                var req = URLRequest(url: url)
                req.setValue(embyAuthHeader, forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                if let (data, response) = try? await session().data(for: req),
                   (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
                   let r = try? JSONDecoder().decode(ConnectResp.self, from: data), r.authenticated == true {
                    return try await jellyfinAuthenticateWithQuickConnect(root: root, secret: secret)
                }
            }
            try await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
        }
        throw MediaServerAuthError.timedOut
    }

    private static func jellyfinAuthenticateWithQuickConnect(root: String, secret: String) async throws -> MediaServerAuthResult {
        guard let url = URL(string: "\(root)/Users/AuthenticateWithQuickConnect") else { throw MediaServerAuthError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(embyAuthHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["Secret": secret])
        let (data, response) = try await run(req)
        try ensureOK(response)
        return try await authResult(from: data, base: root)
    }

    // MARK: - Emby + Jellyfin username/password

    /// Username/password sign-in (Jellyfin fallback AND the Emby primary path). `header` is the auth header
    /// field name: Jellyfin reads `Authorization`, Emby reads `X-Emby-Authorization` (both carry the same
    /// MediaBrowser value). The password is used only for this one exchange and never stored.
    static func authenticateByName(base: String, username: String, password: String, headerField: String) async throws -> MediaServerAuthResult {
        guard let root = MediaServerResolve.normalizedBase(base), let url = URL(string: "\(root)/Users/AuthenticateByName") else { throw MediaServerAuthError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(embyAuthHeader, forHTTPHeaderField: headerField)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let (data, response) = try await run(req)
        try ensureOK(response)
        return try await authResult(from: data, base: root)
    }

    static func jellyfinAuthByPassword(base: String, username: String, password: String) async throws -> MediaServerAuthResult {
        try await authenticateByName(base: base, username: username, password: password, headerField: "Authorization")
    }

    static func embyAuthByPassword(base: String, username: String, password: String) async throws -> MediaServerAuthResult {
        try await authenticateByName(base: base, username: username, password: password, headerField: "X-Emby-Authorization")
    }

    // MARK: - Response mapping

    /// Map an `AuthenticationResult` ({AccessToken, User:{Id}}) into our result, enriching with the public
    /// server info (name/id) when available. Missing server info is non-fatal (the caller falls back to a
    /// host-derived name).
    private static func authResult(from data: Data, base: String) async throws -> MediaServerAuthResult {
        struct AuthResp: Decodable {
            let accessToken: String?; let user: User?; let serverId: String?
            struct User: Decodable { let id: String?; enum CodingKeys: String, CodingKey { case id = "Id" } }
            enum CodingKeys: String, CodingKey { case accessToken = "AccessToken", user = "User", serverId = "ServerId" }
        }
        let r = try decode(AuthResp.self, from: data)
        guard let token = r.accessToken, !token.isEmpty else { throw MediaServerAuthError.decode }
        let info = await publicServerInfo(base: base)
        return MediaServerAuthResult(accessToken: token, userId: r.user?.id ?? "",
                                     serverId: r.serverId ?? info?.id, serverName: info?.name)
    }

    /// `GET /System/Info/Public` -> (id, name). Best-effort, nil on any failure.
    static func publicServerInfo(base: String) async -> (id: String?, name: String?)? {
        guard let root = MediaServerResolve.normalizedBase(base), let url = URL(string: "\(root)/System/Info/Public") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Info: Decodable { let id: String?; let serverName: String?
            enum CodingKeys: String, CodingKey { case id = "Id", serverName = "ServerName" } }
        guard let (data, response) = try? await session().data(for: req),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
              let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
        return (info.id, info.serverName)
    }

    // MARK: - Low-level

    private static func run(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session().data(for: req) }
        catch is CancellationError { throw MediaServerAuthError.cancelled }
        catch { throw MediaServerAuthError.network(error.localizedDescription) }
    }

    private static func ensureOK(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw MediaServerAuthError.http(code) }
    }
}
