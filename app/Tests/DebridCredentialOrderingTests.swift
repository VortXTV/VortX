// Standalone executable gate over the production credential state primitives.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
//     -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     app/SourcesShared/DebridCredentialState.swift \
//     app/Tests/DebridCredentialOrderingTests.swift \
//     -o /tmp/debrid-credential-ordering && /tmp/debrid-credential-ordering
//
// The production state file is Foundation-only so this suite can exercise the real revision, owner,
// snapshot-store, and migration laws without an app target or test-only reimplementation.

import Foundation

private struct Results {
    private(set) var passed = 0
    private(set) var failed: [String] = []

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passed += 1
            print("PASS  \(message)")
        } else {
            failed.append(message)
            print("FAIL  \(message)")
        }
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return messages.isEmpty
    }
}

private final class MemoryCredentialStorage {
    var values: [String: String] = [:]
    var failWrites: Set<String> = []
    var corruptReadback: Set<String> = []
    var failDeletes: Set<String> = []

    func read(_ key: String) -> String? {
        guard values[key] != nil, corruptReadback.contains(key) else { return values[key] }
        return "corrupt"
    }

    func write(_ value: String, _ key: String) -> Bool {
        guard !failWrites.contains(key) else { return false }
        values[key] = value
        return true
    }

    func delete(_ key: String) -> Bool {
        guard !failDeletes.contains(key) else { return false }
        values.removeValue(forKey: key)
        return true
    }
}

private let accountAString = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let accountBString = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private let accountA = UUID(uuidString: accountAString)!
private let accountB = UUID(uuidString: accountBString)!

private func snapshot(_ owner: DebridOwnerScope, _ revision: UInt64,
                      _ keys: [DebridService: String] = [:]) -> DebridCredentialSnapshot {
    DebridCredentialSnapshot(owner: owner, revision: revision, keys: keys)
}

private func testOwnerGrammar(_ results: inout Results) {
    results.expect(DebridOwnerScope.canonicalAccount(accountAString) == .account(accountA),
                   "lowercase server UUID is a canonical account owner")
    results.expect(DebridOwnerScope.canonicalAccount(accountAString.uppercased()) == nil,
                   "uppercase UUID-like owner remains noncanonical and unmigrated")
    results.expect(DebridOwnerScope.canonicalAccount("{\(accountAString)}") == nil,
                   "braced UUID-like owner remains noncanonical and unmigrated")
    results.expect(DebridOwnerScope.canonicalAccount("") == nil,
                   "empty signed-in owner is rejected rather than mapped to signed out")
    results.expect(DebridOwnerScope.canonicalAccount("local") == nil,
                   "literal local cannot become a signed-in namespace")
    results.expect(DebridOwnerScope.signedOutDevice.storageNamespace
                   != DebridOwnerScope.account(accountA).storageNamespace,
                   "signed-out and account storage namespaces are disjoint")
    results.expect(DebridService.torBox.keychainAccount(owner: .signedOutDevice)
                   == "vortx.debrid.torBox.local",
                   "old local slot stays permanently device-local")
}

private func testRevisionOrdering(_ results: inout Results) {
    let a1 = snapshot(.account(accountA), 1, [.realDebrid: "a1"])
    let signedOut2 = snapshot(.signedOutDevice, 2)
    let b3 = snapshot(.account(accountB), 3, [.torBox: "b3"])
    let orders = [
        [a1, signedOut2, b3], [a1, b3, signedOut2], [signedOut2, a1, b3],
        [signedOut2, b3, a1], [b3, a1, signedOut2], [b3, signedOut2, a1],
    ]
    for (index, order) in orders.enumerated() {
        var fence = DebridCredentialRevisionFence()
        var accepted: DebridCredentialSnapshot?
        for candidate in order where fence.accept(candidate) { accepted = candidate }
        results.expect(accepted == b3, "adverse delivery order \(index + 1) leaves B revision 3 final")
    }

    var fence = DebridCredentialRevisionFence()
    results.expect(fence.accept(b3), "first delivered snapshot is accepted")
    results.expect(!fence.accept(b3), "equal revision never rebuilds resolvers")
    results.expect(!fence.accept(signedOut2), "older revision never rebuilds resolvers")
}

private func testMutableState(_ results: inout Results) {
    var state = DebridCredentialMutableState(owner: .signedOutDevice,
                                             keys: [.realDebrid: "local-a"])
    let initial = state.snapshot
    results.expect(initial.revision == 1 && initial.owner == .signedOutDevice,
                   "relaunch without session publishes device-local revision 1")

    let boundA = state.replace(owner: .account(accountA), keys: [.realDebrid: "account-a"])
    results.expect(boundA?.revision == 2 && boundA?.owner == .account(accountA),
                   "restored-account bind advances owner and key revision once")

    let edit = state.setKey("newest", for: .realDebrid)
    results.expect(edit?.revision == 3 && edit?.keys[.realDebrid] == "newest",
                   "one local key edit advances exactly one revision")
    results.expect(state.setKey("newest", for: .realDebrid) == nil,
                   "idempotent local edit publishes no duplicate revision")

    let beforeRemote = state.revision
    let remote = state.applyRemoteKeys([.allDebrid: "ad", .premiumize: "pm", .torBox: "tb"])
    results.expect(remote?.revision == beforeRemote + 1,
                   "four-service remote apply publishes exactly one revision")
    results.expect(remote?.keys[.realDebrid] == "newest",
                   "remote apply preserves absent services")
    results.expect(remote?.keys[.allDebrid] == "ad"
                   && remote?.keys[.premiumize] == "pm"
                   && remote?.keys[.torBox] == "tb",
                   "remote apply publishes one complete key envelope")

    let signedOut = state.replace(owner: .signedOutDevice, keys: [.realDebrid: "device"])
    let store = DebridCredentialSnapshotStore(initial: remote!)
    results.expect(store.publish(signedOut!), "sign-out snapshot publishes synchronously")
    results.expect(store.load() == signedOut,
                   "later coordinator operation observes signed-out state immediately")
}

private func testStoreAndInFlightFences(_ results: inout Results) {
    let local1 = snapshot(.signedOutDevice, 1, [.realDebrid: "local"])
    let a2 = snapshot(.account(accountA), 2, [.realDebrid: "account"])
    let b3 = snapshot(.account(accountB), 3, [.torBox: "new"])
    let store = DebridCredentialSnapshotStore(initial: local1)

    results.expect(store.publish(a2), "account restore supersedes a captured local lazy warm")
    results.expect(!store.publish(local1), "delayed local lazy warm cannot replace restored account")
    results.expect(store.publish(b3), "account B bind supersedes account A")
    results.expect(!store.publish(a2), "delayed account A edit cannot replace account B")
    results.expect(store.isCurrent(revision: 3), "revision 3 may spend its credential")
    results.expect(!store.isCurrent(revision: 2),
                   "revision A is rejected at credential use after revision B")
    results.expect(!store.resultIsCurrent(revision: 2),
                   "provider result issued under A is rejected after B")
    results.expect(store.isConfigured(.torBox),
                   "detached configured-service query reads immutable current snapshot")
    results.expect(!store.isConfigured(.realDebrid),
                   "detached query never sees a stale owner's configured service")

    let newest = snapshot(.account(accountB), 6, [.torBox: "six"])
    let edit5 = snapshot(.account(accountB), 5, [.torBox: "five"])
    let edit4 = snapshot(.account(accountB), 4, [.torBox: "four"])
    results.expect(store.publish(newest), "newest per-keystroke edit is accepted first")
    results.expect(!store.publish(edit5) && !store.publish(edit4),
                   "older per-keystroke tasks delivered last are rejected")
    results.expect(store.load() == newest, "newest-first delivery remains newest")
}

private func migrate(_ storage: MemoryCredentialStorage, target: String, sources: [String])
    -> DebridCredentialMigrationResult {
    DebridCredentialMigration.migrateFirstAvailable(
        target: target,
        sources: sources,
        read: storage.read,
        write: storage.write,
        delete: storage.delete
    )
}

private func testMigration(_ results: inout Results) {
    let targetA = DebridService.realDebrid.keychainAccount(owner: .account(accountA))
    let targetB = DebridService.realDebrid.keychainAccount(owner: .account(accountB))
    let rawA = DebridService.realDebrid.legacyRawAccountKeychainAccount(accountA)
    let rawB = DebridService.realDebrid.legacyRawAccountKeychainAccount(accountB)
    let global = DebridService.realDebrid.legacyGlobalKeychainAccount

    do {
        let storage = MemoryCredentialStorage()
        storage.values[targetA] = "target"
        storage.values[rawA] = "raw"
        storage.values[global] = "global"
        results.expect(migrate(storage, target: targetA, sources: [rawA, global]) == .targetPresent,
                       "existing target wins over raw and global sources")
        results.expect(storage.values[rawA] == "raw" && storage.values[global] == "global",
                       "target conflict retains every source")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[rawA] = "raw-a"
        results.expect(migrate(storage, target: targetA, sources: [rawA, global]) == .migrated,
                       "matching readback migrates the raw account source")
        results.expect(storage.values[targetA] == "raw-a" && storage.values[rawA] == nil,
                       "successful copy deletes only its source")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[rawA] = "a"
        storage.values[rawB] = "b"
        results.expect(migrate(storage, target: targetA, sources: [rawA]) == .migrated,
                       "account A raw-scope migration runs")
        results.expect(migrate(storage, target: targetB, sources: [rawB]) == .migrated,
                       "account B raw-scope migration also runs in one process")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[rawA] = "secret"
        storage.failWrites.insert(targetA)
        results.expect(migrate(storage, target: targetA, sources: [rawA]) == .writeFailed,
                       "silent target write failure is reported")
        results.expect(storage.values[rawA] == "secret",
                       "silent write failure retains the source")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[rawA] = "secret"
        storage.corruptReadback.insert(targetA)
        results.expect(migrate(storage, target: targetA, sources: [rawA]) == .readbackMismatch,
                       "corrupt target readback is reported")
        results.expect(storage.values[rawA] == "secret",
                       "corrupt readback retains the source")
    }

    do {
        let storage = MemoryCredentialStorage()
        storage.values[rawA] = "secret"
        storage.failDeletes.insert(rawA)
        results.expect(migrate(storage, target: targetA, sources: [rawA]) == .deleteFailed,
                       "source deletion failure is reported")
        results.expect(storage.values[rawA] == "secret",
                       "delete failure retains the source")
    }

    do {
        let storage = MemoryCredentialStorage()
        let noncanonical = accountAString.uppercased()
        let rawNoncanonical = "vortx.debrid.realDebrid." + noncanonical
        storage.values[rawNoncanonical] = "must-stay"
        results.expect(DebridOwnerScope.canonicalAccount(noncanonical) == nil,
                       "noncanonical raw owner is not eligible for migration")
        results.expect(storage.values[rawNoncanonical] == "must-stay",
                       "noncanonical raw source remains intact")
    }
}

private func testConcurrentReads(_ results: inout Results) {
    let initial = snapshot(.signedOutDevice, 1)
    let store = DebridCredentialSnapshotStore(initial: initial)
    let failures = FailureBox()
    let queue = DispatchQueue(label: "vortx.debrid.snapshot-writes")

    queue.async {
        for revision in UInt64(2)...UInt64(2_000) {
            let service: DebridService = revision.isMultiple(of: 2) ? .torBox : .realDebrid
            _ = store.publish(snapshot(.account(accountA), revision, [service: String(revision)]))
        }
    }
    DispatchQueue.concurrentPerform(iterations: 20_000) { _ in
        let current = store.load()
        if current.revision == 1 {
            if current.owner != .signedOutDevice || !current.keys.isEmpty {
                failures.append("initial envelope was torn")
            }
        } else {
            let expectedService: DebridService =
                current.revision.isMultiple(of: 2) ? .torBox : .realDebrid
            if current.owner != .account(accountA)
                || current.keys != [expectedService: String(current.revision)] {
                failures.append("published envelope was torn")
            }
        }
        _ = store.isConfigured(.torBox)
        _ = store.isCurrent(revision: current.revision)
    }
    queue.sync {}
    results.expect(failures.isEmpty,
                   "concurrent detached reads observe only complete immutable snapshots")
    results.expect(store.load().revision == 2_000,
                   "concurrent publication converges on the final revision")
}

@main
private enum DebridCredentialOrderingTestRunner {
    static func main() {
        var results = Results()
        testOwnerGrammar(&results)
        testRevisionOrdering(&results)
        testMutableState(&results)
        testStoreAndInFlightFences(&results)
        testMigration(&results)
        testConcurrentReads(&results)

        if results.failed.isEmpty {
            print("ALL PASS (\(results.passed) checks)")
        } else {
            print("FAILED \(results.failed.count) of \(results.passed + results.failed.count) checks")
            for failure in results.failed { print(" - \(failure)") }
            exit(1)
        }
    }
}
