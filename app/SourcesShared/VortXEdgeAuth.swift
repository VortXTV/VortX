import Foundation
import CryptoKit

/// Client-side request signing for the hardened VortX edge workers.
///
/// VortX's first-party edge services (skip / trickplay / ratings / poster / erdb / trailer) are
/// fronted by Cloudflare Workers that verify an HMAC signature so a request can be attributed to a
/// real VortX build rather than a scraper hammering the free, keyless endpoints. `sign(_:)` is the
/// one place that stamps a request; every URLSession call site that targets one of OUR gated hosts
/// runs the outgoing `URLRequest` through it right before it is sent.
///
/// THE SIGNING CONTRACT (must match the workers byte-for-byte):
///   - Header `X-VX-Ts`: current unix time in SECONDS, as an integer string.
///   - Header `X-VX-Sig`: lowercase hex of HMAC-SHA256(key, message).
///   - key     = the UTF-8 bytes of the 64-char hex secret STRING (NOT hex-decoded): `Data(secret.utf8)`.
///   - message = METHOD (uppercase) + "\n" + url.path + "\n" + ts
///               (url.path is the path only: no query, no host, e.g. "/skip", "/tp/<key>",
///                "/v1/ratings/tt...", "/clip"). The default HTTP method is GET.
///
/// SECRET PROVENANCE (no-leak):
///   The secret is read ONCE from Info.plist key `VortXEdgeSecret`, which Xcode substitutes from the
///   `VORTX_EDGE_SECRET` build setting. That value comes from the GITIGNORED `Config/VortXEdge.xcconfig`
///   locally (or a CI GitHub repo secret), and defaults to EMPTY. The public repo never carries a real
///   value. An empty / absent secret makes signing a safe no-op: an empty-key signature is still
///   attached, which the workers' OBSERVE mode lets through, so nothing breaks until the owner
///   provisions the real key and the workers flip to enforce.
enum VortXEdgeAuth {
    /// Header names, shared with the workers.
    private static let tsHeader = "X-VX-Ts"
    private static let sigHeader = "X-VX-Sig"

    /// The hosts WE operate behind the signing gate. A request is only signed when its URL host is one
    /// of these. `api.vortx.tv` is deliberately EXCLUDED: it is account-authed separately (the account
    /// token path) and must not carry this signature. The R2 public asset host that serves trickplay
    /// sprite images is a different host (not listed), so sprite downloads stay unsigned, which matches
    /// the worker's exempt asset route.
    private static let gatedHosts: Set<String> = [
        "skip.vortx.tv",
        "trickplay.vortx.tv",
        "ratings.vortx.tv",
        "poster.vortx.tv",
        "erdb.vortx.tv",
        "trailer.vortx.tv",
        "catalogs.vortx.tv",
    ]

    /// The shared secret, read once from Info.plist. Empty string when absent (signing becomes a
    /// no-op / empty-key signature that OBSERVE mode allows). Read lazily and cached; never crashes.
    private static let secret: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "VortXEdgeSecret") as? String
        return (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// Sign `request` IFF its URL host is one of our gated services. No-op otherwise (third-party and
    /// `api.vortx.tv` requests pass through untouched). Safe to call on any outgoing request; it never
    /// throws and never crashes. With an empty secret it still stamps an (empty-key) signature so the
    /// wire shape is identical in observe and enforce modes.
    static func sign(_ request: inout URLRequest) {
        guard let url = request.url, let host = url.host, gatedHosts.contains(host) else { return }

        let method = (request.httpMethod ?? "GET").uppercased()
        let ts = String(Int(Date().timeIntervalSince1970))
        // url.path is the path only (no host, no query), exactly what the worker hashes.
        let message = "\(method)\n\(url.path)\n\(ts)"

        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        let sig = mac.map { String(format: "%02x", $0) }.joined()

        request.setValue(ts, forHTTPHeaderField: tsHeader)
        request.setValue(sig, forHTTPHeaderField: sigHeader)
    }
}
