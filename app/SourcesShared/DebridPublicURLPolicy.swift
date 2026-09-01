import Foundation
import Darwin

/// Trust boundary for provider-minted debrid playback links and provider HTTP redirects.
///
/// A provider response is untrusted input even after it has passed that provider's JSON schema.  A direct
/// playback link must name a public HTTP(S) origin, and a redirect must meet the same rule before URLSession
/// follows it.  Requiring every DNS answer to be public deliberately fails closed on split-horizon and
/// rebinding answers: a single private destination is enough to reject the host.
enum DebridPublicURLPolicy {
    typealias AddressResolver = (String) -> [String]

    /// Returns `true` only for an absolute HTTP(S) URL without userinfo whose literal or resolved addresses
    /// are all public-unicast.  The injectable resolver keeps the classification testable without network I/O.
    static func permits(_ url: URL, resolvingAddresses: AddressResolver = resolvedAddresses) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            return false
        }

        if isPublicAddress(host) { return true }

        let addresses = resolvingAddresses(host)
        return !addresses.isEmpty && addresses.allSatisfy(isPublicAddress)
    }

    /// Converts a provider's raw download field into an opaque local playback URL. The media engines never see
    /// the remote host: the loopback gateway resolves and pins every media request and redirect at dial time.
    static func playbackURL(from raw: String, failure: Error) async throws -> URL {
        guard let url = URL(string: raw), permits(url) else { throw failure }
        do { return try await CommunityStreamGateway.shared.registerNativeDebrid(upstream: url) }
        catch { throw failure }
    }

    /// Used by the URLSession redirect delegate. Returning nil cancels the redirect before URLSession sends it.
    static func permittedRedirectRequest(_ request: URLRequest,
                                         resolvingAddresses: AddressResolver = resolvedAddresses) -> URLRequest? {
        guard let url = request.url, permits(url, resolvingAddresses: resolvingAddresses) else { return nil }
        return request
    }

    private static func isPublicAddress(_ raw: String) -> Bool {
        let address = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let ipv4 = ipv4Octets(address) { return isPublicIPv4(ipv4) }
        if let ipv6 = ipv6Bytes(address) { return isPublicIPv6(ipv6) }
        return false
    }

    private static func ipv4Octets(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }),
                  let number = UInt8(part) else { return nil }
            result.append(number)
        }
        return result
    }

    private static func ipv6Bytes(_ value: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, value, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isPublicIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        let a = octets[0]
        let b = octets[1]

        switch a {
        case 0, 10, 127, 224...255:
            return false // unspecified, RFC1918, loopback, multicast/reserved
        case 100 where (64...127).contains(b):
            return false // carrier-grade NAT, not public Internet space
        case 169 where b == 254:
            return false // link-local
        case 172 where (16...31).contains(b):
            return false // RFC1918
        case 192 where b == 168 || b == 0 || b == 2:
            return false // RFC1918, IETF protocol assignments, documentation
        case 198 where b == 18 || b == 19 || b == 51:
            return false // benchmarking and documentation
        case 203 where b == 0 && octets[2] == 113:
            return false // documentation
        default:
            return true
        }
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) ||
            bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 {
            return false // :: and ::1
        }
        if bytes[0] == 0xff || (bytes[0] & 0xfe) == 0xfc ||
            (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
            return false // multicast, unique-local, link-local
        }
        // IPv4-mapped and IPv4-compatible addresses inherit the IPv4 policy.
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isPublicIPv4(Array(bytes.suffix(4)))
        }
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) {
            return isPublicIPv4(Array(bytes.suffix(4)))
        }
        return true
    }

    private static func resolvedAddresses(for host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: 0,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let first else { return [] }
        defer { freeaddrinfo(first) }

        var values: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            let info = current.pointee
            guard let socketAddress = info.ai_addr else { node = info.ai_next; continue }
            var numericHost = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(socketAddress, info.ai_addrlen, &numericHost, socklen_t(numericHost.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                values.append(String(cString: numericHost))
            }
            node = info.ai_next
        }
        return Array(Set(values))
    }
}

/// URLSession retains this delegate for provider API requests. Media redirects are separately enforced at the
/// loopback gateway because AVPlayer and libmpv otherwise own their transport independently.
final class DebridRedirectPolicyDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(DebridPublicURLPolicy.permittedRedirectRequest(request))
    }
}

enum DebridHTTPSession {
    static func make(timeout: TimeInterval = 20) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration, delegate: DebridRedirectPolicyDelegate(), delegateQueue: nil)
    }
}
