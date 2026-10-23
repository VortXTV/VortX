import Foundation

// The runner takes the existing inert RestoreManagerFixture dependency definitions from
// AccountRestoreHandoffTests.swift, and extracts all three actual production methods into
// another file. No production method is reimplemented here. The only added dependencies
// below are a checkpoint-attempt probe using the actual RecoveryBackoff value, and the
// resident branch's convenience overload. No engine, preference/Keychain or transport I/O.
@MainActor enum WatchedRetryProbe {
    static var now = Date(timeIntervalSince1970: 1_000)
    static var backoff = NativeForegroundSyncPolicy.RecoveryBackoff()
    static var attempts: [Bool] = []

    static func reset() {
        attempts = []
        backoff = .init()
        backoff.recordFailure(at: now)
        CoreBridge.shared.certified = []
    }
}

@MainActor extension CoreBridge {
    var hasNativeSession: Bool { !certified.isEmpty }
}

@MainActor extension RestoreManagerFixture {
    func restoreNativeCheckpoint(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,
                                 userInitiated: Bool = false) async -> Bool {
        let capture = suppliedCapture ?? credentialAuthority.capture()
        WatchedRetryProbe.attempts.append(userInitiated)
        guard WatchedRetryProbe.backoff.permitsAttempt(at: WatchedRetryProbe.now,
                                                      userInitiated: userInitiated) else { return false }
        return await ensureNativeCheckpoint(credentialCapture: capture)
    }

    func syncDown(force: Bool) async -> Bool {
        await syncDown(force: force, credentialCapture: credentialAuthority.capture())
    }
}

@main @MainActor enum NativeWatchedRetryTests {
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) {
        guard value else { fatalError("FAIL: " + label) }
        checks += 1
        print("PASS: " + label)
    }
    static func waitUntil(_ label: String, _ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if predicate() { return }
            await _Concurrency.Task<Never, Never>.yield()
        }
        fatalError("FAIL: dependency did not reach " + label)
    }

    static func main() async {
        // A pending first-open failure has armed automatic backoff. The explicit notice
        // retry must reach the existing user-initiated boundary, not silently do nothing.
        WatchedRetryProbe.reset()
        expect(!WatchedRetryProbe.backoff.permitsAttempt(at: WatchedRetryProbe.now,
                                                        userInitiated: false), "automatic retry remains backed off")
        let historical = RestoreManagerFixture(historicallyApplied: true)
        historical.accountRestoreState = .failed
        let firstCapture = historical.credentialAuthority.capture()
        let first = _Concurrency.Task { @MainActor in await historical.retryNativeWatchedMigration() }
        await waitUntil("explicit checkpoint attempt") { !WatchedRetryProbe.attempts.isEmpty }
        expect(WatchedRetryProbe.attempts == [true], "notice retry is explicitly user-initiated")
        await waitUntil("held native mount") { historical.mountStarts[firstCapture] == 1 }
        expect(!historical.publications.contains(.ready), "a pending mount cannot publish account ready")
        historical.releaseMount(firstCapture, success: true, certify: true)
        await first.value
        expect(historical.accountRestoreState == .ready, "certified retry re-enters the real restore handoff")
        expect(historical.pullStarts.isEmpty && historical.pushes == 0,
               "historical acknowledged document does not need a new pull or any push")

        // A genuinely first-open account must finish document acknowledgement, not just
        // mount the native dependency. Both methods under test are actual source extracts.
        WatchedRetryProbe.reset()
        let fresh = RestoreManagerFixture()
        fresh.accountRestoreState = .failed
        let freshCapture = fresh.credentialAuthority.capture()
        let freshRetry = _Concurrency.Task { @MainActor in await fresh.retryNativeWatchedMigration() }
        await waitUntil("fresh held mount") { fresh.mountStarts[freshCapture] == 1 }
        fresh.releaseMount(freshCapture, success: true, certify: true)
        await waitUntil("fresh forced pull") { fresh.pullStarts[freshCapture] == 1 }
        expect(fresh.accountRestoreState == .restoring && !fresh.publications.contains(.ready),
               "mount alone cannot acknowledge first-open account data")
        fresh.releasePull(freshCapture, applied: true, certified: true)
        await freshRetry.value
        expect(fresh.accountRestoreState == .ready && fresh.pushes == 0,
               "first-open retry becomes ready only after acknowledged pull and certification")

        WatchedRetryProbe.reset()
        let failed = RestoreManagerFixture(historicallyApplied: true)
        failed.accountRestoreState = .failed
        let failedCapture = failed.credentialAuthority.capture()
        let failure = _Concurrency.Task { @MainActor in await failed.retryNativeWatchedMigration() }
        await waitUntil("failed held mount") { failed.mountStarts[failedCapture] == 1 }
        failed.releaseMount(failedCapture, success: false, certify: false)
        await failure.value
        expect(failed.accountRestoreState == .failed && !failed.publications.contains(.ready)
               && failed.pullStarts.isEmpty && failed.pushes == 0,
               "failed preparation does not acknowledge, publish ready, or push a replacement")

        WatchedRetryProbe.reset()
        let uncertified = RestoreManagerFixture(historicallyApplied: true)
        uncertified.accountRestoreState = .failed
        let uncertifiedCapture = uncertified.credentialAuthority.capture()
        let uncertifiedRetry = _Concurrency.Task { @MainActor in await uncertified.retryNativeWatchedMigration() }
        await waitUntil("uncertified held mount") { uncertified.mountStarts[uncertifiedCapture] == 1 }
        uncertified.releaseMount(uncertifiedCapture, success: true, certify: false)
        await uncertifiedRetry.value
        expect(uncertified.accountRestoreState == .failed && !uncertified.publications.contains(.ready),
               "a success-shaped dependency result without certification is not readiness")

        WatchedRetryProbe.reset()
        let switched = RestoreManagerFixture(historicallyApplied: true)
        switched.accountRestoreState = .failed
        let retiredCapture = switched.credentialAuthority.capture()
        let retired = _Concurrency.Task { @MainActor in await switched.retryNativeWatchedMigration() }
        await waitUntil("old account held mount") { switched.mountStarts[retiredCapture] == 1 }
        switched.replaceCredentials()
        switched.releaseMount(retiredCapture, success: true, certify: true)
        await retired.value
        expect(switched.accountRestoreState == .idle && !switched.publications.contains(.ready)
               && switched.pullStarts.isEmpty && switched.pushes == 0,
               "retired account retry cannot publish into the replacement owner")

        WatchedRetryProbe.reset()
        let resident = RestoreManagerFixture(historicallyApplied: true)
        resident.accountRestoreState = .ready
        let residentCapture = resident.credentialAuthority.capture()
        CoreBridge.shared.certify(residentCapture)
        let residentRetry = _Concurrency.Task { @MainActor in await resident.retryNativeWatchedMigration() }
        await waitUntil("resident forced pull") { resident.pullStarts[residentCapture] == 1 }
        expect(WatchedRetryProbe.attempts.isEmpty && resident.mountStarts.isEmpty,
               "resident retry retains its session and takes the existing forced pull branch")
        resident.releasePull(residentCapture, applied: true, certified: true)
        await residentRetry.value
        expect(resident.accountRestoreState == .ready && resident.pushes == 0,
               "resident branch preserves ready state without creating a push")
        print("Native watched retry actual-method checks: \(checks)")
    }
}
