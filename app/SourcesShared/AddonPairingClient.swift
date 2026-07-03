import Foundation

/// Client for the "Install by QR / pair once, add many" add-on pairing relay at `add.vortx.tv`.
///
/// THE FLOW: the TV creates a pairing SESSION (`POST /pair/new`) and renders the returned `pageUrl`
/// as a QR. The user's phone opens that page and pastes one or more add-on manifest URLs, which the
/// relay appends to the session's list. The TV POLLS the session (`GET /pair/<token>`) to see the
/// live incoming list, then installs each manifest through the app's OWN hardened install path
/// (`CoreBridge.installAddon`) after a TV-side confirm. The relay is a DUMB PIPE: it only carries
/// URL strings; the TV validates and installs.
///
/// SIGNING: `add.vortx.tv` is a gated VortX host (see `VortXEdgeAuth.gatedHosts`), so both routes are
/// HMAC-signed with `VortXEdgeAuth.sign(&req)`. Signing is a no-op without a provisioned secret, which
/// the worker's observe mode lets through, so the flow works in every build.
enum AddonPairingClient {
    /// The relay base. HTTPS only; the host must stay in `VortXEdgeAuth.gatedHosts` for signing.
    private static let baseURL = URL(string: "https://add.vortx.tv")!

    /// A freshly created pairing session: the QR target (`pageUrl`), the poll `token`, and the
    /// session expiry (unix ms). The TV renders `pageUrl` as the QR and polls with `token`.
    struct Session: Equatable {
        let token: String
        let pageUrl: String
        let expiresAtMs: Double

        /// Wall-clock expiry as a `Date`, so the view can decide when to rotate the session.
        var expiresAt: Date { Date(timeIntervalSince1970: expiresAtMs / 1000) }
        var isExpired: Bool { Date() >= expiresAt }
    }

    /// One manifest URL the phone has added to the session, with when it landed (unix ms).
    struct IncomingManifest: Equatable, Identifiable {
        let url: String
        let addedAtMs: Double
        /// Stable identity so SwiftUI rows keep their per-row install state as the list grows.
        var id: String { url }
    }

    /// The current state of a polled session: the live list plus whether it expired or was closed.
    struct Poll: Equatable {
        let manifests: [IncomingManifest]
        let expiresAtMs: Double
        let closed: Bool

        var expiresAt: Date { Date(timeIntervalSince1970: expiresAtMs / 1000) }
        var isExpired: Bool { Date() >= expiresAt }
    }

    /// A poll outcome. `.gone` maps the relay's 404 (expired / unknown token) so the view can rotate
    /// to a fresh session instead of spinning on a dead one.
    enum PollResult: Equatable {
        case ok(Poll)
        case gone
        case failed
    }

    // MARK: - POST /pair/new

    /// Create a new pairing session. Returns nil on any failure so the view can show a retry.
    static func createSession() async -> Session? {
        var req = URLRequest(url: baseURL.appendingPathComponent("pair/new"), timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&req)   // gated host (add.vortx.tv /pair/new POST): stamp X-VX-Ts / X-VX-Sig

        guard let data = await performData(req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty,
              let pageUrl = obj["pageUrl"] as? String, !pageUrl.isEmpty,
              let expiresAt = numeric(obj["expiresAt"]) else { return nil }
        return Session(token: token, pageUrl: pageUrl, expiresAtMs: expiresAt)
    }

    // MARK: - GET /pair/<token>

    /// Poll a session's live manifest list. A 404 becomes `.gone` (expired / unknown token).
    static func poll(token: String) async -> PollResult {
        // Percent-encode the token into the path so a stray character can't break the URL.
        let safeToken = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        var req = URLRequest(url: baseURL.appendingPathComponent("pair").appendingPathComponent(safeToken),
                             timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        VortXEdgeAuth.sign(&req)   // gated host (add.vortx.tv /pair/<token> GET): stamp X-VX-Ts / X-VX-Sig

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed }
            if http.statusCode == 404 { return .gone }
            guard (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed }
            let rawManifests = (obj["manifests"] as? [[String: Any]]) ?? []
            let manifests: [IncomingManifest] = rawManifests.compactMap { entry in
                guard let url = entry["url"] as? String, !url.isEmpty else { return nil }
                return IncomingManifest(url: url, addedAtMs: numeric(entry["addedAt"]) ?? 0)
            }
            let expiresAt = numeric(obj["expiresAt"]) ?? 0
            let closed = (obj["closed"] as? Bool) ?? false
            return .ok(Poll(manifests: manifests, expiresAtMs: expiresAt, closed: closed))
        } catch {
            return .failed
        }
    }

    // MARK: - Session persistence (resume across sheet opens)

    /// The most recent session, persisted so a manifest the phone adds AFTER the pairing sheet closes
    /// still arrives: the view resumes this session on the next open instead of minting a fresh one.
    /// The relay keeps a session alive ~10 min from its last activity, and the phone page's own 2s
    /// polling keeps bumping that while it stays open, so the stored expiry is only a lower bound;
    /// liveness is decided by polling the token, never by the stored timestamp. Only the short-lived
    /// token + page URL are stored, no account data.
    private static let persistedSessionKey = "vortx.addonPair.session"

    static func persist(_ session: Session) {
        UserDefaults.standard.set(
            ["token": session.token, "pageUrl": session.pageUrl, "expiresAtMs": session.expiresAtMs],
            forKey: persistedSessionKey)
    }

    static func persistedSession() -> Session? {
        guard let dict = UserDefaults.standard.dictionary(forKey: persistedSessionKey),
              let token = dict["token"] as? String, !token.isEmpty,
              let pageUrl = dict["pageUrl"] as? String, !pageUrl.isEmpty else { return nil }
        return Session(token: token, pageUrl: pageUrl, expiresAtMs: numeric(dict["expiresAtMs"]) ?? 0)
    }

    static func clearPersistedSession() {
        UserDefaults.standard.removeObject(forKey: persistedSessionKey)
    }

    // MARK: - Helpers

    /// Coerce a JSON number that may arrive as `Double`, `Int`, or a numeric `String` into a `Double`.
    private static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Signed request → `Data?` (nil on transport error or non-2xx), matching the other edge clients.
    private static func performData(_ req: URLRequest) async -> Data? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
