// KeychainFailureClosedTests: executable coverage for the iOS/tvOS credential fallback policy.
//
// This compiles the real Keychain.swift. The injectable policy is platform-neutral so these tests can
// exercise Security.framework failures on macOS without copying or retyping production logic.
//
// RUN:
//   xcrun swiftc -o /tmp/keychain-failure-closed \
//     app/SourcesShared/Keychain.swift \
//     app/Tests/KeychainFailureClosedTests.swift &&
//   /tmp/keychain-failure-closed

import Foundation

@main
struct KeychainFailureClosedTests {
    final class FakeBackend {
        var values: [String: String] = [:]
        var readFails = false
        var writeFails = false
        var deleteFails = false
        var legacyFallbacks: [String: String] = [:]
        var invalidationFlags: [String: Bool] = [:]
        var purgedAccounts: [String] = []
        var purgeAllCount = 0
        var secureReadAccounts: [String] = []

        func makeStore() -> KeychainFailureClosedStore {
            KeychainFailureClosedStore(
                readSecure: { [self] account in
                    secureReadAccounts.append(account)
                    if readFails { return .failure }
                    if let value = values[account] { return .value(value) }
                    return .missing
                },
                writeSecure: { [self] value, account in
                    if value == nil, deleteFails { return .failure }
                    if value != nil, writeFails { return .failure }
                    values[account] = value
                    return .success
                },
                isInvalidated: { [self] account in
                    invalidationFlags[Keychain.invalidationKeyPrefix + account] == true
                },
                markInvalidated: { [self] account in
                    invalidationFlags[Keychain.invalidationKeyPrefix + account] = true
                },
                clearInvalidated: { [self] account in
                    invalidationFlags.removeValue(forKey: Keychain.invalidationKeyPrefix + account)
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
        testLegacyFallbackPurgedOnEveryPath()

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
        check("successful write clears invalidation", backend.invalidationFlags.isEmpty)
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
        check("failed add leaves a persistent invalidation", !backend.invalidationFlags.isEmpty)
        check("failed add purges legacy plaintext", backend.legacyFallbacks.isEmpty)
        check(
            "invalidation stores no secret bytes",
            !backend.invalidationFlags.description.contains("volatile-secret")
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
        check("invalidated read does not consult secure storage",
              backend.secureReadAccounts.count == readsBeforeRestart)

        backend.writeFails = false
        freshProcess.set("confirmed-secure-secret", for: "account")
        check("later confirmed replacement clears invalidation", backend.invalidationFlags.isEmpty)
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

        check("failed delete leaves a persistent invalidation", !backend.invalidationFlags.isEmpty)
        check("failed delete cannot resurrect stale value in-process", store.string("account") == nil)
        check("failed delete does not copy secret to plaintext", backend.legacyFallbacks.isEmpty)
        let freshProcess = backend.makeStore()
        check("failed delete cannot resurrect stale value after restart", freshProcess.string("account") == nil)

        backend.deleteFails = false
        freshProcess.set(nil, for: "account")
        check("later confirmed delete clears invalidation", backend.invalidationFlags.isEmpty)
        check("fresh store sees confirmed deletion", backend.makeStore().string("account") == nil)
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
}
