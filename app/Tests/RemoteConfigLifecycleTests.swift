// Standalone production-linked lifecycle harness for RemoteConfig:
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/remote-config-lifecycle-test \
//     app/SourcesShared/RemoteConfig.swift \
//     app/Tests/RemoteConfigLifecycleTests.swift && /tmp/remote-config-lifecycle-test
//
// The real RemoteConfig actor performs every install, cache load/write, conditional request, and metadata
// transition below. Only the edge signer, Source Index lifecycle symbols, and URL transport are stubbed.

import Foundation

// Foundation documents UserDefaults as thread-safe, but its overlay does not declare Sendable. The production
// actor owns each injected instance after init; observations below deliberately reopen separate suite instances.
extension UserDefaults: @retroactive @unchecked Sendable {}

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
    /// Behaves like an origin with one current representation: a matching conditional request receives 304,
    /// while an unconditional or stale-validator request receives the full 200 body.
    case conditional(etag: String, body: Data, requiresSignature: Bool)
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
        case let .conditional(etag, body, requiresSignature):
            if requiresSignature,
               request.value(forHTTPHeaderField: "X-VortX-Test-Signature") != "test-signature" {
                throw MockTransportError.unsignedRequest
            }
            if request.value(forHTTPHeaderField: "If-None-Match") == etag {
                return (304, [:], Data())
            }
            return (200, ["Etag": etag], body)
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
        guard UserDefaults(suiteName: suiteName) != nil else {
            print("FAIL  could not create isolated UserDefaults suite")
            exit(1)
        }
        func suiteDefaults(_ name: String = suiteName) -> UserDefaults {
            guard let value = UserDefaults(suiteName: name) else {
                fatalError("could not reopen isolated UserDefaults suite \(name)")
            }
            return value
        }
        suiteDefaults().removePersistentDomain(forName: suiteName)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteConfigLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDirectory = root.appendingPathComponent("RemoteConfig", isDirectory: true)
        let cacheFile = cacheDirectory.appendingPathComponent("config.json")
        defer {
            suiteDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let etagKey = "vortx.remoteConfig.etag"
        let bodyETagKey = "vortx.remoteConfig.bodyETag"
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
        let initial = RemoteConfig(defaults: suiteDefaults(), cacheDirectory: cacheDirectory, session: session)
        await initial.refresh()
        expect(RemoteConfig.snapshot.remoteConfigEnabled,
               "initial authenticated config installs as enabled")
        expect(!RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
               "initial remote feature value is live before the kill switch")
        expect((try? Data(contentsOf: cacheFile)) == enabledV1,
               "initial refresh writes the production cache file")
        expect(suiteDefaults().string(forKey: etagKey) == "enabled-v1",
               "initial refresh persists its ETag")
        expect(suiteDefaults().string(forKey: bodyETagKey) == "enabled-v1",
               "initial refresh binds its validator to the persisted body")
        let firstFetch = suiteDefaults().double(forKey: lastFetchKey)
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
        expect(suiteDefaults().bool(forKey: masterDisabledKey),
               "master disable persists an explicit durable latch")
        expect((try? Data(contentsOf: cacheFile)) == disabledV2,
               "master disable atomically replaces the stale enabled cache")
        expect(suiteDefaults().string(forKey: etagKey) == "disabled-v2",
               "master disable persists its own ETag")
        expect(suiteDefaults().string(forKey: bodyETagKey) == "disabled-v2",
               "master disable binds its validator only after the disabling body persists")
        let disableFetch = suiteDefaults().double(forKey: lastFetchKey)
        expect(disableFetch > firstFetch, "master disable stamps successful-fetch metadata")

        try? await Task.sleep(nanoseconds: 20_000_000)
        MockTransport.enqueue(.http(status: 304, etag: nil, body: Data(), requiresSignature: true))
        await initial.refresh()
        expect(MockTransport.requests[2].value(forHTTPHeaderField: "If-None-Match") == nil,
               "a durable disable forces an unconditional refresh even with a bound ETag")
        expect(suiteDefaults().bool(forKey: masterDisabledKey),
               "304 keeps the durable disable latched")
        expect(suiteDefaults().string(forKey: etagKey) == "disabled-v2",
               "304 preserves the validator for the current disabled representation")
        expect(suiteDefaults().double(forKey: lastFetchKey) == disableFetch,
               "an unexpected unconditional 304 cannot stamp freshness and throttle the repair fetch")

        // Mutation fixture: restore the exact stale enabled bytes after disable. Bootstrap must still honor
        // the durable latch. Removing the latch check makes this production-linked assertion go red.
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? enabledV1.write(to: cacheFile, options: .atomic)
        MockTransport.enqueue(.offline)
        let offlineRelaunch = RemoteConfig(defaults: suiteDefaults(), cacheDirectory: cacheDirectory, session: session)
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
        expect(suiteDefaults().bool(forKey: masterDisabledKey),
               "expired or denied authentication cannot clear the durable disable")
        expect(suiteDefaults().string(forKey: etagKey) == "disabled-v2",
               "401 response cannot replace the disabling ETag")

        AuthRecorder.useValidSignature(false)
        MockTransport.enqueue(.http(status: 200, etag: "bad-signature", body: enabledV3,
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        AuthRecorder.useValidSignature(true)
        expect(suiteDefaults().bool(forKey: masterDisabledKey),
               "bad request signature cannot clear the durable disable")
        expect(suiteDefaults().string(forKey: etagKey) == "disabled-v2",
               "bad request signature cannot replace the disabling ETag")

        MockTransport.enqueue(.http(status: 200, etag: "invalid-json", body: Data("{".utf8),
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        expect(suiteDefaults().bool(forKey: masterDisabledKey),
               "malformed authenticated 200 cannot clear the durable disable")
        expect((try? Data(contentsOf: cacheFile)) == enabledV1,
               "failed re-enable leaves cache bytes untouched")

        MockTransport.enqueue(.http(status: 200, etag: "implicit-v3", body: implicitV3,
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        expect(suiteDefaults().bool(forKey: masterDisabledKey),
               "valid config that omits the master switch cannot implicitly clear the durable disable")
        expect(!RemoteConfig.snapshot.remoteConfigEnabled,
               "omitted master switch leaves the installed snapshot disabled")
        expect(suiteDefaults().string(forKey: etagKey) == "implicit-v3",
               "valid non-re-enabling response advances the server validator while preserving the latch")
        expect((try? Data(contentsOf: cacheFile)) == implicitV3
               && suiteDefaults().string(forKey: bodyETagKey) == "implicit-v3",
               "omitted master switch advances the validator only with matching durable bytes")

        MockTransport.enqueue(.http(status: 200, etag: "null-v3", body: nullV3,
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        expect(suiteDefaults().bool(forKey: masterDisabledKey),
               "valid config with a null master switch cannot clear the durable disable")
        expect(!RemoteConfig.snapshot.remoteConfigEnabled,
               "null master switch leaves the installed snapshot disabled")
        expect(suiteDefaults().string(forKey: etagKey) == "null-v3",
               "valid null-switch response advances the server validator while preserving the latch")
        expect((try? Data(contentsOf: cacheFile)) == nullV3
               && suiteDefaults().string(forKey: bodyETagKey) == "null-v3",
               "null master switch advances the validator only with matching durable bytes")

        try? await Task.sleep(nanoseconds: 20_000_000)
        MockTransport.enqueue(.http(status: 200, etag: "enabled-v3", body: enabledV3,
                                    requiresSignature: true))
        await offlineRelaunch.refresh()
        expect(MockTransport.requests[9].value(forHTTPHeaderField: "If-None-Match") == nil,
               "explicit re-enable requests a body while the durable disable remains latched")
        expect(suiteDefaults().object(forKey: masterDisabledKey) == nil,
               "later valid authenticated re-enable is the transition that clears the latch")
        expect(RemoteConfig.snapshot.remoteConfigEnabled,
               "valid re-enable installs an enabled snapshot")
        expect(!RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
               "valid re-enable restores its validated remote behavior")
        expect((try? Data(contentsOf: cacheFile)) == enabledV3,
               "valid re-enable replaces the cache with its own bytes")
        expect(suiteDefaults().string(forKey: etagKey) == "enabled-v3",
               "valid re-enable replaces the disabling ETag")
        expect(suiteDefaults().string(forKey: bodyETagKey) == "enabled-v3",
               "valid re-enable binds the new ETag to its durable enabled body")
        expect(suiteDefaults().double(forKey: lastFetchKey) > disableFetch,
               "valid re-enable advances fetch metadata")

        MockTransport.enqueue(.offline)
        let enabledRelaunch = RemoteConfig(defaults: suiteDefaults(), cacheDirectory: cacheDirectory, session: session)
        await enabledRelaunch.bootstrap()
        expect(RemoteConfig.snapshot.remoteConfigEnabled,
               "offline relaunch after valid re-enable loads the enabled cache")
        expect(!RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
               "offline relaunch after re-enable restores the cached remote behavior")
        await waitForRequestCount(11)

        // Crash fixture A: an explicit-true body and its ETag reached disk, but the old ordering crashed before
        // clearing the durable disable. A conditional request would receive 304 forever. The repair request
        // must omit the validator, receive the full body, and complete the re-enable transaction.
        let partialEnableSuite = "RemoteConfigLifecycleTests.partialEnable.\(UUID().uuidString)"
        suiteDefaults(partialEnableSuite).removePersistentDomain(forName: partialEnableSuite)
        defer { suiteDefaults(partialEnableSuite).removePersistentDomain(forName: partialEnableSuite) }
        let partialEnableDirectory = root.appendingPathComponent("PartialEnable", isDirectory: true)
        let partialEnableFile = partialEnableDirectory.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: partialEnableDirectory, withIntermediateDirectories: true)
        try? enabledV3.write(to: partialEnableFile, options: .atomic)
        suiteDefaults(partialEnableSuite).set(true, forKey: masterDisabledKey)
        suiteDefaults(partialEnableSuite).set("enabled-v3", forKey: etagKey)
        suiteDefaults(partialEnableSuite).removeObject(forKey: bodyETagKey)
        let partialEnableRequest = MockTransport.requests.count
        MockTransport.enqueue(.conditional(etag: "enabled-v3", body: enabledV3, requiresSignature: true))
        let partialEnable = RemoteConfig(
            defaults: suiteDefaults(partialEnableSuite),
            cacheDirectory: partialEnableDirectory,
            session: session
        )
        await partialEnable.bootstrap()
        await waitForRequestCount(partialEnableRequest + 1)
        expect(MockTransport.requests[partialEnableRequest].value(forHTTPHeaderField: "If-None-Match") == nil,
               "partial re-enable state forces a body instead of accepting a matching 304")
        expect(suiteDefaults(partialEnableSuite).object(forKey: masterDisabledKey) == nil,
               "full explicit-true body repairs the partial state and clears the disable")
        expect(suiteDefaults(partialEnableSuite).string(forKey: bodyETagKey) == "enabled-v3"
               && suiteDefaults(partialEnableSuite).string(forKey: etagKey) == "enabled-v3",
               "repaired re-enable binds and commits its validator")
        expect(RemoteConfig.snapshot.remoteConfigEnabled,
               "repaired re-enable installs enabled behavior only after durable repair")

        // Crash fixture B: a disabling ETag advanced even though the disabling body did not replace the old
        // enabled cache, and the process died before the latch write. Legacy state has no body binding marker.
        // An unconditional repair fetch must recover the false body and restore the durable disable.
        let partialDisableSuite = "RemoteConfigLifecycleTests.partialDisable.\(UUID().uuidString)"
        suiteDefaults(partialDisableSuite).removePersistentDomain(forName: partialDisableSuite)
        defer { suiteDefaults(partialDisableSuite).removePersistentDomain(forName: partialDisableSuite) }
        let partialDisableDirectory = root.appendingPathComponent("PartialDisable", isDirectory: true)
        let partialDisableFile = partialDisableDirectory.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: partialDisableDirectory, withIntermediateDirectories: true)
        try? enabledV1.write(to: partialDisableFile, options: .atomic)
        suiteDefaults(partialDisableSuite).set("disabled-v2", forKey: etagKey)
        suiteDefaults(partialDisableSuite).removeObject(forKey: bodyETagKey)
        suiteDefaults(partialDisableSuite).removeObject(forKey: masterDisabledKey)
        let partialDisableRequest = MockTransport.requests.count
        MockTransport.enqueue(.conditional(etag: "disabled-v2", body: disabledV2, requiresSignature: true))
        let partialDisable = RemoteConfig(
            defaults: suiteDefaults(partialDisableSuite),
            cacheDirectory: partialDisableDirectory,
            session: session
        )
        await partialDisable.bootstrap()
        await waitForRequestCount(partialDisableRequest + 1)
        expect(MockTransport.requests[partialDisableRequest].value(forHTTPHeaderField: "If-None-Match") == nil,
               "unbound disabling validator cannot conditionally validate an older enabled body")
        expect(suiteDefaults(partialDisableSuite).bool(forKey: masterDisabledKey)
               && !RemoteConfig.snapshot.remoteConfigEnabled,
               "full false body repairs the partial disable and installs durable disabled behavior")
        expect((try? Data(contentsOf: partialDisableFile)) == disabledV2
               && suiteDefaults(partialDisableSuite).string(forKey: bodyETagKey) == "disabled-v2",
               "partial disable repair persists the matching false body before binding its validator")

        // A validator has no meaning without a readable matching body. Missing, corrupt, and schema-undecodable
        // caches all force a full fetch even when the old metadata claims the ETag was body-bound.
        let missingSuite = "RemoteConfigLifecycleTests.missing.\(UUID().uuidString)"
        suiteDefaults(missingSuite).removePersistentDomain(forName: missingSuite)
        defer { suiteDefaults(missingSuite).removePersistentDomain(forName: missingSuite) }
        let missingDirectory = root.appendingPathComponent("Missing", isDirectory: true)
        suiteDefaults(missingSuite).set("stale-missing", forKey: etagKey)
        suiteDefaults(missingSuite).set("stale-missing", forKey: bodyETagKey)
        let missingRequest = MockTransport.requests.count
        MockTransport.enqueue(.conditional(etag: "stale-missing", body: enabledV1, requiresSignature: true))
        let missing = RemoteConfig(
            defaults: suiteDefaults(missingSuite), cacheDirectory: missingDirectory, session: session
        )
        await missing.bootstrap()
        await waitForRequestCount(missingRequest + 1)
        expect(MockTransport.requests[missingRequest].value(forHTTPHeaderField: "If-None-Match") == nil,
               "missing cache body suppresses a stale ETag")
        expect((try? Data(contentsOf: missingDirectory.appendingPathComponent("config.json"))) == enabledV1
               && !RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
               "missing cache is repaired from the unconditional full response")

        let corruptSuite = "RemoteConfigLifecycleTests.corrupt.\(UUID().uuidString)"
        suiteDefaults(corruptSuite).removePersistentDomain(forName: corruptSuite)
        defer { suiteDefaults(corruptSuite).removePersistentDomain(forName: corruptSuite) }
        let corruptDirectory = root.appendingPathComponent("Corrupt", isDirectory: true)
        let corruptFile = corruptDirectory.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try? Data("{".utf8).write(to: corruptFile, options: .atomic)
        suiteDefaults(corruptSuite).set("stale-corrupt", forKey: etagKey)
        suiteDefaults(corruptSuite).set("stale-corrupt", forKey: bodyETagKey)
        let corruptRequest = MockTransport.requests.count
        MockTransport.enqueue(.conditional(etag: "stale-corrupt", body: enabledV1, requiresSignature: true))
        let corrupt = RemoteConfig(
            defaults: suiteDefaults(corruptSuite), cacheDirectory: corruptDirectory, session: session
        )
        await corrupt.bootstrap()
        await waitForRequestCount(corruptRequest + 1)
        expect(MockTransport.requests[corruptRequest].value(forHTTPHeaderField: "If-None-Match") == nil,
               "syntactically corrupt cache suppresses a stale ETag")
        expect((try? Data(contentsOf: corruptFile)) == enabledV1,
               "syntactically corrupt cache is replaced by the full response")

        let undecodableSuite = "RemoteConfigLifecycleTests.undecodable.\(UUID().uuidString)"
        suiteDefaults(undecodableSuite).removePersistentDomain(forName: undecodableSuite)
        defer { suiteDefaults(undecodableSuite).removePersistentDomain(forName: undecodableSuite) }
        let undecodableDirectory = root.appendingPathComponent("Undecodable", isDirectory: true)
        let undecodableFile = undecodableDirectory.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: undecodableDirectory, withIntermediateDirectories: true)
        let undecodableBody = Data(#"{"master":{"remoteConfigEnabled":"yes"}}"#.utf8)
        try? undecodableBody.write(to: undecodableFile, options: .atomic)
        suiteDefaults(undecodableSuite).set("stale-undecodable", forKey: etagKey)
        suiteDefaults(undecodableSuite).set("stale-undecodable", forKey: bodyETagKey)
        let undecodableRequest = MockTransport.requests.count
        MockTransport.enqueue(.conditional(etag: "stale-undecodable", body: enabledV1, requiresSignature: true))
        let undecodable = RemoteConfig(
            defaults: suiteDefaults(undecodableSuite), cacheDirectory: undecodableDirectory, session: session
        )
        await undecodable.bootstrap()
        await waitForRequestCount(undecodableRequest + 1)
        expect(MockTransport.requests[undecodableRequest].value(forHTTPHeaderField: "If-None-Match") == nil,
               "schema-undecodable cache suppresses a stale ETag")
        expect((try? Data(contentsOf: undecodableFile)) == enabledV1,
               "schema-undecodable cache is replaced by the full response")

        // A regular file used as the cache directory makes config.json persistence fail deterministically.
        // Explicit true must leave every durable disable field and the installed snapshot untouched.
        let failedEnableSuite = "RemoteConfigLifecycleTests.failedEnable.\(UUID().uuidString)"
        suiteDefaults(failedEnableSuite).removePersistentDomain(forName: failedEnableSuite)
        defer { suiteDefaults(failedEnableSuite).removePersistentDomain(forName: failedEnableSuite) }
        let blockedEnableDirectory = root.appendingPathComponent("BlockedEnable")
        try? Data("not-a-directory".utf8).write(to: blockedEnableDirectory, options: .atomic)
        suiteDefaults(failedEnableSuite).set(true, forKey: masterDisabledKey)
        suiteDefaults(failedEnableSuite).set("disabled-stable", forKey: etagKey)
        suiteDefaults(failedEnableSuite).set("disabled-stable", forKey: bodyETagKey)
        suiteDefaults(failedEnableSuite).set(101.0, forKey: lastFetchKey)
        let failedEnableRequest = MockTransport.requests.count
        MockTransport.enqueue(.http(status: 200, etag: "enabled-write-failed", body: enabledV3,
                                    requiresSignature: true))
        let failedEnable = RemoteConfig(
            defaults: suiteDefaults(failedEnableSuite),
            cacheDirectory: blockedEnableDirectory,
            session: session
        )
        await failedEnable.bootstrap()
        await waitForRequestCount(failedEnableRequest + 1)
        expect(MockTransport.requests[failedEnableRequest].value(forHTTPHeaderField: "If-None-Match") == nil,
               "failed re-enable persistence still requests a full body while latched")
        expect(suiteDefaults(failedEnableSuite).bool(forKey: masterDisabledKey)
               && !RemoteConfig.snapshot.remoteConfigEnabled,
               "failed enabled-body write cannot clear the latch or install enabled memory state")
        expect(suiteDefaults(failedEnableSuite).string(forKey: etagKey) == "disabled-stable"
               && suiteDefaults(failedEnableSuite).string(forKey: bodyETagKey) == "disabled-stable"
               && suiteDefaults(failedEnableSuite).double(forKey: lastFetchKey) == 101.0,
               "failed enabled-body write advances neither BV, V, nor lastFetch")

        // False is safety-first: latch before any fallible body write. A failed body write must still leave the
        // process disabled, while the prior body validator and freshness metadata remain unchanged for repair.
        let failedDisableSuite = "RemoteConfigLifecycleTests.failedDisable.\(UUID().uuidString)"
        suiteDefaults(failedDisableSuite).removePersistentDomain(forName: failedDisableSuite)
        defer { suiteDefaults(failedDisableSuite).removePersistentDomain(forName: failedDisableSuite) }
        let blockedDisableDirectory = root.appendingPathComponent("BlockedDisable")
        try? Data("not-a-directory".utf8).write(to: blockedDisableDirectory, options: .atomic)
        suiteDefaults(failedDisableSuite).set("enabled-stable", forKey: etagKey)
        suiteDefaults(failedDisableSuite).set("enabled-stable", forKey: bodyETagKey)
        suiteDefaults(failedDisableSuite).set(202.0, forKey: lastFetchKey)
        let failedDisableRequest = MockTransport.requests.count
        MockTransport.enqueue(.http(status: 200, etag: "disabled-write-failed", body: disabledV2,
                                    requiresSignature: true))
        let failedDisable = RemoteConfig(
            defaults: suiteDefaults(failedDisableSuite),
            cacheDirectory: blockedDisableDirectory,
            session: session
        )
        await failedDisable.bootstrap()
        await waitForRequestCount(failedDisableRequest + 1)
        expect(MockTransport.requests[failedDisableRequest].value(forHTTPHeaderField: "If-None-Match") == nil,
               "absent readable body suppresses the stale validator before a disable fetch")
        expect(suiteDefaults(failedDisableSuite).bool(forKey: masterDisabledKey)
               && !RemoteConfig.snapshot.remoteConfigEnabled,
               "false response latches and installs disabled behavior even when body persistence fails")
        expect(suiteDefaults(failedDisableSuite).string(forKey: etagKey) == "enabled-stable"
               && suiteDefaults(failedDisableSuite).string(forKey: bodyETagKey) == "enabled-stable"
               && suiteDefaults(failedDisableSuite).double(forKey: lastFetchKey) == 202.0,
               "failed disabling-body write advances neither BV, V, nor lastFetch")

        // Missing and null cannot re-enable while latched, but their validators still must not outrun their
        // bodies. Exercise that separate branch with the same deterministic write failure.
        let failedImplicitSuite = "RemoteConfigLifecycleTests.failedImplicit.\(UUID().uuidString)"
        suiteDefaults(failedImplicitSuite).removePersistentDomain(forName: failedImplicitSuite)
        defer { suiteDefaults(failedImplicitSuite).removePersistentDomain(forName: failedImplicitSuite) }
        let blockedImplicitDirectory = root.appendingPathComponent("BlockedImplicit")
        try? Data("not-a-directory".utf8).write(to: blockedImplicitDirectory, options: .atomic)
        suiteDefaults(failedImplicitSuite).set(true, forKey: masterDisabledKey)
        suiteDefaults(failedImplicitSuite).set("disabled-stable", forKey: etagKey)
        suiteDefaults(failedImplicitSuite).set("disabled-stable", forKey: bodyETagKey)
        suiteDefaults(failedImplicitSuite).set(303.0, forKey: lastFetchKey)
        let failedImplicitRequest = MockTransport.requests.count
        MockTransport.enqueue(.http(status: 200, etag: "implicit-write-failed", body: implicitV3,
                                    requiresSignature: true))
        let failedImplicit = RemoteConfig(
            defaults: suiteDefaults(failedImplicitSuite),
            cacheDirectory: blockedImplicitDirectory,
            session: session
        )
        await failedImplicit.bootstrap()
        await waitForRequestCount(failedImplicitRequest + 1)
        expect(suiteDefaults(failedImplicitSuite).bool(forKey: masterDisabledKey)
               && !RemoteConfig.snapshot.remoteConfigEnabled,
               "failed omitted-master body write preserves durable and in-memory disable")
        expect(suiteDefaults(failedImplicitSuite).string(forKey: etagKey) == "disabled-stable"
               && suiteDefaults(failedImplicitSuite).string(forKey: bodyETagKey) == "disabled-stable"
               && suiteDefaults(failedImplicitSuite).double(forKey: lastFetchKey) == 303.0,
               "failed omitted-master body write advances neither BV, V, nor lastFetch")

        // Positive 304 control: once a readable decoded body and both validator fields agree with no latch,
        // the exact request is conditional and a matching 304 may stamp freshness without touching the body.
        let coherentSuite = "RemoteConfigLifecycleTests.coherent304.\(UUID().uuidString)"
        suiteDefaults(coherentSuite).removePersistentDomain(forName: coherentSuite)
        defer { suiteDefaults(coherentSuite).removePersistentDomain(forName: coherentSuite) }
        let coherentDirectory = root.appendingPathComponent("Coherent304", isDirectory: true)
        let coherentFile = coherentDirectory.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: coherentDirectory, withIntermediateDirectories: true)
        try? enabledV1.write(to: coherentFile, options: .atomic)
        suiteDefaults(coherentSuite).set("enabled-coherent", forKey: etagKey)
        suiteDefaults(coherentSuite).set("enabled-coherent", forKey: bodyETagKey)
        suiteDefaults(coherentSuite).set(404.0, forKey: lastFetchKey)
        let coherentRequest = MockTransport.requests.count
        MockTransport.enqueue(.conditional(etag: "enabled-coherent", body: enabledV1, requiresSignature: true))
        let coherent = RemoteConfig(
            defaults: suiteDefaults(coherentSuite), cacheDirectory: coherentDirectory, session: session
        )
        await coherent.bootstrap()
        await waitForRequestCount(coherentRequest + 1)
        expect(MockTransport.requests[coherentRequest].value(forHTTPHeaderField: "If-None-Match")
               == "enabled-coherent",
               "coherent readable body sends its bound validator")
        expect(suiteDefaults(coherentSuite).double(forKey: lastFetchKey) > 404.0
               && (try? Data(contentsOf: coherentFile)) == enabledV1,
               "304 from the exact coherent conditional request may stamp freshness and keep its body")

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
