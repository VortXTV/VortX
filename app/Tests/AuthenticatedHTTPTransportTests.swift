// Standalone hostile contracts for the shared bearer-token HTTP transport.
//
// Run with:
//   swiftc -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/AuthenticatedHTTPTransport.swift \
//     app/Tests/AuthenticatedHTTPTransportTests.swift \
//     -o /tmp/authenticated-http-transport && /tmp/authenticated-http-transport

import Foundation

private final class AuthenticatedTransportProbe: URLProtocol, @unchecked Sendable {
    struct RequestSnapshot: Sendable {
        let url: URL?
        let cachePolicy: URLRequest.CachePolicy
        let handlesCookies: Bool
        let cookieHeader: String?
        let authorizationHeader: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [RequestSnapshot] = []
    nonisolated(unsafe) private static var targetHits = 0
    nonisolated(unsafe) private static var stopCounts: [String: Int] = [:]

    static func reset() {
        lock.lock()
        requests = []
        targetHits = 0
        stopCounts = [:]
        lock.unlock()
    }

    static func snapshot() -> (requests: [RequestSnapshot], targetHits: Int, stopCounts: [String: Int]) {
        lock.lock()
        defer { lock.unlock() }
        return (requests, targetHits, stopCounts)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "allowed.test" || host == "redirect-target.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.requests.append(RequestSnapshot(
            url: url,
            cachePolicy: request.cachePolicy,
            handlesCookies: request.httpShouldHandleCookies,
            cookieHeader: request.value(forHTTPHeaderField: "Cookie"),
            authorizationHeader: request.value(forHTTPHeaderField: "Authorization")
        ))
        if url.host == "redirect-target.test" { Self.targetHits += 1 }
        Self.lock.unlock()

        if url.host == "redirect-target.test" {
            respond(status: 200, headers: ["Content-Length": "2"], chunks: [Data("{}".utf8)])
            return
        }

        switch url.path {
        case "/redirect":
            let target = URL(string: "https://redirect-target.test/collect")!
            var redirected = request
            redirected.url = target
            let response = HTTPURLResponse(
                url: url,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString, "Content-Length": "0"]
            )!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case "/response-host":
            let responseURL = URL(string: "https://attacker.test/injected")!
            respond(
                status: 200,
                responseURL: responseURL,
                headers: ["Content-Length": "2"],
                chunks: [Data("{}".utf8)]
            )
        case "/declared-too-large":
            respond(status: 200, headers: ["Content-Length": "65"], chunks: [])
        case "/malformed-length":
            respond(status: 200, headers: ["Content-Length": "1x"], chunks: [Data([0x7B])])
        case "/missing-too-large":
            respond(status: 200, headers: [:], chunks: [Data(repeating: 0x61, count: 64), Data([0x62])])
        case "/understated":
            respond(
                status: 200,
                headers: ["Content-Length": "1"],
                chunks: [Data(repeating: 0x61, count: 64), Data([0x62])]
            )
        case "/exact-cap":
            respond(
                status: 200,
                headers: ["Content-Length": "64"],
                chunks: [Data(repeating: 0x61, count: 32), Data(repeating: 0x62, count: 32)]
            )
        case "/invalid-utf8":
            respond(status: 200, headers: ["Content-Length": "1"], chunks: [Data([0xFF])])
        case "/transport-marker":
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "secret-body-marker bearer-token-marker",
                    code: 91,
                    userInfo: [NSLocalizedDescriptionKey: "secret-body-marker bearer-token-marker"]
                )
            )
        case "/slow":
            break
        default:
            respond(status: 200, headers: ["Content-Length": "2"], chunks: [Data("{}".utf8)])
        }
    }

    override func stopLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.stopCounts[path, default: 0] += 1
        Self.lock.unlock()
    }

    private func respond(
        status: Int,
        responseURL: URL? = nil,
        headers: [String: String],
        chunks: [Data]
    ) {
        let response = HTTPURLResponse(
            url: responseURL ?? request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
private struct AuthenticatedHTTPTransportTests {
    @MainActor private static var failures = 0
    @MainActor private static var checks = 0

    @MainActor
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if condition() {
            print("PASS  \(message)")
        } else {
            failures += 1
            print("FAIL  \(message)")
        }
    }

    private static func request(_ path: String, host: String = "allowed.test") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.cachePolicy = .returnCacheDataDontLoad
        request.httpShouldHandleCookies = true
        request.setValue("session=private-cookie", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer private-token-marker", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func receives(
        _ transport: AuthenticatedHTTPTransport,
        path: String,
        cap: Int = 64,
        allowedHosts: Set<String> = ["allowed.test"]
    ) async -> Result<AuthenticatedHTTPResponse, Error> {
        do {
            return .success(try await transport.send(
                request(path),
                allowedHosts: allowedHosts,
                maxResponseBytes: cap
            ))
        } catch {
            return .failure(error)
        }
    }

    @MainActor
    static func main() async {
        AuthenticatedTransportProbe.reset()
        let transport = AuthenticatedHTTPTransport(
            protocolClasses: [AuthenticatedTransportProbe.self]
        )

        let beforeHostile = AuthenticatedTransportProbe.snapshot().requests.count
        let wrongHost = await receives(
            transport,
            path: "/ok",
            allowedHosts: ["api.trakt.tv"]
        )
        expect(failure(wrongHost) == .invalidEndpoint,
               "an exact host allowlist rejects a different HTTPS host before sending")
        expect(AuthenticatedTransportProbe.snapshot().requests.count == beforeHostile,
               "preflight host rejection emits no network request")

        do {
            _ = try await transport.send(
                request("/ok", host: "allowed.test").withURLScheme("http"),
                allowedHosts: ["allowed.test"],
                maxResponseBytes: 64
            )
            expect(false, "plain HTTP is rejected before sending")
        } catch let error as AuthenticatedHTTPTransportError {
            expect(error == .invalidEndpoint, "plain HTTP is rejected before sending")
        } catch {
            expect(false, "plain HTTP uses a static transport error")
        }

        let responseHost = await receives(transport, path: "/response-host")
        expect(failure(responseHost) == .invalidEndpoint,
               "the response URL is revalidated against the exact HTTPS host allowlist")

        let redirect = await receives(transport, path: "/redirect")
        let redirectSnapshot = AuthenticatedTransportProbe.snapshot()
        expect(failure(redirect) == .redirectRejected,
               "a real URLSession redirect callback is rejected")
        expect(redirectSnapshot.targetHits == 0,
               "redirect refusal never sends the bearer request to the target")

        let declared = await receives(transport, path: "/declared-too-large")
        expect(failure(declared) == .responseTooLarge,
               "an oversized declared Content-Length is rejected before body buffering")

        let malformed = await receives(transport, path: "/malformed-length")
        expect(failure(malformed) == .invalidContentLength,
               "a malformed Content-Length is rejected rather than treated as absent")

        let missing = await receives(transport, path: "/missing-too-large")
        expect(failure(missing) == .responseTooLarge,
               "a missing Content-Length cannot bypass streamed cap-plus-one cancellation")

        let understated = await receives(transport, path: "/understated")
        expect(failure(understated) == .responseTooLarge,
               "an understated Content-Length cannot bypass streamed cap-plus-one cancellation")

        let exact = await receives(transport, path: "/exact-cap")
        switch exact {
        case .success(let response):
            expect(response.statusCode == 200 && response.data.count == 64,
                   "an exact-cap streamed response succeeds without truncation")
        case .failure:
            expect(false, "an exact-cap streamed response succeeds without truncation")
        }

        let stopSnapshot = AuthenticatedTransportProbe.snapshot().stopCounts
        expect((stopSnapshot["/missing-too-large"] ?? 0) >= 1
                && (stopSnapshot["/understated"] ?? 0) >= 1,
               "both cap-plus-one paths explicitly cancel their URLSession task")

        let invalidUTF8 = await receives(transport, path: "/invalid-utf8")
        switch invalidUTF8 {
        case .success(let response):
            do {
                let _: [String: String] = try AuthenticatedHTTPTransport.decodeJSON(
                    [String: String].self,
                    from: response.data
                )
                expect(false, "JSON text decoding rejects malformed UTF-8 fatally")
            } catch let error as AuthenticatedHTTPTransportError {
                expect(error == .invalidUTF8, "JSON text decoding rejects malformed UTF-8 fatally")
            } catch {
                expect(false, "invalid UTF-8 maps to the static transport error")
            }
        case .failure:
            expect(false, "invalid UTF-8 reaches the explicit JSON text boundary")
        }

        let markerFault = await receives(transport, path: "/transport-marker")
        if case .failure(let error) = markerFault {
            let publicText = String(describing: error)
                + " " + ((error as? LocalizedError)?.errorDescription ?? "")
            expect(failure(markerFault) == .transportFailure
                    && !publicText.contains("secret-body-marker")
                    && !publicText.contains("bearer-token-marker")
                    && !publicText.contains("allowed.test"),
                   "transport failures expose only a static redacted category")
        } else {
            expect(false, "transport failures expose only a static redacted category")
        }

        let hardened = await receives(transport, path: "/ok")
        let requestSnapshot = AuthenticatedTransportProbe.snapshot().requests.last
        expect(success(hardened), "a valid exact-host request succeeds")
        expect(requestSnapshot?.cachePolicy == .reloadIgnoringLocalCacheData
                && requestSnapshot?.handlesCookies == false
                && requestSnapshot?.cookieHeader == nil
                && requestSnapshot?.authorizationHeader == "Bearer private-token-marker",
               "the transport forces reload/no-cookie policy while retaining the required bearer header")

        let slow = Task {
            try await transport.send(
                request("/slow"),
                allowedHosts: ["allowed.test"],
                maxResponseBytes: 64
            )
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        slow.cancel()
        do {
            _ = try await slow.value
            expect(false, "caller cancellation cancels the in-flight URLSession task")
        } catch is CancellationError {
            expect(true, "caller cancellation cancels the in-flight URLSession task")
        } catch {
            expect(false, "caller cancellation remains CancellationError")
        }

        sourceContracts()

        if failures == 0 {
            print("PASS  all \(checks) authenticated HTTP transport contracts")
        } else {
            print("FAIL  \(failures) of \(checks) authenticated HTTP transport contracts")
            Foundation.exit(1)
        }
    }

    @MainActor
    private static func sourceContracts() {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source: (String) -> String = { path in
            (try? String(
                contentsOf: app.appendingPathComponent(path),
                encoding: .utf8
            )) ?? ""
        }
        let transport = source("SourcesShared/AuthenticatedHTTPTransport.swift")
        let simklAuth = source("SourcesShared/SIMKLAuth.swift")
        let sync = source("SourcesShared/TraktSyncEngine.swift")
        let lists = source("SourcesShared/TraktMyListsClient.swift")
        let playback = source("SourcesShared/TraktPlaybackShadow.swift")
        let traktService = source("SourcesShared/TraktService.swift")
        let importClient = source("SourcesShared/LetterboxdImportClient.swift")
        let simklService = source("SourcesShared/SIMKLService.swift")
        let traktAuth = source("SourcesShared/TraktAuth.swift")

        expect(transport.contains("URLSessionConfiguration.ephemeral")
                && transport.contains("httpShouldSetCookies = false")
                && transport.contains("httpCookieStorage = nil")
                && transport.contains("urlCredentialStorage = nil")
                && transport.contains("urlCache = nil")
                && transport.contains("reloadIgnoringLocalCacheData"),
               "the live transport is an ephemeral no-cookie/no-credential/no-cache session")
        expect(transport.contains("completionHandler(nil)")
                && transport.contains("allowedHosts")
                && transport.contains("Content-Length")
                && transport.contains("task?.cancel()"),
               "the shared transport source keeps redirect, host, length, and cancellation guards")

        let routed = [simklAuth, sync, lists, playback, traktService, simklService]
        expect(routed.allSatisfy { $0.contains("AuthenticatedHTTPTransport") },
               "every named auth and service client routes through the shared transport")
        expect(importClient.segment(from: "enum TraktListImportClient", to: nil)
                    .contains("AuthenticatedHTTPTransport")
                && importClient.segment(from: "enum ListImport", to: "enum TraktListImportClient")
                    .contains("URLSession.shared.data(for: req)"),
               "only token-bearing Trakt list import moves; the public Letterboxd fetch stays unchanged")

        let migrated = routed + [importClient.segment(from: "enum TraktListImportClient", to: nil)]
        expect(migrated.allSatisfy { !$0.contains("error.localizedDescription") },
               "migrated bearer clients never publish dynamic transport error text")
        expect(migrated.allSatisfy { $0.contains("maxResponseBytes:") },
               "every migrated bearer client supplies an explicit endpoint response cap")
        expect(simklAuth.contains("controlResponseLimit")
                && traktService.contains("controlResponseLimit")
                && simklService.contains("controlResponseLimit")
                && [sync, lists, playback, importClient, traktService, simklService]
                    .allSatisfy { $0.contains("snapshotResponseLimit") },
               "control replies use 64 KiB while full authenticated snapshots/lists use 8 MiB")
        expect(simklAuth.contains("let allowedAPIHosts: Set<String>")
                && simklAuth.contains("allowedAPIHosts: [\"api.simkl.com\"]")
                && simklAuth.contains("allowedHosts: configuration.allowedAPIHosts")
                && !simklAuth.contains("URL(string: configuration.apiBase).flatMap(\\.host)"),
               "SIMKL's allowlist is an independent fixed policy, never derived from the requested URL")
        expect(migrated.allSatisfy {
            $0.contains("decodeJSON") || $0.contains("jsonObject")
        }, "every migrated JSON text decoder enters the fatal UTF-8 helper")

        expect(traktAuth.contains("TraktOAuthNoRedirectDelegate")
                && traktAuth.contains("session.bytes(for: request)")
                && traktAuth.contains("/v1/oauth/trakt/device/start")
                && !traktAuth.contains("AuthenticatedHTTPTransport"),
               "the separately hardened Trakt broker OAuth transport remains unchanged")
    }

    private static func failure<T>(_ result: Result<T, Error>) -> AuthenticatedHTTPTransportError? {
        guard case .failure(let error) = result else { return nil }
        return error as? AuthenticatedHTTPTransportError
    }

    private static func success<T>(_ result: Result<T, Error>) -> Bool {
        if case .success = result { return true }
        return false
    }
}

private extension URLRequest {
    func withURLScheme(_ scheme: String) -> URLRequest {
        var copy = self
        var components = copy.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        components?.scheme = scheme
        copy.url = components?.url
        return copy
    }
}

private extension String {
    func segment(from start: String, to end: String?) -> String {
        guard let startRange = range(of: start) else { return "" }
        let tail = self[startRange.lowerBound...]
        guard let end,
              let endRange = tail.range(of: end) else { return String(tail) }
        return String(tail[..<endRange.lowerBound])
    }
}
