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
            Self.hostResolvesOnlyPublic(host)
        }.value
    }

    private static func hostResolvesOnlyPublic(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return false }
        defer { freeaddrinfo(result) }

        var address: UnsafeMutablePointer<addrinfo>? = result
        var resolvedAny = false
        while let current = address {
            let info = current.pointee
            address = info.ai_next
            var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.ai_addr, info.ai_addrlen, &numeric, socklen_t(numeric.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return false }
            resolvedAny = true
            let value = String(cString: numeric)
            if isBlockedNumericHost(value) { return false }
        }
        return resolvedAny
    }

    private static func isBlockedNumericHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isBlockedIPv4(normalized) { return true }
        if normalized.hasPrefix("::ffff:"), isBlockedIPv4(String(normalized.dropFirst(7))) { return true }
        if normalized == "::" || normalized == "::1" { return true }
        if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") { return true } // IPv6 unique-local
        if ["fe8", "fe9", "fea", "feb"].contains(where: { normalized.hasPrefix($0) }) { return true } // link-local
        return false
    }

    /// Block loopback (127/8), link-local (169.254/16), and the private RFC1918 + CGNAT ranges when the host is
    /// a literal IPv4 address. Hostnames are also checked by `isAllowedResolved(_:)` before URLSession starts.
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
        return false
    }
}
