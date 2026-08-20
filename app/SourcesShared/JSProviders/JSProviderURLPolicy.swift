import Foundation
import Darwin

/// The outbound-request policy for community JS providers, enforced NATIVELY inside `JSProviderRuntime`'s
/// fetch primitive so a provider cannot reach it or turn it off from JS.
///
/// Untrusted provider code makes network requests on the user's device. This policy keeps those requests to
/// http(s) only and blocks anything that could reach the user's own machine or local network: loopback, the
/// embedded streaming server, link-local, and RFC1918 / CGNAT private ranges. It mirrors the community host's
/// `URL_VALIDATION_ENABLED` toggle (surfaced to the provider as that global) but the ACTUAL decision is made
/// here, not in the sandbox.
struct JSProviderURLPolicy: Sendable {

    /// Surfaced to provider code as `URL_VALIDATION_ENABLED`. The native `isAllowed` gate runs regardless; this
    /// only tells a provider whether the host claims to be validating (community-contract compatibility).
    let validationEnabled: Bool

    /// Extra hostnames to block outright (lowercased), on top of the built-in loopback/private-range rules.
    let deniedHosts: Set<String>

    init(validationEnabled: Bool = true, deniedHosts: Set<String> = []) {
        self.validationEnabled = validationEnabled
        self.deniedHosts = Set(deniedHosts.map { $0.lowercased() })
    }

    static let `default` = JSProviderURLPolicy()

    /// The desktop-browser User-Agent forced by default when a provider does not set its own, so hotlink/bot
    /// checks that reject a non-browser UA pass. Providers routinely override this per request.
    static let defaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

    func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if deniedHosts.contains(host) { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        let normalizedIPv6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // IPv6 loopback, unspecified, unique-local, and link-local literals.
        if normalizedIPv6 == "::" || normalizedIPv6 == "::1" || normalizedIPv6.hasPrefix("fc") ||
            normalizedIPv6.hasPrefix("fd") || ["fe8", "fe9", "fea", "feb"].contains(where: { normalizedIPv6.hasPrefix($0) }) { return false }
        if Self.isBlockedIPv4(host) { return false }
        return true
    }

    /// DNS names are validated as well as literal IP addresses. Every resolved address must be public; an
    /// unresolvable name is refused rather than falling through to URLSession and accidentally reaching a
    /// local resolver result. Redirects are separately refused by the runtime.
    func isAllowedResolved(_ url: URL) async -> Bool {
        guard isAllowed(url), let host = url.host else { return false }
        return await Task.detached(priority: .utility) {
            Self.vettedNumericAddresses(for: host) != nil
        }.value
    }

    /// Resolves a name once and returns the exact numeric peers a caller may dial. A single private, special,
    /// or malformed answer rejects the complete result, which prevents an attacker from racing a safe answer
    /// against a private one. Callers must dial one of these numeric addresses directly rather than resolving
    /// the hostname again.
    static func vettedNumericAddresses(for host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }

        var address: UnsafeMutablePointer<addrinfo>? = result
        var addresses = Set<String>()
        while let current = address {
            let info = current.pointee
            address = info.ai_next
            var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.ai_addr, info.ai_addrlen, &numeric, socklen_t(numeric.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            let value = String(cString: numeric)
            guard isPublicNumericAddress(value) else { return nil }
            addresses.insert(value)
        }
        return addresses.isEmpty ? nil : addresses.sorted()
    }

    /// Returns true only for a syntactically numeric, globally routable address. This deliberately treats
    /// documentation, multicast, carrier, loopback, private, link-local, and IPv4-mapped private ranges as
    /// unsafe. Names are not accepted here: they must first pass `vettedNumericAddresses(for:)`.
    static func isPublicNumericAddress(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isNumericIPv4(normalized) { return !isBlockedIPv4(normalized) }
        var storage = in6_addr()
        guard inet_pton(AF_INET6, normalized, &storage) == 1 else { return false }
        if normalized.hasPrefix("::ffff:") {
            return isPublicNumericAddress(String(normalized.dropFirst(7)))
        }
        if normalized == "::" || normalized == "::1" { return false }
        if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") { return false }
        if ["fe8", "fe9", "fea", "feb"].contains(where: { normalized.hasPrefix($0) }) { return false }
        if normalized.hasPrefix("ff") || normalized.hasPrefix("2001:db8") { return false }
        return true
    }

    /// Block loopback (127/8), link-local (169.254/16), and the private RFC1918 + CGNAT ranges when the host is
    /// a literal IPv4 address. Hostnames are also checked by `isAllowedResolved(_:)` before URLSession starts.
    private static func isNumericIPv4(_ host: String) -> Bool {
        var storage = in_addr()
        return inet_pton(AF_INET, host, &storage) == 1
    }

    private static func isBlockedIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return false }
        let a = octets[0], b = octets[1]
        if a == 127 { return true }                    // loopback
        if a == 10 { return true }                     // 10.0.0.0/8
        if a == 169 && b == 254 { return true }        // link-local 169.254.0.0/16
        if a == 172 && (16...31).contains(b) { return true }  // 172.16.0.0/12
        if a == 192 && b == 168 { return true }        // 192.168.0.0/16
        if a == 100 && (64...127).contains(b) { return true } // CGNAT 100.64.0.0/10
        if a == 0 { return true }                      // 0.0.0.0/8
        if a >= 224 { return true }                    // multicast and reserved
        if a == 192 && (b == 0 || b == 88 || b == 168) { return true }
        if a == 198 && (18...19).contains(b) { return true } // benchmark network
        if (a == 192 && b == 0 && octets[2] == 2) ||
            (a == 198 && b == 51 && octets[2] == 100) ||
            (a == 203 && b == 0 && octets[2] == 113) { return true } // documentation ranges
        return false
    }
}
