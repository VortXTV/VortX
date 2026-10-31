import Foundation
import Darwin

/// Cast receiver and resolved-torrent policy, also applied to each Cast preflight redirect. Those lanes
/// require explicit selected-server authority for LAN origins. The separate ordinary external-player
/// helper preserves chosen NAS/LAN add-on compatibility without granting Cast or torrent authority.
enum ReceiverURLPolicy {
    enum HostScope: Equatable { case publicHost, lan, forbidden }

    /// An installed external player can reach an ordinary NAS/LAN/Tailscale URL selected by the user.
    /// It does not need to match the separate torrent streaming-server preference. Preserve the legacy
    /// HTTP(S) URL channel, including URL userinfo/fragment, while keeping forbidden endpoints closed.
    /// Cast never uses this broader lane: its own permits/preflight still rejects userinfo and requires
    /// explicit server authority for private addresses.
    static func permitsExternalHandoff(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return false }
        return scope(host) != .forbidden
    }

    static func permits(_ url: URL, selectedServer: URL? = nil) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host, url.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        switch scope(host) {
        case .forbidden: return false
        case .publicHost: return true
        case .lan: return selectedServer.map { sameOrigin(url, $0) } ?? false
        }
    }

    static func permitsTorrent(_ url: URL, selectedServer: URL?) -> Bool {
        guard let selectedServer, permits(url, selectedServer: selectedServer),
              sameOrigin(url, selectedServer) else { return false }
        let basePath = selectedServer.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = basePath.isEmpty ? "/" : "/\(basePath)/"
        guard url.path.hasPrefix(prefix) else { return false }
        let tail = String(url.path.dropFirst(prefix.count))
        return tail.range(of: "^[a-fA-F0-9]{40}/[0-9]+$", options: .regularExpression) != nil
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && normalizedHost(lhs.host ?? "") == normalizedHost(rhs.host ?? "")
            && (lhs.port ?? (lhs.scheme?.lowercased() == "https" ? 443 : 80))
                == (rhs.port ?? (rhs.scheme?.lowercased() == "https" ? 443 : 80))
    }

    static func normalizedHost(_ raw: String) -> String {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    static func scope(_ raw: String) -> HostScope {
        let host = normalizedHost(raw)
        guard !host.isEmpty, !host.contains("%"),
              host != "localhost", !host.hasSuffix(".localhost"),
              host != "metadata.google.internal", !host.hasSuffix(".metadata.google.internal"),
              host != "instance-data.ec2.internal" else { return .forbidden }
        if host.contains(":") {
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return .forbidden }
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return ipv4Scope(Array(bytes.suffix(4)))
            }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return .forbidden }
            if bytes[0] == 255 || (bytes[0] == 254 && bytes[1] & 0xc0 == 0x80) { return .forbidden }
            let metadataPrefix = Array(bytes.prefix(4))
            if [ [UInt8(0xfd), 0, 0x0e, 0xc2], [UInt8(0xfd), 0x20, 0, 0xce] ].contains(metadataPrefix),
               bytes[4..<14].allSatisfy({ $0 == 0 }), bytes[14] == 2, bytes[15] == 0x54 { return .forbidden }
            if bytes[0] & 0xfe == 0xfc { return .lan }
            // IPv4-compatible and translation forms can hide a special IPv4 endpoint. They are unnecessary
            // for a user-selected LAN server; reject instead of weakening the address-class guard.
            if bytes.prefix(12).allSatisfy({ $0 == 0 }) || (bytes[0] == 0 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b) { return .forbidden }
            return .publicHost
        }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        if components.count == 4, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            guard components.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }),
                  components.allSatisfy({ UInt8($0) != nil }) else { return .forbidden }
            return ipv4Scope(components.compactMap { UInt8($0) })
        }
        // Reject legacy inet_aton spellings (127.1, integer and octal/hex forms).
        if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.hasPrefix("0x") { return .forbidden }
        if !host.contains(".") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return .lan }
        return .publicHost
    }

    static func ipv4Scope(_ bytes: [UInt8]) -> HostScope {
        guard bytes.count == 4 else { return .forbidden }
        let a = bytes[0], b = bytes[1]
        if bytes == [168, 63, 129, 16] || bytes == [100, 100, 100, 200] { return .forbidden }
        if a == 0 || a == 127 || a >= 224 || (a == 169 && b == 254) { return .forbidden }
        if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 100 && (64...127).contains(b)) { return .lan }
        // CGNAT includes explicitly selected Tailscale servers; it is LAN scope, not blanket forbidden.
        // Benchmarking addresses remain ineligible as media origins.
        if a == 198 && (18...19).contains(b) { return .forbidden }
        return .publicHost
    }
}
