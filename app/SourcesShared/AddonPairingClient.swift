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

    /// One delivery the phone has added to the session: a durable delivery id (relay-minted, STABLE across
    /// session-token rotation), the raw URL, when it landed, and the install status the relay currently holds
    /// (`pending` until the TV acks a confirmed `installed` / `failed`). `deliveryId` is the stable identity so a
    /// row's install state survives token rotation; a legacy relay that omits it falls back to the URL.
    struct IncomingManifest: Equatable, Identifiable {
        let deliveryId: String
        let url: String
        let addedAtMs: Double
        let status: String
        /// Stable identity so SwiftUI rows keep their per-row install state as the list grows.
        var id: String { deliveryId }
    }

    /// The current state of a polled session: the live list, the session revision, plus whether it expired or was
    /// closed.
    struct Poll: Equatable {
        let manifests: [IncomingManifest]
        let expiresAtMs: Double
        let closed: Bool
        let rev: Int

        var expiresAt: Date { Date(timeIntervalSince1970: expiresAtMs / 1000) }
        var isExpired: Bool { Date() >= expiresAt }
    }

    /// One TV install acknowledgement: the delivery id, its confirmed terminal status, the local install
    /// `attempt` that produced it (H3 attempt authority — the worker rejects an ack from a superseded attempt),
    /// the session `rev` the ack was computed against (H3 revision authority — a stale ack cannot overwrite a
    /// newer worker attempt), and a unique `mutationId` NONCE (replay enforcement — the worker records the nonce
    /// and rejects a replayed ack body).
    struct DeliveryAck: Equatable {
        let deliveryId: String
        let status: String   // "installed" | "failed"
        let attempt: Int
        let rev: Int
        let mutationId: String
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
              let token = obj["token"] as? String, isStrictToken(token),
              let pageUrl = obj["pageUrl"] as? String, isTrustedPageURL(pageUrl),
              let expiresAt = numeric(obj["expiresAt"]) else { return nil }
        return Session(token: token, pageUrl: pageUrl, expiresAtMs: expiresAt)
    }

    /// M4: a strict token alphabet. The token is spliced into the `/pair/<token>` route, so it must be a plain
    /// opaque id (ASCII letters, digits, `-`, `_`) — reject anything with a slash, dot, or other char that could
    /// alter the path (`../`, an extra segment) even after percent-encoding. Bounded length as a sanity cap.
    static func isStrictToken(_ token: String) -> Bool {
        guard (1...200).contains(token.count) else { return false }
        return token.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
        }
    }

    /// M4: only trust a pairing page URL that is HTTPS on our own relay host, so a tampered/injected `pageUrl`
    /// in the create response is never rendered as a QR or shown on screen.
    static func isTrustedPageURL(_ pageUrl: String) -> Bool {
        guard let comps = URLComponents(string: pageUrl),
              comps.scheme?.lowercased() == "https",
              comps.host?.lowercased() == "add.vortx.tv" else { return false }
        return true
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
                // Fall back to the URL as the delivery id for a legacy relay that predates durable ids, so rows
                // still get a stable identity.
                let deliveryId = (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
                let status = (entry["status"] as? String) ?? "pending"
                return IncomingManifest(deliveryId: deliveryId, url: url, addedAtMs: numeric(entry["addedAt"]) ?? 0, status: status)
            }
            let expiresAt = numeric(obj["expiresAt"]) ?? 0
            let closed = (obj["closed"] as? Bool) ?? false
            // H11: a hostile / malformed remote `rev` (NaN, ±inf, a value past Int.max) must never crash the app.
            // `safeRevision` clamps instead of trapping — `Int(numeric(...) ?? 0)` was the reproduced exit-133.
            let rev = safeRevision(numeric(obj["rev"]))
            return .ok(Poll(manifests: manifests, expiresAtMs: expiresAt, closed: closed, rev: rev))
        } catch {
            return .failed
        }
    }

    // MARK: - POST /pair/<token>/ack

    /// Report CONFIRMED per-delivery install results back to the relay so the phone's Done can show the truth.
    /// Best-effort: a `.gone` (404, the session rotated / expired) or a transport error is not fatal to the
    /// install itself (the add-on is already in the engine); it just means the phone can no longer be updated.
    /// Returns true only on a 2xx (H2: the caller HONORS this Bool and retries on false). Never logs the URL or
    /// token. The body carries per-delivery attempt + rev + a unique mutationId nonce (H3 / replay), and the
    /// HMAC signature is BOUND TO THE BODY (H2) so the worker's enforced ack cannot be replayed or forged.
    @discardableResult
    static func ack(token: String, deliveries: [DeliveryAck]) async -> Bool {
        guard !deliveries.isEmpty else { return true }
        let safeToken = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        var req = URLRequest(url: baseURL.appendingPathComponent("pair").appendingPathComponent(safeToken).appendingPathComponent("ack"),
                             timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        let body: [String: Any] = ["deliveries": deliveries.map {
            ["id": $0.deliveryId, "status": $0.status, "attempt": $0.attempt, "rev": $0.rev, "mid": $0.mutationId]
        }]
        // Canonical (sorted-keys) body so the exact bytes we sign are the exact bytes the worker verifies.
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        // gated host (add.vortx.tv /pair/<token>/ack POST): sign method+path+ts+SHA256(body) so the signature
        // covers the body (H2 body-binding). Body must be set BEFORE signing.
        VortXEdgeAuth.signIncludingBody(&req)
        return await performData(req) != nil
    }

    /// Mint a fresh replay nonce (mutation id) for an ack. UUID: unique per ack POST, so the worker can record
    /// it and reject a byte-for-byte replay of the same signed body.
    static func newMutationId() -> String { UUID().uuidString }

    // MARK: - Session persistence (resume across sheet opens)

    /// The most recent session, held so a manifest the phone adds AFTER the pairing sheet closes
    /// still arrives: the view resumes this session on the next open instead of minting a fresh one.
    /// The relay keeps a session alive ~10 min from its last activity, and the phone page's own 2s
    /// polling keeps bumping that while it stays open, so the stored expiry is only a lower bound;
    /// liveness is decided by polling the token, never by the stored timestamp.
    ///
    /// This lives IN MEMORY ONLY (not UserDefaults): the token is a bearer credential for the relay
    /// session, and plaintext UserDefaults is captured by Finder/iCloud device backups. Resume is only
    /// needed while the app process is alive (sheet close then reopen), so a static holder is enough,
    /// and it leaves no on-disk trace to back up. `nil` = no session to resume.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedSession: Session?

    static func persist(_ session: Session) {
        lock.lock(); defer { lock.unlock() }
        storedSession = session
    }

    static func persistedSession() -> Session? {
        lock.lock(); defer { lock.unlock() }
        return storedSession
    }

    static func clearPersistedSession() {
        lock.lock(); defer { lock.unlock() }
        storedSession = nil
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
