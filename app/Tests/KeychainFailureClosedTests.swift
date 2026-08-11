// KeychainFailureClosedTests: executable coverage for the iOS/tvOS credential fallback policy.
//
// This compiles the real Keychain.swift. The injectable policy is platform-neutral so these tests can
// exercise Security.framework failures on macOS without copying or retyping production logic.
//
// RUN:
//   xcrun swiftc -o /tmp/keychain-failure-closed \
//     app/SourcesShared/CredentialScope.swift \
//     app/SourcesShared/Keychain.swift \
//     app/Tests/KeychainFailureClosedTests.swift &&
//   /tmp/keychain-failure-closed

import Foundation

private final class KeychainTestLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ next: Value) {
        lock.lock(); defer { lock.unlock() }
        value = next
    }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@MainActor
@main
struct KeychainFailureClosedTests {
    final class FakeBackend {
        static let durableMarkerPrefix = "vortx.keychain.invalidation.v1."

        static func durableMarkerAccount(_ account: String) -> String {
            durableMarkerPrefix + Data(account.utf8).base64EncodedString()
        }

        var values: [String: String] = [:]
        var readFails = false
        var readbackMismatch = false
        var writeFails = false
        var deleteFails = false
        var legacyFallbacks: [String: String] = [:]
        var invalidationFlags: [String: Bool] = [:]
        var purgedAccounts: [String] = []
        var purgeAllCount = 0
        var secureReadAccounts: [String] = []
        var secureWriteAccounts: [String] = []
        var failedWriteAccounts = Set<String>()
        var failedDeleteAccounts = Set<String>()
        var failAfterPersistDeleteAccounts = Set<String>()
        var legacyClearFails = false

        func isDurablyInvalidated(_ account: String) -> Bool {
            values[Self.durableMarkerAccount(account)] == Keychain.durableInvalidationSentinel
        }

        func makeStore() -> KeychainFailureClosedStore {
            KeychainFailureClosedStore(
                readSecure: { [self] account in
                    secureReadAccounts.append(account)
                    let isMarker = account.hasPrefix(Self.durableMarkerPrefix)
                    if readFails && !isMarker { return .failure }
                    if readbackMismatch && !isMarker { return .value("mismatched-secure-value") }
                    if let value = values[account] { return .value(value) }
                    return .missing
                },
                writeSecure: { [self] value, account in
                    secureWriteAccounts.append(account)
                    if failedWriteAccounts.contains(account) { return .failure }
                    if value == nil, failedDeleteAccounts.contains(account) { return .failure }
                    if value == nil, failAfterPersistDeleteAccounts.contains(account) {
                        values.removeValue(forKey: account)
                        return .failure
                    }
                    let isMarker = account.hasPrefix(Self.durableMarkerPrefix)
                    if value == nil, deleteFails && !isMarker { return .failure }
                    if value != nil, writeFails && !isMarker { return .failure }
                    values[account] = value
                    return .success
                },
                invalidationAccount: { Self.durableMarkerAccount($0) },
                invalidationSentinel: Keychain.durableInvalidationSentinel,
                isLegacyInvalidated: { [self] account in
                    invalidationFlags[Keychain.invalidationKeyPrefix + account] == true
                },
                clearLegacyInvalidated: { [self] account in
                    if !legacyClearFails {
                        invalidationFlags.removeValue(forKey: Keychain.invalidationKeyPrefix + account)
                    }
                },
                purgeAllLegacy: { [self] in
                    purgeAllCount += 1
                    legacyFallbacks = legacyFallbacks.filter {
                        !$0.key.hasPrefix(Keychain.fallbackKeyPrefix)
                    }
                },
                purgeLegacy: { [self] account in
                    purgedAccounts.append(account)
                    legacyFallbacks.removeValue(forKey: Keychain.fallbackKeyPrefix + account)
                }
            )
        }
    }

    final class ConcurrentBackend {
        let lock = NSLock()
        var values: [String: String] = [:]
        var writeCount = 0
        var readCount = 0
        var purgeCount = 0
        var blockFirstWrite = false
        var failFirstWrite = false
        var failSecondWrite = false
        var blockFirstRead = false
        var readFails = false
        let firstWriteEntered = DispatchSemaphore(value: 0)
        let secondWriteEntered = DispatchSemaphore(value: 0)
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let firstReadEntered = DispatchSemaphore(value: 0)
        let releaseFirstRead = DispatchSemaphore(value: 0)
        let secondTransitionBegan = DispatchSemaphore(value: 0)

        func makeStore() -> KeychainFailureClosedStore {
            KeychainFailureClosedStore(
                readSecure: { [self] account in read(account) },
                writeSecure: { [self] value, account in write(value, account) },
                invalidationAccount: { FakeBackend.durableMarkerAccount($0) },
                invalidationSentinel: Keychain.durableInvalidationSentinel,
                isLegacyInvalidated: { _ in false },
                clearLegacyInvalidated: { _ in },
                purgeAllLegacy: {},
                purgeLegacy: { [self] _ in
                    lock.lock()
                    purgeCount += 1
                    let isSecond = purgeCount == 2
                    lock.unlock()
                    if isSecond { secondTransitionBegan.signal() }
                }
            )
        }

        private func read(_ account: String) -> CredentialDurableReadResult {
            if account.hasPrefix(FakeBackend.durableMarkerPrefix) {
                lock.lock(); defer { lock.unlock() }
                return values[account].map(CredentialDurableReadResult.value) ?? .missing
            }
            lock.lock()
            let snapshot = values[account]
            let shouldBlock = blockFirstRead && readCount == 0
            let shouldFail = readFails
            readCount += 1
            lock.unlock()

            if shouldBlock {
                firstReadEntered.signal()
                _ = releaseFirstRead.wait(timeout: .now() + 5)
            }
            if shouldFail { return .failure }
            return snapshot.map(CredentialDurableReadResult.value) ?? .missing
        }

        private func write(_ value: String?, _ account: String) -> CredentialMutationResult {
            if account.hasPrefix(FakeBackend.durableMarkerPrefix) {
                lock.lock()
                if let value { values[account] = value }
                else { values.removeValue(forKey: account) }
                lock.unlock()
                return .success
            }
            lock.lock()
            writeCount += 1
            let number = writeCount
            let shouldBlock = blockFirstWrite && number == 1
            let shouldFail = (failFirstWrite && number == 1) || (failSecondWrite && number == 2)
            lock.unlock()

            if shouldBlock {
                firstWriteEntered.signal()
                _ = releaseFirstWrite.wait(timeout: .now() + 5)
            }
            if number == 2 { secondWriteEntered.signal() }
            if shouldFail { return .failure }

            lock.lock()
            if let value { values[account] = value }
            else { values.removeValue(forKey: account) }
            lock.unlock()
            return .success
        }

        func isDurablyInvalidated(_ account: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return values[FakeBackend.durableMarkerAccount(account)] == Keychain.durableInvalidationSentinel
        }
    }

    final class SecureItemAdapterBackend {
        var values: [String: String] = [:]
        var failedUpdates = Set<String>()
        var legacyMarkers = Set<String>()
        var mutations: [String] = []

        func makeStore() -> KeychainFailureClosedStore {
            KeychainFailureClosedStore(
                readSecure: { [self] account in
                    values[account].map(CredentialDurableReadResult.value) ?? .missing
                },
                writeSecure: { [self] value, account in
                    KeychainSecureItemWriter.write(
                        value: value,
                        update: { candidate in
                            mutations.append("update:\(account)")
                            guard values[account] != nil else { return .notFound }
                            guard !failedUpdates.contains(account) else { return .failure }
                            values[account] = candidate
                            return .success
                        },
                        add: { candidate in
                            mutations.append("add:\(account)")
                            guard values[account] == nil else { return .failure }
                            values[account] = candidate
                            return .success
                        },
                        delete: {
                            mutations.append("delete:\(account)")
                            guard values.removeValue(forKey: account) != nil else { return .notFound }
                            return .success
                        })
                },
                invalidationAccount: { FakeBackend.durableMarkerAccount($0) },
                invalidationSentinel: Keychain.durableInvalidationSentinel,
                isLegacyInvalidated: { [self] account in legacyMarkers.contains(account) },
                clearLegacyInvalidated: { [self] account in legacyMarkers.remove(account) },
                purgeAllLegacy: {},
                purgeLegacy: { _ in })
        }
    }

    static var passes = 0
    static var failures = 0

    static func check(
        _ name: String,
        _ condition: @autoclosure () -> Bool,
        _ detail: @autoclosure () -> String = ""
    ) {
        if condition() {
            passes += 1
            print("  PASS  \(name)")
        } else {
            failures += 1
            let message = detail()
            print("  FAIL  \(name)\(message.isEmpty ? "" : " [\(message)]")")
        }
    }

    static func main() {
        testSuccessfulKeychainAuthority()
        testAddFailureIsMemoryOnly()
        testFailedReplacementCannotResurrectAfterRestart()
        testReadFailureFailsClosed()
        testDeletionAndFailedDeletion()
        testConfirmedReadNeverUsesUnconfirmedState()
        testConfirmedMutationRequiresReadback()
        testDurableMigrationBypass()
        testLegacyFallbackPurgedOnEveryPath()
        testSameAccountTransitionOwnership()
        testSameAccountDelayedSuccessesAreBackendLinearizable()
        testConfirmedReadRejectsTransitionRace()
        testStringRejectsStaleBlockedRead()
        testDurableTombstoneSurvivesDefaultsReset()
        testTombstoneWriteFailureDoesNotTouchCredential()
        testExistingTombstoneMustBeRepersistedBeforeMutation()
        testSecureAdapterUpdateFailurePreservesExistingTombstone()
        testLegacyInvalidationMigratesBeforeDefaultsRemoval()
        testTombstoneClearFailureRemainsRetryable()
        testTombstoneDeleteAfterEffectReconciles()
        testProductionBackendsOwnTheirTombstones()

        print("\n----------------------------------------")
        print("passes: \(passes)  failures: \(failures)")
        print("----------------------------------------")
        exit(failures == 0 ? 0 : 1)
    }

    static func testSuccessfulKeychainAuthority() {
        print("\n=== successful Keychain authority ===")
        let backend = FakeBackend()
        let store = backend.makeStore()

        store.set("keychain-value", for: "account")

        check("write reaches secure storage", backend.values["account"] == "keychain-value")
        check("successful write clears invalidation", !backend.isDurablyInvalidated("account"))
        check("read returns secure storage", store.string("account") == "keychain-value")

        backend.values["account"] = "rotated-keychain-value"
        check("a successful secure read supersedes memory", store.string("account") == "rotated-keychain-value")
    }

    static func testAddFailureIsMemoryOnly() {
        print("\n=== add failure remains process-local ===")
        let backend = FakeBackend()
        backend.writeFails = true
        backend.legacyFallbacks[Keychain.fallbackKeyPrefix + "account"] = "plaintext-secret"
        let sameProcess = backend.makeStore()

        sameProcess.set("volatile-secret", for: "account")

        check("failed add does not persist", backend.values["account"] == nil)
        check("failed add leaves a persistent invalidation", backend.isDurablyInvalidated("account"))
        check("failed add purges legacy plaintext", backend.legacyFallbacks.isEmpty)
        check(
            "invalidation stores no secret bytes",
            backend.values[FakeBackend.durableMarkerAccount("account")] != "volatile-secret"
        )
        backend.readFails = true
        check("same process retains intended value", sameProcess.string("account") == "volatile-secret")

        let freshProcess = backend.makeStore()
        check("fresh store cannot recover volatile value", freshProcess.string("account") == nil)
    }

    static func testFailedReplacementCannotResurrectAfterRestart() {
        print("\n=== failed replacement cannot resurrect stale secure state ===")
        let backend = FakeBackend()
        backend.values["account"] = "old-secure-secret"
        backend.writeFails = true
        let sameProcess = backend.makeStore()

        sameProcess.set("new-volatile-secret", for: "account")

        check("failed replacement keeps old secure item underneath", backend.values["account"] == "old-secure-secret")
        check("same process sees replacement intent", sameProcess.string("account") == "new-volatile-secret")
        let readsBeforeRestart = backend.secureReadAccounts.count
        let freshProcess = backend.makeStore()
        check("fresh store rejects stale secure item", freshProcess.string("account") == nil)
        check("invalidated read consults only the durable marker",
              !backend.secureReadAccounts[readsBeforeRestart...].contains("account"))

        backend.writeFails = false
        freshProcess.set("confirmed-secure-secret", for: "account")
        check("later confirmed replacement clears invalidation", !backend.isDurablyInvalidated("account"))
        let afterRecovery = backend.makeStore()
        check("fresh store accepts confirmed replacement",
              afterRecovery.string("account") == "confirmed-secure-secret")
    }

    static func testReadFailureFailsClosed() {
        print("\n=== read failure never consults plaintext fallback ===")
        let backend = FakeBackend()
        backend.values["account"] = "secure-secret"
        let store = backend.makeStore()

        check("successful secure read seeds process memory", store.string("account") == "secure-secret")
        backend.legacyFallbacks[Keychain.fallbackKeyPrefix + "account"] = "plaintext-secret"
        backend.readFails = true
        check("later read failure uses process memory", store.string("account") == "secure-secret")
        check("legacy plaintext is purged", backend.legacyFallbacks.isEmpty)

        let freshProcess = backend.makeStore()
        check("fresh store fails closed while secure reads fail", freshProcess.string("account") == nil)
    }

    static func testDeletionAndFailedDeletion() {
        print("\n=== deletion is authoritative in-process ===")
        let backend = FakeBackend()
        backend.values["account"] = "secure-secret"
        let store = backend.makeStore()

        store.set(nil, for: "account")

        check("successful delete removes secure value", backend.values["account"] == nil)
        check("successful delete reads nil", store.string("account") == nil)

        backend.values["account"] = "stale-secure-secret"
        backend.deleteFails = true
        backend.legacyFallbacks[Keychain.fallbackKeyPrefix + "account"] = "plaintext-secret"
        store.set(nil, for: "account")

        check("failed delete leaves a persistent invalidation", backend.isDurablyInvalidated("account"))
        check("failed delete cannot resurrect stale value in-process", store.string("account") == nil)
        check("failed delete does not copy secret to plaintext", backend.legacyFallbacks.isEmpty)
        let freshProcess = backend.makeStore()
        check("failed delete cannot resurrect stale value after restart", freshProcess.string("account") == nil)

        backend.deleteFails = false
        freshProcess.set(nil, for: "account")
        check("later confirmed delete clears invalidation", !backend.isDurablyInvalidated("account"))
        check("fresh store sees confirmed deletion", backend.makeStore().string("account") == nil)
    }

    static func testConfirmedReadNeverUsesUnconfirmedState() {
        print("\n=== confirmed reads exclude pending, cache, and invalidated values ===")
        let backend = FakeBackend()
        backend.values["account"] = "secure-secret"
        let store = backend.makeStore()

        check("confirmed read accepts a backend value",
              store.confirmedString("account") == .value("secure-secret"))

        backend.readFails = true
        check("confirmed read reports backend failure instead of cache",
              store.confirmedString("account") == .failure)

        backend.readFails = false
        backend.writeFails = true
        _ = store.set("pending-secret", for: "account")
        check("confirmed read rejects a pending override",
              store.confirmedString("account") == .failure)

        backend.writeFails = false
        backend.invalidationFlags[Keychain.invalidationKeyPrefix + "account"] = true
        backend.secureReadAccounts.removeAll()
        check("confirmed read rejects an invalidation marker",
              store.confirmedString("account") == .failure)
        check("marker rejection does not consult credential bytes",
              !backend.secureReadAccounts.contains("account"))
    }

    static func testConfirmedMutationRequiresReadback() {
        print("\n=== mutations are confirmed only after exact read-back ===")
        let backend = FakeBackend()
        let store = backend.makeStore()

        backend.readbackMismatch = true
        check("a mismatched read-back is an uncertain mutation",
              store.set("new-secret", for: "account") == .failure)
        check("uncertain mutation leaves an invalidation marker",
              backend.isDurablyInvalidated("account"))
        check("uncertain mutation is not confirmed",
              store.confirmedString("account") == .failure)

        backend.readbackMismatch = false
        check("a later exact read-back confirms the retry",
              store.set("confirmed-secret", for: "account") == .success)
        check("confirmed retry clears the marker",
              !backend.isDurablyInvalidated("account"))
        check("confirmed retry is readable as backend truth",
              store.confirmedString("account") == .value("confirmed-secret"))
    }

    static func testDurableMigrationBypass() {
        print("\n=== legacy migration can inspect durable bytes without certifying them ===")
        let backend = FakeBackend()
        backend.values["legacy"] = "legacy-secret"
        backend.invalidationFlags[Keychain.invalidationKeyPrefix + "legacy"] = true
        let store = backend.makeStore()

        check("confirmed read remains failure-closed for a marked slot",
              store.confirmedString("legacy") == .failure)
        check("durable migration read bypasses only the marker",
              store.durableString("legacy") == .value("legacy-secret"))

        backend.readFails = true
        check("durable migration still fails when the backend cannot be read",
              store.durableString("legacy") == .failure)
    }

    static func testLegacyFallbackPurgedOnEveryPath() {
        print("\n=== all legacy fallback slots are swept, then exact slots stay purged ===")
        let backend = FakeBackend()
        let store = backend.makeStore()
        let prefix = Keychain.fallbackKeyPrefix

        backend.legacyFallbacks[prefix + "read"] = "legacy-read"
        backend.legacyFallbacks[prefix + "inactive-account"] = "legacy-inactive"
        backend.legacyFallbacks[prefix + "removed-account"] = "legacy-removed"
        backend.legacyFallbacks["unrelated.preference"] = "keep"
        _ = store.string("read")
        check("first operation sweeps every legacy account",
              !backend.legacyFallbacks.keys.contains { $0.hasPrefix(prefix) })
        check("full sweep preserves unrelated defaults",
              backend.legacyFallbacks["unrelated.preference"] == "keep")
        check("full sweep runs once", backend.purgeAllCount == 1)

        backend.legacyFallbacks[prefix + "write"] = "legacy-write"
        store.set("new-secret", for: "write")
        check("write purges exact slot", backend.legacyFallbacks[prefix + "write"] == nil)

        backend.legacyFallbacks[prefix + "delete"] = "legacy-delete"
        store.set(nil, for: "delete")
        check("delete purges exact slot", backend.legacyFallbacks[prefix + "delete"] == nil)
        check(
            "all operations invoked purge",
            backend.purgedAccounts == ["read", "write", "delete"],
            "got \(backend.purgedAccounts)"
        )
        check("full sweep still ran only once", backend.purgeAllCount == 1)
    }

    static func testSameAccountTransitionOwnership() {
        print("\n=== same-account transitions cannot publish stale completions ===")

        do {
            let backend = ConcurrentBackend()
            backend.blockFirstWrite = true
            backend.failFirstWrite = true
            let store = backend.makeStore()
            let oldResult = KeychainTestLockedBox(CredentialMutationResult.success)
            let newResult = KeychainTestLockedBox(CredentialMutationResult.failure)
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global().async {
                oldResult.set(store.set("old-failure", for: "account"))
                group.leave()
            }
            check("old failure enters backend", backend.firstWriteEntered.wait(timeout: .now() + 5) == .success)

            group.enter()
            DispatchQueue.global().async {
                newResult.set(store.set("new-success", for: "account"))
                group.leave()
            }
            check("new success owns its transition generation before release",
                  backend.secondTransitionBegan.wait(timeout: .now() + 5) == .success)
            backend.releaseFirstWrite.signal()
            check("new success enters backend after the old write releases",
                  backend.secondWriteEntered.wait(timeout: .now() + 5) == .success)
            check("both transitions finish", group.wait(timeout: .now() + 5) == .success)
            check("new success owns the result", newResult.get() == .success)
            check("old failure remains a failure", oldResult.get() == .failure)
            check("old failure cannot restore pending state", store.string("account") == "new-success")
            check("new success leaves confirmed backend truth",
                  store.confirmedString("account") == .value("new-success"))
            check("new success owns the marker", !backend.isDurablyInvalidated("account"))
        }

        do {
            let backend = ConcurrentBackend()
            backend.blockFirstWrite = true
            backend.failSecondWrite = true
            let store = backend.makeStore()
            let oldResult = KeychainTestLockedBox(CredentialMutationResult.failure)
            let newResult = KeychainTestLockedBox(CredentialMutationResult.success)
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global().async {
                oldResult.set(store.set("old-success", for: "account"))
                group.leave()
            }
            check("old success enters backend", backend.firstWriteEntered.wait(timeout: .now() + 5) == .success)

            group.enter()
            DispatchQueue.global().async {
                newResult.set(store.set("new-failure", for: "account"))
                group.leave()
            }
            check("new failure owns its transition generation before release",
                  backend.secondTransitionBegan.wait(timeout: .now() + 5) == .success)
            backend.releaseFirstWrite.signal()
            check("new failure enters backend after the old write releases",
                  backend.secondWriteEntered.wait(timeout: .now() + 5) == .success)
            check("both inverse transitions finish", group.wait(timeout: .now() + 5) == .success)
            check("new failure remains a failure", newResult.get() == .failure)
            check("old success loses transition ownership", oldResult.get() == .failure)
            check("new failure owns the pending override", store.string("account") == "new-failure")
            check("old success cannot clear the newer marker", backend.isDurablyInvalidated("account"))
            check("confirmed read remains failure-closed", store.confirmedString("account") == .failure)
        }
    }

    static func testSameAccountDelayedSuccessesAreBackendLinearizable() {
        print("\n=== delayed same-account successes serialize backend bytes ===")
        let backend = ConcurrentBackend()
        backend.blockFirstWrite = true
        let store = backend.makeStore()
        let oldResult = KeychainTestLockedBox(CredentialMutationResult.failure)
        let newResult = KeychainTestLockedBox(CredentialMutationResult.failure)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            oldResult.set(store.set("A", for: "account"))
            group.leave()
        }
        check("old success enters the blocked backend write",
              backend.firstWriteEntered.wait(timeout: .now() + 5) == .success)

        group.enter()
        DispatchQueue.global().async {
            newResult.set(store.set("B", for: "account"))
            group.leave()
        }

        check("new success owns its transition generation before release",
              backend.secondTransitionBegan.wait(timeout: .now() + 5) == .success)
        backend.releaseFirstWrite.signal()
        check("new success reaches backend only after old write releases",
              backend.secondWriteEntered.wait(timeout: .now() + 5) == .success)
        check("delayed successes finish", group.wait(timeout: .now() + 5) == .success)
        check("stale first success is fenced", oldResult.get() == .failure)
        check("newer success is committed", newResult.get() == .success)
        check("backend retains the newer certified bytes", backend.values["account"] == "B")
        check("backend marker is clear only for the newer success", !backend.isDurablyInvalidated("account"))
        check("confirmed reads publish B", store.confirmedString("account") == .value("B"))
        check("confirmed reads cannot publish stale A", store.confirmedString("account") != .value("A"))
    }

    static func testConfirmedReadRejectsTransitionRace() {
        print("\n=== confirmed reads reject a concurrent transition ===")
        let backend = ConcurrentBackend()
        backend.values["account"] = "old-secure"
        backend.blockFirstRead = true
        let store = backend.makeStore()
        let readResult = KeychainTestLockedBox(CredentialDurableReadResult.missing)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            readResult.set(store.confirmedString("account"))
            group.leave()
        }
        check("confirmed read enters backend", backend.firstReadEntered.wait(timeout: .now() + 5) == .success)

        check("concurrent replacement succeeds", store.set("new-secure", for: "account") == .success)
        _ = backend.releaseFirstRead.signal()
        check("racing read finishes", group.wait(timeout: .now() + 5) == .success)
        check("racing read rejects its stale backend bytes", readResult.get() == .failure)
        check("the replacement remains confirmed",
              store.confirmedString("account") == .value("new-secure"))
    }

    static func testStringRejectsStaleBlockedRead() {
        print("\n=== compatibility reads reject stale blocked backend bytes ===")
        let backend = ConcurrentBackend()
        backend.values["account"] = "old-secure"
        backend.blockFirstRead = true
        let store = backend.makeStore()
        let staleResult = KeychainTestLockedBox<String?>(nil)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            staleResult.set(store.string("account"))
            group.leave()
        }
        check("old compatibility read enters the backend",
              backend.firstReadEntered.wait(timeout: .now() + 5) == .success)

        check("new replacement succeeds while the old read is blocked",
              store.set("new-secure", for: "account") == .success)
        backend.releaseFirstRead.signal()
        check("blocked compatibility read finishes",
              group.wait(timeout: .now() + 5) == .success)
        check("obsolete compatibility read fails closed", staleResult.get() == nil)

        backend.readFails = true
        let laterFailure = store.string("account")
        check("later backend failure retains only the current cached value",
              laterFailure == "new-secure")
        check("later backend failure cannot resurrect the stale value",
              laterFailure != "old-secure")
    }

    static func testDurableTombstoneSurvivesDefaultsReset() {
        print("\n=== durable tombstone survives disposable-defaults reset ===")
        let backend = FakeBackend()
        backend.values["account"] = "old-secure"
        backend.writeFails = true
        let sameProcess = backend.makeStore()

        check("failed replacement remains a failure",
              sameProcess.set("replacement", for: "account") == .failure)
        check("failed replacement leaves the old secure value underneath",
              backend.values["account"] == "old-secure")

        // Model reinstall/reset: the persistent secure backend survives, while UserDefaults does not.
        backend.invalidationFlags.removeAll()
        backend.writeFails = false
        let freshProcess = backend.makeStore()
        check("clearing defaults cannot re-certify stale secure bytes",
              freshProcess.confirmedString("account") == .failure)

        check("a successful replacement clears the durable tombstone",
              freshProcess.set("replacement", for: "account") == .success)
        backend.invalidationFlags.removeAll()
        check("fresh process accepts the certified replacement",
              backend.makeStore().confirmedString("account") == .value("replacement"))

        backend.deleteFails = true
        let deletingProcess = backend.makeStore()
        check("failed delete remains a failure", deletingProcess.set(nil, for: "account") == .failure)
        backend.invalidationFlags.removeAll()
        backend.deleteFails = false
        check("defaults reset cannot resurrect bytes after failed delete",
              backend.makeStore().confirmedString("account") == .failure)
        check("a successful delete clears the durable tombstone",
              backend.makeStore().set(nil, for: "account") == .success)
        check("fresh process accepts certified absence",
              backend.makeStore().confirmedString("account") == .missing)
    }

    static func testTombstoneWriteFailureDoesNotTouchCredential() {
        print("\n=== tombstone write failure cannot touch credential bytes ===")
        let backend = FakeBackend()
        backend.values["account"] = "old-secure"
        let markerAccount = FakeBackend.durableMarkerAccount("account")
        backend.failedWriteAccounts.insert(markerAccount)
        let store = backend.makeStore()

        check("replacement fails when its durable tombstone cannot be written",
              store.set("replacement", for: "account") == .failure)
        check("failed tombstone leaves credential bytes untouched",
              backend.values["account"] == "old-secure")
        check("failed tombstone never invokes the credential mutation",
              !backend.secureWriteAccounts.contains("account"))
    }

    static func testExistingTombstoneMustBeRepersistedBeforeMutation() {
        print("\n=== an existing tombstone is durably rewritten before target mutation ===")
        let backend = FakeBackend()
        let markerAccount = FakeBackend.durableMarkerAccount("account")
        backend.values["account"] = "old-secure"
        backend.values[markerAccount] = Keychain.durableInvalidationSentinel
        backend.failedWriteAccounts.insert(markerAccount)
        let store = backend.makeStore()

        check("retry fails when the existing tombstone cannot be durably rewritten",
              store.set("replacement", for: "account") == .failure)
        check("failed tombstone rewrite leaves prior credential bytes exact",
              backend.values["account"] == "old-secure")
        check("the first attempted mutation is the tombstone rewrite",
              backend.secureWriteAccounts.first == markerAccount)
        check("failed tombstone rewrite never reaches the credential account",
              !backend.secureWriteAccounts.contains("account"))
    }

    static func testSecureAdapterUpdateFailurePreservesExistingTombstone() {
        print("\n=== secure adapter update failure preserves an existing tombstone ===")
        let backend = SecureItemAdapterBackend()
        let markerAccount = FakeBackend.durableMarkerAccount("account")
        backend.values["account"] = "old-secure"
        backend.values[markerAccount] = Keychain.durableInvalidationSentinel
        backend.failedUpdates.insert(markerAccount)
        let store = backend.makeStore()

        check("existing-tombstone update failure rejects replacement",
              store.set("replacement", for: "account") == .failure)
        check("update failure never deletes or adds the existing tombstone",
              backend.mutations == ["update:\(markerAccount)"])
        check("failed marker update leaves old target untouched",
              backend.values["account"] == "old-secure")
        check("failed marker update retains the durable tombstone",
              backend.values[markerAccount] == Keychain.durableInvalidationSentinel)

        // Model defaults reset plus a fresh process over the same persistent secure backend.
        backend.legacyMarkers.removeAll()
        check("fresh process remains failure-closed after defaults reset",
              backend.makeStore().confirmedString("account") == .failure)
        check("fresh process still has the protecting tombstone",
              backend.values[markerAccount] == Keychain.durableInvalidationSentinel)
    }

    static func testLegacyInvalidationMigratesBeforeDefaultsRemoval() {
        print("\n=== legacy defaults marker migrates into secure storage ===")
        let backend = FakeBackend()
        backend.values["account"] = "old-secure"
        backend.invalidationFlags[Keychain.invalidationKeyPrefix + "account"] = true
        let markerAccount = FakeBackend.durableMarkerAccount("account")
        let store = backend.makeStore()

        check("legacy-marked value stays failure-closed",
              store.confirmedString("account") == .failure)
        check("legacy marker is removed only after durable migration",
              backend.invalidationFlags.isEmpty && backend.values[markerAccount] != nil)
        backend.invalidationFlags.removeAll()
        check("migrated marker survives a defaults reset",
              backend.makeStore().confirmedString("account") == .failure)

        let failed = FakeBackend()
        failed.values["account"] = "old-secure"
        failed.invalidationFlags[Keychain.invalidationKeyPrefix + "account"] = true
        failed.failedWriteAccounts.insert(FakeBackend.durableMarkerAccount("account"))
        check("failed migration remains failure-closed",
              failed.makeStore().confirmedString("account") == .failure)
        check("failed migration retains the legacy marker",
              failed.invalidationFlags[Keychain.invalidationKeyPrefix + "account"] == true)

        let uncleared = FakeBackend()
        uncleared.values["account"] = "old-secure"
        uncleared.invalidationFlags[Keychain.invalidationKeyPrefix + "account"] = true
        uncleared.legacyClearFails = true
        check("failed legacy removal remains failure-closed",
              uncleared.makeStore().confirmedString("account") == .failure)
        check("failed legacy removal retains both durable and legacy protection",
              uncleared.isDurablyInvalidated("account")
                && uncleared.invalidationFlags[Keychain.invalidationKeyPrefix + "account"] == true)
    }

    static func testTombstoneClearFailureRemainsRetryable() {
        print("\n=== tombstone clear failure remains retryable ===")
        let backend = FakeBackend()
        backend.values["account"] = "old-secure"
        let markerAccount = FakeBackend.durableMarkerAccount("account")
        backend.failedDeleteAccounts.insert(markerAccount)
        let store = backend.makeStore()

        check("marker-clear failure reports the replacement as unconfirmed",
              store.set("new-secure", for: "account") == .failure)
        check("exact target bytes remain protected by the durable marker",
              backend.values["account"] == "new-secure" && backend.isDurablyInvalidated("account"))
        check("fresh process cannot publish before marker cleanup",
              backend.makeStore().confirmedString("account") == .failure)

        backend.failedDeleteAccounts.remove(markerAccount)
        check("the same replacement retries to certified completion",
              backend.makeStore().set("new-secure", for: "account") == .success)
        check("retry clears the marker and publishes exact bytes",
              backend.makeStore().confirmedString("account") == .value("new-secure"))
    }

    static func testTombstoneDeleteAfterEffectReconciles() {
        print("\n=== exact target plus absent tombstone reconciles delete after-effect ===")
        let backend = FakeBackend()
        backend.values["account"] = "old-secure"
        let markerAccount = FakeBackend.durableMarkerAccount("account")
        backend.failAfterPersistDeleteAccounts.insert(markerAccount)
        let store = backend.makeStore()

        check("an after-effect marker delete is certified by exact absence",
              store.set("new-secure", for: "account") == .success)
        check("the exact target remains authoritative after reconciliation",
              backend.makeStore().confirmedString("account") == .value("new-secure"))
        check("the reconciled marker is durably absent", backend.values[markerAccount] == nil)
    }

    static func testProductionBackendsOwnTheirTombstones() {
        print("\n=== production backends own their durable tombstones ===")
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SourcesShared/Keychain.swift")
        let source = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        let durableWiring = "invalidationAccount: { account in durableInvalidationAccount(for: account) }"

        check("both platform stores use the reserved durable account",
              source.components(separatedBy: durableWiring).count - 1 == 2)
        check("macOS tombstones traverse the same file adapter map",
              source.contains("readSecure: { account in fileAdapter.read(account) },\n"
                + "        writeSecure: { value, account in fileAdapter.write(value, for: account) },\n"
                + "        \(durableWiring)"))
        check("iOS and tvOS secure replacement uses the executable update-first adapter",
              source.contains("return KeychainSecureItemWriter.write(\n"
                + "                value: value,\n"
                + "                update:")
                && source.contains("SecItemUpdate(base as CFDictionary, attributes as CFDictionary)"))
        check("system Keychain replacement no longer deletes before adding",
              !source.contains("let deleteStatus = SecItemDelete(base as CFDictionary)"))
        check("new mutations never recreate a disposable defaults marker",
              !source.contains("UserDefaults.standard.set(true, forKey: invalidationKey(account))"))
    }
}
