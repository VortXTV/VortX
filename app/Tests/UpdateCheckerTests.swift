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
    private let gatedCall: Int
    private let result: (Data, URLResponse)
    private(set) var calls = 0

    init(_ result: (Data, URLResponse), gatedCall: Int = 1) {
        self.result = result
        self.gatedCall = gatedCall
    }

    func load(_ request: URLRequest) async -> (Data, URLResponse) {
        if request.url?.host == "vortx.tv" { return (Data("{}".utf8), response(503)) }
        calls += 1
        if calls == gatedCall {
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
    private(set) var requestedHosts: [String] = []

    init(appcast: Result<(Data, URLResponse), Error>, github: Result<(Data, URLResponse), Error>) {
        self.appcast = appcast
        self.github = github
    }

    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        let host = request.url?.host ?? ""
        requestedHosts.append(host)
        return try (host == "vortx.tv" ? appcast : github).get()
    }

    var appcastCalls: Int { requestedHosts.filter { $0 == "vortx.tv" }.count }
    var githubCalls: Int { requestedHosts.filter { $0 == "api.github.com" }.count }
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

func appcast(version: String, build: Int) -> Data {
    let sha256 = String(repeating: "a", count: 64)
    let fixture = """
    {"schemaVersion":2,
     "ios":{"version":"\(version)","build":\(build),"name":"VortX \(version) (build \(build))","notes":"Release notes","ipa":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-iOS-v\(version)-ci.ipa","url":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-iOS-v\(version)-ci.ipa","size":101,"sha256":"\(sha256)","altstore":"https://vortx.tv/altstore.json","artifactType":"ipa"},
     "tvos":{"version":"\(version)","build":\(build),"name":"VortX \(version) (build \(build))","notes":"Release notes","ipa":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-tvOS-v\(version)-ci.ipa","url":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-tvOS-v\(version)-ci.ipa","size":102,"sha256":"\(sha256)","altstore":null,"artifactType":"ipa"},
     "mac":{"version":"\(version)","build":\(build),"name":"VortX \(version) (build \(build))","notes":"Release notes","ipa":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-macOS-v\(version)-ci.dmg","url":"https://github.com/VortXTV/VortX/releases/download/v\(version)/VortX-macOS-v\(version)-ci.dmg","size":103,"sha256":"\(sha256)","altstore":null,"artifactType":"dmg"}}
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

        // A valid appcast that exactly matches the installed build is still authoritative and must report current
        // instead of falling through to a potentially different GitHub result.
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
        check(await manualOutcome(appcastCurrent) == .upToDate, "valid current appcast reports current")
        let appcastCurrentAppcastCalls = await appcastCurrentLoader.appcastCalls
        let appcastCurrentGitHubCalls = await appcastCurrentLoader.githubCalls
        check(appcastCurrentAppcastCalls == 1 && appcastCurrentGitHubCalls == 0,
              "valid current appcast avoids the GitHub fallback")

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

        exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
