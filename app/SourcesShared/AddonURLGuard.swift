import Foundation

/// Bounded client transport for add-ons and public catalog/artwork resources.
/// Installing an add-on selects its endpoint: LAN, loopback and Tailscale hosts are legitimate destinations.
/// Only that selected origin may resolve privately; a redirect to a different private origin is not part of
/// that choice. Public catalog/artwork URLs retain the strict public-address policy. Link-local and
/// unspecified destinations stay blocked even for an add-on. TLS verification is never disabled.
///
/// RESIDUAL RISK (accepted, resolve-then-connect): `validate` resolves the host and `fetch` then issues a
/// SEPARATE `URLSession` request that re-resolves DNS independently, so the connected IP is not pinned to the
/// validated one. A hostile authoritative DNS with a ~0 TTL can answer a PUBLIC address to `validate` and a
/// PRIVATE one to the actual connection (classic DNS rebinding), bypassing the private-address block. This is
/// not fully closable here: `URLSession` on Apple platforms exposes no connection-time IP pinning. The blast
/// radius is bounded (the "server" is the user's own device, the target is only the LAN / on-device loopback,
/// and responses are bounded before JSON or local static-image decoding), so this stays a known,
/// accepted limitation rather than an implied guarantee.
enum AddonURLGuard {
    enum AccessScope: Sendable {
        case publicNetwork
        case addon(origin: URL)

        func allowsPrivateAddress(for url: URL) -> Bool {
            guard case .addon(let origin) = self else { return false }
            func port(_ value: URL) -> Int? {
                value.port ?? (value.scheme?.lowercased() == "https" ? 443 : 80)
            }
            return url.scheme?.lowercased() == origin.scheme?.lowercased()
                && url.host?.lowercased() == origin.host?.lowercased()
                && port(url) == port(origin)
        }
    }
    /// Why a manifest URL was refused. `message` is the user-facing string the install/preview surfaces.
    enum Rejection: Error {
        case invalidScheme
        case privateAddress
        case unresolvable
        case tooManyRedirects

        var message: String {
            switch self {
            case .invalidScheme:
                return "Enter a valid add-on URL (http:// or https://…/manifest.json)."
            case .privateAddress:
                return "That URL uses an unsupported network address or redirects to a different private server."
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
    /// Hard upper bound for a manifest response. The check is applied to Content-Length when present and again
    /// while consuming the streamed body, so chunked/lying responses cannot grow an unbounded Data buffer.
    static let maxManifestBytes = 2 * 1024 * 1024

    /// Callers select a known response purpose; a supplied URL cannot choose an arbitrary body cap.
    enum ResponseContext: Sendable {
        case manifest
        case xperienceCatalog
        case xperienceArtwork

        var maximumBytes: Int {
            switch self {
            case .manifest: return AddonURLGuard.maxManifestBytes
            case .xperienceCatalog: return 4 * 1024 * 1024
            case .xperienceArtwork: return 8 * 1024 * 1024
            }
        }

        fileprivate var accept: String {
            switch self {
            case .manifest, .xperienceCatalog: return "application/json"
            case .xperienceArtwork: return "image/png,image/jpeg,image/webp,image/heic,image/heif"
            }
        }
    }

    struct Response: Sendable {
        let data: Data
        let finalURL: URL
        let mimeType: String?
    }

    /// Return whether appending a streamed chunk remains inside this purpose's cap without overflow.
    static func canAcceptBody(currentBytes: Int, incomingBytes: Int,
                              context: ResponseContext = .manifest) -> Bool {
        let maximum = context.maximumBytes
        guard currentBytes >= 0, incomingBytes >= 0, currentBytes <= maximum else { return false }
        return incomingBytes <= maximum - currentBytes
    }

    /// Resolve one redirect Location against the current URL. The caller must run the result through
    /// `validate` before issuing the next request; this helper deliberately does not trust the target.
    static func redirectTarget(from current: URL, location: String) -> URL? {
        guard !location.isEmpty else { return nil }
        return URL(string: location, relativeTo: current)?.absoluteURL
    }

    // MARK: - Public validation

    /// Require HTTP(S) and validate literal/resolved destinations. Public resources reject private ranges;
    /// a selected add-on can use ordinary private addresses only at its selected origin.
    static func validate(_ url: URL, access: AccessScope = .publicNetwork) async -> Rejection? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else { return .invalidScheme }

        // Literal hosts are checked directly without DNS, including private and mapped addresses.
        let bareHost = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())   // IPv6 literals arrive bracketed from URL.host
            : host
        if let literal = IPAddress(parsing: bareHost) {
            if literal.isBlocked && !(access.allowsPrivateAddress(for: url) && literal.isSelfHostedAddress) {
                return .privateAddress
            }
            // WHY (viewer regression after b215): Comet/StreamFusion manifests commonly live on plain
            // http:// or redirect through it; the HTTPS-only rule from 0d6f360e locked them out while
            // well-hosted addons kept working. Public hosts may use http again - every private-address
            // check below still applies to BOTH schemes, so the SSRF posture is unchanged.
            guard scheme == "http" || scheme == "https",
                  Data(url.absoluteString.utf8).count <= AddonPairingProtocol.maxManifestURLBytes else {
                return .invalidScheme
            }
            return nil
        }

        guard scheme == "http" || scheme == "https",
              Data(url.absoluteString.utf8).count <= AddonPairingProtocol.maxManifestURLBytes else {
            return .invalidScheme
        }

        // Otherwise resolve the hostname and check EVERY address it maps to. Any blocked address fails closed.
        let resolved = resolve(host: bareHost)
        guard !resolved.isEmpty else { return .unresolvable }
        if resolved.contains(where: {
            $0.isBlocked && !(access.allowsPrivateAddress(for: url) && $0.isSelfHostedAddress)
        }) { return .privateAddress }
        return nil
    }

    /// Compatibility surface for existing install/preview callers. Catalog and artwork callers use
    /// the throwing overload so cancellation remains distinct from an unreachable provider.
    static func fetch(_ url: URL) async -> Result<(data: Data, finalURL: URL), Rejection> {
        do {
            let response = try await fetch(url, context: .manifest, access: .addon(origin: url))
            return .success((response.data, response.finalURL))
        } catch let rejection as Rejection {
            return .failure(rejection)
        } catch {
            return .failure(.unresolvable)
        }
    }

    /// Shared transport with manual redirects, DNS checks, bounded bytes and cancellation.
    /// Resource purpose never grants private access; only the selected add-on origin does.
    static func fetch(_ url: URL, context: ResponseContext,
                      access: AccessScope = .publicNetwork,
                      timeout: TimeInterval = 15) async throws -> Response {
        let deadline = Date().addingTimeInterval(timeout)
        var current = url
        for _ in 0...maxRedirects {
            try Task.checkCancellation()
            let validationFailure = await validate(current, access: access)
            try Task.checkCancellation()
            if let validationFailure { throw validationFailure }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Rejection.unresolvable }

            var request = URLRequest(url: current)
            request.timeoutInterval = remaining
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            request.setValue(context.accept, forHTTPHeaderField: "Accept")
            // Keep the browser-compatible health-probe UA: some add-on CDNs refuse URLSession's default.
            request.setValue("Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/604.1",
                             forHTTPHeaderField: "User-Agent")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForResource = remaining
            let delegate = NoRedirectDelegate()
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            do {
                let (byteStream, response) = try await session.bytes(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw Rejection.unresolvable }
                if (300...399).contains(http.statusCode),
                   let location = http.value(forHTTPHeaderField: "Location"),
                   let next = redirectTarget(from: current, location: location) {
                    current = next
                    continue
                }
                guard (200...299).contains(http.statusCode),
                      http.expectedContentLength <= Int64(context.maximumBytes) else {
                    throw Rejection.unresolvable
                }
                var data = Data()
                data.reserveCapacity(min(context.maximumBytes, 64 * 1024))
                for try await byte in byteStream {
                    if (data.count & 4095) == 0 {
                        try Task.checkCancellation()
                        guard deadline.timeIntervalSinceNow > 0 else { throw Rejection.unresolvable }
                    }
                    guard canAcceptBody(currentBytes: data.count, incomingBytes: 1, context: context) else {
                        throw Rejection.unresolvable
                    }
                    data.append(byte)
                }
                try Task.checkCancellation()
                // This is a second resolution check, not connection IP pinning. The accepted
                // resolve-then-connect rebinding limitation above still applies.
                let finalURL = http.url ?? current
                if let rejection = await validate(finalURL, access: access) { throw rejection }
                try Task.checkCancellation()
                return Response(data: data, finalURL: finalURL, mimeType: http.mimeType)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw (error as? Rejection) ?? .unresolvable
            }
        }
        throw Rejection.tooManyRedirects
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

/// Address classification shared by the strict public policy and the selected self-hosted endpoint policy.
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

    /// Local services and tailnets are usable add-on endpoints, not an invitation to metadata/link-local URLs.
    var isSelfHostedAddress: Bool {
        switch kind {
        case .v4(let b):
            return Self.isSelfHostedV4(b)
        case .v6(let b):
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
                return Self.isSelfHostedV4(Array(b[12...]))
            }
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b,
               b[4...11].allSatisfy({ $0 == 0 }) {
                return Self.isSelfHostedV4(Array(b[12...]))
            }
            return (b[0] & 0xFE) == 0xFC
                ? b != [0xfd, 0x00, 0x0e, 0xc2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x54]
                : (b[0...14].allSatisfy({ $0 == 0 }) && b[15] == 1)
        }
    }

    private static func isSelfHostedV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        if b == [100, 100, 100, 200] { return false } // Cloud instance metadata, not an add-on endpoint.
        return b[0] == 10 || b[0] == 127
            || (b[0] == 100 && (b[1] & 0xC0) == 0x40)
            || (b[0] == 172 && (b[1] & 0xF0) == 0x10)
            || (b[0] == 192 && b[1] == 168)
    }

    /// True when this address is loopback / private / link-local / CGNAT / ULA / unspecified, anything that
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
        case 100: return (b[1] & 0xC0) == 0x40                  // 100.64.0.0/10 (CGNAT: 100.64-100.127)
        case 169: return b[1] == 254                            // 169.254.0.0/16 (link-local)
        case 172: return (b[1] & 0xF0) == 0x10                  // 172.16.0.0/12 (172.16-172.31)
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
