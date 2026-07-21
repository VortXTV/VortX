// Standalone production-linked durable-cache and 304 harness for RemoteConfig:
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/RemoteConfig.swift \
//     app/Tests/CacheDeletion304Tests.swift \
//     -o /tmp/cache-deletion-304-test && \
//   /tmp/cache-deletion-304-test
//
// The real actor owns state and persistence. The transport only records request headers and controls when an
// origin-style response or fixed 304 arrives, allowing durable state to change during the await.

import Foundation

extension UserDefaults: @retroactive @unchecked Sendable {}

enum VortXEdgeAuth {
    static func sign(_ request: inout URLRequest) {}
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
        let value = SourceIndexLifecycleSnapshot(sourceGeneration: 0, sessionGeneration: 0, consentGeneration: 0)
        return SourceIndexLifecycleTransition(
            retired: value,
            current: value,
            retiredSession: false,
            retiredConsent: false
        )
    }
}

private enum CacheStep: Sendable {
    case origin(etag: String, body: Data, waitsForRelease: Bool)
    case fixed304(waitsForRelease: Bool)

    var waitsForRelease: Bool {
        switch self {
        case let .origin(_, _, waitsForRelease), let .fixed304(waitsForRelease):
            return waitsForRelease
        }
    }
}

private struct CacheResponse: Sendable {
    let status: Int
    let etag: String?
    let body: Data
}

private final class PendingCacheProtocol: @unchecked Sendable {
    let value: CacheURLProtocol
    let response: CacheResponse

    init(value: CacheURLProtocol, response: CacheResponse) {
        self.value = value
        self.response = response
    }

    func deliver() {
        var headers: [String: String] = [:]
        if let etag = response.etag { headers["Etag"] = etag }
        guard let http = HTTPURLResponse(
            url: value.request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            value.client?.urlProtocol(value, didFailWithError: URLError(.badServerResponse))
            return
        }
        value.client?.urlProtocol(value, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { value.client?.urlProtocol(value, didLoad: response.body) }
        value.client?.urlProtocolDidFinishLoading(value)
    }
}

private enum CacheTransport {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var steps: [CacheStep] = []
    nonisolated(unsafe) private static var received: [URLRequest] = []
    nonisolated(unsafe) private static var pending: [Int: PendingCacheProtocol] = [:]

    static func configure(_ newSteps: [CacheStep]) {
        lock.lock()
        steps = newSteps
        received = []
        pending = [:]
        lock.unlock()
    }

    static func start(_ value: CacheURLProtocol) {
        lock.lock()
        let index = received.count
        received.append(value.request)
        guard steps.indices.contains(index) else {
            lock.unlock()
            value.client?.urlProtocol(value, didFailWithError: URLError(.badServerResponse))
            return
        }
        let step = steps[index]
        let response: CacheResponse
        switch step {
        case let .origin(etag, body, _):
            if value.request.value(forHTTPHeaderField: "If-None-Match") == etag {
                response = CacheResponse(status: 304, etag: nil, body: Data())
            } else {
                response = CacheResponse(status: 200, etag: etag, body: body)
            }
        case .fixed304:
            response = CacheResponse(status: 304, etag: nil, body: Data())
        }
        pending[index] = PendingCacheProtocol(value: value, response: response)
        lock.unlock()

        if !step.waitsForRelease { release(index) }
    }

    static func release(_ index: Int) {
        lock.lock()
        let response = pending.removeValue(forKey: index)
        lock.unlock()
        response?.deliver()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

private final class CacheURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { CacheTransport.start(self) }
    override func stopLoading() {}
}

nonisolated(unsafe) private var failures = 0

private func expect(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

private func waitForRequests(_ expected: Int) async -> Bool {
    for _ in 0..<200 where CacheTransport.requests.count < expected {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return CacheTransport.requests.count >= expected
}

private let etagKey = "vortx.remoteConfig.etag"
private let bodyETagKey = "vortx.remoteConfig.bodyETag"
private let lastFetchKey = "vortx.remoteConfig.lastFetchEpoch"
private let masterDisabledKey = "vortx.remoteConfig.masterDisabled"
private let enabledBody = Data(
    #"{"master":{"remoteConfigEnabled":true},"features":{"trailers":false}}"#.utf8
)
private let validDifferentBody = Data(
    #"{"master":{"remoteConfigEnabled":true},"features":{"trailers":true}}"#.utf8
)

private enum DurableMutation: String, CaseIterable, Sendable {
    case deletion
    case corruption
    case validDifferent

    func apply(file: URL) {
        switch self {
        case .deletion:
            try? FileManager.default.removeItem(at: file)
        case .corruption:
            try? Data("{".utf8).write(to: file, options: .atomic)
        case .validDifferent:
            try? validDifferentBody.write(to: file, options: .atomic)
        }
    }

    func remainsApplied(file: URL) -> Bool {
        switch self {
        case .deletion:
            return !FileManager.default.fileExists(atPath: file.path)
        case .corruption:
            return (try? Data(contentsOf: file)) == Data("{".utf8)
        case .validDifferent:
            return (try? Data(contentsOf: file)) == validDifferentBody
        }
    }
}

private func makeRemote(_ label: String) -> (RemoteConfig, UserDefaults, URL, URL, String) {
    let suiteName = "CacheDeletion304Tests.\(label).\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { fatalError("could not create defaults") }
    defaults.removePersistentDomain(forName: suiteName)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CacheDeletion304Tests-\(label)-\(UUID().uuidString)")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CacheURLProtocol.self]
    let remote = RemoteConfig(
        defaults: defaults,
        cacheDirectory: directory,
        session: URLSession(configuration: configuration)
    )
    return (remote, defaults, directory, directory.appendingPathComponent("config.json"), suiteName)
}

private func runBeforeRequestMutation(_ mutation: DurableMutation) async {
    CacheTransport.configure([
        .origin(etag: "enabled-v1", body: enabledBody, waitsForRelease: false),
        .origin(etag: "enabled-v1", body: enabledBody, waitsForRelease: false),
    ])
    let (remote, defaults, directory, file, suiteName) = makeRemote("before-\(mutation.rawValue)")
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    await remote.refresh()
    expect((try? Data(contentsOf: file)) == enabledBody,
           "before \(mutation.rawValue): setup installs the durable body")
    mutation.apply(file: file)
    defaults.set(101.0, forKey: lastFetchKey)

    await remote.refresh()
    let requests = CacheTransport.requests
    expect(requests.count == 2,
           "before \(mutation.rawValue): repair performs the second request")
    expect(requests.count == 2 && requests[1].value(forHTTPHeaderField: "If-None-Match") == nil,
           "before \(mutation.rawValue): incoherent durable body forces an unconditional request")
    expect((try? Data(contentsOf: file)) == enabledBody,
           "before \(mutation.rawValue): full response repairs the durable body")
    expect(defaults.double(forKey: lastFetchKey) > 101.0,
           "before \(mutation.rawValue): successful full repair advances freshness")
}

private func runDuringRequestMutation(_ mutation: DurableMutation) async {
    CacheTransport.configure([
        .origin(etag: "enabled-v1", body: enabledBody, waitsForRelease: false),
        .fixed304(waitsForRelease: true),
    ])
    let (remote, defaults, directory, file, suiteName) = makeRemote("during-\(mutation.rawValue)")
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    await remote.refresh()
    defaults.set(202.0, forKey: lastFetchKey)
    let conditional = Task { await remote.refresh() }
    guard await waitForRequests(2) else {
        expect(false, "during \(mutation.rawValue): conditional request starts")
        return
    }
    let requests = CacheTransport.requests
    expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "enabled-v1",
           "during \(mutation.rawValue): request begins from coherent durable state")

    mutation.apply(file: file)
    CacheTransport.release(1)
    await conditional.value

    expect(defaults.double(forKey: lastFetchKey) == 202.0,
           "during \(mutation.rawValue): 304 cannot stamp freshness after durable mutation")
    expect(mutation.remainsApplied(file: file),
           "during \(mutation.rawValue): untrusted 304 does not claim to repair the changed body")
}

private func runRequestETagReplacementDuring304() async {
    CacheTransport.configure([
        .origin(etag: "enabled-v1", body: enabledBody, waitsForRelease: false),
        .fixed304(waitsForRelease: true),
    ])
    let (remote, defaults, directory, _, suiteName) = makeRemote("during-validator-replacement")
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    await remote.refresh()
    defaults.set(303.0, forKey: lastFetchKey)
    let conditional = Task { await remote.refresh() }
    guard await waitForRequests(2) else {
        expect(false, "during validator replacement: conditional request starts")
        return
    }
    expect(CacheTransport.requests[1].value(forHTTPHeaderField: "If-None-Match") == "enabled-v1",
           "during validator replacement: request carries the original validator")

    defaults.set("enabled-v2", forKey: etagKey)
    defaults.set("enabled-v2", forKey: bodyETagKey)
    CacheTransport.release(1)
    await conditional.value

    expect(defaults.double(forKey: lastFetchKey) == 303.0,
           "during validator replacement: 304 must match the exact request ETag before stamping")
}

private func runLatchDuring304() async {
    CacheTransport.configure([
        .origin(etag: "enabled-v1", body: enabledBody, waitsForRelease: false),
        .fixed304(waitsForRelease: true),
    ])
    let (remote, defaults, directory, _, suiteName) = makeRemote("during-latch")
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    await remote.refresh()
    defaults.set(404.0, forKey: lastFetchKey)
    let conditional = Task { await remote.refresh() }
    guard await waitForRequests(2) else {
        expect(false, "during latch: conditional request starts")
        return
    }
    defaults.set(true, forKey: masterDisabledKey)
    CacheTransport.release(1)
    await conditional.value

    expect(defaults.double(forKey: lastFetchKey) == 404.0,
           "during latch: 304 cannot stamp after the durable disable appears")
}

private func runOversizedEnabledResponseBound() async {
    let padding = String(repeating: "a", count: 1_048_576)
    let oversized = Data(
        (#"{"master":{"remoteConfigEnabled":true},"features":{"trailers":true},"padding":""#
            + padding + #""}"#).utf8
    )
    CacheTransport.configure([
        .origin(etag: "enabled-v1", body: enabledBody, waitsForRelease: false),
        .origin(etag: "oversized-v2", body: oversized, waitsForRelease: false),
    ])
    let (remote, defaults, directory, file, suiteName) = makeRemote("oversized-enabled-response")
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    await remote.refresh()
    expect((try? Data(contentsOf: file)) == enabledBody,
           "oversized enabled response: setup installs the bounded last-good body")
    defaults.set(505.0, forKey: lastFetchKey)
    await remote.refresh()

    let requests = CacheTransport.requests
    expect(requests.count == 2
               && requests[1].value(forHTTPHeaderField: "If-None-Match") == "enabled-v1",
           "oversized enabled response: request begins from the bounded last-good validator")
    expect((try? Data(contentsOf: file)) == enabledBody,
           "oversized enabled response: response cannot overwrite the durable body")
    expect(defaults.string(forKey: etagKey) == "enabled-v1"
               && defaults.string(forKey: bodyETagKey) == "enabled-v1",
           "oversized enabled response: response cannot advance durable validators")
    expect(defaults.double(forKey: lastFetchKey) == 505.0,
           "oversized enabled response: response cannot stamp freshness")
    expect(!RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
           "oversized enabled response: response cannot replace the in-memory snapshot")
}

private func runOversizedDisableResponseBound() async {
    let padding = String(repeating: "b", count: 1_048_576)
    let oversized = Data(
        (#"{"master":{"remoteConfigEnabled":false},"padding":""# + padding + #""}"#).utf8
    )
    CacheTransport.configure([
        .origin(etag: "enabled-v1", body: enabledBody, waitsForRelease: false),
        .origin(etag: "oversized-disabled-v2", body: oversized, waitsForRelease: false),
    ])
    let (remote, defaults, directory, file, suiteName) = makeRemote("oversized-disable-response")
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    await remote.refresh()
    defaults.set(606.0, forKey: lastFetchKey)
    await remote.refresh()

    expect(!defaults.bool(forKey: masterDisabledKey),
           "oversized disable response: response cannot commit the durable disable latch")
    expect((try? Data(contentsOf: file)) == enabledBody,
           "oversized disable response: response cannot overwrite the durable body")
    expect(defaults.string(forKey: etagKey) == "enabled-v1"
               && defaults.string(forKey: bodyETagKey) == "enabled-v1",
           "oversized disable response: response cannot advance durable validators")
    expect(defaults.double(forKey: lastFetchKey) == 606.0,
           "oversized disable response: response cannot stamp freshness")
    expect(RemoteConfig.snapshot.remoteConfigEnabled,
           "oversized disable response: response cannot replace the in-memory snapshot")
}

@main
private struct CacheDeletion304Tests {
    static func main() async {
        for mutation in DurableMutation.allCases {
            await runBeforeRequestMutation(mutation)
        }
        for mutation in DurableMutation.allCases {
            await runDuringRequestMutation(mutation)
        }
        await runRequestETagReplacementDuring304()
        await runLatchDuring304()
        await runOversizedEnabledResponseBound()
        await runOversizedDisableResponseBound()

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
