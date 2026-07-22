// Standalone executable for the credential owner and sync-session fences.
//
// This test extracts the real production primitives from DebridKeys.swift and
// VortXSyncManager.swift, compiles those exact definitions into a child
// executable, and exercises their concurrent behavior. VortX has no Xcode test
// bundle, so keeping the extraction fail-closed prevents a copied test shim
// from drifting away from the code the app ships.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/credential-owner-tests app/Tests/CredentialOwnerScopingTests.swift
//   /tmp/credential-owner-tests

import Foundation

private enum HarnessError: Error, CustomStringConvertible {
    case missingMarker(String)
    case childCompile(String)
    case childRun(String)

    var description: String {
        switch self {
        case .missingMarker(let marker): return "missing production marker: \(marker)"
        case .childCompile(let output): return "child compile failed:\n\(output)"
        case .childRun(let output): return "child tests failed:\n\(output)"
        }
    }
}

private func sourcePath(environmentKey: String, defaultRelativePath: String) -> String {
    if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
        return override
    }
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return tests.deletingLastPathComponent().appendingPathComponent(defaultRelativePath).path
}

private func extract(_ source: String, begin: String, end: String) throws -> String {
    guard let beginRange = source.range(of: begin) else { throw HarnessError.missingMarker(begin) }
    let bodyStart = beginRange.upperBound
    guard let endRange = source.range(of: end, range: bodyStart..<source.endIndex) else {
        throw HarnessError.missingMarker(end)
    }
    return String(source[bodyStart..<endRange.lowerBound])
}

// ORDER-SENSITIVE marker checks. Presence alone lets a mutant that MOVES a gate to a useless position stay
// green; these assert the gate sits AFTER the suspension point and BEFORE the apply, so a removal OR a reorder
// turns the corresponding assertion red.

/// True iff `gateToken` occurs strictly AFTER the first occurrence of `awaitToken` in `region`.
private func gateAfterAwait(_ region: String, awaitToken: String, gateToken: String) -> Bool {
    guard let a = region.range(of: awaitToken) else { return false }
    return region.range(of: gateToken, range: a.upperBound..<region.endIndex) != nil
}

/// True iff `gateToken` occurs, and `applyToken` occurs strictly AFTER it (gate guards the apply).
private func gateBeforeApply(_ region: String, gateToken: String, applyToken: String) -> Bool {
    guard let g = region.range(of: gateToken) else { return false }
    return region.range(of: applyToken, range: g.upperBound..<region.endIndex) != nil
}

/// True iff the three tokens appear in the order await -> gate -> apply (a full suspend/revalidate/apply gate).
private func orderedAwaitGateApply(_ region: String, awaitToken: String, gateToken: String, applyToken: String) -> Bool {
    guard let a = region.range(of: awaitToken) else { return false }
    guard let g = region.range(of: gateToken, range: a.upperBound..<region.endIndex) else { return false }
    return region.range(of: applyToken, range: g.upperBound..<region.endIndex) != nil
}

/// Count of non-overlapping occurrences of `sub` in `s`.
private func occurrences(_ s: String, _ sub: String) -> Int {
    guard !sub.isEmpty else { return 0 }
    var count = 0
    var idx = s.startIndex
    while let r = s.range(of: sub, range: idx..<s.endIndex) {
        count += 1
        idx = r.upperBound
    }
    return count
}

private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@main
private enum CredentialOwnerScopingHarness {
    static func main() throws {
        let debridPath = sourcePath(
            environmentKey: "VORTX_CREDENTIAL_DEBRID_SOURCE",
            defaultRelativePath: "SourcesShared/DebridKeys.swift"
        )
        let syncPath = sourcePath(
            environmentKey: "VORTX_CREDENTIAL_SYNC_SOURCE",
            defaultRelativePath: "SourcesShared/VortXSyncManager.swift"
        )
        let debridSource = try String(contentsOfFile: debridPath, encoding: .utf8)
        let syncSource = try String(contentsOfFile: syncPath, encoding: .utf8)

        let identity = try extract(
            debridSource,
            begin: "// CREDENTIAL_OWNER_IDENTITY_BEGIN",
            end: "// CREDENTIAL_OWNER_IDENTITY_END"
        )
        let reloadFence = try extract(
            debridSource,
            begin: "// CREDENTIAL_RELOAD_FENCE_BEGIN",
            end: "// CREDENTIAL_RELOAD_FENCE_END"
        )
        let sessionStamp = try extract(
            syncSource,
            begin: "// CREDENTIAL_SESSION_STAMP_BEGIN",
            end: "// CREDENTIAL_SESSION_STAMP_END"
        )
        let restoreTaskSlot = try extract(
            syncSource,
            begin: "// CREDENTIAL_RESTORE_TASK_SLOT_BEGIN",
            end: "// CREDENTIAL_RESTORE_TASK_SLOT_END"
        )
        let syncResolverReload = try extract(
            syncSource,
            begin: "// CREDENTIAL_SYNC_RESOLVER_RELOAD_BEGIN",
            end: "// CREDENTIAL_SYNC_RESOLVER_RELOAD_END"
        )
        let pushCompletionGate = try extract(
            syncSource,
            begin: "// CREDENTIAL_PUSH_COMPLETION_GATE_BEGIN",
            end: "// CREDENTIAL_PUSH_COMPLETION_GATE_END"
        )
        // The systematic session-stamp gate sites added by INS-06 (the SYSTEMATIC corrections). Each is
        // extracted and checked for order-sensitive placement, so a gate REMOVAL or REORDER mutant turns the
        // matching assertion red.
        let sessionGateHelper = try extract(
            syncSource,
            begin: "// CREDENTIAL_SESSION_GATE_BEGIN",
            end: "// CREDENTIAL_SESSION_GATE_END"
        )
        let refreshAccountGate = try extract(
            syncSource,
            begin: "// CREDENTIAL_REFRESH_ACCOUNT_GATE_BEGIN",
            end: "// CREDENTIAL_REFRESH_ACCOUNT_GATE_END"
        )
        let syncDownFinalGate = try extract(
            syncSource,
            begin: "// CREDENTIAL_SYNCDOWN_FINAL_APPLY_GATE_BEGIN",
            end: "// CREDENTIAL_SYNCDOWN_FINAL_APPLY_GATE_END"
        )
        let syncUpPushGate = try extract(
            syncSource,
            begin: "// CREDENTIAL_SYNCUP_PUSH_GATE_BEGIN",
            end: "// CREDENTIAL_SYNCUP_PUSH_GATE_END"
        )
        let syncUpRestoreGate = try extract(
            syncSource,
            begin: "// CREDENTIAL_SYNCUP_RESTORE_GATE_BEGIN",
            end: "// CREDENTIAL_SYNCUP_RESTORE_GATE_END"
        )
        let mergePullGate = try extract(
            syncSource,
            begin: "// CREDENTIAL_MERGE_PULL_GATE_BEGIN",
            end: "// CREDENTIAL_MERGE_PULL_GATE_END"
        )
        let mergeTokenGate = try extract(
            syncSource,
            begin: "// CREDENTIAL_MERGE_TOKEN_GATE_BEGIN",
            end: "// CREDENTIAL_MERGE_TOKEN_GATE_END"
        )
        let hydrateGate = try extract(
            syncSource,
            begin: "// CREDENTIAL_HYDRATE_GATE_BEGIN",
            end: "// CREDENTIAL_HYDRATE_GATE_END"
        )
        let recoverLoopGate = try extract(
            syncSource,
            begin: "// CREDENTIAL_RECOVER_LOOP_GATE_BEGIN",
            end: "// CREDENTIAL_RECOVER_LOOP_GATE_END"
        )
        let traktTask = try extract(
            syncSource,
            begin: "// CREDENTIAL_SYNCDOWN_TRAKT_TASK_BEGIN",
            end: "// CREDENTIAL_SYNCDOWN_TRAKT_TASK_END"
        )
        let simklTask = try extract(
            syncSource,
            begin: "// CREDENTIAL_SYNCDOWN_SIMKL_TASK_BEGIN",
            end: "// CREDENTIAL_SYNCDOWN_SIMKL_TASK_END"
        )
        let mediaServerTask = try extract(
            syncSource,
            begin: "// CREDENTIAL_SYNCDOWN_MEDIASERVER_TASK_BEGIN",
            end: "// CREDENTIAL_SYNCDOWN_MEDIASERVER_TASK_END"
        )
        let uninstallTask = try extract(
            syncSource,
            begin: "// CREDENTIAL_SYNCDOWN_UNINSTALL_TASK_BEGIN",
            end: "// CREDENTIAL_SYNCDOWN_UNINSTALL_TASK_END"
        )
        let syncResolverReloadUsesFence = syncResolverReload
            .trimmingCharacters(in: .whitespacesAndNewlines) == "debrid.reloadResolvers()"
        // 2b is now ORDER-SENSITIVE (was presence-only): the gate must sit AFTER the PUT await and BEFORE the
        // success stamp, so moving it below the stamp (or deleting it) turns the stale-completion test red.
        let pushCompletionGateOrdered = orderedAwaitGateApply(
            pushCompletionGate,
            awaitToken: "request(\"PUT\"",
            gateToken: "isCurrentCredentialSession(pushSession)",
            applyToken: "lastSyncedVersion = max"
        )
        // The central reusable gate revalidates AFTER running the async work (capture / work / revalidate).
        let sessionGateRevalidatesAfterWork = gateAfterAwait(
            sessionGateHelper, awaitToken: "await work()", gateToken: "isCurrentCredentialSession(session)"
        )
        // M-1: revalidate-after-work alone is not enough. A mutant that MOVES the capture below `await work()`
        // still leaves the revalidate after the await (so sessionGateRevalidatesAfterWork stays true) yet makes
        // the gate a no-op: it captures + stamps whatever session is current AFTER the suspension. Assert the full
        // capture -> await -> revalidate ordering so the stamp-after-await mutant turns red. The capture token is
        // the code statement `let session = credentialSessionStamp` (not the bare identifier), so the doc comment's
        // mention of `credentialSessionStamp` above the body cannot satisfy the ordering on its own.
        let sessionGateCapturesBeforeWork = orderedAwaitGateApply(
            sessionGateHelper,
            awaitToken: "let session = credentialSessionStamp",
            gateToken: "await work()",
            applyToken: "isCurrentCredentialSession(session)"
        )
        let refreshAccountGateOrdered = gateBeforeApply(
            refreshAccountGate, gateToken: "withCredentialSessionGate", applyToken: "account = a"
        )
        let syncDownFinalGateOrdered = gateAfterAwait(
            syncDownFinalGate, awaitToken: "pullDocVersionedRetrying", gateToken: "isCurrentCredentialSession(syncSession)"
        )
        let syncUpPushGateOrdered = gateBeforeApply(
            syncUpPushGate, gateToken: "isCurrentCredentialSession(syncSession)", applyToken: "pushDerivedDoc"
        )
        let syncUpRestoreGatePresent = syncUpRestoreGate.contains("isCurrentCredentialSession(syncSession)")
        let mergePullGateOrdered = gateAfterAwait(
            mergePullGate, awaitToken: "await request(\"GET\"", gateToken: "isCurrentCredentialSession(session)"
        )
        let mergeTokenGateCount = occurrences(mergeTokenGate, "isCurrentCredentialSession(session)")
        let hydrateGateOrdered = gateAfterAwait(
            hydrateGate, awaitToken: "pullSyncDocResult", gateToken: "isCurrentCredentialSession(hydrateSession)"
        )
        let recoverLoopGatePresent = recoverLoopGate.contains("isCurrentCredentialSession(session)")
        let traktTaskOrdered = gateBeforeApply(
            traktTask, gateToken: "isCurrentCredentialSession(syncSession)", applyToken: "adoptTokens"
        )
        let simklTaskOrdered = gateBeforeApply(
            simklTask, gateToken: "isCurrentCredentialSession(syncSession)", applyToken: "adoptTokens"
        )
        let mediaServerTaskOrdered = gateBeforeApply(
            mediaServerTask, gateToken: "isCurrentCredentialSession(syncSession)", applyToken: "applySyncBlob"
        )
        let uninstallTaskOrdered = gateBeforeApply(
            uninstallTask, gateToken: "isCurrentCredentialSession(syncSession)", applyToken: "uninstallAddon"
        )

        let child = #"""
import Foundation

\#(identity)
\#(reloadFence)
\#(sessionStamp)
\#(restoreTaskSlot)

let productionSyncResolverReloadUsesFence = \#(syncResolverReloadUsesFence)
let productionPushCompletionGateOrdered = \#(pushCompletionGateOrdered)
let productionSessionGateRevalidatesAfterWork = \#(sessionGateRevalidatesAfterWork)
let productionSessionGateCapturesBeforeWork = \#(sessionGateCapturesBeforeWork)
let productionRefreshAccountGateOrdered = \#(refreshAccountGateOrdered)
let productionSyncDownFinalGateOrdered = \#(syncDownFinalGateOrdered)
let productionSyncUpPushGateOrdered = \#(syncUpPushGateOrdered)
let productionSyncUpRestoreGatePresent = \#(syncUpRestoreGatePresent)
let productionMergePullGateOrdered = \#(mergePullGateOrdered)
let productionMergeTokenGateCount = \#(mergeTokenGateCount)
let productionHydrateGateOrdered = \#(hydrateGateOrdered)
let productionRecoverLoopGatePresent = \#(recoverLoopGatePresent)
let productionTraktTaskOrdered = \#(traktTaskOrdered)
let productionSimklTaskOrdered = \#(simklTaskOrdered)
let productionMediaServerTaskOrdered = \#(mediaServerTaskOrdered)
let productionUninstallTaskOrdered = \#(uninstallTaskOrdered)

actor ApplyProbe {
    private let blockA: Bool
    private var values: [String] = []
    private var aStarted = false
    private var aContinuation: CheckedContinuation<Void, Never>?

    init(blockA: Bool) {
        self.blockA = blockA
    }

    func apply(_ value: String) async {
        if value == "A", blockA {
            aStarted = true
            await withCheckedContinuation { continuation in
                aContinuation = continuation
            }
        }
        values.append(value)
    }

    func hasStartedA() -> Bool { aStarted }
    func releaseA() {
        aContinuation?.resume()
        aContinuation = nil
    }
    func appliedValues() -> [String] { values }
}

@main
@MainActor
enum CredentialOwnerScopingTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            print("PASS \(name)")
        } else {
            failures += 1
            print("FAIL \(name)")
        }
    }

    static func waitUntilAStarts(_ probe: ApplyProbe) async {
        for _ in 0..<10_000 {
            if await probe.hasStartedA() { return }
            await Task.yield()
        }
    }

    static func testRapidOwnerSwitchEndsAtB() async {
        let fence = LatestCredentialReload<String>()
        let probe = ApplyProbe(blockA: true)
        let first = Task {
            await fence.submit(generation: 1, value: "A") { value in
                await probe.apply(value)
            }
        }
        await waitUntilAStarts(probe)
        let second = Task {
            await fence.submit(generation: 2, value: "B") { value in
                await probe.apply(value)
            }
        }
        await Task.yield()
        await probe.releaseA()
        await first.value
        await second.value
        for _ in 0..<100 { await Task.yield() }
        let values = await probe.appliedValues()
        expect(values.last == "B", "rapid A to B leaves coordinator at B")
        expect(values == ["A", "B"], "in-flight A serializes before B")
    }

    static func testSignOutDuringPullDiscardsResult() async {
        let captured = CredentialSessionStamp(accountID: "acct_A", generation: 7)
        var writes = 0
        await Task.yield()
        if captured.isCurrent(accountID: "acct_A", generation: 8, isSignedIn: false) {
            writes += 1
        }
        expect(writes == 0, "sign-out mid-pull discards result without writes")
    }

    static func testMissingIDRejected() {
        expect(CredentialOwnerIdentity.remoteAccountID(nil) == nil,
               "missing account id is rejected")
        expect(CredentialOwnerIdentity.accountNamespace(prefix: "scope.", accountID: nil) == nil,
               "missing account id creates no namespace")
    }

    static func testEmptyIDRejectedWithoutLocalAlias() {
        expect(CredentialOwnerIdentity.remoteAccountID("") == nil,
               "empty account id is rejected")
        expect(CredentialOwnerIdentity.remoteAccountID("   ") == nil,
               "whitespace account id is rejected")
        expect(CredentialOwnerIdentity.remoteAccountID(CredentialOwnerIdentity.deviceOwnerID) == nil,
               "remote account cannot alias explicit signed-out owner")
        expect(CredentialOwnerIdentity.accountNamespace(prefix: "scope.", accountID: "") == nil,
               "empty account id creates no namespace")
        expect(CredentialOwnerIdentity.explicitOwnerID(CredentialOwnerIdentity.deviceOwnerID)
               == CredentialOwnerIdentity.deviceOwnerID,
               "explicit signed-out device owner remains supported")
    }

    static func testLateSupersededGenerationNeverApplies() async {
        let fence = LatestCredentialReload<String>()
        let probe = ApplyProbe(blockA: false)
        await fence.submit(generation: 2, value: "B") { value in
            await probe.apply(value)
        }
        await fence.submit(generation: 1, value: "A") { value in
            await probe.apply(value)
        }
        let values = await probe.appliedValues()
        expect(values == ["B"], "late superseded generation is not applied")
    }

    static func testLateCombinedSyncDownResolverReloadIsFenced() async {
        let fence = LatestCredentialReload<String>()
        let probe = ApplyProbe(blockA: false)
        await fence.submit(generation: 22, value: "bind_B") { value in
            await probe.apply(value)
        }
        await fence.submit(generation: 21, value: "syncDown_A_combined") { value in
            await probe.apply(value)
        }
        let values = await probe.appliedValues()
        expect(values == ["bind_B"] && productionSyncResolverReloadUsesFence,
               "late combined syncDown A resolver reload after B is dropped")
    }

    static func testStalePushCompletionAfterAccountSwitchDoesNotStamp() {
        let captured = CredentialSessionStamp(accountID: "acct_A", generation: 31)
        var successStamps = 0
        // ORDER-SENSITIVE now: the gate must sit between the PUT await and the success stamp. A mutant that
        // deletes it OR moves it below `lastSyncedVersion = max` flips productionPushCompletionGateOrdered false.
        if !productionPushCompletionGateOrdered ||
            captured.isCurrent(accountID: "acct_B", generation: 32, isSignedIn: true) {
            successStamps += 1
        }
        expect(successStamps == 0,
               "stale A push completion after B writes no B stamp (order-sensitive)")
    }

    /// Shared model for every single-apply gate added by the SYSTEMATIC INS-06 pass. `productionOrdered` is the
    /// order-sensitive marker check for the site; the `isCurrent` call is the exact predicate the production gate
    /// evaluates, modelling the discard of a stale account-A completion after a switch to account B. The apply
    /// fires ONLY IF the production gate is missing / misordered OR the discard predicate wrongly stays true, so
    /// a gate-removal mutant on that site turns this assertion red.
    static func expectStaleCompletionDiscarded(_ productionOrdered: Bool, _ name: String) {
        let captured = CredentialSessionStamp(accountID: "acct_A", generation: 100)
        var applied = 0
        if !productionOrdered || captured.isCurrent(accountID: "acct_B", generation: 101, isSignedIn: true) {
            applied += 1
        }
        expect(applied == 0, name)
    }

    static func testRefreshAccountStaleCompletionDiscarded() {
        expectStaleCompletionDiscarded(
            productionRefreshAccountGateOrdered,
            "refreshAccount discards a stale /me completion after an account switch"
        )
    }

    static func testSyncDownStalePullDiscardedAfterSwitch() {
        expectStaleCompletionDiscarded(
            productionSyncDownFinalGateOrdered,
            "syncDown final apply gate discards a stale pulled doc after an account switch"
        )
    }

    static func testHydrateStalePullDiscardedAfterSwitch() {
        expectStaleCompletionDiscarded(
            productionHydrateGateOrdered,
            "hydrate discards a stale account doc after an account switch"
        )
    }

    static func testDeferredTaskBodiesRecheckSession() {
        // Each of the four unstructured Tasks spawned from the syncDown apply region must re-check the captured
        // session INSIDE its body before applying, so a switch between spawning and running drops the apply.
        expectStaleCompletionDiscarded(productionTraktTaskOrdered,
            "syncDown Trakt Task re-checks the session before adopting tokens")
        expectStaleCompletionDiscarded(productionSimklTaskOrdered,
            "syncDown SIMKL Task re-checks the session before adopting tokens")
        expectStaleCompletionDiscarded(productionMediaServerTaskOrdered,
            "syncDown media-server Task re-checks the session before applying the blob")
        expectStaleCompletionDiscarded(productionUninstallTaskOrdered,
            "syncDown uninstall Task re-checks the session before uninstalling add-ons")
    }

    static func testSyncUpMidAwaitSwitchNoOverwrite() {
        // A switch to account B lands during syncUp's merge; the pre-push gate must fail so A's merged doc is
        // never pushed over B's server document. Modelled by the discard predicate plus the site's order checks.
        let session = CredentialSessionStamp(accountID: "acct_A", generation: 9)
        let pushWouldRun = session.isCurrent(accountID: "acct_B", generation: 10, isSignedIn: true)
        expect(!pushWouldRun, "syncUp: a mid-merge A->B switch fails the pre-push session predicate")
        expect(productionSyncUpPushGateOrdered, "syncUp gates between the merge await and pushDerivedDoc")
        expect(productionSyncUpRestoreGatePresent, "syncUp revalidates the session after restoreAccountDocIfNeeded")
        expect(productionMergePullGateOrdered, "mergeLocalIntoDoc revalidates after its base pull await")
        expect(productionMergeTokenGateCount >= 2, "mergeLocalIntoDoc revalidates after each token await")
    }

    static func testRecoverLoopStopsMidSwitch() {
        // Model the recover re-add loop: it re-checks the session at the TOP of each iteration and BREAKS once
        // the session is no longer current, so a switch after some items stops adding A's titles under B.
        let session = CredentialSessionStamp(accountID: "acct_A", generation: 5)
        var currentAccount = "acct_A"
        var currentGen: UInt64 = 5
        var addedUnderA = 0
        for i in 0..<5 {
            guard session.isCurrent(accountID: currentAccount, generation: currentGen, isSignedIn: true) else { break }
            if i == 1 { currentAccount = "acct_B"; currentGen = 6 }   // switch lands during iteration 1's re-add await
            addedUnderA += 1
        }
        expect(addedUnderA == 2, "recover loop stops adding once the session switches to B")
        expect(productionRecoverLoopGatePresent, "recover loop has a per-iteration session gate")
    }

    static func testCentralSessionGateRevalidatesAfterWork() {
        expect(productionSessionGateRevalidatesAfterWork,
               "the central session gate revalidates AFTER running the work (capture / work / revalidate)")
        expect(productionSessionGateCapturesBeforeWork,
               "the central session gate captures the session BEFORE the await (stamp-after-await mutant is a no-op)")
    }

    static func testOldRestoreCleanupCannotClearNewSessionTask() async {
        let oldSession = CredentialSessionStamp(accountID: "acct_A", generation: 11)
        let newSession = CredentialSessionStamp(accountID: "acct_B", generation: 12)
        let slot = CredentialRestoreTaskSlot()
        let oldTask = Task { false }
        slot.install(oldTask, for: oldSession)
        slot.cancelAndClear()
        let newTask = Task { true }
        slot.install(newTask, for: newSession)

        // Models the cancelled old task reaching its deferred cleanup after the new install.
        slot.clear(ifOwnedBy: oldSession)
        expect(slot.task(for: newSession) != nil,
               "old restore cleanup cannot clear new session task")
        slot.cancelAndClear()
        _ = await oldTask.value
        _ = await newTask.value
    }

    static func main() async {
        await testRapidOwnerSwitchEndsAtB()
        await testSignOutDuringPullDiscardsResult()
        testMissingIDRejected()
        testEmptyIDRejectedWithoutLocalAlias()
        await testLateSupersededGenerationNeverApplies()
        await testLateCombinedSyncDownResolverReloadIsFenced()
        testStalePushCompletionAfterAccountSwitchDoesNotStamp()
        await testOldRestoreCleanupCannotClearNewSessionTask()
        // SYSTEMATIC INS-06 session-stamp gate coverage (the recurring TOCTOU on every post-await apply path).
        testCentralSessionGateRevalidatesAfterWork()
        testRefreshAccountStaleCompletionDiscarded()
        testSyncDownStalePullDiscardedAfterSwitch()
        testHydrateStalePullDiscardedAfterSwitch()
        testDeferredTaskBodiesRecheckSession()
        testSyncUpMidAwaitSwitchNoOverwrite()
        testRecoverLoopStopsMidSwitch()
        if failures > 0 {
            print("FAILED \(failures) assertion(s)")
            Foundation.exit(1)
        }
        print("PASS credential owner scoping contract")
    }
}
"""#

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vortx-credential-owner-tests-\(ProcessInfo.processInfo.processIdentifier)"
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let childSource = temporary.appendingPathComponent("CredentialOwnerChild.swift")
        let childBinary = temporary.appendingPathComponent("CredentialOwnerChild")
        try child.write(to: childSource, atomically: true, encoding: .utf8)

        let compile = try run("/usr/bin/xcrun", [
            "swiftc", "-parse-as-library", "-strict-concurrency=complete", "-warnings-as-errors",
            "-o", childBinary.path, childSource.path,
        ])
        guard compile.status == 0 else { throw HarnessError.childCompile(compile.output) }
        let result = try run(childBinary.path, [])
        print(result.output, terminator: "")
        guard result.status == 0 else { throw HarnessError.childRun(result.output) }
    }
}
