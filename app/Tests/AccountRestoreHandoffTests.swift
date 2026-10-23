import Foundation

// This file supplies state/dependency fixtures only. The runner mechanically extracts the actual
// production restoreAccountDocIfNeeded and AccountRestoreState declarations into a separate file.
// Its method bytes are not rewritten; this in-memory Task wrapper keeps real task/cancellation
// semantics while replacing only the dependency clock's one-second backoff with a scheduler yield.
struct FixtureTask<Success: Sendable, Failure: Error>: Sendable {
    let underlying: _Concurrency.Task<Success, Failure>
    func cancel() { underlying.cancel() }
}
extension FixtureTask where Failure == Never {
    init(operation: @escaping @Sendable @MainActor () async -> Success) {
        underlying = _Concurrency.Task { @MainActor in await operation() }
    }
    var value: Success { get async { await underlying.value } }
}
extension FixtureTask where Success == Never, Failure == Never {
    static func sleep(nanoseconds: UInt64) async throws {
        await RestoreFixtureClock.record(nanoseconds)
        await _Concurrency.Task<Never, Never>.yield()
        try _Concurrency.Task<Never, Never>.checkCancellation()
    }
    static var isCancelled: Bool { _Concurrency.Task<Never, Never>.isCancelled }
}
@MainActor enum RestoreFixtureClock {
    static var requestedBackoffs: [UInt64] = []
    static func record(_ nanoseconds: UInt64) { requestedBackoffs.append(nanoseconds) }
}

@MainActor final class CredentialScopeRegistry {
    struct Capture: Equatable, Hashable, Sendable { let generation: UInt64 }
    private var generation: UInt64 = 1
    func capture() -> Capture { Capture(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
    func replace() { generation += 1 }
}
@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    var activeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
@MainActor final class CoreBridge {
    static let shared = CoreBridge()
    struct Certification: Hashable { let capture: CredentialScopeRegistry.Capture; let profileID: UUID }
    var certified: Set<Certification> = []
    func hasCertifiedNativeSession(capture: CredentialScopeRegistry.Capture, profileID: UUID) -> Bool {
        certified.contains(Certification(capture: capture, profileID: profileID))
    }
    func certify(_ capture: CredentialScopeRegistry.Capture, profileID: UUID = ProfileStore.shared.activeID) {
        certified.insert(Certification(capture: capture, profileID: profileID))
    }
}

@MainActor final class RestoreManagerFixture {
    typealias Task<Success: Sendable, Failure: Error> = FixtureTask<Success, Failure>
    let credentialAuthority = CredentialScopeRegistry()
    var isSignedIn = true
    var accountRestoreState: AccountRestoreState = .idle {
        didSet { publications.append(accountRestoreState) }
    }
    var publications: [AccountRestoreState] = []
    var restoreTaskCapture: CredentialScopeRegistry.Capture?
    var restoreTask: Task<Bool, Never>?
    var applied: [CredentialScopeRegistry.Capture: Bool] = [:]
    var pending: Set<CredentialScopeRegistry.Capture> = []
    var appliedReadOverrides: [Bool] = []
    var hasAppliedAccountDoc: Bool {
        get {
            if !appliedReadOverrides.isEmpty { return appliedReadOverrides.removeFirst() }
            return applied[credentialAuthority.capture()] == true
        }
        set { applied[credentialAuthority.capture()] = newValue }
    }
    var mountStarts: [CredentialScopeRegistry.Capture: Int] = [:]
    var ensureStarts: [CredentialScopeRegistry.Capture: Int] = [:]
    var pullStarts: [CredentialScopeRegistry.Capture: Int] = [:]
    var pushes = 0
    var heldMounts: [CredentialScopeRegistry.Capture: [CheckedContinuation<Bool, Never>]] = [:]
    var heldPulls: [CredentialScopeRegistry.Capture: [CheckedContinuation<Bool, Never>]] = [:]

    init(historicallyApplied: Bool = false) { hasAppliedAccountDoc = historicallyApplied }
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { credentialAuthority.isCurrent(capture) }
    func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool { pending.contains(capture) }
    func ensureNativeCheckpoint(credentialCapture capture: CredentialScopeRegistry.Capture) async -> Bool {
        ensureStarts[capture, default: 0] += 1
        if CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: ProfileStore.shared.activeID) {
            return true // An already certified dependency resolves without a cold-mount request.
        }
        mountStarts[capture, default: 0] += 1
        let acknowledged = await withCheckedContinuation { heldMounts[capture, default: []].append($0) }
        // Contract of the dependency, not a second restore implementation: a mount response alone
        // cannot certify a native session. The held result can succeed only with its certificate.
        return acknowledged && CoreBridge.shared.hasCertifiedNativeSession(
            capture: capture, profileID: ProfileStore.shared.activeID)
    }
    func syncDown(force: Bool, credentialCapture capture: CredentialScopeRegistry.Capture) async -> Bool {
        precondition(force, "restore must request a forced pull")
        pullStarts[capture, default: 0] += 1
        return await withCheckedContinuation { heldPulls[capture, default: []].append($0) }
    }
    func requestSyncSoon() { pushes += 1 }
    func syncUp() async -> Bool { pushes += 1; return false }
    func releaseMount(_ capture: CredentialScopeRegistry.Capture, success: Bool, certify: Bool) {
        if certify { CoreBridge.shared.certify(capture) }
        guard var held = heldMounts[capture], !held.isEmpty else { preconditionFailure("missing held mount") }
        let next = held.removeFirst(); heldMounts[capture] = held; next.resume(returning: success)
    }
    func releasePull(_ capture: CredentialScopeRegistry.Capture, applied: Bool, certified: Bool,
                     pending: Bool = false, result: Bool = true) {
        self.applied[capture] = applied
        if pending { self.pending.insert(capture) } else { self.pending.remove(capture) }
        if certified { CoreBridge.shared.certify(capture) }
        guard var held = heldPulls[capture], !held.isEmpty else { preconditionFailure("missing held pull") }
        let next = held.removeFirst(); heldPulls[capture] = held; next.resume(returning: result)
    }
    func replaceCredentials() {
        credentialAuthority.replace()
        appliedReadOverrides = []
        accountRestoreState = .idle
    }
}

@main @MainActor enum AccountRestoreHandoffTests {
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
    static func resetDependencies() {
        CoreBridge.shared.certified = []
        ProfileStore.shared.activeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        RestoreFixtureClock.requestedBackoffs = []
    }

    static func historicalReceiptWaitsForMount() async {
        resetDependencies()
        let manager = RestoreManagerFixture(historicallyApplied: true)
        let capture = manager.credentialAuthority.capture()
        var firstFinished = false
        let first = _Concurrency.Task { @MainActor in
            let result = await manager.restoreAccountDocIfNeeded()
            firstFinished = true
            return result
        }
        await waitUntil("historical cold mount") { manager.mountStarts[capture] == 1 }
        expect(manager.accountRestoreState == .restoring && !firstFinished,
               "historical applied receipt cannot hand off while cold native mount is pending")
        expect(!manager.publications.contains(.ready), "historical receipt publishes no premature ready")
        var secondFinished = false
        let second = _Concurrency.Task { @MainActor in
            let result = await manager.restoreAccountDocIfNeeded(credentialCapture: capture)
            secondFinished = true
            return result
        }
        await _Concurrency.Task<Never, Never>.yield()
        expect(manager.mountStarts[capture] == 1 && !secondFinished, "concurrent historical restore joins one held mount")
        manager.releaseMount(capture, success: true, certify: true)
        let firstResult = await first.value, secondResult = await second.value
        expect(firstResult && secondResult, "joined historical callers succeed after certified mount")
        expect(manager.accountRestoreState == .ready, "historical restore publishes ready only after native certification")
        expect(manager.pullStarts.isEmpty && manager.pushes == 0, "historical mounting neither double-pulls nor pushes")
        expect(manager.restoreTask == nil && manager.restoreTaskCapture == nil, "completed mount retires single-flight lease")
    }

    static func failedHistoricalMountCannotReady() async {
        resetDependencies()
        let manager = RestoreManagerFixture(historicallyApplied: true)
        let capture = manager.credentialAuthority.capture()
        let operation = _Concurrency.Task { @MainActor in await manager.restoreAccountDocIfNeeded() }
        await waitUntil("failed historical mount") { manager.mountStarts[capture] == 1 }
        manager.releaseMount(capture, success: false, certify: false)
        expect(await operation.value == false, "false mount result is a failed restore even with historical applied=true")
        expect(manager.accountRestoreState == .failed && !manager.publications.contains(.ready),
               "historical mount failure stays failed, never ready")
        expect(manager.pushes == 0, "failed historical mount issues no push dependency call")
        expect(manager.restoreTask == nil, "failed mount retires lease so a later explicit retry can run")
        let retry = _Concurrency.Task { @MainActor in await manager.restoreAccountDocIfNeeded() }
        await waitUntil("historical retry") { manager.mountStarts[capture] == 2 }
        manager.releaseMount(capture, success: true, certify: true)
        expect(await retry.value && manager.accountRestoreState == .ready, "later certified mount can recover failed handoff")
    }

    static func firstDocumentRequiresCertification() async {
        resetDependencies()
        let manager = RestoreManagerFixture()
        let capture = manager.credentialAuthority.capture()
        var finished = false
        let first = _Concurrency.Task { @MainActor in
            let result = await manager.restoreAccountDocIfNeeded()
            finished = true
            return result
        }
        await waitUntil("first document pull") { manager.pullStarts[capture] == 1 }
        expect(manager.accountRestoreState == .restoring && !finished && !manager.publications.contains(.ready),
               "first account document remains restoring while dependency is held")
        let joined = _Concurrency.Task { @MainActor in await manager.restoreAccountDocIfNeeded() }
        await _Concurrency.Task<Never, Never>.yield()
        expect(manager.pullStarts[capture] == 1, "concurrent first-document callers join one forced pull")
        manager.releasePull(capture, applied: true, certified: true)
        let firstResult = await first.value, joinedResult = await joined.value
        expect(firstResult && joinedResult && manager.accountRestoreState == .ready,
               "first document hands off only after applied receipt and current certification agree")
        expect(manager.pushes == 0 && manager.mountStarts.isEmpty,
               "restore helper never echoes first-document pull into a push")

        resetDependencies()
        let uncertified = RestoreManagerFixture()
        let uncertainCapture = uncertified.credentialAuthority.capture()
        let uncertain = _Concurrency.Task { @MainActor in await uncertified.restoreAccountDocIfNeeded() }
        await waitUntil("uncertified first pull") { uncertified.pullStarts[uncertainCapture] == 1 }
        uncertified.releasePull(uncertainCapture, applied: true, certified: false)
        await waitUntil("uncertified first mount") { uncertified.mountStarts[uncertainCapture] == 1 }
        expect(uncertified.accountRestoreState == .restoring && !uncertified.publications.contains(.ready),
               "applied first document waits for missing native mount rather than handing off")
        uncertified.releaseMount(uncertainCapture, success: false, certify: false)
        expect(await uncertain.value == false, "applied document without certified native session cannot return success")
        expect(uncertified.accountRestoreState == .failed && !uncertified.publications.contains(.ready),
               "applied but uncertified first document publishes failure, not ready")
        expect(uncertified.pushes == 0, "uncertified first document issues no push dependency call")
        expect(uncertified.ensureStarts[uncertainCapture] == 1 && uncertified.pullStarts[uncertainCapture] == 1,
               "failed first-document mount does not spin duplicate pulls or mounts")

        resetDependencies()
        let acknowledgedOnly = RestoreManagerFixture()
        let acknowledgedCapture = acknowledgedOnly.credentialAuthority.capture()
        let acknowledgment = _Concurrency.Task { @MainActor in await acknowledgedOnly.restoreAccountDocIfNeeded() }
        await waitUntil("acknowledged but uncertified pull") { acknowledgedOnly.pullStarts[acknowledgedCapture] == 1 }
        acknowledgedOnly.releasePull(acknowledgedCapture, applied: true, certified: false)
        await waitUntil("acknowledged but uncertified mount") { acknowledgedOnly.mountStarts[acknowledgedCapture] == 1 }
        acknowledgedOnly.releaseMount(acknowledgedCapture, success: true, certify: false)
        expect(await acknowledgment.value == false,
               "mount acknowledgement without native certification cannot hand off")
        expect(acknowledgedOnly.accountRestoreState == .failed && !acknowledgedOnly.publications.contains(.ready),
               "acknowledged but uncertified mount publishes failure, never ready")
        expect(acknowledgedOnly.pushes == 0 && acknowledgedOnly.ensureStarts[acknowledgedCapture] == 1,
               "acknowledged but uncertified mount neither pushes nor retries the dependency")
    }

    static func definitivelyEmptyAccountWaitsForMount() async {
        resetDependencies()
        let manager = RestoreManagerFixture()
        let capture = manager.credentialAuthority.capture()
        var finished = false
        let first = _Concurrency.Task { @MainActor in
            let result = await manager.restoreAccountDocIfNeeded()
            finished = true
            return result
        }
        await waitUntil("definitively empty pull") { manager.pullStarts[capture] == 1 }
        // Production syncDown returns false for a definitive empty account but opens the document
        // gate. That is a known absence, not a failed pull and not a certified native session.
        manager.releasePull(capture, applied: true, certified: false, result: false)
        await waitUntil("definitively empty native mount") { manager.mountStarts[capture] == 1 }
        expect(!finished && manager.accountRestoreState == .restoring && !manager.publications.contains(.ready),
               "definitively empty account waits for native mount before setup/ready")
        let joined = _Concurrency.Task { @MainActor in await manager.restoreAccountDocIfNeeded() }
        await _Concurrency.Task<Never, Never>.yield()
        expect(manager.pullStarts[capture] == 1 && manager.mountStarts[capture] == 1,
               "empty-account concurrent callers join one pull and one held mount")
        manager.releaseMount(capture, success: true, certify: true)
        let firstResult = await first.value, joinedResult = await joined.value
        expect(firstResult && joinedResult && manager.accountRestoreState == .ready,
               "definitively empty account becomes ready only after acknowledged certified mount")
        expect(manager.pushes == 0, "empty-account restore does not seed or push before an explicit upload workflow")

        resetDependencies()
        let failed = RestoreManagerFixture()
        let failedCapture = failed.credentialAuthority.capture()
        let operation = _Concurrency.Task { @MainActor in await failed.restoreAccountDocIfNeeded() }
        await waitUntil("failed empty pull") { failed.pullStarts[failedCapture] == 1 }
        failed.releasePull(failedCapture, applied: true, certified: false, result: false)
        await waitUntil("failed empty mount") { failed.mountStarts[failedCapture] == 1 }
        failed.releaseMount(failedCapture, success: false, certify: false)
        expect(await operation.value == false && failed.accountRestoreState == .failed,
               "definitively empty account with false native mount result remains failed")
        expect(!failed.publications.contains(.ready) && failed.pushes == 0,
               "failed empty-account mount never publishes ready or requests a push")
        expect(failed.ensureStarts[failedCapture] == 1 && failed.pullStarts[failedCapture] == 1,
               "failed empty-account handoff attempts exactly one pull and one native ensure")
    }

    static func replacementRejectsStaleReady() async {
        resetDependencies()
        let manager = RestoreManagerFixture(historicallyApplied: true)
        let oldCapture = manager.credentialAuthority.capture()
        let old = _Concurrency.Task { @MainActor in await manager.restoreAccountDocIfNeeded(credentialCapture: oldCapture) }
        await waitUntil("old owner mount") { manager.mountStarts[oldCapture] == 1 }
        manager.replaceCredentials()
        let newCapture = manager.credentialAuthority.capture()
        let successor = _Concurrency.Task { @MainActor in await manager.restoreAccountDocIfNeeded(credentialCapture: newCapture) }
        await waitUntil("successor first document") { manager.pullStarts[newCapture] == 1 }
        manager.releaseMount(oldCapture, success: true, certify: true)
        expect(await old.value == false, "credential replacement rejects a held old mount result")
        expect(manager.accountRestoreState == .restoring && manager.restoreTaskCapture == newCapture,
               "old owner's defer cannot publish ready or clear successor lease")
        expect(!manager.publications.contains(.ready), "old certification never becomes new-account readiness")
        manager.releasePull(newCapture, applied: true, certified: true)
        expect(await successor.value && manager.accountRestoreState == .ready,
               "successor independently hands off after its own applied/certified restore")
        expect(manager.pushes == 0, "superseded restore issues no push dependency call")
        expect(await manager.restoreAccountDocIfNeeded(credentialCapture: oldCapture) == false,
               "explicit stale capture cannot start a new restore")
    }

    static func exhaustedRetriesStayFailed() async {
        resetDependencies()
        let manager = RestoreManagerFixture()
        let capture = manager.credentialAuthority.capture()
        let operation = _Concurrency.Task { @MainActor in await manager.restoreAccountDocIfNeeded() }
        for attempt in 1...5 {
            await waitUntil("failed pull \(attempt)") { manager.pullStarts[capture] == attempt }
            manager.releasePull(capture, applied: false, certified: false, result: false)
        }
        expect(await operation.value == false && manager.accountRestoreState == .failed,
               "five exhausted pull attempts leave both restore result and publication failed")
        expect(manager.pushes == 0 && !manager.publications.contains(.ready), "exhausted restore never requests push or ready")
        expect(RestoreFixtureClock.requestedBackoffs == [1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000],
               "actual production retry loop requests bounded backoff and exactly five pulls")

        resetDependencies()
        let boundary = RestoreManagerFixture()
        let boundaryCapture = boundary.credentialAuthority.capture()
        let final = _Concurrency.Task { @MainActor in await boundary.restoreAccountDocIfNeeded() }
        for attempt in 1...5 {
            await waitUntil("boundary pull \(attempt)") { boundary.pullStarts[boundaryCapture] == attempt }
            if attempt == 5 {
                // Stress an independently persisted receipt advancing between the last loop check and
                // fallback return. The first two reads still report no applied receipt; subsequent
                // reads report applied, but there is deliberately no native certificate.
                boundary.appliedReadOverrides = [false, false]
                boundary.releasePull(boundaryCapture, applied: true, certified: false, result: false)
            } else {
                boundary.releasePull(boundaryCapture, applied: false, certified: false, result: false)
            }
        }
        await waitUntil("uncertified final fallback mount") { boundary.mountStarts[boundaryCapture] == 1 }
        expect(boundary.accountRestoreState == .restoring && !boundary.publications.contains(.ready),
               "final fallback waits for native certification after the late document receipt")
        boundary.releaseMount(boundaryCapture, success: false, certify: false)
        expect(await final.value == false, "final fallback cannot return success from document receipt alone")
        expect(boundary.accountRestoreState == .failed && !boundary.publications.contains(.ready),
               "final fallback still publishes failure when native certification is absent")
        expect(boundary.pushes == 0, "uncertified final fallback issues no push dependency call")
        expect(boundary.ensureStarts[boundaryCapture] == 1 && boundary.pullStarts[boundaryCapture] == 5,
               "final fallback attempts one native ensure only after exactly five pulls")
    }

    static func main() async {
        await historicalReceiptWaitsForMount()
        await failedHistoricalMountCannotReady()
        await firstDocumentRequiresCertification()
        await definitivelyEmptyAccountWaitsForMount()
        await replacementRejectsStaleReady()
        await exhaustedRetriesStayFailed()
        print("AccountRestoreHandoffTests: \(checks) actual extracted production checks passed; offline dependency fixtures only")
    }
}
