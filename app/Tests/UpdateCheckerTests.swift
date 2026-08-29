// Focused executable for the in-app updater's retry, cadence, and release parsing contracts:
//
//   xcrun swiftc -parse-as-library -o /tmp/update-checker-tests \
//     app/SourcesShared/UpdateChecker.swift app/Tests/UpdateCheckerTests.swift && /tmp/update-checker-tests

import Foundation

actor ScriptedLoader {
    enum Failure: Error { case exhausted }

    private var results: [Result<(Data, URLResponse), Error>]
    private(set) var calls = 0

    init(_ results: [Result<(Data, URLResponse), Error>]) { self.results = results }

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        calls += 1
        guard !results.isEmpty else { throw Failure.exhausted }
        return try results.removeFirst().get()
    }
}

actor ControlledSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuations.append($0) }
    }

    var waitingCount: Int { continuations.count }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

final class TestClock: @unchecked Sendable {
    var seconds: TimeInterval
    init(_ seconds: TimeInterval) { self.seconds = seconds }
    func date() -> Date { Date(timeIntervalSince1970: seconds) }
}

func response(_ status: Int) -> URLResponse {
    HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: status,
                    httpVersion: nil, headerFields: nil)!
}

func release(build: Int, body: String = "") -> Data {
    let fixture = """
    [{"tag_name":"v0.3.15","name":"VortX 0.3.15 (Build \(build))","body":"\(body)","draft":false,"prerelease":false,"published_at":"2026-08-30T00:00:00Z","assets":[{"name":"VortX-macOS.dmg","browser_download_url":"https://example.invalid/VortX-macOS.dmg"}]}]
    """
    return Data(fixture.utf8)
}

func waitForCalls(_ loader: ScriptedLoader, _ count: Int) async {
    for _ in 0..<100 {
        if await loader.calls >= count { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func waitForAvailable(_ checker: UpdateChecker, build: Int) async {
    for _ in 0..<100 {
        if await MainActor.run(body: { checker.available?.build == build }) { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func waitForSleeper(_ sleeper: ControlledSleeper, _ count: Int) async {
    for _ in 0..<100 {
        if await sleeper.waitingCount >= count { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@main
struct UpdateCheckerTests {
    static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { print("PASS  \(message)") }
            else { failures += 1; print("FAIL  \(message)") }
        }

        let suiteName = "UpdateCheckerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A published beta checked on one launch must not prevent a later foreground/cold launch from seeing
        // the stable build after the hourly cadence has elapsed.
        let betaLoader = ScriptedLoader([.success((release(build: 232), response(200)))])
        let beta = await MainActor.run {
            UpdateChecker(defaults: defaults, now: { Date(timeIntervalSince1970: 100_000) },
                          requestLoader: { request in try await betaLoader.load(request) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { beta.startMonitoring() }
        await waitForCalls(betaLoader, 1)
        await waitForAvailable(beta, build: 232)
        let betaBuild = await MainActor.run { beta.available?.build }
        check(betaBuild == 232, "published beta is discovered")

        let stableLoader = ScriptedLoader([.success((release(build: 233), response(200)))])
        let stable = await MainActor.run {
            UpdateChecker(defaults: defaults, now: { Date(timeIntervalSince1970: 103_601) },
                          requestLoader: { request in try await stableLoader.load(request) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { stable.startMonitoring() }
        await waitForCalls(stableLoader, 1)
        await waitForAvailable(stable, build: 233)
        let stableBuild = await MainActor.run { stable.available?.build }
        check(stableBuild == 233, "later launch refreshes to current stable build")

        // A non-200 response must not consume the automatic check budget. The next active call retries.
        let retryDefaults = UserDefaults(suiteName: "\(suiteName).retry")!
        defer { retryDefaults.removePersistentDomain(forName: "\(suiteName).retry") }
        let retryLoader = ScriptedLoader([.success((Data("[]".utf8), response(503))),
                                         .success((Data("not a release payload".utf8), response(200))),
                                         .success((release(build: 233), response(200)))])
        let retry = await MainActor.run {
            UpdateChecker(defaults: retryDefaults, now: { Date(timeIntervalSince1970: 200_000) },
                          requestLoader: { request in try await retryLoader.load(request) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { retry.checkIfStale() }
        await waitForCalls(retryLoader, 1)
        await MainActor.run { retry.checkIfStale() }
        await waitForCalls(retryLoader, 2)
        await MainActor.run { retry.checkIfStale() }
        await waitForCalls(retryLoader, 3)
        await waitForAvailable(retry, build: 233)
        let retryCalls = await retryLoader.calls
        let retryBuild = await MainActor.run { retry.available?.build }
        check(retryCalls == 3, "non-200 and decode failures both remain retryable")
        check(retryBuild == 233, "retry can surface the update")

        // Release notes can contain historical build markers. The title is the canonical marker for this
        // release and must win over those older values.
        let historicalLoader = ScriptedLoader([.success((release(build: 233, body: "Build 221; Build 232"), response(200)))])
        let historical = await MainActor.run {
            UpdateChecker(defaults: UserDefaults(suiteName: "\(suiteName).history")!,
                          now: { Date(timeIntervalSince1970: 300_000) },
                          requestLoader: { request in try await historicalLoader.load(request) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { historical.checkIfStale() }
        await waitForCalls(historicalLoader, 1)
        await waitForAvailable(historical, build: 233)
        let historicalBuild = await MainActor.run { historical.available?.build }
        check(historicalBuild == 233, "canonical title build wins over historical body markers")

        // A persisted success from a former process cannot hide a release on this process's cold launch.
        // The same controllable sleeper proves one hourly loop, repeated starts, and clean cancellation.
        let schedulerDefaults = UserDefaults(suiteName: "\(suiteName).scheduler")!
        defer { schedulerDefaults.removePersistentDomain(forName: "\(suiteName).scheduler") }
        schedulerDefaults.set(400_000, forKey: "stremiox.update.lastChecked")
        let schedulerLoader = ScriptedLoader([.success((release(build: 233), response(200))),
                                              .success((release(build: 234), response(200)))])
        let sleeper = ControlledSleeper()
        let clock = TestClock(400_001)
        let scheduled = await MainActor.run {
            UpdateChecker(defaults: schedulerDefaults, now: { clock.date() },
                          requestLoader: { request in try await schedulerLoader.load(request) },
                          sleeper: { seconds in await sleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { scheduled.startMonitoring(); scheduled.startMonitoring() }
        await waitForCalls(schedulerLoader, 1)
        await waitForSleeper(sleeper, 1)
        let initialCalls = await schedulerLoader.calls
        check(initialCalls == 1, "cold launch ignores prior process timestamp and repeated starts stay single-flight")

        clock.seconds += 3_600
        await sleeper.resumeNext()
        await waitForCalls(schedulerLoader, 2)
        check(await schedulerLoader.calls == 2, "unattended scheduler performs the hourly request")

        await waitForSleeper(sleeper, 1)
        await MainActor.run { scheduled.stopMonitoring() }
        await sleeper.resumeNext()
        try? await Task.sleep(for: .milliseconds(20))
        check(await schedulerLoader.calls == 2, "suspension cancels the pending hourly scheduler")

        exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
