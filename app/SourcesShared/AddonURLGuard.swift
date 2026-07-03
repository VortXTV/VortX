import Foundation

/// SSRF / private-address guard for user-supplied add-on manifest URLs.
///
/// An add-on install URL is pasted (or relayed via the Install-by-QR pairing flow) and then FETCHED by the
/// app. Without a guard, a hostile or careless URL could point the fetch at a private / loopback / internal
/// address (`127.0.0.1`, `10.x`, `192.168.x`, `169.254.x`, a `.local` LAN service, a cloud metadata endpoint),
/// turning the install into a server-side-request-forgery probe of the device's own network. This validates
/// BOTH the pasted URL's host AND every address that host RESOLVES to, and re-checks each redirect hop, so a
/// public URL that 3xx-redirects to a private one is refused too.
///
/// It is FAIL-CLOSED for private targets: a host that resolves to any blocked address is rejected. It does not
/// break normal public manifests: a public host with only public resolved addresses passes. A DNS failure is
/// reported as unreachable (the install then surfaces the usual "could not reach" error), never silently
/// allowed.
///
/// Used by both `CoreBridge.installAddon` and `CoreBridge.previewAddonManifest` (the QR confirm resolves the
/// name via preview), so the exact same policy gates every manifest fetch.
///
/// RESIDUAL RISK (accepted, resolve-then-connect): `validate` resolves the host and `fetch` then issues a
/// SEPARATE `URLSession` request that re-resolves DNS independently, so the connected IP is not pinned to the
/// validated one. A hostile authoritative DNS with a ~0 TTL can answer a PUBLIC address to `validate` and a
/// PRIVATE one to the actual connection (classic DNS rebinding), bypassing the private-address block. This is
/// not fully closable here: `URLSession` on Apple platforms exposes no connection-time IP pinning. The blast
/// radius is bounded (the "server" is the user's own device, the target is only the LAN / on-device loopback,
/// and the response is parsed solely as manifest JSON, never reflected to the attacker), so this stays a known,
/// accepted limitation rather than an implied guarantee.
enum AddonURLGuard {
    /// Why a manifest URL was refused. `message` is the user-facing string the install/preview surfaces.
    enum Rejection: Error {
        case invalidScheme
        case privateAddress
        case unresolvable
        case tooManyRedirects

        var message: String {
            switch self {
            case .invalidScheme:
                return "Enter a valid add-on URL (https://…/manifest.json)."
            case .privateAddress:
                return "This add-on URL points to a private address and can't be installed."
            case .unresolvable:
                return "Could not reach that add-on. Check the URL and your connection."
            case .tooManyRedirects:
                return "That add-on URL redirects too many times."
            }
        }
    }

    /// Max redirect hops we follow while re-validating each target. A normal manifest never needs more than a
    /// couple; a chain longer than this is treated as abuse and refused.
    private static let maxRedirects = 5

    // MARK: - Public validation

    /// Validate a URL's SCHEME + HOST before any fetch: reject a non-http(s) scheme, a literal-IP host in a
    /// blocked range, and a hostname that RESOLVES to any blocked address. This is the synchronous pre-fetch
    /// gate; `fetch(...)` additionally re-checks every redirect target.
    static func validate(_ url: URL) async -> Rejection? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .invalidScheme
        }
        guard let host = url.host, !host.isEmpty else { return .invalidScheme }

        // A bracketed/literal IP host is checked directly (no DNS), so a raw `http://127.0.0.1/…` or
        // `http://[::1]/…` is refused without a lookup.
        let bareHost = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())   // IPv6 literals arrive bracketed from URL.host
            : host
        if let literal = IPAddress(parsing: bareHost) {
            return literal.isBlocked ? .privateAddress : nil
        }

        // Otherwise resolve the hostname and check EVERY address it maps to. Any blocked address fails closed.
        let resolved = resolve(host: bareHost)
        guard !resolved.isEmpty else { return .unresolvable }
        if resolved.contains(where: { $0.isBlocked }) { return .privateAddress }
        return nil
    }

    /// Fetch a validated manifest URL with MANUAL redirect handling, re-validating each hop so a public URL
    /// that redirects to a private address is blocked too. Returns the response data + the FINAL URL, or a
    /// `Rejection` describing why it was refused / unreachable. This is the one fetch path both install and
    /// preview use, so the SSRF policy can never be bypassed by a redirect.
    static func fetch(_ url: URL) async -> Result<(data: Data, finalURL: URL), Rejection> {
        var current = url
        for _ in 0...maxRedirects {
            if let rejection = await validate(current) { return .failure(rejection) }

            var request = URLRequest(url: current)
            request.timeoutInterval = 15
            let delegate = NoRedirectDelegate()
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return .failure(.unresolvable) }
                // 3xx with a Location: re-validate the target host before following it.
                if (300...399).contains(http.statusCode),
                   let location = http.value(forHTTPHeaderField: "Location"),
                   let next = URL(string: location, relativeTo: current)?.absoluteURL {
                    current = next
                    continue
                }
                return .success((data, http.url ?? current))
            } catch {
                return .failure(.unresolvable)
            }
        }
        return .failure(.tooManyRedirects)
    }

    // MARK: - DNS resolution

    /// Resolve a hostname to its IPv4 + IPv6 addresses via `getaddrinfo`. Returns [] on failure (treated as
    /// unresolvable by the caller). Synchronous but wrapped by the async `validate`; getaddrinfo is a blocking
    /// call, so it runs off the caller's actor via the surrounding `Task` the async context already provides.
    private static func resolve(host: String) -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC       // both A and AAAA
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var addresses: [IPAddress] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let sa = current.pointee.ai_addr {
                if current.pointee.ai_family == AF_INET {
                    sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                        addresses.append(IPAddress(v4: ptr.pointee.sin_addr))
                    }
                } else if current.pointee.ai_family == AF_INET6 {
                    sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
                        addresses.append(IPAddress(v6: ptr.pointee.sin6_addr))
                    }
                }
            }
            node = current.pointee.ai_next
        }
        return addresses
    }
}

/// A resolved or literal IP address, reduced to the bytes we test against the blocked ranges. Kept private to
/// the guard; the only question it answers is `isBlocked`.
private struct IPAddress {
    enum Kind { case v4([UInt8]), v6([UInt8]) }
    let kind: Kind

    init(v4 addr: in_addr) {
        // `s_addr` is already stored in NETWORK byte order (big-endian): its raw memory bytes ARE the dotted
        // octets in order, e.g. 127.0.0.1 -> [127, 0, 0, 1]. Read them directly; do NOT byte-swap (a
        // `.bigEndian` here would reverse them on a little-endian host and misclassify every v4 address).
        var raw = addr.s_addr
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        kind = .v4(bytes)
    }

    init(v6 addr: in6_addr) {
        let b = addr.__u6_addr.__u6_addr8
        kind = .v6([b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15])
    }

    /// Parse a literal-IP host ("10.0.0.1", "::1", "fe80::1", "::ffff:127.0.0.1") via `inet_pton`. nil when the
    /// string is not a bare IP (i.e. it is a hostname that must go through DNS).
    init?(parsing string: String) {
        var v4 = in_addr()
        if string.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            self.init(v4: v4); return
        }
        var v6 = in6_addr()
        if string.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            self.init(v6: v6); return
        }
        return nil
    }

    /// True when this address is loopback / private / link-local / CGNAT / ULA / unspecified — anything that
    /// must NOT be reachable from a pasted add-on URL. IPv4-mapped IPv6 (::ffff:0:0/96) and NAT64
    /// (64:ff9b::/96) both embed a v4 that is unwrapped and tested with the v4 rules.
    var isBlocked: Bool {
        switch kind {
        case .v4(let b):
            return Self.isBlockedV4(b)
        case .v6(let b):
            // ::ffff:a.b.c.d  (IPv4-mapped) -> apply the v4 rules to the embedded v4.
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
                return Self.isBlockedV4(Array(b[12...]))
            }
            // 64:ff9b::a.b.c.d  (NAT64 well-known prefix, RFC 6052) -> a private/loopback v4 embedded here would
            // be translated back to that v4 on a NAT64 path, so unwrap and apply the v4 rules to the embedded v4.
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4...11].allSatisfy({ $0 == 0 }) {
                return Self.isBlockedV4(Array(b[12...]))
            }
            return Self.isBlockedV6(b)
        }
    }

    /// IPv4 blocked ranges: 0.0.0.0/8, 10/8, 100.64/10 (CGNAT), 127/8 (loopback), 169.254/16 (link-local),
    /// 172.16/12, 192.168/16.
    private static func isBlockedV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }   // malformed -> fail closed
        switch b[0] {
        case 0:   return true                                   // 0.0.0.0/8 (this-network / unspecified)
        case 10:  return true                                   // 10.0.0.0/8
        case 127: return true                                   // 127.0.0.0/8 (loopback)
        case 100: return (b[1] & 0xC0) == 0x40                  // 100.64.0.0/10 (CGNAT: 100.64–100.127)
        case 169: return b[1] == 254                            // 169.254.0.0/16 (link-local)
        case 172: return (b[1] & 0xF0) == 0x10                  // 172.16.0.0/12 (172.16–172.31)
        case 192: return b[1] == 168                            // 192.168.0.0/16
        default:  return false
        }
    }

    /// IPv6 blocked ranges: ::1 (loopback), :: (unspecified), fc00::/7 (ULA), fe80::/10 (link-local).
    private static func isBlockedV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }   // malformed -> fail closed
        // ::1 loopback and :: unspecified.
        if b[0...14].allSatisfy({ $0 == 0 }) { return b[15] == 1 || b[15] == 0 }
        if (b[0] & 0xFE) == 0xFC { return true }            // fc00::/7 (unique-local)
        if b[0] == 0xFE, (b[1] & 0xC0) == 0x80 { return true }   // fe80::/10 (link-local)
        return false
    }
}

/// A `URLSession` delegate that DISABLES automatic redirect following, so `AddonURLGuard.fetch` sees each 3xx
/// and re-validates the target host itself. Without this, `URLSession`'s default handling would silently
/// follow a redirect to a private address after we validated only the public entry URL.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // do not auto-follow; the guard's loop re-validates + re-issues manually
    }
}
