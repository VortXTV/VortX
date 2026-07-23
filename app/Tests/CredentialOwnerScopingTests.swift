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
        let syncResolverReloadUsesFence = syncResolverReload
            .trimmingCharacters(in: .whitespacesAndNewlines) == "debrid.reloadResolvers()"
        let pushCompletionGatePresent = pushCompletionGate.contains(
            "isCurrentCredentialSession(pushSession)"
        )

        let child = #"""
import Foundation

\#(identity)
\#(reloadFence)
\#(sessionStamp)
\#(restoreTaskSlot)

let productionSyncResolverReloadUsesFence = \#(syncResolverReloadUsesFence)
let productionPushCompletionGatePresent = \#(pushCompletionGatePresent)

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
        if !productionPushCompletionGatePresent ||
            captured.isCurrent(accountID: "acct_B", generation: 32, isSignedIn: true) {
            successStamps += 1
        }
        expect(successStamps == 0,
               "stale A push completion after B writes no B stamp")
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
