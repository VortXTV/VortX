// Standalone production-linked lifecycle harness for RemoteConfig:
//
//   xcrun swiftc -warnings-as-errors -o /tmp/remote-config-lifecycle-test \
//     app/SourcesShared/RemoteConfig.swift \
//     app/Tests/RemoteConfigLifecycleTests.swift && /tmp/remote-config-lifecycle-test
//
// The real RemoteConfig actor performs every install, cache load/write, conditional request, and metadata
// transition below. Only the edge signer, Source Index lifecycle symbols, and URL transport are stubbed.

import Foundation

private enum AuthRecorder {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var signature = "test-signature"

    static func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    static var signCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func useValidSignature(_ valid: Bool) {
        lock.lock()
        signature = valid ? "test-signature" : "bad-signature"
        lock.unlock()
    }

    static var currentSignature: String {
        lock.lock()
        defer { lock.unlock() }
        return signature
    }
}

enum VortXEdgeAuth {
    static func sign(_ request: inout URLRequest) {
        AuthRecorder.record()
        request.setValue(AuthRecorder.currentSignature, forHTTPHeaderField: "X-VortX-Test-Signature")
    }
}

struct SourceIndexLifecycleSnapshot: Hashable, Sendable {
    let sourceGeneration: UInt64
    let sessionGeneration: UInt64
    let consentGeneration: UInt64
}

struct SourceIndexLifecycleTransition: Sendable {
    let retired: SourceIndexLifecycleSnapshot
    let current: SourceIndexLifecycleSnapshot
    let retiredSession: Bool
    let retiredConsent: Bool
}

enum SourceIndexLifecycleClock {
    static func closeSource() -> SourceIndexLifecycleTransition {
        let zero = SourceIndexLifecycleSnapshot(sourceGeneration: 0, sessionGeneration: 0, consentGeneration: 0)
        return SourceIndexLifecycleTransition(retired: zero, current: zero,
                                              retiredSession: false, retiredConsent: false)
    }
}

private enum MockTransportError: Error {
    case offline
    case unsignedRequest
    case missingFixture
}

private enum MockResponse {
    case http(status: Int, etag: String?, body: Data, requiresSignature: Bool)
    case offline
}

private enum MockTransport {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [MockResponse] = []
    nonisolated(unsafe) private static var received: [URLRequest] = []

    static func enqueue(_ response: MockResponse) {
        lock.lock()
        queued.append(response)
        lock.unlock()
    }

    static func take(_ request: URLRequest) throws -> (status: Int, headers: [String: String], body: Data) {
        lock.lock()
        received.append(request)
        guard !queued.isEmpty else {
            lock.unlock()
            throw MockTransportError.missingFixture
        }
        let response = queued.removeFirst()
        lock.unlock()

        switch response {
        case .offline:
            throw MockTransportError.offline
        case let .http(status, etag, body, requiresSignature):
            if requiresSignature,
               request.value(forHTTPHeaderField: "X-VortX-Test-Signature") != "test-signature" {
                throw MockTransportError.unsignedRequest
            }
            var headers: [String: String] = [:]
            if let etag { headers["Etag"] = etag }
            return (status, headers, body)
        }
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

private final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "config.vortx.tv"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let fixture = try MockTransport.take(request)
            guard let response = HTTPURLResponse(
                url: request.url!,
                statusCode: fixture.status,
                httpVersion: "HTTP/1.1",
                headerFields: fixture.headers
            ) else {
                throw MockTransportError.missingFixture
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !fixture.body.isEmpty { client?.urlProtocol(self, didLoad: fixture.body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

nonisolated(unsafe) private var failures = 0

private func expect(_ condition: Bool, _ what: String) {
    if condition {
        print("PASS  \(what)")
    } else {
        failures += 1
        print("FAIL  \(what)")
    }
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func waitForRequestCount(_ expected: Int) async {
    for _ in 0..<100 where MockTransport.requests.count < expected {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    expect(MockTransport.requests.count >= expected,
           "background refresh completed request \(expected)")
}

@main
private struct RemoteConfigLifecycleTests {
    static func main() async {
        let suiteName = "RemoteConfigLifecycleTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("FAIL  could not create isolated UserDefaults suite")
            exit(1)
        }
        defaults.removePersistentDomain(forName: suiteName)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteConfigLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDirectory = root.appendingPathComponent("RemoteConfig", isDirectory: true)
        let cacheFile = cacheDirectory.appendingPathComponent("config.json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let etagKey = "vortx.remoteConfig.etag"
        let lastFetchKey = "vortx.remoteConfig.lastFetchEpoch"
        let masterDisabledKey = "vortx.remoteConfig.masterDisabled"
        let enabledV1 = Data(#"{"master":{"remoteConfigEnabled":true},"features":{"trailers":false}}"#.utf8)
        let disabledV2 = Data(#"{"master":{"remoteConfigEnabled":false},"features":{"trailers":false}}"#.utf8)
        let implicitV3 = Data(#"{"features":{"trailers":false},"refreshIntervalHours":2}"#.utf8)
        let nullV3 = Data(#"{"master":{"remoteConfigEnabled":null},"features":{"trailers":false}}"#.utf8)
        let enabledV3 = Data(#"{"master":{"remoteConfigEnabled":true},"features":{"trailers":false},"refreshIntervalHours":2}"#.utf8)
        let session = makeSession()

        // Seed a real last-good cache so the disabling transition has stale behavior to displace.
        MockTransport.enqueue(.http(status: 200, etag: "enabled-v1", body: enabledV1,
                                    requiresSignature: true))
        let initial = RemoteConfig(defaults: defaults, cacheDirectory: cacheDirectory, session: session)
        await initial.refresh()
        expect(RemoteConfig.snapshot.remoteConfigEnabled,
               "initial authenticated config installs as enabled")
        expect(!RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
               "initial remote feature value is live before the kill switch")
        expect((try? Data(contentsOf: cacheFile)) == enabledV1,
               "initial refresh writes the production cache file")
        expect(defaults.string(forKey: etagKey) == "enabled-v1",
               "initial refresh persists its ETag")
        let firstFetch = defaults.double(forKey: lastFetchKey)
        expect(firstFetch > 0, "initial refresh stamps fetch metadata")

        try? await Task.sleep(nanoseconds: 20_000_000)
        MockTransport.enqueue(.http(status: 200, etag: "disabled-v2", body: disabledV2,
                                    requiresSignature: true))
        await initial.refresh()
        let disableRequest = MockTransport.requests[1]
        expect(disableRequest.value(forHTTPHeaderField: "If-None-Match") == "enabled-v1",
               "disable fetch validates the previously installed ETag")
        expect(!RemoteConfig.snapshot.remoteConfigEnabled,
               "authenticated master disable remains represented in the installed snapshot")
        expect(RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
               "master disable installs baked behavior instead of sibling remote fields")
        expect(defaults.bool(forKey: masterDisabledKey),
               "master disable persists an explicit durable latch")
        expect((try? Data(contentsOf: cacheFile)) == disabledV2,
               "master disable atomically replaces the stale enabled cache")
        expect(defaults.string(forKey: etagKey) == "disabled-v2",
               "master disable persists its own ETag")
        let disableFetch = defaults.double(forKey: lastFetchKey)
        expect(disableFetch > firstFetch, "master disable stamps successful-fetch metadata")

        try? await Task.sleep(nanoseconds: 20_000_000)
        MockTransport.enqueue(.http(status: 304, etag: nil, body: Data(), requiresSignature: true))
        await initial.refresh()
        expect(MockTransport.requests[2].value(forHTTPHeaderField: "If-None-Match") == "disabled-v2",
               "disabled 304 request carries the disabling ETag")
        expect(defaults.bool(forKey: masterDisabledKey),
               "304 keeps the durable disable latched")
        expect(defaults.string(forKey: etagKey) == "disabled-v2",
               "304 preserves the validator for the current disabled representation")
        expect(defaults.double(forKey: lastFetchKey) > disableFetch,
               "304 advances successful-fetch metadata without clearing the disable")

        // Mutation fixture: restore the exact stale enabled bytes after disable. Bootstrap must still honor
        // the durable latch. Removing the latch check makes this production-linked assertion go red.
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? enabledV1.write(to: cacheFile, options: .atomic)
        MockTransport.enqueue(.offline)
        let offlineRelaunch = RemoteConfig(defaults: defaults, cacheDirectory: cacheDirectory, session: session)
        await offlineRelaunch.bootstrap()
        expect(!RemoteConfig.snapshot.remoteConfigEnabled,
               "offline relaunch keeps master disable despite a mutated stale enabled cache")
        expect(RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
               "offline relaunch cannot resurrect stale remote behavior")
        await waitForRequestCount(4)
        expect(!RemoteConfig.snapshot.remoteConfigEnabled,
               "offline fetch failure keeps the installed durable disable")

        // Neither an expired/denied signature, a bad request signature, nor malformed JSON is a valid re-enable.
        MockTransport.enqueue(.http(status: 401, etag: "rejected", body: enabledV3,
                                    requiresSignature: false))
        await offlineRelaunch.refresh()
        expect(defaults.bool(forKey: masterDisabledKey),
               "expired or denied authentication cannot clear the durable disable")
        expect(defaults.string(forKey: etagKey) == "disabled-v2",
               "401 response cannot replace the disabling ETag")

        AuthRecorder.useValidSignature(false)
        MockTransport.enqueue(.http(status: 200, etag: "bad-signature", body: enabledV3,
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        AuthRecorder.useValidSignature(true)
        expect(defaults.bool(forKey: masterDisabledKey),
               "bad request signature cannot clear the durable disable")
        expect(defaults.string(forKey: etagKey) == "disabled-v2",
               "bad request signature cannot replace the disabling ETag")

        MockTransport.enqueue(.http(status: 200, etag: "invalid-json", body: Data("{".utf8),
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        expect(defaults.bool(forKey: masterDisabledKey),
               "malformed authenticated 200 cannot clear the durable disable")
        expect((try? Data(contentsOf: cacheFile)) == enabledV1,
               "failed re-enable leaves cache bytes untouched")

        MockTransport.enqueue(.http(status: 200, etag: "implicit-v3", body: implicitV3,
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        expect(defaults.bool(forKey: masterDisabledKey),
               "valid config that omits the master switch cannot implicitly clear the durable disable")
        expect(!RemoteConfig.snapshot.remoteConfigEnabled,
               "omitted master switch leaves the installed snapshot disabled")
        expect(defaults.string(forKey: etagKey) == "implicit-v3",
               "valid non-re-enabling response advances the server validator while preserving the latch")

        MockTransport.enqueue(.http(status: 200, etag: "null-v3", body: nullV3,
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        expect(defaults.bool(forKey: masterDisabledKey),
               "valid config with a null master switch cannot clear the durable disable")
        expect(!RemoteConfig.snapshot.remoteConfigEnabled,
               "null master switch leaves the installed snapshot disabled")
        expect(defaults.string(forKey: etagKey) == "null-v3",
               "valid null-switch response advances the server validator while preserving the latch")

        try? await Task.sleep(nanoseconds: 20_000_000)
        MockTransport.enqueue(.http(status: 200, etag: "enabled-v3", body: enabledV3,
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        expect(MockTransport.requests[9].value(forHTTPHeaderField: "If-None-Match") == "null-v3",
               "explicit re-enable validates the latest non-re-enabling server representation")
        expect(defaults.object(forKey: masterDisabledKey) == nil,
               "later valid authenticated re-enable is the transition that clears the latch")
        expect(RemoteConfig.snapshot.remoteConfigEnabled,
               "valid re-enable installs an enabled snapshot")
        expect(!RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
               "valid re-enable restores its validated remote behavior")
        expect((try? Data(contentsOf: cacheFile)) == enabledV3,
               "valid re-enable replaces the cache with its own bytes")
        expect(defaults.string(forKey: etagKey) == "enabled-v3",
               "valid re-enable replaces the disabling ETag")
        expect(defaults.double(forKey: lastFetchKey) > disableFetch,
               "valid re-enable advances fetch metadata")

        MockTransport.enqueue(.offline)
        let enabledRelaunch = RemoteConfig(defaults: defaults, cacheDirectory: cacheDirectory, session: session)
        await enabledRelaunch.bootstrap()
        expect(RemoteConfig.snapshot.remoteConfigEnabled,
               "offline relaunch after valid re-enable loads the enabled cache")
        expect(!RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
               "offline relaunch after re-enable restores the cached remote behavior")
        await waitForRequestCount(11)

        let requests = MockTransport.requests
        expect(requests.enumerated().allSatisfy { index, request in
            let expected = index == 5 ? "bad-signature" : "test-signature"
            return request.value(forHTTPHeaderField: "X-VortX-Test-Signature") == expected
        }, "every lifecycle request traverses the production edge-auth signer")
        expect(AuthRecorder.signCount == requests.count,
               "the signer runs exactly once for every lifecycle request")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
