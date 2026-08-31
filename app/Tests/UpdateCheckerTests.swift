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
        // Existing fixtures exercise the GitHub fallback. The production checker always probes the appcast first.
        if request.url?.host == "vortx.tv" { return (Data("{}".utf8), response(503)) }
        calls += 1
        guard !results.isEmpty else { throw Failure.exhausted }
        return try results.removeFirst().get()
    }
}

actor ControlledSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var durations: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async {
        durations.append(seconds)
        await withCheckedContinuation { continuations.append($0) }
    }

    var waitingCount: Int { continuations.count }
    func duration(at index: Int) -> TimeInterval? { durations.indices.contains(index) ? durations[index] : nil }

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

actor LatencyLoader {
    private let clock: TestClock
    private let latency: TimeInterval
    private let result: (Data, URLResponse)
    private(set) var calls = 0

    init(clock: TestClock, latency: TimeInterval, result: (Data, URLResponse)) {
        self.clock = clock
        self.latency = latency
        self.result = result
    }

    func load(_ request: URLRequest) -> (Data, URLResponse) {
        if request.url?.host == "vortx.tv" { return (Data("{}".utf8), response(503)) }
        calls += 1
        clock.seconds += latency
        return result
    }
}

actor GateLoader {
    private var continuation: CheckedContinuation<Void, Never>?
    private let gatedCalls: Set<Int>
    private let result: (Data, URLResponse)
    private(set) var calls = 0

    init(_ result: (Data, URLResponse), gatedCall: Int = 1) {
        self.result = result
        self.gatedCalls = [gatedCall]
    }

    init(_ result: (Data, URLResponse), gatedCalls: Set<Int>) {
        self.result = result
        self.gatedCalls = gatedCalls
    }

    func load(_ request: URLRequest) async -> (Data, URLResponse) {
        if request.url?.host == "vortx.tv" { return (Data("{}".utf8), response(503)) }
        calls += 1
        if gatedCalls.contains(calls) {
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }

    func resumeFirst() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

actor RoutedLoader {
    private let appcast: Result<(Data, URLResponse), Error>
    private let github: Result<(Data, URLResponse), Error>
    private let preserveResponseURL: Bool
    private(set) var requestedHosts: [String] = []

    init(appcast: Result<(Data, URLResponse), Error>, github: Result<(Data, URLResponse), Error>,
         preserveResponseURL: Bool = false) {
        self.appcast = appcast
        self.github = github
        self.preserveResponseURL = preserveResponseURL
    }

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        let host = request.url?.host ?? ""
        requestedHosts.append(host)
        let (data, originalResponse) = try (host == "vortx.tv" ? appcast : github).get()
        let status = (originalResponse as? HTTPURLResponse)?.statusCode ?? 200
        return (data, preserveResponseURL ? originalResponse : response(status, url: request.url!))
    }

    var appcastCalls: Int { requestedHosts.filter { $0 == "vortx.tv" }.count }
    var githubCalls: Int { requestedHosts.filter { $0 == "api.github.com" }.count }
}

func response(_ status: Int, url: URL = URL(string: "https://api.github.com/repos/VortXTV/VortX/releases?per_page=20")!) -> URLResponse {
    HTTPURLResponse(url: url, statusCode: status,
                    httpVersion: nil, headerFields: nil)!
}

func release(build: Int, body: String = "", tag: String = "v0.3.15", assetName: String? = nil) -> Data {
    let resolvedAssetName = assetName ?? "VortX-macOS-\(tag)-ci.dmg"
    let version = String(tag.dropFirst().split(separator: "-", maxSplits: 1)[0])
    let fixture = """
    [{"tag_name":"\(tag)","name":"VortX \(version) (Build \(build))","body":"\(body)","draft":false,"prerelease":false,"published_at":"2026-08-30T00:00:00Z","assets":[{"name":"\(resolvedAssetName)","browser_download_url":"https://github.com/VortXTV/VortX/releases/download/\(tag)/\(resolvedAssetName)"}]}]
    """
    return Data(fixture.utf8)
}

func appcast(version: String, build: Int) -> Data {
    let sha256 = String(repeating: "a", count: 64)
    let fixture = """
    {"schemaVersion":2,
     "ios":{"tag":"v\(version)","version":"\(version)","build":\(build),"name":"VortX \(version) (build \(build))","notes":"Release notes","ipa":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-iOS-v\(version)-ci.ipa","url":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-iOS-v\(version)-ci.ipa","size":101,"sha256":"\(sha256)","altstore":"https://vortx.tv/altstore.json","artifactType":"ipa"},
     "tvos":{"tag":"v\(version)","version":"\(version)","build":\(build),"name":"VortX \(version) (build \(build))","notes":"Release notes","ipa":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-tvOS-v\(version)-ci.ipa","url":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-tvOS-v\(version)-ci.ipa","size":102,"sha256":"\(sha256)","altstore":null,"artifactType":"ipa"},
     "mac":{"tag":"v\(version)","version":"\(version)","build":\(build),"name":"VortX \(version) (build \(build))","notes":"Release notes","ipa":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-macOS-v\(version)-ci.dmg","url":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-macOS-v\(version)-ci.dmg","size":103,"sha256":"\(sha256)","altstore":null,"artifactType":"dmg"}}
    """
    return Data(fixture.utf8)
}

func waitForCalls(_ loader: ScriptedLoader, _ count: Int) async {
    for _ in 0..<100 {
        if await loader.calls >= count { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func waitForCalls(_ loader: LatencyLoader, _ count: Int) async {
    for _ in 0..<100 {
        if await loader.calls >= count { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func waitForCalls(_ loader: GateLoader, _ count: Int) async {
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

func waitForManualCheckToFinish(_ checker: UpdateChecker) async {
    for _ in 0..<100 {
        if !(await MainActor.run(body: { checker.isManualCheckInProgress })) { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func manualOutcome(_ checker: UpdateChecker) async -> UpdateChecker.ManualCheckOutcome {
    await MainActor.run { checker.manualOutcome }
}

func waitForManualOutcome(_ checker: UpdateChecker, _ expected: UpdateChecker.ManualCheckOutcome) async {
    for _ in 0..<100 {
        if await manualOutcome(checker) == expected { return }
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

        // The hourly delay begins when the accepted response completes, not when the request started.
        let latencyDefaults = UserDefaults(suiteName: "\(suiteName).latency")!
        defer { latencyDefaults.removePersistentDomain(forName: "\(suiteName).latency") }
        let latencyClock = TestClock(500_000)
        let latencySleeper = ControlledSleeper()
        let latencyLoader = LatencyLoader(clock: latencyClock, latency: 120,
                                          result: (release(build: 233), response(200)))
        let latencyChecked = await MainActor.run {
            UpdateChecker(defaults: latencyDefaults, now: { latencyClock.date() },
                          requestLoader: { request in await latencyLoader.load(request) },
                          sleeper: { seconds in await latencySleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { latencyChecked.startMonitoring() }
        await waitForCalls(latencyLoader, 1)
        await waitForSleeper(latencySleeper, 1)
        check(await latencySleeper.duration(at: 0) == 3_600, "hourly deadline is measured from successful completion")
        latencyClock.seconds += 3_600
        await latencySleeper.resumeNext()
        await waitForCalls(latencyLoader, 2)
        check(await latencyLoader.calls == 2, "successful completion schedules the next unattended check exactly one hour later")

        // A failure after a successful hourly check must override the old successful timestamp. Otherwise the
        // replacement task computes a zero delay and hammers the endpoints instead of respecting the retry floor.
        let postSuccessFailureDefaults = UserDefaults(suiteName: "\(suiteName).post-success-failure")!
        defer { postSuccessFailureDefaults.removePersistentDomain(forName: "\(suiteName).post-success-failure") }
        let postSuccessFailureClock = TestClock(600_000)
        let postSuccessFailureSleeper = ControlledSleeper()
        let postSuccessFailureLoader = ScriptedLoader([.success((release(build: 233), response(200))),
                                                       .success((Data("[]".utf8), response(503)))])
        let postSuccessFailure = await MainActor.run {
            UpdateChecker(defaults: postSuccessFailureDefaults, now: { postSuccessFailureClock.date() },
                          requestLoader: { request in try await postSuccessFailureLoader.load(request) },
                          sleeper: { seconds in await postSuccessFailureSleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { postSuccessFailure.startMonitoring() }
        await waitForCalls(postSuccessFailureLoader, 1)
        await waitForSleeper(postSuccessFailureSleeper, 1)
        postSuccessFailureClock.seconds += 3_600
        await postSuccessFailureSleeper.resumeNext()
        await waitForCalls(postSuccessFailureLoader, 2)
        await waitForSleeper(postSuccessFailureSleeper, 1)
        let postSuccessFailureRetryDelay = await postSuccessFailureSleeper.duration(at: 1)
        check(postSuccessFailureRetryDelay == 60,
              "failure after a successful hourly check uses the 60-second retry floor")
        try? await Task.sleep(for: .milliseconds(20))
        check(await postSuccessFailureLoader.calls == 2,
              "post-success failure does not immediately hot-retry")
        await MainActor.run { postSuccessFailure.stopMonitoring() }
        await postSuccessFailureSleeper.resumeNext()

        // A forced cold-launch request that fails cannot inherit a former process's recent success as a long
        // suppression window. A stop/start foreground cycle retains the short retry cadence.
        let failedDefaults = UserDefaults(suiteName: "\(suiteName).failed")!
        defer { failedDefaults.removePersistentDomain(forName: "\(suiteName).failed") }
        failedDefaults.set(700_000, forKey: "stremiox.update.lastChecked")
        let failedSleeper = ControlledSleeper()
        let failedLoader = ScriptedLoader([.success((Data("[]".utf8), response(503))),
                                           .success((release(build: 233), response(200)))])
        let failed = await MainActor.run {
            UpdateChecker(defaults: failedDefaults, now: { Date(timeIntervalSince1970: 700_001) },
                          requestLoader: { request in try await failedLoader.load(request) },
                          sleeper: { seconds in await failedSleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { failed.startMonitoring() }
        await waitForCalls(failedLoader, 1)
        await waitForSleeper(failedSleeper, 1)
        check(await failedSleeper.duration(at: 0) == 60, "failed cold launch schedules a short retry despite recent persisted success")
        await MainActor.run { failed.stopMonitoring(); failed.startMonitoring() }
        await waitForSleeper(failedSleeper, 2)
        await failedSleeper.resumeNext() // cancelled pre-foreground task
        await failedSleeper.resumeNext() // foreground task
        await waitForCalls(failedLoader, 2)
        check(await failedLoader.calls == 2, "foreground after failed cold launch retries without inheriting the old timestamp")

        // A manual success after a failed automatic request replaces the pending 60-second retry with a normal
        // hourly deadline. Otherwise the user can recover in Settings and still receive a redundant retry.
        let recoveryDefaults = UserDefaults(suiteName: "\(suiteName).manual-recovery")!
        defer { recoveryDefaults.removePersistentDomain(forName: "\(suiteName).manual-recovery") }
        let recoverySleeper = ControlledSleeper()
        let recoveryLoader = ScriptedLoader([.success((Data("[]".utf8), response(503))),
                                            .success((release(build: 233), response(200)))])
        let recovery = await MainActor.run {
            UpdateChecker(defaults: recoveryDefaults, now: { Date(timeIntervalSince1970: 750_000) },
                          requestLoader: { request in try await recoveryLoader.load(request) },
                          sleeper: { seconds in await recoverySleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { recovery.startMonitoring() }
        await waitForCalls(recoveryLoader, 1)
        await waitForSleeper(recoverySleeper, 1)
        check(await recoverySleeper.duration(at: 0) == 60, "automatic failure first arms a short retry")
        await MainActor.run { recovery.checkNow() }
        await waitForCalls(recoveryLoader, 2)
        await waitForManualCheckToFinish(recovery)
        await waitForSleeper(recoverySleeper, 2)
        check(await recoverySleeper.duration(at: 1) == 3_600,
              "successful manual recovery replaces the short retry with the hourly deadline")
        await MainActor.run { recovery.stopMonitoring() }
        await recoverySleeper.resumeNext()
        await recoverySleeper.resumeNext()

        // An in-flight initial request cannot re-arm monitoring after the app becomes inactive.
        let stoppedDefaults = UserDefaults(suiteName: "\(suiteName).stopped")!
        defer { stoppedDefaults.removePersistentDomain(forName: "\(suiteName).stopped") }
        let stoppedSleeper = ControlledSleeper()
        let stoppedLoader = GateLoader((release(build: 233), response(200)))
        let stopped = await MainActor.run {
            UpdateChecker(defaults: stoppedDefaults, now: { Date(timeIntervalSince1970: 800_000) },
                          requestLoader: { request in await stoppedLoader.load(request) },
                          sleeper: { seconds in await stoppedSleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { stopped.startMonitoring() }
        await waitForCalls(stoppedLoader, 1)
        await MainActor.run { stopped.stopMonitoring() }
        await stoppedLoader.resumeFirst()
        try? await Task.sleep(for: .milliseconds(20))
        check(await stoppedSleeper.waitingCount == 0, "stop during initial request leaves no stale scheduler")

        // Stop/start while the old generation is in-flight may start one fresh generation after it completes,
        // but the stale completion cannot create a second timer or replace that newer generation.
        let restartDefaults = UserDefaults(suiteName: "\(suiteName).restart")!
        defer { restartDefaults.removePersistentDomain(forName: "\(suiteName).restart") }
        let restartSleeper = ControlledSleeper()
        let restartLoader = GateLoader((release(build: 233), response(200)))
        let restarted = await MainActor.run {
            UpdateChecker(defaults: restartDefaults, now: { Date(timeIntervalSince1970: 900_000) },
                          requestLoader: { request in await restartLoader.load(request) },
                          sleeper: { seconds in await restartSleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { restarted.startMonitoring() }
        await waitForCalls(restartLoader, 1)
        await MainActor.run { restarted.stopMonitoring(); restarted.startMonitoring() }
        await restartLoader.resumeFirst()
        await waitForCalls(restartLoader, 2)
        await waitForSleeper(restartSleeper, 1)
        check(await restartSleeper.waitingCount == 1, "stop/start stale completion creates only the new generation scheduler")
        await MainActor.run { restarted.stopMonitoring() }
        await restartSleeper.resumeNext()

        // The same invalidation applies to an in-flight scheduled request, not just the launch request.
        let scheduledStopDefaults = UserDefaults(suiteName: "\(suiteName).scheduled-stop")!
        defer { scheduledStopDefaults.removePersistentDomain(forName: "\(suiteName).scheduled-stop") }
        let scheduledStopSleeper = ControlledSleeper()
        let scheduledStopLoader = GateLoader((release(build: 233), response(200)), gatedCall: 2)
        let scheduledStopClock = TestClock(1_000_000)
        let scheduledStop = await MainActor.run {
            UpdateChecker(defaults: scheduledStopDefaults, now: { scheduledStopClock.date() },
                          requestLoader: { request in await scheduledStopLoader.load(request) },
                          sleeper: { seconds in await scheduledStopSleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { scheduledStop.startMonitoring() }
        await waitForSleeper(scheduledStopSleeper, 1)
        scheduledStopClock.seconds += 3_600
        await scheduledStopSleeper.resumeNext()
        await waitForCalls(scheduledStopLoader, 2)
        await MainActor.run { scheduledStop.stopMonitoring() }
        await scheduledStopLoader.resumeFirst()
        try? await Task.sleep(for: .milliseconds(20))
        check(await scheduledStopSleeper.waitingCount == 0, "stop during scheduled request leaves no replacement scheduler")

        // An explicit check reports current instead of failing silently. It does not use the automatic cadence
        // timestamp, so the result is always fresh and visible to Settings.
        let currentDefaults = UserDefaults(suiteName: "\(suiteName).manual-current")!
        defer { currentDefaults.removePersistentDomain(forName: "\(suiteName).manual-current") }
        let currentLoader = ScriptedLoader([.success((release(build: 233), response(200)))])
        let current = await MainActor.run {
            UpdateChecker(defaults: currentDefaults, now: { Date(timeIntervalSince1970: 1_100_000) },
                          requestLoader: { request in try await currentLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { current.checkNow() }
        await waitForCalls(currentLoader, 1)
        await waitForManualCheckToFinish(current)
        check(await manualOutcome(current) == .upToDate, "manual current check publishes an up-to-date result")

        // HTTP failures become an explicit retryable outcome. No raw request, decoder, or server error leaks
        // through the observable UI contract.
        let manualFailureDefaults = UserDefaults(suiteName: "\(suiteName).manual-failure")!
        defer { manualFailureDefaults.removePersistentDomain(forName: "\(suiteName).manual-failure") }
        let manualFailureLoader = ScriptedLoader([.success((Data("[]".utf8), response(503)))])
        let manualFailure = await MainActor.run {
            UpdateChecker(defaults: manualFailureDefaults, now: { Date(timeIntervalSince1970: 1_200_000) },
                          requestLoader: { request in try await manualFailureLoader.load(request) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { manualFailure.checkNow() }
        await waitForCalls(manualFailureLoader, 1)
        await waitForManualCheckToFinish(manualFailure)
        check(await manualOutcome(manualFailure) == .failure, "manual HTTP failure publishes a retryable failure")

        // A later successful automatic result owns the overall discovery state and retires an old manual
        // terminal outcome, whether that automatic result says current or finds a newer build.
        let automaticCurrentDefaults = UserDefaults(suiteName: "\(suiteName).automatic-after-manual-current")!
        defer { automaticCurrentDefaults.removePersistentDomain(forName: "\(suiteName).automatic-after-manual-current") }
        let automaticCurrentLoader = ScriptedLoader([.success((Data("[]".utf8), response(503))),
                                                     .success((release(build: 233), response(200)))])
        let automaticCurrent = await MainActor.run {
            UpdateChecker(defaults: automaticCurrentDefaults, now: { Date(timeIntervalSince1970: 1_250_000) },
                          requestLoader: { request in try await automaticCurrentLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { automaticCurrent.checkNow() }
        await waitForManualCheckToFinish(automaticCurrent)
        await MainActor.run { automaticCurrent.checkIfStale() }
        await waitForCalls(automaticCurrentLoader, 2)
        await waitForManualOutcome(automaticCurrent, .idle)
        check(await manualOutcome(automaticCurrent) == .idle,
              "automatic current result clears stale manual failure feedback")

        let automaticNewerDefaults = UserDefaults(suiteName: "\(suiteName).automatic-after-manual-newer")!
        defer { automaticNewerDefaults.removePersistentDomain(forName: "\(suiteName).automatic-after-manual-newer") }
        let automaticNewerLoader = ScriptedLoader([.success((Data("[]".utf8), response(503))),
                                                   .success((release(build: 234), response(200)))])
        let automaticNewer = await MainActor.run {
            UpdateChecker(defaults: automaticNewerDefaults, now: { Date(timeIntervalSince1970: 1_260_000) },
                          requestLoader: { request in try await automaticNewerLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { automaticNewer.checkNow() }
        await waitForManualCheckToFinish(automaticNewer)
        await MainActor.run { automaticNewer.checkIfStale() }
        await waitForCalls(automaticNewerLoader, 2)
        await waitForManualOutcome(automaticNewer, .idle)
        let automaticNewerOutcome = await manualOutcome(automaticNewer)
        let automaticNewerBuild = await MainActor.run { automaticNewer.available?.build }
        check(automaticNewerOutcome == .idle && automaticNewerBuild == 234,
              "automatic newer result clears stale manual failure feedback")

        // A newer release publishes the typed outcome and still emits the existing forced-presentation signal.
        let manualUpdateDefaults = UserDefaults(suiteName: "\(suiteName).manual-update")!
        defer { manualUpdateDefaults.removePersistentDomain(forName: "\(suiteName).manual-update") }
        let manualUpdateLoader = ScriptedLoader([.success((release(build: 233), response(200)))])
        let manualUpdate = await MainActor.run {
            UpdateChecker(defaults: manualUpdateDefaults, now: { Date(timeIntervalSince1970: 1_300_000) },
                          requestLoader: { request in try await manualUpdateLoader.load(request) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { manualUpdate.checkNow() }
        await waitForCalls(manualUpdateLoader, 1)
        await waitForManualCheckToFinish(manualUpdate)
        let updateOutcome = await manualOutcome(manualUpdate)
        let discoveredManualBuild: Int?
        if case .updateAvailable(let release) = updateOutcome { discoveredManualBuild = release.build }
        else { discoveredManualBuild = nil }
        let manualPresentationNonce = await MainActor.run { manualUpdate.forcePresentationNonce }
        check(discoveredManualBuild == 233, "manual newer check publishes the discovered release")
        check(manualPresentationNonce == 1, "manual newer check preserves the existing forced-presentation signal")

        // A Settings request made while automatic monitoring is in flight remains single-flight, then performs
        // its own forced request after the automatic response completes.
        let queuedDefaults = UserDefaults(suiteName: "\(suiteName).manual-queued")!
        defer { queuedDefaults.removePersistentDomain(forName: "\(suiteName).manual-queued") }
        let queuedLoader = GateLoader((release(build: 233), response(200)))
        let queued = await MainActor.run {
            UpdateChecker(defaults: queuedDefaults, now: { Date(timeIntervalSince1970: 1_400_000) },
                          requestLoader: { request in await queuedLoader.load(request) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { queued.startMonitoring() }
        await waitForCalls(queuedLoader, 1)
        await MainActor.run { queued.checkNow() }
        check(await queuedLoader.calls == 1, "manual request queues behind the automatic in-flight request")
        check(await MainActor.run { queued.isManualCheckInProgress }, "queued manual request remains visibly checking")
        await queuedLoader.resumeFirst()
        await waitForCalls(queuedLoader, 2)
        await waitForManualCheckToFinish(queued)
        let queuedOutcome = await manualOutcome(queued)
        let queuedBuild: Int?
        if case .updateAvailable(let release) = queuedOutcome { queuedBuild = release.build }
        else { queuedBuild = nil }
        check(queuedBuild == 233, "queued manual request ultimately performs its forced check")
        check(await queuedLoader.calls == 2, "queued manual request never overlaps the automatic request")
        await MainActor.run { queued.stopMonitoring() }

        // The automatic success that hands off to a queued manual request must not briefly publish `.idle`.
        // Settings derives its disabled state from this outcome, so it must remain checking until call two ends.
        let queuedStateDefaults = UserDefaults(suiteName: "\(suiteName).manual-queued-state")!
        defer { queuedStateDefaults.removePersistentDomain(forName: "\(suiteName).manual-queued-state") }
        let queuedStateLoader = GateLoader((release(build: 233), response(200)), gatedCalls: [1, 2])
        let queuedState = await MainActor.run {
            UpdateChecker(defaults: queuedStateDefaults, now: { Date(timeIntervalSince1970: 1_450_000) },
                          requestLoader: { request in await queuedStateLoader.load(request) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { queuedState.startMonitoring() }
        await waitForCalls(queuedStateLoader, 1)
        await MainActor.run { queuedState.checkNow() }
        await queuedStateLoader.resumeFirst()
        await waitForCalls(queuedStateLoader, 2)
        check(await manualOutcome(queuedState) == .checking,
              "queued manual request stays visibly checking through automatic handoff")
        await queuedStateLoader.resumeFirst()
        await waitForManualCheckToFinish(queuedState)
        await MainActor.run { queuedState.stopMonitoring() }

        // The appcast is the primary Apple release contract. This fixture mirrors the live 0.3.16 / build 234
        // shape and must win without consulting generic GitHub release assets.
        let appcastNewerDefaults = UserDefaults(suiteName: "\(suiteName).appcast-newer")!
        defer { appcastNewerDefaults.removePersistentDomain(forName: "\(suiteName).appcast-newer") }
        let appcastNewerLoader = RoutedLoader(
            appcast: .success((appcast(version: "0.3.16", build: 234), response(200))),
            github: .failure(ScriptedLoader.Failure.exhausted)
        )
        let appcastNewer = await MainActor.run {
            UpdateChecker(defaults: appcastNewerDefaults, now: { Date(timeIntervalSince1970: 1_500_000) },
                          requestLoader: { request in try await appcastNewerLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { appcastNewer.checkNow() }
        await waitForManualCheckToFinish(appcastNewer)
        let appcastNewerOutcome = await manualOutcome(appcastNewer)
        let appcastNewerBuild: Int?
        let appcastNewerIntegrity: Bool
        if case .updateAvailable(let release) = appcastNewerOutcome {
            appcastNewerBuild = release.build
            appcastNewerIntegrity = release.size == 103 && release.sha256 == String(repeating: "a", count: 64)
        } else {
            appcastNewerBuild = nil
            appcastNewerIntegrity = false
        }
        check(appcastNewerBuild == 234, "live-shaped appcast discovers 0.3.16 build 234")
        check(appcastNewerIntegrity, "appcast release retains validated size and SHA-256 metadata")
        let appcastNewerAppcastCalls = await appcastNewerLoader.appcastCalls
        let appcastNewerGitHubCalls = await appcastNewerLoader.githubCalls
        check(appcastNewerAppcastCalls == 1 && appcastNewerGitHubCalls == 0,
              "valid appcast is authoritative and does not merge GitHub")

        // A valid but current appcast cannot suppress a newer GitHub candidate. The appcast remains authoritative
        // only when it itself proves a newer build, which avoids a stale edge response hiding a live release.
        let appcastCurrentDefaults = UserDefaults(suiteName: "\(suiteName).appcast-current")!
        defer { appcastCurrentDefaults.removePersistentDomain(forName: "\(suiteName).appcast-current") }
        let appcastCurrentLoader = RoutedLoader(
            appcast: .success((appcast(version: "0.3.15", build: 233), response(200))),
            github: .success((release(build: 234), response(200)))
        )
        let appcastCurrent = await MainActor.run {
            UpdateChecker(defaults: appcastCurrentDefaults, now: { Date(timeIntervalSince1970: 1_600_000) },
                          requestLoader: { request in try await appcastCurrentLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { appcastCurrent.checkNow() }
        await waitForManualCheckToFinish(appcastCurrent)
        let appcastCurrentOutcome = await manualOutcome(appcastCurrent)
        let appcastCurrentBuild: Int?
        if case .updateAvailable(let release) = appcastCurrentOutcome { appcastCurrentBuild = release.build }
        else { appcastCurrentBuild = nil }
        check(appcastCurrentBuild == 234, "valid current appcast falls through to a newer GitHub release")
        let appcastCurrentAppcastCalls = await appcastCurrentLoader.appcastCalls
        let appcastCurrentGitHubCalls = await appcastCurrentLoader.githubCalls
        check(appcastCurrentAppcastCalls == 1 && appcastCurrentGitHubCalls == 1,
              "valid current appcast performs one GitHub comparison")

        // Primary status or schema failure falls back to the existing GitHub parser. Both transport chains
        // failing still surface the manual retry state instead of quietly recording the request.
        let fallbackDefaults = UserDefaults(suiteName: "\(suiteName).appcast-fallback")!
        defer { fallbackDefaults.removePersistentDomain(forName: "\(suiteName).appcast-fallback") }
        let fallbackLoader = RoutedLoader(
            appcast: .success((Data("not an appcast".utf8), response(200))),
            github: .success((release(build: 234), response(200)))
        )
        let fallback = await MainActor.run {
            UpdateChecker(defaults: fallbackDefaults, now: { Date(timeIntervalSince1970: 1_700_000) },
                          requestLoader: { request in try await fallbackLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { fallback.checkNow() }
        await waitForManualCheckToFinish(fallback)
        let fallbackOutcome = await manualOutcome(fallback)
        let fallbackBuild: Int?
        if case .updateAvailable(let release) = fallbackOutcome { fallbackBuild = release.build }
        else { fallbackBuild = nil }
        check(fallbackBuild == 234, "malformed appcast falls back to the GitHub release parser")
        let fallbackAppcastCalls = await fallbackLoader.appcastCalls
        let fallbackGitHubCalls = await fallbackLoader.githubCalls
        check(fallbackAppcastCalls == 1 && fallbackGitHubCalls == 1,
              "malformed appcast performs exactly one GitHub fallback")

        let statusFallbackDefaults = UserDefaults(suiteName: "\(suiteName).appcast-status-fallback")!
        defer { statusFallbackDefaults.removePersistentDomain(forName: "\(suiteName).appcast-status-fallback") }
        let statusFallbackLoader = RoutedLoader(
            appcast: .success((Data("{}".utf8), response(503))),
            github: .success((release(build: 234), response(200)))
        )
        let statusFallback = await MainActor.run {
            UpdateChecker(defaults: statusFallbackDefaults, now: { Date(timeIntervalSince1970: 1_750_000) },
                          requestLoader: { request in try await statusFallbackLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { statusFallback.checkNow() }
        await waitForManualCheckToFinish(statusFallback)
        let statusFallbackOutcome = await manualOutcome(statusFallback)
        let statusFallbackBuild: Int?
        if case .updateAvailable(let release) = statusFallbackOutcome { statusFallbackBuild = release.build }
        else { statusFallbackBuild = nil }
        check(statusFallbackBuild == 234, "non-200 appcast falls back to the GitHub release parser")
        let statusFallbackAppcastCalls = await statusFallbackLoader.appcastCalls
        let statusFallbackGitHubCalls = await statusFallbackLoader.githubCalls
        check(statusFallbackAppcastCalls == 1 && statusFallbackGitHubCalls == 1,
              "non-200 appcast performs exactly one GitHub fallback")

        let bothFailedDefaults = UserDefaults(suiteName: "\(suiteName).appcast-both-failed")!
        defer { bothFailedDefaults.removePersistentDomain(forName: "\(suiteName).appcast-both-failed") }
        let bothFailedLoader = RoutedLoader(
            appcast: .success((Data("{}".utf8), response(503))),
            github: .success((Data("[]".utf8), response(503)))
        )
        let bothFailed = await MainActor.run {
            UpdateChecker(defaults: bothFailedDefaults, now: { Date(timeIntervalSince1970: 1_800_000) },
                          requestLoader: { request in try await bothFailedLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { bothFailed.checkNow() }
        await waitForManualCheckToFinish(bothFailed)
        check(await manualOutcome(bothFailed) == .failure, "both appcast and GitHub failure stay visibly retryable")
        let bothFailedAppcastCalls = await bothFailedLoader.appcastCalls
        let bothFailedGitHubCalls = await bothFailedLoader.githubCalls
        check(bothFailedAppcastCalls == 1 && bothFailedGitHubCalls == 1,
              "both-source failure attempts the fallback once")

        // A structurally current appcast cannot turn a failed GitHub comparison into a successful check. With
        // no newer cached candidate it remains retryable; a newer validated cache is still retained.
        let currentAppcastFailureDefaults = UserDefaults(suiteName: "\(suiteName).current-appcast-github-failure")!
        defer { currentAppcastFailureDefaults.removePersistentDomain(forName: "\(suiteName).current-appcast-github-failure") }
        let currentAppcastFailureLoader = RoutedLoader(
            appcast: .success((appcast(version: "0.3.15", build: 233), response(200))),
            github: .success((Data("[]".utf8), response(503)))
        )
        let currentAppcastFailure = await MainActor.run {
            UpdateChecker(defaults: currentAppcastFailureDefaults, now: { Date(timeIntervalSince1970: 1_850_000) },
                          requestLoader: { request in try await currentAppcastFailureLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { currentAppcastFailure.checkNow() }
        await waitForManualCheckToFinish(currentAppcastFailure)
        check(await manualOutcome(currentAppcastFailure) == .failure,
              "current appcast plus failed GitHub is a retryable failed check")

        let cachedFallbackDefaults = UserDefaults(suiteName: "\(suiteName).current-appcast-cached-fallback")!
        defer { cachedFallbackDefaults.removePersistentDomain(forName: "\(suiteName).current-appcast-cached-fallback") }
        let cachedFallbackRelease = UpdateChecker.Release(
            version: "0.3.16", tag: "v0.3.16", build: 234, name: "VortX 0.3.16 (Build 234)", notes: "Release notes",
            ipa: "https://github.com/VortXTV/VortX/releases/download/v0.3.16/VortX-macOS-v0.3.16-ci.dmg",
            altstore: nil, size: nil, sha256: nil
        )
        cachedFallbackDefaults.set(try! JSONEncoder().encode(cachedFallbackRelease), forKey: "stremiox.update.cachedRelease")
        let cachedFallbackLoader = RoutedLoader(
            appcast: .success((appcast(version: "0.3.15", build: 233), response(200))),
            github: .success((Data("[]".utf8), response(503)))
        )
        let cachedFallback = await MainActor.run {
            UpdateChecker(defaults: cachedFallbackDefaults, now: { Date(timeIntervalSince1970: 1_860_000) },
                          requestLoader: { request in try await cachedFallbackLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { cachedFallback.checkNow() }
        await waitForManualCheckToFinish(cachedFallback)
        check(await MainActor.run { cachedFallback.available?.build } == 234,
              "newer validated cache survives current appcast and failed GitHub")

        // Monitoring can first be requested while a user-initiated check owns discovery. The manual completion
        // must inherit exactly one scheduler deadline rather than leaving monitoring stranded.
        let manualFirstDefaults = UserDefaults(suiteName: "\(suiteName).manual-first-monitoring")!
        defer { manualFirstDefaults.removePersistentDomain(forName: "\(suiteName).manual-first-monitoring") }
        let manualFirstLoader = GateLoader((release(build: 233), response(200)))
        let manualFirstSleeper = ControlledSleeper()
        let manualFirst = await MainActor.run {
            UpdateChecker(defaults: manualFirstDefaults, now: { Date(timeIntervalSince1970: 1_900_000) },
                          requestLoader: { request in await manualFirstLoader.load(request) },
                          sleeper: { seconds in await manualFirstSleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { manualFirst.checkNow() }
        await waitForCalls(manualFirstLoader, 1)
        await MainActor.run { manualFirst.startMonitoring() }
        await manualFirstLoader.resumeFirst()
        await waitForManualCheckToFinish(manualFirst)
        await waitForSleeper(manualFirstSleeper, 1)
        check(await manualFirstSleeper.waitingCount == 1,
              "monitoring started during a manual check inherits one scheduler deadline")
        await MainActor.run { manualFirst.stopMonitoring() }
        await manualFirstSleeper.resumeNext()

        // The same manual-first handoff must keep the short retry when both appcast and GitHub fail. The
        // request began from Settings, but it was also the cold-launch monitoring request's only in-flight work.
        let manualFirstFailureDefaults = UserDefaults(suiteName: "\(suiteName).manual-first-monitoring-failure")!
        defer { manualFirstFailureDefaults.removePersistentDomain(forName: "\(suiteName).manual-first-monitoring-failure") }
        let manualFirstFailureLoader = GateLoader((Data("[]".utf8), response(503)))
        let manualFirstFailureSleeper = ControlledSleeper()
        let manualFirstFailure = await MainActor.run {
            UpdateChecker(defaults: manualFirstFailureDefaults, now: { Date(timeIntervalSince1970: 1_950_000) },
                          requestLoader: { request in await manualFirstFailureLoader.load(request) },
                          sleeper: { seconds in await manualFirstFailureSleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { manualFirstFailure.checkNow() }
        await waitForCalls(manualFirstFailureLoader, 1)
        await MainActor.run { manualFirstFailure.startMonitoring() }
        await manualFirstFailureLoader.resumeFirst()
        await waitForManualCheckToFinish(manualFirstFailure)
        await waitForSleeper(manualFirstFailureSleeper, 1)
        check(await manualFirstFailureSleeper.duration(at: 0) == 60,
              "manual-first total failure arms the monitoring short retry")
        await MainActor.run { manualFirstFailure.stopMonitoring() }
        await manualFirstFailureSleeper.resumeNext()

        // If the hourly task wakes while a manual fetch is in flight, it transfers scheduler ownership to that
        // request. It must not synchronously re-arm a zero-delay loop while the manual request is still gated.
        let timerDuringManualDefaults = UserDefaults(suiteName: "\(suiteName).timer-during-manual")!
        defer { timerDuringManualDefaults.removePersistentDomain(forName: "\(suiteName).timer-during-manual") }
        let timerDuringManualLoader = GateLoader((release(build: 233), response(200)), gatedCall: 2)
        let timerDuringManualSleeper = ControlledSleeper()
        let timerClock = TestClock(2_000_000)
        let timerDuringManual = await MainActor.run {
            UpdateChecker(defaults: timerDuringManualDefaults, now: { timerClock.date() },
                          requestLoader: { request in await timerDuringManualLoader.load(request) },
                          sleeper: { seconds in await timerDuringManualSleeper.sleep(seconds) },
                          currentBuild: 230, currentVersion: "0.3.14")
        }
        await MainActor.run { timerDuringManual.startMonitoring() }
        await waitForCalls(timerDuringManualLoader, 1)
        await waitForSleeper(timerDuringManualSleeper, 1)
        await MainActor.run { timerDuringManual.checkNow() }
        await waitForCalls(timerDuringManualLoader, 2)
        timerClock.seconds += 3_600
        await timerDuringManualSleeper.resumeNext()
        try? await Task.sleep(for: .milliseconds(20))
        let callsDuringManual = await timerDuringManualLoader.calls
        let sleepersDuringManual = await timerDuringManualSleeper.waitingCount
        check(callsDuringManual == 2 && sleepersDuringManual == 0,
              "hourly tick during manual discovery does not hot-loop a zero-delay scheduler")
        await timerDuringManualLoader.resumeFirst()
        await waitForManualCheckToFinish(timerDuringManual)
        await waitForSleeper(timerDuringManualSleeper, 1)
        check(await timerDuringManualSleeper.waitingCount == 1,
              "manual completion re-arms the deferred hourly scheduler once")
        await MainActor.run { timerDuringManual.stopMonitoring() }
        await timerDuringManualSleeper.resumeNext()

        // A URL that looks close to an artifact is still rejected at the final sink. This protects both a
        // malformed appcast and any persisted release from selecting a query-bearing or redirected destination.
        let poisonedAppcastString = String(data: appcast(version: "0.3.16", build: 234), encoding: .utf8)!
            .replacingOccurrences(of: "VortX-macOS-v0.3.16-ci.dmg\",\"size", with: "VortX-macOS-v0.3.16-ci.dmg?download=1\",\"size")
        let poisonedAppcast = Data(poisonedAppcastString.utf8)
        let poisonedDefaults = UserDefaults(suiteName: "\(suiteName).poisoned-appcast")!
        defer { poisonedDefaults.removePersistentDomain(forName: "\(suiteName).poisoned-appcast") }
        let poisonedLoader = RoutedLoader(appcast: .success((poisonedAppcast, response(200))),
                                          github: .success((release(build: 234), response(200))))
        let poisoned = await MainActor.run {
            UpdateChecker(defaults: poisonedDefaults, now: { Date(timeIntervalSince1970: 2_100_000) },
                          requestLoader: { request in try await poisonedLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { poisoned.checkNow() }
        await waitForManualCheckToFinish(poisoned)
        let poisonedBuild = await MainActor.run { poisoned.available?.build }
        let poisonedGitHubCalls = await poisonedLoader.githubCalls
        check(poisonedBuild == 234 && poisonedGitHubCalls == 1,
              "query-bearing appcast artifact is rejected and falls back safely")

        let oversizedDefaults = UserDefaults(suiteName: "\(suiteName).oversized-appcast")!
        defer { oversizedDefaults.removePersistentDomain(forName: "\(suiteName).oversized-appcast") }
        let oversizedLoader = RoutedLoader(
            appcast: .success((Data(repeating: 0, count: 512 * 1024 + 1), response(200))),
            github: .success((release(build: 234), response(200)))
        )
        let oversized = await MainActor.run {
            UpdateChecker(defaults: oversizedDefaults, now: { Date(timeIntervalSince1970: 2_150_000) },
                          requestLoader: { request in try await oversizedLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { oversized.checkNow() }
        await waitForManualCheckToFinish(oversized)
        let oversizedBuild = await MainActor.run { oversized.available?.build }
        let oversizedGitHubCalls = await oversizedLoader.githubCalls
        check(oversizedBuild == 234 && oversizedGitHubCalls == 1,
              "oversized primary response is bounded and falls back safely")

        let redirectDefaults = UserDefaults(suiteName: "\(suiteName).redirect")!
        defer { redirectDefaults.removePersistentDomain(forName: "\(suiteName).redirect") }
        let redirectLoader = RoutedLoader(
            appcast: .success((appcast(version: "0.3.16", build: 234), response(200, url: URL(string: "https://evil.example/appcast.json")!))),
            github: .success((release(build: 234), response(200))), preserveResponseURL: true)
        let redirect = await MainActor.run {
            UpdateChecker(defaults: redirectDefaults, now: { Date(timeIntervalSince1970: 2_200_000) },
                          requestLoader: { request in try await redirectLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { redirect.checkNow() }
        await waitForManualCheckToFinish(redirect)
        let redirectBuild = await MainActor.run { redirect.available?.build }
        let redirectOutcome = await manualOutcome(redirect)
        let redirectGitHubCalls = await redirectLoader.githubCalls
        check(redirectBuild == 234 && redirectOutcome != .failure && redirectGitHubCalls == 1,
              "unexpected appcast redirect is rejected before the safe fallback is used")

        let githubRedirectDefaults = UserDefaults(suiteName: "\(suiteName).github-redirect")!
        defer { githubRedirectDefaults.removePersistentDomain(forName: "\(suiteName).github-redirect") }
        let githubRedirectLoader = RoutedLoader(
            appcast: .success((Data("{}".utf8), response(503, url: URL(string: "https://vortx.tv/appcast.json")!))),
            github: .success((release(build: 234), response(200, url: URL(string: "https://evil.example/releases")!))),
            preserveResponseURL: true)
        let githubRedirect = await MainActor.run {
            UpdateChecker(defaults: githubRedirectDefaults, now: { Date(timeIntervalSince1970: 2_250_000) },
                          requestLoader: { request in try await githubRedirectLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { githubRedirect.checkNow() }
        await waitForManualCheckToFinish(githubRedirect)
        check(await manualOutcome(githubRedirect) == .failure,
              "unexpected GitHub final response origin is rejected visibly")

        let liteDefaults = UserDefaults(suiteName: "\(suiteName).lite")!
        defer { liteDefaults.removePersistentDomain(forName: "\(suiteName).lite") }
        let liteLoader = RoutedLoader(
            appcast: .success((appcast(version: "0.3.16", build: 234), response(200))),
            github: .success((release(build: 234, assetName: "VortX-tvOS-lite-v0.3.15-ci.ipa"), response(200))))
        let lite = await MainActor.run {
            UpdateChecker(defaults: liteDefaults, now: { Date(timeIntervalSince1970: 2_300_000) },
                          requestLoader: { request in try await liteLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15", isLite: true)
        }
        await MainActor.run { lite.checkNow() }
        await waitForManualCheckToFinish(lite)
        check(await MainActor.run { lite.available?.ipa?.hasSuffix("VortX-tvOS-lite-v0.3.15-ci.ipa") == true },
              "Lite selects only its exact IPA asset")
        let liteAppcastCalls = await liteLoader.appcastCalls
        let liteGitHubCalls = await liteLoader.githubCalls
        check(liteAppcastCalls == 0 && liteGitHubCalls == 1,
              "Lite bypasses the Full-only appcast entry while remaining update-eligible")

        let betaFullDefaults = UserDefaults(suiteName: "\(suiteName).beta-full")!
        defer { betaFullDefaults.removePersistentDomain(forName: "\(suiteName).beta-full") }
        let betaFullLoader = ScriptedLoader([.success((release(build: 235, tag: "v0.3.16-beta.31"), response(200)))])
        let betaFull = await MainActor.run {
            UpdateChecker(defaults: betaFullDefaults, now: { Date(timeIntervalSince1970: 2_350_000) },
                          requestLoader: { request in try await betaFullLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { betaFull.checkNow() }
        await waitForManualCheckToFinish(betaFull)
        check(await MainActor.run { betaFull.available?.tag == "v0.3.16-beta.31" && betaFull.available?.ipa?.hasSuffix("VortX-macOS-v0.3.16-beta.31-ci.dmg") == true },
              "public beta tags bind the standard artifact URL to the full tag")

        let betaLiteDefaults = UserDefaults(suiteName: "\(suiteName).beta-lite")!
        defer { betaLiteDefaults.removePersistentDomain(forName: "\(suiteName).beta-lite") }
        let betaLiteLoader = ScriptedLoader([.success((release(build: 235, tag: "v0.3.16-beta.31", assetName: "VortX-tvOS-lite-v0.3.16-beta.31-ci.ipa"), response(200)))])
        let betaLite = await MainActor.run {
            UpdateChecker(defaults: betaLiteDefaults, now: { Date(timeIntervalSince1970: 2_360_000) },
                          requestLoader: { request in try await betaLiteLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15", isLite: true)
        }
        await MainActor.run { betaLite.checkNow() }
        await waitForManualCheckToFinish(betaLite)
        check(await MainActor.run { betaLite.available?.tag == "v0.3.16-beta.31" && betaLite.available?.ipa?.hasSuffix("VortX-tvOS-lite-v0.3.16-beta.31-ci.ipa") == true },
              "public beta tags bind the Lite artifact URL to the full tag")

        let cachedRelease = UpdateChecker.Release(
            version: "0.3.16", build: 234, name: "VortX 0.3.16 (Build 234)", notes: "Release notes",
            ipa: "https://github.com/VortXTV/VortX/releases/download/v0.3.16/VortX-macOS-v0.3.16-ci.dmg",
            altstore: nil, size: nil, sha256: nil
        )
        let cachedDefaults = UserDefaults(suiteName: "\(suiteName).cached-highest")!
        defer { cachedDefaults.removePersistentDomain(forName: "\(suiteName).cached-highest") }
        cachedDefaults.set(try! JSONEncoder().encode(cachedRelease), forKey: "stremiox.update.cachedRelease")
        let cachedLoader = ScriptedLoader([.success((release(build: 233), response(200)))])
        let cached = await MainActor.run {
            UpdateChecker(defaults: cachedDefaults, now: { Date(timeIntervalSince1970: 2_400_000) },
                          requestLoader: { request in try await cachedLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { cached.checkNow() }
        await waitForManualCheckToFinish(cached)
        check(await MainActor.run { cached.available?.build } == 234,
              "older valid network data cannot overwrite a newer cached release")

        let invalidCachedDefaults = UserDefaults(suiteName: "\(suiteName).cached-invalid")!
        defer { invalidCachedDefaults.removePersistentDomain(forName: "\(suiteName).cached-invalid") }
        var invalidCachedRelease = cachedRelease
        invalidCachedRelease = UpdateChecker.Release(
            version: invalidCachedRelease.version, build: invalidCachedRelease.build,
            name: invalidCachedRelease.name, notes: invalidCachedRelease.notes,
            ipa: invalidCachedRelease.ipa! + "?download=1", altstore: nil, size: nil, sha256: nil
        )
        invalidCachedDefaults.set(try! JSONEncoder().encode(invalidCachedRelease), forKey: "stremiox.update.cachedRelease")
        let invalidCachedLoader = GateLoader((release(build: 233), response(200)))
        let invalidCached = await MainActor.run {
            UpdateChecker(defaults: invalidCachedDefaults, now: { Date(timeIntervalSince1970: 2_500_000) },
                          requestLoader: { request in await invalidCachedLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { invalidCached.checkNow() }
        check(await MainActor.run { invalidCached.available == nil },
              "invalid cached release is rejected before it can be shown")
        await waitForCalls(invalidCachedLoader, 1)
        await invalidCachedLoader.resumeFirst()
        await waitForManualCheckToFinish(invalidCached)

        // Cached releases from the prior schema have no tag, size, or SHA keys. A stable artifact can derive
        // its exact tag from the numeric version, while a beta path without a saved tag remains untrusted.
        let legacyCacheDefaults = UserDefaults(suiteName: "\(suiteName).legacy-cache")!
        defer { legacyCacheDefaults.removePersistentDomain(forName: "\(suiteName).legacy-cache") }
        let legacyCacheJSON = #"{"version":"0.3.16","build":234,"name":"VortX 0.3.16 (Build 234)","notes":"Release notes","ipa":"https://github.com/VortXTV/VortX/releases/download/v0.3.16/VortX-macOS-v0.3.16-ci.dmg","altstore":null}"#
        legacyCacheDefaults.set(Data(legacyCacheJSON.utf8), forKey: "stremiox.update.cachedRelease")
        let legacyCacheLoader = GateLoader((release(build: 233), response(200)))
        let legacyCache = await MainActor.run {
            UpdateChecker(defaults: legacyCacheDefaults, now: { Date(timeIntervalSince1970: 2_600_000) },
                          requestLoader: { request in await legacyCacheLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { legacyCache.checkNow() }
        check(await MainActor.run { legacyCache.available?.build == 234 && legacyCache.available?.tag == nil },
              "literal stable legacy cache derives its safe stable tag identity")
        await waitForCalls(legacyCacheLoader, 1)
        await legacyCacheLoader.resumeFirst()
        await waitForManualCheckToFinish(legacyCache)

        let legacyBetaCacheDefaults = UserDefaults(suiteName: "\(suiteName).legacy-beta-cache")!
        defer { legacyBetaCacheDefaults.removePersistentDomain(forName: "\(suiteName).legacy-beta-cache") }
        let legacyBetaCacheJSON = #"{"version":"0.3.16","build":235,"name":"VortX 0.3.16 (Build 235)","notes":"Release notes","ipa":"https://github.com/VortXTV/VortX/releases/download/v0.3.16-beta.31/VortX-macOS-v0.3.16-beta.31-ci.dmg","altstore":null}"#
        legacyBetaCacheDefaults.set(Data(legacyBetaCacheJSON.utf8), forKey: "stremiox.update.cachedRelease")
        let legacyBetaCacheLoader = GateLoader((release(build: 233), response(200)))
        let legacyBetaCache = await MainActor.run {
            UpdateChecker(defaults: legacyBetaCacheDefaults, now: { Date(timeIntervalSince1970: 2_610_000) },
                          requestLoader: { request in await legacyBetaCacheLoader.load(request) },
                          currentBuild: 233, currentVersion: "0.3.15")
        }
        await MainActor.run { legacyBetaCache.checkNow() }
        check(await MainActor.run { legacyBetaCache.available == nil },
              "tagless beta legacy cache cannot derive a safe artifact identity")
        await waitForCalls(legacyBetaCacheLoader, 1)
        await legacyBetaCacheLoader.resumeFirst()
        await waitForManualCheckToFinish(legacyBetaCache)

        let canonicalArtifact = "https://github.com/VortXTV/VortX/releases/download/v0.3.16/VortX-macOS-v0.3.16-ci.dmg"
        let trustedDirectRelease = UpdateChecker.Release(version: "0.3.16", tag: "v0.3.16", build: 234,
                                                          name: "VortX 0.3.16 (Build 234)", notes: "",
                                                          ipa: canonicalArtifact, altstore: nil, size: nil, sha256: nil)
        check(trustedDirectRelease.installURL?.absoluteString == canonicalArtifact,
              "Release intrinsically accepts only the canonical stable artifact")
        let unsafeAltstores = [
            "https://vortx.tv/altstore.json?x=1", "https://user@vortx.tv/altstore.json",
            "https://vortx.tv:443/altstore.json", "https://vortx.tv/altstore.json#x", "http://vortx.tv/altstore.json"
        ]
        check(unsafeAltstores.allSatisfy {
            UpdateChecker.Release(version: "0.3.16", tag: "v0.3.16", build: 234, name: "VortX 0.3.16 (Build 234)", notes: "", ipa: nil, altstore: $0, size: nil, sha256: nil).installURL == nil
        }, "Release intrinsically rejects noncanonical AltStore URLs")
        let unsafeArtifacts = [
            canonicalArtifact + "?x=1", canonicalArtifact + "#x",
            canonicalArtifact.replacingOccurrences(of: "https://", with: "https://user@"),
            canonicalArtifact.replacingOccurrences(of: "github.com", with: "github.com:443"),
            canonicalArtifact.replacingOccurrences(of: "/VortXTV/", with: "/%56ortXTV/"),
            canonicalArtifact.replacingOccurrences(of: "https://", with: "http://")
        ]
        check(unsafeArtifacts.allSatisfy {
            UpdateChecker.Release(version: "0.3.16", tag: "v0.3.16", build: 234, name: "VortX 0.3.16 (Build 234)", notes: "", ipa: $0, altstore: nil, size: nil, sha256: nil).installURL == nil
        }, "Release intrinsically rejects userinfo, port, query, fragment, encoded-path, and custom-scheme artifacts")
        let overflowVersion = String(repeating: "9", count: 80) + ".1"
        let overflowTag = "v\(overflowVersion)"
        let overflowArtifact = "https://github.com/VortXTV/VortX/releases/download/\(overflowTag)/VortX-macOS-\(overflowTag)-ci.dmg"
        check(UpdateChecker.Release(version: overflowVersion, tag: overflowTag, build: 234, name: "VortX", notes: "", ipa: overflowArtifact, altstore: nil, size: nil, sha256: nil).installURL == nil,
              "Release intrinsically rejects overflowing version components and has no fallback URL")

        exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
