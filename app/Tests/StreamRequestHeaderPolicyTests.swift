import Foundation

@main
private struct StreamRequestHeaderPolicyTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("Stream header policy failed: \(message)") }
            checks += 1
        }

        let sentinelAuthorization = "Bearer transport-secret-sentinel"
        let sentinelCookie = "session=cookie-secret-sentinel"
        let sanitized = StreamRequestHeaderPolicy.sanitized([
            "Authorization": sentinelAuthorization,
            "Cookie": sentinelCookie,
            "Referer": "https://addon.example/",
            "User-Agent": "VortX fixture",
            "Range": "bytes=0-1023",
            "Host": "attacker.invalid",
            "Content-Length": "999",
            "Transfer-Encoding": "chunked",
            "Connection": "keep-alive",
            "tE": "trailers",
            "Trailer": "X-Checksum",
            "Keep-Alive": "timeout=5",
            "Proxy-Authorization": "Basic secret",
            "Proxy-Authenticate": "Basic",
            "Upgrade": "websocket",
            "Proxy-Connection": "keep-alive",
            "Bad Name": "invalid",
            "X-Injected": "safe\r\nRange: bytes=0-0"
        ])
        expect(sanitized["Authorization"] == sentinelAuthorization
               && sanitized["Cookie"] == sentinelCookie
               && sanitized["Referer"] != nil && sanitized["User-Agent"] != nil,
               "origin identity headers survive sanitization")
        let blockedNames = Set(["range", "host", "content-length", "transfer-encoding", "connection", "te", "trailer",
                                "keep-alive", "proxy-authorization", "proxy-authenticate", "upgrade", "proxy-connection"])
        expect(sanitized.keys.allSatisfy { !blockedNames.contains($0.lowercased()) },
               "add-on transport and framing headers are stripped")
        expect(sanitized["Bad Name"] == nil && sanitized["X-Injected"] == nil,
               "invalid names and CRLF field values are stripped")
        var playerRequest = sanitized
        playerRequest["Range"] = "bytes=4096-8191"
        expect(playerRequest["Range"] == "bytes=4096-8191",
               "the downstream player can install a fresh dynamic Range")

        expect(StreamRequestHeaderPolicy.isLocalPlaybackURL(URL(string: "http://127.0.0.1:11470/file")!),
               "IPv4 loopback is local")
        expect(StreamRequestHeaderPolicy.isLocalPlaybackURL(URL(string: "http://192.168.1.5/file")!),
               "private embedded routes are local")
        expect(StreamRequestHeaderPolicy.isLocalPlaybackURL(URL(string: "http://[fd12:3456::1]/file")!),
               "IPv6 unique-local routes are local")
        expect(StreamRequestHeaderPolicy.isLocalPlaybackURL(URL(string: "http://[fe80::1]/file")!),
               "IPv6 link-local routes are local")
        expect(!StreamRequestHeaderPolicy.isLocalPlaybackHost("fczz::1"), "malformed IPv6 is remote")
        expect(!StreamRequestHeaderPolicy.isLocalPlaybackHost("127.a.0.0.1"), "malformed IPv4 is remote")
        expect(!StreamRequestHeaderPolicy.isLocalPlaybackURL(URL(string: "https://foo.strem.io/file")!),
               "a strem.io subdomain is remote")
        expect(!StreamRequestHeaderPolicy.isLocalPlaybackURL(URL(string: "https://evilstrem.io/file")!),
               "a lookalike suffix is remote")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let gateway = (try? String(contentsOf: root.appendingPathComponent("SourcesShared/JSProviders/CommunityStreamGateway.swift"), encoding: .utf8)) ?? ""
        let server = (try? String(contentsOf: root.appendingPathComponent("SourcesShared/StremioServer.swift"), encoding: .utf8)) ?? ""
        let mpv = (try? String(contentsOf: root.appendingPathComponent("Sources/Player/MPVMetalViewController.swift"), encoding: .utf8)) ?? ""
        let remux = (try? String(contentsOf: root.appendingPathComponent("Sources/Player/VortXMKVRemuxStream.swift"), encoding: .utf8)) ?? ""
        let avplayer = (try? String(contentsOf: root.appendingPathComponent("Sources/Player/AVPlayerEngine.swift"), encoding: .utf8)) ?? ""
        expect([server, gateway, mpv, remux, avplayer].allSatisfy { $0.contains("StreamRequestHeaderPolicy.sanitized") },
               "every Apple playback transport uses the canonical sanitizer")
        expect(gateway.contains("forwardFollowingRedirects")
               && !gateway.contains("destinationFollowingRedirects")
               && !gateway.contains("private func probe("),
               "the community gateway streams the final origin request without a probe duplicate")
        expect(server.contains("caseInsensitiveCompare(\"authorization\")")
               && server.contains("caseInsensitiveCompare(\"cookie\")"),
               "secret headers are refused from the legacy header-in-URL proxy route")

        print("Stream request header policy: PASS (\(checks) checks)")
    }
}
