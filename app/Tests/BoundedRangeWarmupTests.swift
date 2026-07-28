import Foundation

private final class WarmupRedirectProbeURLProtocol: URLProtocol, @unchecked Sendable {
    struct Snapshot {
        let sourceHits: Int
        let targetHits: Int
        let range: String?
        let cookie: String?
        let authorization: String?
        let proxyAuthorization: String?
        let privateHeader: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sourceHits = 0
    nonisolated(unsafe) private static var targetHits = 0
    nonisolated(unsafe) private static var targetHeaders: [String: String] = [:]

    static func reset() {
        lock.lock()
        sourceHits = 0
        targetHits = 0
        targetHeaders = [:]
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            sourceHits: sourceHits,
            targetHits: targetHits,
            range: targetHeaders["range"],
            cookie: targetHeaders["cookie"],
            authorization: targetHeaders["authorization"],
            proxyAuthorization: targetHeaders["proxy-authorization"],
            privateHeader: targetHeaders["x-addon-private"]
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "warmup-source.test"
            || request.url?.host == "warmup-target.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.host == "warmup-target.test" {
            Self.lock.lock()
            Self.targetHits += 1
            Self.targetHeaders = Dictionary(
                uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map {
                    ($0.key.lowercased(), $0.value)
                }
            )
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "4",
                    "Content-Range": "bytes 0-3/4"
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("warm".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        Self.lock.lock()
        Self.sourceHits += 1
        Self.lock.unlock()
        let target = URL(string: "https://warmup-target.test/media")!
        var redirected = request
        redirected.url = target
        let response = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": "0",
                "Location": target.absoluteString
            ]
        )!
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
private enum BoundedRangeWarmupTests {
    nonisolated(unsafe) private static var passed = 0

    static func main() async {
        testOriginAndRedirectPolicy()
        expect(
            BoundedRangeWarmup.acceptsRangeResponse(
                statusCode: 206,
                contentRange: "bytes 0-16777215/4000000000"
            ),
            "a valid 206 byte-range response is accepted"
        )
        expect(
            !BoundedRangeWarmup.acceptsRangeResponse(
                statusCode: 200,
                contentRange: nil
            ),
            "an origin that ignores Range is rejected before its body is retained"
        )
        expect(
            !BoundedRangeWarmup.acceptsRangeResponse(
                statusCode: 206,
                contentRange: nil
            ),
            "a 206 without Content-Range is rejected"
        )
        expect(
            !BoundedRangeWarmup.acceptsRangeResponse(
                statusCode: 206,
                contentRange: "bytes 1024-2047/4000000000",
                requestedLimit: 16 * 1_024 * 1_024
            ),
            "a shifted response cannot masquerade as the requested prefix"
        )
        expect(
            !BoundedRangeWarmup.acceptsRangeResponse(
                statusCode: 206,
                contentRange: "bytes 0-16777216/4000000000",
                requestedLimit: 16 * 1_024 * 1_024
            ),
            "a Content-Range extending past the requested bound is rejected"
        )
        expect(
            BoundedRangeWarmup.acceptsRangeResponse(
                statusCode: 206,
                contentRange: "bytes 0-1048575/4000000000",
                requestedLimit: 16 * 1_024 * 1_024
            ),
            "a shorter zero-based prefix inside the requested bound is accepted"
        )
        expect(
            !BoundedRangeWarmup.acceptsRangeResponse(
                statusCode: 206,
                contentRange: "bytes nope/4000000000"
            ),
            "a malformed Content-Range is rejected"
        )
        expect(
            BoundedRangeWarmup.acceptedBytes(
                current: 15,
                incoming: 10_000,
                limit: 16
            ) == 1,
            "the final delegate chunk is capped at the exact byte budget"
        )
        expect(
            BoundedRangeWarmup.acceptedBytes(
                current: 16,
                incoming: 10_000,
                limit: 16
            ) == 0,
            "no bytes are accepted after the cap"
        )
        await testEmpiricalCrossOriginRedirect()
        print("BoundedRangeWarmupTests: \(passed)/\(passed) passed")
    }

    private static func testOriginAndRedirectPolicy() {
        expect(
            BoundedRangeWarmup.isSameOrigin(
                URL(string: "https://EXAMPLE.test/start")!,
                URL(string: "https://example.test:443/next")!
            ),
            "HTTPS default port and host case normalize to one exact origin"
        )
        expect(
            BoundedRangeWarmup.isSameOrigin(
                URL(string: "http://example.test:80/start")!,
                URL(string: "http://example.test/next")!
            ),
            "HTTP default port normalizes to one exact origin"
        )
        expect(
            !BoundedRangeWarmup.isSameOrigin(
                URL(string: "https://example.test/start")!,
                URL(string: "http://example.test/next")!
            ),
            "a scheme change is cross-origin"
        )
        expect(
            !BoundedRangeWarmup.isSameOrigin(
                URL(string: "https://example.test/start")!,
                URL(string: "https://example.test:8443/next")!
            ),
            "an effective-port change is cross-origin"
        )
        expect(
            !BoundedRangeWarmup.isSameOrigin(
                URL(string: "https://example.test/start")!,
                URL(string: "https://cdn.example.test/next")!
            ),
            "a host change is cross-origin"
        )

        var source = URLRequest(url: URL(string: "https://example.test/start")!)
        source.setValue("bytes=0-16777215", forHTTPHeaderField: "Range")
        source.setValue("session=private", forHTTPHeaderField: "Cookie")
        source.setValue("Bearer private", forHTTPHeaderField: "Authorization")
        source.setValue("Basic proxy-private", forHTTPHeaderField: "Proxy-Authorization")
        source.setValue("addon-private", forHTTPHeaderField: "X-Addon-Private")

        let sameOriginProposed = URLRequest(
            url: URL(string: "https://example.test:443/next")!
        )
        let sameOrigin = BoundedRangeWarmup.redirectRequest(
            from: source,
            to: sameOriginProposed
        )
        expect(
            sameOrigin?.value(forHTTPHeaderField: "Range") == "bytes=0-16777215"
                && sameOrigin?.value(forHTTPHeaderField: "Cookie") == "session=private"
                && sameOrigin?.value(forHTTPHeaderField: "X-Addon-Private") == "addon-private",
            "same-origin redirect retains headers required by the add-on"
        )

        let crossOriginProposed = URLRequest(
            url: URL(string: "https://cdn.example.test/media")!
        )
        let crossOrigin = BoundedRangeWarmup.redirectRequest(
            from: source,
            to: crossOriginProposed
        )
        expect(
            crossOrigin?.allHTTPHeaderFields == ["Range": "bytes=0-16777215"],
            "cross-origin redirect rebuilds a fresh request with only Range"
        )
        expect(
            crossOrigin?.value(forHTTPHeaderField: "Cookie") == nil
                && crossOrigin?.value(forHTTPHeaderField: "Authorization") == nil
                && crossOrigin?.value(forHTTPHeaderField: "Proxy-Authorization") == nil
                && crossOrigin?.value(forHTTPHeaderField: "X-Addon-Private") == nil
                && crossOrigin?.httpShouldHandleCookies == false,
            "cross-origin redirect strips private, cookie and authorization-like state"
        )
    }

    private static func testEmpiricalCrossOriginRedirect() async {
        WarmupRedirectProbeURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WarmupRedirectProbeURLProtocol.self]
        var request = URLRequest(
            url: URL(string: "https://warmup-source.test/start")!
        )
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        request.setValue("session=private", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer private", forHTTPHeaderField: "Authorization")
        request.setValue("Basic proxy-private", forHTTPHeaderField: "Proxy-Authorization")
        request.setValue("addon-private", forHTTPHeaderField: "X-Addon-Private")

        let result = try? await BoundedRangeWarmup.fetch(
            request,
            limit: 4,
            configuration: configuration
        )
        let snapshot = WarmupRedirectProbeURLProtocol.snapshot()
        expect(
            result == .init(statusCode: 206, byteCount: 4)
                && snapshot.sourceHits == 1
                && snapshot.targetHits == 1,
            "real URLSession redirect reaches the sanitized cross-origin range target"
        )
        expect(
            snapshot.range == "bytes=0-3"
                && snapshot.cookie == nil
                && snapshot.authorization == nil
                && snapshot.proxyAuthorization == nil
                && snapshot.privateHeader == nil,
            "real redirected target observes Range and no private add-on headers"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else { fatalError("\(file):\(line): \(message)") }
        passed += 1
    }
}
