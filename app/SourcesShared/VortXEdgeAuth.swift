import Foundation
import CryptoKit

/// Client-side request signing for the hardened VortX edge workers.
///
/// VortX's first-party edge services (skip / trickplay / ratings / poster / erdb / trailer / catalogs /
/// config / subtitles / add-pair) are fronted by Cloudflare Workers that verify an HMAC signature so a
/// request can be attributed to a real VortX build rather than a scraper leeching the keyless endpoints.
/// `sign(_:)` is the one place that stamps a request; every URLSession call site that targets one of OUR
/// gated hosts runs the outgoing `URLRequest` through it right before it is sent.
///
/// THREAT MODEL (be honest): a secret embedded in a CLIENT is never truly non-extractable, and a sideloaded
/// app cannot use App Attest / DeviceCheck (no valid app identity). So this is DETERRENCE + REVOCATION, not
/// a wall:
///   1. OBFUSCATION: the secret is NEVER stored or shipped as a contiguous plaintext string. Info.plist
///      carries only a MASKED (XOR + base64) blob, and the mask is assembled at runtime from scattered
///      byte fragments, so `strings`/`plutil`/a casual unzip of the .ipa yields nothing usable. Pulling the
///      real key requires actually reverse-engineering the de-mask path.
///   2. KEY VERSIONING + ROTATION: every request carries a key id (`X-VX-Kid`). The workers hold a MAP of
///      id -> secret and can REVOKE an id (kill any leaked/extracted key, and anyone who scraped it) and
///      roll to a new id, WITHOUT breaking already-sideloaded builds still signing with a still-valid id.
///      Rotate on a cadence so an extracted key has a short useful life; revoke immediately on abuse.
///   3. OBSERVE -> ENFORCE stays: with an empty/absent secret this is a safe no-op the workers allow, so
///      the web client + older builds keep working until every shipping client signs and we flip enforce.
/// The long-term move (compiled-Rust vortx-core holding the key) raises the RE cost further; see the Brain
/// note vortx-core-native-features-and-moat. This is the strongest we can do in a sideloaded Swift client now.
///
/// THE SIGNING CONTRACT (must match the workers byte-for-byte):
///   - Header `X-VX-Ts`:  current unix time in SECONDS, integer string.
///   - Header `X-VX-Kid`: the key id the signature was made with (lets the worker pick + revoke a secret).
///   - Header `X-VX-Sig`: lowercase hex of HMAC-SHA256(key, message).
///   - key     = UTF-8 bytes of the 64-char hex secret STRING (NOT hex-decoded): `Data(secret.utf8)`.
///   - message = METHOD (uppercase) + "\n" + percent-encoded path + "\n" + ts (matches the workers'
///     `url.pathname`, which is percent-encoded; do NOT use the percent-decoded `URL.path`).
enum VortXEdgeAuth {
    private static let tsHeader = "X-VX-Ts"
    private static let sigHeader = "X-VX-Sig"
    private static let kidHeader = "X-VX-Kid"

    /// Query-param names for the header-less signing variant (`signedURL`). These MUST match the workers'
    /// shared `edge_auth.ts` (`SIG_QUERY_TS` / `SIG_QUERY_SIG` / `SIG_QUERY_KID`), which read a query signature
    /// for GETs that cannot carry `X-VX-*` headers (an `AsyncImage` / `<img>` load).
    private static let tsQuery = "vts"
    private static let sigQuery = "vsig"
    private static let kidQuery = "vkid"

    /// MEMO CACHE for `signedURL` (D15). `signedURL` bakes a per-SECOND `vts` into the URL, so calling it
    /// from a SwiftUI view body (the only caller, `ResolvedTitleLogo`) would mint a DIFFERENT URL every wall-
    /// clock second the body re-evaluates. `AsyncImage(url:)` treats a changed URL as a new resource: the
    /// phase resets (the logo visibly flashes back to the title-text fallback) and the bytes are re-fetched,
    /// because `URLCache` keys on the full URL and every new `vts` is a permanent miss. Hero/detail views
    /// re-render constantly (focus moves, scroll, progress ticks), so without memoization an ERDB logo would
    /// flicker and refetch forever. We cache the signed URL per (method, raw URL) and reuse it until it is
    /// halfway to the worker's acceptance window, then re-sign lazily. The poster/erdb workers (and the
    /// shared `edge_auth.ts`) accept `|now - ts| <= 300s` (`SIG_SKEW_SECONDS`), so a 150s reuse keeps every
    /// served URL comfortably fresh (max age 150s « 300s) while the URL stays STABLE across renders and only
    /// rotates rarely. The lock makes the cache safe even though today's sole caller is main-actor-bound.
    private static let signedURLReuse: TimeInterval = 150   // half the 300s worker skew window
    private static let signedURLCacheCap = 512              // bound growth across a long browse session
    private static let signedURLLock = NSLock()
    private static var signedURLCache: [String: (signed: URL, at: TimeInterval)] = [:]

    /// Current signing key id. Rotation is a TWO-part change provisioned together: (1) a NEW masked
    /// `VortXEdgeSecret` in Info.plist (via `maskedValue(for:)`) AND (2) this new kid, plus the matching
    /// new id -> secret entry on the workers BEFORE the build ships; revoke the old id after a grace window.
    /// Bumping the kid alone changes only the label, not the signature, so it would fail worker verification
    /// without the paired secret. Shipped builds keep working on their id until it is revoked.
    private static let keyId = "k1"

    /// Hosts WE operate behind the signing gate. `api.vortx.tv` is deliberately EXCLUDED (account-authed).
    private static let gatedHosts: Set<String> = [
        "skip.vortx.tv", "trickplay.vortx.tv", "ratings.vortx.tv", "poster.vortx.tv", "erdb.vortx.tv",
        "trailer.vortx.tv", "catalogs.vortx.tv", "config.vortx.tv", "subtitles.vortx.tv", "add.vortx.tv",
        "sources.vortx.tv", "watch.vortx.tv", "iptv.vortx.tv",
    ]

    /// The runtime de-mask key, assembled from two scattered fragments so it is not a single findable
    /// literal. XORing these two equal-length byte runs yields the actual 32-byte mask applied to the
    /// secret. Split + combined on purpose: neither fragment alone is the mask, and the combine happens in
    /// code, not in any resource a static dump can read.
    private static let maskFragmentA: [UInt8] = [
        0x9e, 0x41, 0xb7, 0x2c, 0xd5, 0x6a, 0x03, 0xf8, 0x11, 0xae, 0x77, 0x50, 0xc9, 0x34, 0x8b, 0x22,
        0x5f, 0xe0, 0x19, 0xa6, 0x7d, 0xc2, 0x3b, 0x94, 0x08, 0xbf, 0x66, 0xd1, 0x4a, 0xe7, 0x2d, 0x80,
    ]
    private static let maskFragmentB: [UInt8] = [
        0x37, 0xdc, 0x61, 0x8a, 0x1f, 0xb4, 0x49, 0xe2, 0x7b, 0x06, 0x95, 0x28, 0xc3, 0x5e, 0xf1, 0x40,
        0xa9, 0x12, 0x8f, 0x64, 0xd3, 0x38, 0xad, 0x02, 0x71, 0xce, 0x1b, 0x84, 0x39, 0x96, 0x4f, 0xba,
    ]
    private static let mask: [UInt8] = zip(maskFragmentA, maskFragmentB).map { $0 ^ $1 }

    /// The real secret (64-hex STRING), de-masked at runtime. Info.plist `VortXEdgeSecret` holds
    /// base64( XOR(secretUTF8, mask-repeated) ). Absent/empty/malformed => "" (no-op signing, observe-safe).
    /// Never stored as plaintext anywhere in the shipped bundle. Read once, cached; never crashes.
    private static let secret: String = {
        guard let masked = (Bundle.main.object(forInfoDictionaryKey: "VortXEdgeSecret") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !masked.isEmpty,
            let blob = Data(base64Encoded: masked), !blob.isEmpty, !mask.isEmpty
        else { return "" }
        var out = [UInt8](); out.reserveCapacity(blob.count)
        for (i, b) in blob.enumerated() { out.append(b ^ mask[i % mask.count]) }
        // The de-masked value must be a 64-char hex string; anything else means a bad/placeholder config,
        // which we treat as unprovisioned (no-op) rather than sign with garbage.
        guard let s = String(bytes: out, encoding: .utf8),
              s.count == 64, s.allSatisfy({ $0.isHexDigit }) else { return "" }
        return s
    }()

    /// Sign `request` IFF its URL host is one of our gated services. No-op otherwise. Never throws/crashes.
    /// With an empty secret it stamps an (empty-key) signature so the wire shape is identical in observe and
    /// enforce modes.
    static func sign(_ request: inout URLRequest) {
        guard let url = request.url, let host = url.host, gatedHosts.contains(host) else { return }

        let method = (request.httpMethod ?? "GET").uppercased()
        let ts = String(Int(Date().timeIntervalSince1970))
        let sig = hexSignature(method: method, signedPath: signedPath(of: url), ts: ts)

        request.setValue(ts, forHTTPHeaderField: tsHeader)
        request.setValue(keyId, forHTTPHeaderField: kidHeader)
        request.setValue(sig, forHTTPHeaderField: sigHeader)
    }

    /// Header name carrying the SHA-256 of the request body, so a body-bound signature is self-describing on the
    /// wire and the worker can recompute + compare it.
    private static let bodyHeader = "X-VX-Body"

    /// Sign `request` like `sign(_:)` but BIND THE BODY into the signature (H2): the message is
    /// `METHOD\npath\nts\nSHA256(body)`, and `X-VX-Body` carries that lowercase-hex body hash. This lets the
    /// enforced-ack worker reject a request whose body was altered or replayed with a signature the body did not
    /// cover. The body must already be set on the request. No-op for a non-gated host, matching `sign(_:)`.
    static func signIncludingBody(_ request: inout URLRequest) {
        guard let url = request.url, let host = url.host, gatedHosts.contains(host) else { return }

        let method = (request.httpMethod ?? "GET").uppercased()
        let ts = String(Int(Date().timeIntervalSince1970))
        let bodyHash = sha256Hex(request.httpBody ?? Data())
        let message = "\(method)\n\(signedPath(of: url))\n\(ts)\n\(bodyHash)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        let sig = mac.map { String(format: "%02x", $0) }.joined()

        request.setValue(ts, forHTTPHeaderField: tsHeader)
        request.setValue(keyId, forHTTPHeaderField: kidHeader)
        request.setValue(sig, forHTTPHeaderField: sigHeader)
        request.setValue(bodyHash, forHTTPHeaderField: bodyHeader)
    }

    /// Lowercase-hex SHA-256 of arbitrary bytes (the ack body hash).
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Return a QUERY-signed copy of `url` for header-less asset loads: `AsyncImage(url:)` and other `<img>`/
    /// `<video>`-style GETs that cannot attach `X-VX-*` headers. Appends `vts` / `vkid` / `vsig`, where `vsig`
    /// is the SAME `HMAC-SHA256(key, METHOD\npath\nts)` the header path computes, so a worker verifies a
    /// query-signed image GET exactly as it verifies a header-signed API call (see `edge_auth.ts`
    /// `sigMatchesAny` + the `SIG_QUERY_*` params). The signature covers only METHOD + path + ts, so the three
    /// appended query params are outside the signed message and never invalidate it.
    ///
    /// FAIL-OPEN by contract. Returns the URL UNCHANGED (unsigned) for a non-gated host, an unprovisioned
    /// build (empty secret), or any URL we cannot decompose. Enforcement flips one worker at a time, so an
    /// unsigned URL must degrade to a normal (observe-mode) load, never a broken image. Never throws/crashes.
    ///
    /// Prefer `sign(_:)` (header signing) whenever the caller controls a `URLRequest`: headers are not part of
    /// the `URLCache` key, whereas a per-second `vts` in the URL would change the cache key every second and
    /// defeat byte caches. `signedURL` is for the `AsyncImage` case, which cannot set headers.
    static func signedURL(_ url: URL, method: String = "GET") -> URL {
        guard let host = url.host, gatedHosts.contains(host), !secret.isEmpty,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }

        let m = method.uppercased()
        let now = Date().timeIntervalSince1970
        // MEMO: reuse the previously-signed URL for this (method, raw URL) while it is still well inside the
        // worker skew window, so repeated body re-evaluations get a STABLE URL (no AsyncImage churn / cache
        // bust). The raw (unsigned) absolute string is the cache key; the idempotent strip below means a raw
        // URL never carries our signing params, so this key is stable per logo.
        let cacheKey = m + "\n" + url.absoluteString
        signedURLLock.lock()
        if let hit = signedURLCache[cacheKey], now - hit.at < signedURLReuse {
            let cached = hit.signed
            signedURLLock.unlock()
            return cached
        }
        signedURLLock.unlock()

        let ts = String(Int(now))
        let sig = hexSignature(method: m, signedPath: comps.percentEncodedPath, ts: ts)

        // Idempotent: strip any prior signing params before re-appending, so re-signing an already-signed URL
        // never accumulates duplicates.
        var items = (comps.queryItems ?? []).filter { $0.name != tsQuery && $0.name != sigQuery && $0.name != kidQuery }
        items.append(URLQueryItem(name: tsQuery, value: ts))
        items.append(URLQueryItem(name: kidQuery, value: keyId))
        items.append(URLQueryItem(name: sigQuery, value: sig))
        comps.queryItems = items
        let signed = comps.url ?? url

        signedURLLock.lock()
        // Bound the cache: when full, drop entries already past the reuse horizon (they would re-sign anyway).
        if signedURLCache.count >= signedURLCacheCap {
            for (k, v) in signedURLCache where now - v.at >= signedURLReuse { signedURLCache.removeValue(forKey: k) }
        }
        signedURLCache[cacheKey] = (signed, now)
        signedURLLock.unlock()
        return signed
    }

    /// The canonical signed path: the PERCENT-ENCODED path so it matches the workers, which verify against
    /// `url.pathname` (percent-encoded in the Workers runtime). `URL.path` is percent-DECODED, so any gated
    /// route with an encodable char (space, colon, non-ASCII) would otherwise sign a decoded path and mismatch
    /// the worker's encoded one. ASCII paths are unaffected.
    private static func signedPath(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
    }

    /// Lowercase-hex `HMAC-SHA256(key, METHOD\npath\nts)`. `key` = UTF-8 bytes of the 64-char hex secret STRING
    /// (NOT hex-decoded), matching the workers. With an empty secret this is an (empty-key) HMAC; the header
    /// path stamps it regardless (identical wire shape in observe + enforce), while `signedURL` fails open
    /// before ever reaching here.
    private static func hexSignature(method: String, signedPath: String, ts: String) -> String {
        let message = "\(method)\n\(signedPath)\n\(ts)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// One-off helper to compute the MASKED Info.plist value from a raw 64-hex secret, so provisioning never
    /// puts the plaintext key in the xcconfig/Info.plist. Not called at runtime; kept here so the mask stays
    /// the single source of truth. Usage (debug REPL / a tiny tool): `VortXEdgeAuth.maskedValue(for: "<hex>")`.
    static func maskedValue(for rawHexSecret: String) -> String {
        let bytes = Array(rawHexSecret.utf8)
        guard !mask.isEmpty else { return "" }
        var out = [UInt8](); out.reserveCapacity(bytes.count)
        for (i, b) in bytes.enumerated() { out.append(b ^ mask[i % mask.count]) }
        return Data(out).base64EncodedString()
    }
}
