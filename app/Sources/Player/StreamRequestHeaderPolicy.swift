import Foundation
import Darwin

/// The trust boundary for request headers supplied by stream add-ons.
///
/// Add-ons may supply origin identity headers, but transport state belongs to the client that is actually
/// moving bytes. In particular, forwarding a fixed add-on `Range` prevents AVFoundation, FFmpeg, and mpv from
/// issuing their own seek/read ranges and can permanently starve playback after the first byte window.
enum StreamRequestHeaderPolicy {
    private static let transportHeaders: Set<String> = [
        "connection", "content-length", "host", "keep-alive", "proxy-authenticate",
        "proxy-authorization", "proxy-connection", "range", "te", "trailer",
        "transfer-encoding", "upgrade"
    ]

    static func sanitized(_ input: [String: String]?) -> [String: String] {
        guard let input else { return [:] }
        return input.reduce(into: [:]) { output, entry in
            let normalized = entry.key.lowercased()
            guard isHTTPToken(entry.key),
                  !transportHeaders.contains(normalized),
                  isValidFieldValue(entry.value) else { return }
            output[entry.key] = entry.value
        }
    }

    static func isLocalPlaybackURL(_ url: URL) -> Bool {
        guard let rawHost = url.host else { return false }
        return isLocalPlaybackHost(rawHost)
    }

    static func isLocalPlaybackHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let octets = withUnsafeBytes(of: &ipv4) { Array($0) }
            if octets[0] == 127 || octets[0] == 10 { return true }
            if octets[0] == 172, (16...31).contains(octets[1]) { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 169, octets[1] == 254 { return true }
            return false
        }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let octets = withUnsafeBytes(of: &ipv6) { Array($0) }
            if octets.dropLast().allSatisfy({ $0 == 0 }), octets.last == 1 { return true }
            if octets[0] & 0xfe == 0xfc { return true }
            if octets[0] == 0xfe, octets[1] & 0xc0 == 0x80 { return true }
        }
        return false
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 33 || (35...39).contains(scalar.value) || (42...43).contains(scalar.value)
                || (45...46).contains(scalar.value) || (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value) || (94...122).contains(scalar.value)
                || scalar.value == 124 || scalar.value == 126
        }
    }

    private static func isValidFieldValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 9 || (32...126).contains(scalar.value)
        }
    }
}
