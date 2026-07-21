// Standalone production-linked concurrency harness for RemoteConfig:
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/RemoteConfig.swift \
//     app/Tests/ConcurrentRefreshReorderTests.swift \
//     -o /tmp/concurrent-refresh-reorder-test && \
//   /tmp/concurrent-refresh-reorder-test
//
// The transport holds responses so the test can prove whether actor-reentrant refresh calls overlap. The real
// RemoteConfig actor performs all request scheduling, persistence, and state installation.

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
        let zero = SourceIndexLifecycleSnapshot(sourceGeneration: 0, sessionGeneration: 0, consentGeneration: 0)
        return SourceIndexLifecycleTransition(
            retired: zero,
            current: zero,
            retiredSession: false,
            retiredConsent: false
        )
    }
}

private enum TestOutcome: Sendable {
    case http(status: Int, etag: String?, body: Data)
    case offline
}

private struct TestStep: Sendable {
    let outcome: TestOutcome
    let waitsForRelease: Bool
}

private final class PendingProtocol: @unchecked Sendable {
    let value: ControlledURLProtocol
    let outcome: TestOutcome

    init(value: ControlledURLProtocol, outcome: TestOutcome) {
        self.value = value
        self.outcome = outcome
    }

    func deliver() {
        switch outcome {
        case .offline:
            value.client?.urlProtocol(value, didFailWithError: URLError(.notConnectedToInternet))
        case let .http(status, etag, body):
            var headers: [String: String] = [:]
            if let etag { headers["Etag"] = etag }
            guard let response = HTTPURLResponse(
                url: value.request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                value.client?.urlProtocol(value, didFailWithError: URLError(.badServerResponse))
                return
            }
            value.client?.urlProtocol(value, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { value.client?.urlProtocol(value, didLoad: body) }
            value.client?.urlProtocolDidFinishLoading(value)
        }
    }
}

private enum ControlledTransport {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var steps: [TestStep] = []
    nonisolated(unsafe) private static var pending: [Int: PendingProtocol] = [:]
    nonisolated(unsafe) private static var received: [URLRequest] = []
    nonisolated(unsafe) private static var active = 0
    nonisolated(unsafe) private static var maximumActive = 0
    nonisolated(unsafe) private static var completed = 0

    static func configure(_ newSteps: [TestStep]) {
        lock.lock()
        steps = newSteps
        pending = [:]
        received = []
        active = 0
        maximumActive = 0
        completed = 0
        lock.unlock()
    }

    static func start(_ value: ControlledURLProtocol) {
        lock.lock()
        let index = received.count
        received.append(value.request)
        guard steps.indices.contains(index) else {
            lock.unlock()
            value.client?.urlProtocol(value, didFailWithError: URLError(.badServerResponse))
            return
        }
        let step = steps[index]
        active += 1
        maximumActive = max(maximumActive, active)
        pending[index] = PendingProtocol(value: value, outcome: step.outcome)
        lock.unlock()

        if !step.waitsForRelease { release(index) }
    }

    static func release(_ index: Int) {
        lock.lock()
        guard let response = pending.removeValue(forKey: index) else {
            lock.unlock()
            return
        }
        active -= 1
        lock.unlock()

        response.deliver()

        lock.lock()
        completed += 1
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return received.count
    }

    static var completedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    static var maxActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActive
    }
}

private final class ControlledURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { ControlledTransport.start(self) }
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

private func waitForRequests(_ expected: Int, attempts: Int = 200) async -> Bool {
    for _ in 0..<attempts where ControlledTransport.requestCount < expected {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return ControlledTransport.requestCount >= expected
}

private func waitForCompletions(_ expected: Int) async -> Bool {
    for _ in 0..<200 where ControlledTransport.completedCount < expected {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return ControlledTransport.completedCount >= expected
}

private func makeRemote(_ label: String) -> (RemoteConfig, UserDefaults, URL, String) {
    let suiteName = "ConcurrentRefreshReorderTests.\(label).\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { fatalError("could not create defaults") }
    defaults.removePersistentDomain(forName: suiteName)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConcurrentRefreshReorderTests-\(label)-\(UUID().uuidString)")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledURLProtocol.self]
    return (
        RemoteConfig(
            defaults: defaults,
            cacheDirectory: directory,
            session: URLSession(configuration: configuration)
        ),
        defaults,
        directory,
        suiteName
    )
}

private func runReorderScenario(
    label: String,
    first: TestOutcome,
    second: TestOutcome,
    expectedEnabled: Bool
) async {
    ControlledTransport.configure([
        TestStep(outcome: first, waitsForRelease: true),
        TestStep(outcome: second, waitsForRelease: true),
    ])
    let (remote, defaults, directory, suiteName) = makeRemote(label)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    let owner = Task { await remote.refresh() }
    guard await waitForRequests(1) else {
        expect(false, "\(label): first request starts")
        return
    }
    let overlap = Task { await remote.refresh() }

    // The blocked implementation starts request two immediately. The corrected implementation records a pending
    // trigger and starts it only after request one finishes. Branching lets the same harness finish either shape.
    let overlappedOnWire = await waitForRequests(2, attempts: 40)
    if overlappedOnWire {
        ControlledTransport.release(1)
        _ = await waitForCompletions(1)
        ControlledTransport.release(0)
    } else {
        ControlledTransport.release(0)
        guard await waitForRequests(2) else {
            expect(false, "\(label): overlap schedules a follow-up request")
            await owner.value
            await overlap.value
            return
        }
        ControlledTransport.release(1)
    }

    await owner.value
    await overlap.value
    expect(ControlledTransport.requestCount == 2,
           "\(label): one overlapping trigger produces one follow-up request")
    expect(ControlledTransport.maxActive == 1,
           "\(label): transport requests are serialized")
    expect(RemoteConfig.snapshot.remoteConfigEnabled == expectedEnabled,
           "\(label): final installed state follows serialized response order")
}

private func runFinalCheckScenario() async {
    let enabled = Data(#"{"master":{"remoteConfigEnabled":true}}"#.utf8)
    let disabled = Data(#"{"master":{"remoteConfigEnabled":false}}"#.utf8)
    ControlledTransport.configure([
        TestStep(outcome: .http(status: 200, etag: "final-gap-true", body: enabled), waitsForRelease: true),
        TestStep(outcome: .http(status: 200, etag: "final-gap-false", body: disabled), waitsForRelease: false),
    ])
    let (remote, defaults, directory, suiteName) = makeRemote("final-check")
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    let owner = Task { await remote.refresh() }
    guard await waitForRequests(1) else {
        expect(false, "final check: first request starts")
        return
    }
    ControlledTransport.release(0)
    _ = await waitForCompletions(1)

    // A target-drop mutant inserts a suspension between the final pending check and owner clear. This delay places
    // the trigger inside that mutant-only window. Without a suspension, it either becomes pending or the next owner.
    try? await Task.sleep(for: .milliseconds(50))
    let boundaryTrigger = Task { await remote.refresh() }
    await boundaryTrigger.value
    await owner.value
    let reran = await waitForRequests(2)

    expect(reran, "final check: trigger cannot be lost between pending check and owner clear")
    expect(ControlledTransport.maxActive == 1,
           "final check: boundary trigger still keeps transport serialized")
    expect(RemoteConfig.snapshot.remoteConfigEnabled == false,
           "final check: boundary trigger applies its disabling follow-up")
}

@main
private struct ConcurrentRefreshReorderTests {
    static func main() async {
        let enabledOld = Data(#"{"master":{"remoteConfigEnabled":true},"features":{"trailers":true}}"#.utf8)
        let disabledNew = Data(#"{"master":{"remoteConfigEnabled":false}}"#.utf8)
        await runReorderScenario(
            label: "older-true-pending-false",
            first: .http(status: 200, etag: "enabled-old", body: enabledOld),
            second: .http(status: 200, etag: "disabled-new", body: disabledNew),
            expectedEnabled: false
        )

        let disabledOld = Data(#"{"master":{"remoteConfigEnabled":false}}"#.utf8)
        let enabledNew = Data(#"{"master":{"remoteConfigEnabled":true},"features":{"trailers":false}}"#.utf8)
        await runReorderScenario(
            label: "older-false-pending-true",
            first: .http(status: 200, etag: "disabled-old", body: disabledOld),
            second: .http(status: 200, etag: "enabled-new", body: enabledNew),
            expectedEnabled: true
        )

        await runReorderScenario(
            label: "valid-false-pending-failure",
            first: .http(status: 200, etag: "disabled-valid", body: disabledOld),
            second: .offline,
            expectedEnabled: false
        )

        await runFinalCheckScenario()

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
