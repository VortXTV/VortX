// Standalone adversarial executable for owner-scoped Debrid credential durability.
//
// Run with:
//   swiftc -D DEBRID_CREDENTIAL_SECURITY_TESTS -module-cache-path /private/tmp/vortx-debrid-security-module-cache \
//     -swift-version 5 -strict-concurrency=complete -warnings-as-errors -o /private/tmp/debrid-security \
//     app/SourcesShared/CredentialScope.swift \
//     app/SourcesShared/DebridPlaybackAvailability.swift \
//     app/SourcesShared/DebridKeys.swift \
//     app/Tests/DebridCredentialSecurityTests.swift && /private/tmp/debrid-security

import Foundation

#if !DEBRID_KEYCHAIN_SOURCE_LINKED

/// Standalone replacement for the app Keychain boundary. The production `DebridKeys` adapter deliberately
/// depends on the separate ApiKeys lane's confirmed Keychain readback; this fake exercises the narrower
/// injectable protocol without editing `Keychain.swift` in this lane.
enum Keychain {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: String] = [:]
        var ignoredWrites = Set<String>()
        var ignoredDeletes = Set<String>()
        var readbackMismatches = Set<String>()
    }

    private static let storage = Storage()

    static func reset() {
        storage.lock.lock()
        storage.values.removeAll()
        storage.ignoredWrites.removeAll()
        storage.ignoredDeletes.removeAll()
        storage.readbackMismatches.removeAll()
        storage.lock.unlock()
    }

    static func confirmedString(_ account: String) -> CredentialDurableReadResult {
        storage.lock.lock()
        let value = storage.values[account]
        storage.lock.unlock()
        return value.map(CredentialDurableReadResult.value) ?? .missing
    }

    static func durableString(_ account: String) -> CredentialDurableReadResult {
        confirmedString(account)
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> CredentialMutationResult {
        storage.lock.lock()
        if value != nil, storage.ignoredWrites.remove(account) != nil {
            storage.lock.unlock()
            return .failure
        }
        if value == nil, storage.ignoredDeletes.remove(account) != nil {
            storage.lock.unlock()
            return .failure
        }
        if let value { storage.values[account] = value }
        else { storage.values.removeValue(forKey: account) }
        storage.lock.unlock()
        return .success
    }

    static func failNextWrite(for account: String) {
        storage.lock.lock(); storage.ignoredWrites.insert(account); storage.lock.unlock()
    }

    static func failNextDelete(for account: String) {
        storage.lock.lock(); storage.ignoredDeletes.insert(account); storage.lock.unlock()
    }

    static func mismatchReadback(for account: String) {
        storage.lock.lock(); storage.readbackMismatches.insert(account); storage.lock.unlock()
    }
}

@MainActor
final class VortXSyncManager {
    static let shared = VortXSyncManager()
    private(set) var requestCount = 0

    func requestSyncSoon() { requestCount += 1 }
}

actor DebridCoordinator {
    static let shared = DebridCoordinator()
    private(set) var reloads: [DebridCredentialSnapshot] = []

    func reload(snapshot: DebridCredentialSnapshot) async {
        reloads.append(snapshot)
    }

    func reloadCount() -> Int { reloads.count }
    func lastSnapshot() -> DebridCredentialSnapshot? { reloads.last }
}

private final class FakeDebridCredentialStorage: @unchecked Sendable, DebridCredentialStorage {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writeFailures: [String: Int] = [:]
    private var deleteFailures: [String: Int] = [:]
    private var readFailures: [String: Int] = [:]
    private var readbackMismatches: [String: Int] = [:]
    private(set) var writes: [(account: String, value: String?)] = []

    func confirmedRead(_ account: String) -> CredentialDurableReadResult {
        lock.lock()
        if (readFailures[account] ?? 0) > 0 {
            readFailures[account, default: 0] -= 1
            lock.unlock()
            return .failure
        }
        if (readbackMismatches[account] ?? 0) > 0 {
            readbackMismatches[account, default: 0] -= 1
            lock.unlock()
            return .value("mismatched-readback")
        }
        let result = values[account].map(CredentialDurableReadResult.value) ?? .missing
        lock.unlock()
        return result
    }

    func durableRead(_ account: String) -> CredentialDurableReadResult {
        confirmedRead(account)
    }

    @discardableResult
    func mutate(_ value: String?, for account: String) -> CredentialMutationResult {
        lock.lock()
        writes.append((account, value))
        if value == nil, (deleteFailures[account] ?? 0) > 0 {
            deleteFailures[account, default: 0] -= 1
            lock.unlock()
            return .failure
        }
        if value != nil, (writeFailures[account] ?? 0) > 0 {
            writeFailures[account, default: 0] -= 1
            lock.unlock()
            return .failure
        }
        if let value { values[account] = value }
        else { values.removeValue(forKey: account) }
        lock.unlock()
        return .success
    }

    func seed(_ value: String?, for account: String) {
        lock.lock()
        if let value { values[account] = value } else { values.removeValue(forKey: account) }
        lock.unlock()
    }

    func value(_ account: String) -> String? {
        guard case let .value(value) = confirmedRead(account) else { return nil }
        return value
    }

    func failWrites(_ count: Int, for account: String) {
        lock.lock(); writeFailures[account, default: 0] += count; lock.unlock()
    }

    func failDeletes(_ count: Int, for account: String) {
        lock.lock(); deleteFailures[account, default: 0] += count; lock.unlock()
    }

    func failReads(_ count: Int, for account: String) {
        lock.lock(); readFailures[account, default: 0] += count; lock.unlock()
    }

    func mismatchReads(_ count: Int, for account: String) {
        lock.lock(); readbackMismatches[account, default: 0] += count; lock.unlock()
    }

    func writeCount(for account: String) -> Int {
        lock.lock()
        let count = writes.lazy.filter { $0.account == account }.count
        lock.unlock()
        return count
    }
}

private func testAccount(_ rawValue: String) -> CredentialScope {
    guard let account = CredentialScope(canonicalRemoteAccountID: rawValue) else {
        fatalError("invalid test account")
    }
    return account
}

@MainActor
private func expect(_ condition: Bool, _ message: String, failures: inout [String], checks: inout Int) {
    checks += 1
    if !condition { failures.append(message) }
}

@MainActor
private func drainOutboundTasks() async {
    for _ in 0..<4 { await Task.yield() }
}

@MainActor
private func testLocalDurability(failures: inout [String], checks: inout Int) async {
    let storage = FakeDebridCredentialStorage()
    let keys = DebridKeys(storage: storage)
    let owner = testAccount("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    _ = CredentialScopeRegistry.shared.bind(owner)
    keys.bind(owner: owner)

    let initial = keys.setKey("old-key", for: .torBox)
    expect(initial, "a certified initial write succeeds", failures: &failures, checks: &checks)
    await drainOutboundTasks()
    let initialRevision = keys.revision
    let initialSnapshot = keys.credentialSnapshot
    let initialReloadCount = await DebridCoordinator.shared.reloadCount()
    let initialRequestCount = VortXSyncManager.shared.requestCount
    let account = DebridService.torBox.keychainAccount(owner: owner)

    storage.failWrites(2, for: account)
    let failedWriteStart = storage.writeCount(for: account)
    let failedReplacement = keys.setKey("new-key", for: .torBox)
    await drainOutboundTasks()
    expect(!failedReplacement, "an unconfirmed replacement fails closed", failures: &failures, checks: &checks)
    expect(storage.writeCount(for: account) == failedWriteStart + 2, "a failed replacement receives exactly one immediate retry", failures: &failures, checks: &checks)
    expect(keys.key(for: .torBox) == "old-key", "failed replacement preserves the published dictionary", failures: &failures, checks: &checks)
    expect(keys.revision == initialRevision, "failed replacement preserves the revision", failures: &failures, checks: &checks)
    expect(keys.credentialSnapshot == initialSnapshot, "failed replacement does not publish a reload snapshot", failures: &failures, checks: &checks)
    expect(await DebridCoordinator.shared.reloadCount() == initialReloadCount, "failed replacement does not reload the resolver cache", failures: &failures, checks: &checks)
    expect(VortXSyncManager.shared.requestCount == initialRequestCount, "failed replacement does not request sync", failures: &failures, checks: &checks)

    storage.failReads(2, for: account)
    let failedReadback = keys.setKey("unknown-key", for: .torBox)
    await drainOutboundTasks()
    expect(!failedReadback, "an unknown readback fails closed after its retry", failures: &failures, checks: &checks)
    expect(keys.key(for: .torBox) == "old-key", "an unknown readback preserves the published authority", failures: &failures, checks: &checks)
    expect(await DebridCoordinator.shared.reloadCount() == initialReloadCount, "an unknown readback does not reload the resolver cache", failures: &failures, checks: &checks)
    expect(VortXSyncManager.shared.requestCount == initialRequestCount, "an unknown readback does not request sync", failures: &failures, checks: &checks)

    storage.failWrites(1, for: account)
    let retryWriteStart = storage.writeCount(for: account)
    let retriedReplacement = keys.setKey("new-key", for: .torBox)
    await drainOutboundTasks()
    expect(retriedReplacement && keys.key(for: .torBox) == "new-key", "one failed write is certified by the immediate retry", failures: &failures, checks: &checks)
    expect(storage.writeCount(for: account) == retryWriteStart + 2, "a recovered replacement writes exactly twice", failures: &failures, checks: &checks)
    expect(keys.revision == initialRevision + 1, "a recovered replacement publishes exactly one revision", failures: &failures, checks: &checks)
    expect(await DebridCoordinator.shared.reloadCount() == initialReloadCount + 1, "a recovered replacement reloads the cache once", failures: &failures, checks: &checks)
    expect(VortXSyncManager.shared.requestCount == initialRequestCount + 1, "a recovered replacement requests sync once", failures: &failures, checks: &checks)

    storage.failDeletes(2, for: account)
    let failedDelete = keys.setKey("", for: .torBox)
    expect(!failedDelete, "an unconfirmed delete fails closed", failures: &failures, checks: &checks)
    expect(keys.key(for: .torBox) == "new-key", "failed delete preserves the prior credential", failures: &failures, checks: &checks)

    let confirmedDelete = keys.setKey("", for: .torBox)
    expect(confirmedDelete && !keys.isConfigured(.torBox), "a confirmed delete updates the dictionary", failures: &failures, checks: &checks)
}

@MainActor
private func testMigrationNeedsCertifiedDestinationAndCleanup(failures: inout [String], checks: inout Int) {
    let storage = FakeDebridCredentialStorage()
    let keys = DebridKeys(storage: storage)
    let owner = testAccount("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    let capture = CredentialScopeRegistry.shared.bind(owner)
    keys.bind(owner: owner)
    _ = CredentialScopeRegistry.shared.establishAuthenticatedOwner(capture)

    let source = DebridService.torBox.legacyGlobalKeychainAccount
    let destination = DebridService.torBox.keychainAccount(owner: owner)
    storage.seed("legacy-key", for: source)
    storage.failWrites(2, for: destination)
    let destinationFailed = keys.migrateLegacyIfEligible(owner: owner, capture: capture)
    expect(!destinationFailed, "migration stays closed when destination certification fails", failures: &failures, checks: &checks)
    expect(storage.value(source) == "legacy-key" && storage.value(destination) == nil, "failed destination migration preserves the source", failures: &failures, checks: &checks)

    let destinationRetried = keys.migrateLegacyIfEligible(owner: owner, capture: capture)
    expect(destinationRetried && storage.value(destination) == "legacy-key", "migration retries after destination certification", failures: &failures, checks: &checks)
    expect(storage.value(source) == nil, "migration deletes the source only after certified destination and cleanup", failures: &failures, checks: &checks)

    let cleanupSource = DebridService.realDebrid.legacyGlobalKeychainAccount
    let cleanupDestination = DebridService.realDebrid.keychainAccount(owner: owner)
    storage.seed("legacy-still-present", for: cleanupSource)
    storage.failDeletes(2, for: cleanupSource)
    let cleanupFailed = keys.migrateLegacyIfEligible(owner: owner, capture: capture)
    expect(!cleanupFailed, "migration stays closed when legacy cleanup cannot be confirmed", failures: &failures, checks: &checks)
    expect(storage.value(cleanupSource) == "legacy-still-present" && storage.value(cleanupDestination) == "legacy-still-present", "failed cleanup preserves the certified destination and retryable source", failures: &failures, checks: &checks)
    let cleanupRetried = keys.migrateLegacyIfEligible(owner: owner, capture: capture)
    expect(cleanupRetried && storage.value(cleanupSource) == nil, "migration retries legacy cleanup without replacing its certified destination", failures: &failures, checks: &checks)
}

@MainActor
private func testProductionAdapterIsTypedAndSourceLinked(failures: inout [String], checks: inout Int) {
    Keychain.reset()
    let keys = DebridKeys()
    let owner = testAccount("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
    let capture = CredentialScopeRegistry.shared.bind(owner)
    keys.bind(owner: owner, capture: capture)

    expect(keys.setKey("typed-adapter-key", for: .realDebrid), "the default production adapter certifies a typed Keychain mutation", failures: &failures, checks: &checks)
    expect(Keychain.confirmedString(DebridService.realDebrid.keychainAccount(owner: owner)) == .value("typed-adapter-key"), "the source-linked adapter leaves a typed certified value", failures: &failures, checks: &checks)
    expect(Keychain.set(nil, for: DebridService.realDebrid.keychainAccount(owner: owner)) == .success, "the typed fixture exposes CredentialMutationResult for cleanup", failures: &failures, checks: &checks)
    expect(Keychain.confirmedString(DebridService.realDebrid.keychainAccount(owner: owner)) == .missing, "typed certified deletion remains distinguishable from failure", failures: &failures, checks: &checks)
}

@MainActor
private func testRemoteDebridApplyRetriesWithoutPublishingPartialTruth(failures: inout [String], checks: inout Int) {
    let storage = FakeDebridCredentialStorage()
    let keys = DebridKeys(storage: storage)
    let owner = testAccount("ffffffff-ffff-ffff-ffff-ffffffffffff")
    let capture = CredentialScopeRegistry.shared.bind(owner)
    keys.bind(owner: owner, capture: capture)
    let account = DebridService.torBox.keychainAccount(owner: owner)
    storage.failWrites(2, for: account)

    let first = keys.applyRemoteKeys([DebridService.torBox.rawValue: "remote-truth"], capture: capture)
    expect(!first.succeeded && first.failedServices == [.torBox], "a remote Debrid apply records the failed slot after both bounded writes fail", failures: &failures, checks: &checks)
    expect(keys.key(for: .torBox).isEmpty && storage.value(account) == nil, "a failed remote apply leaves the old local authority untouched", failures: &failures, checks: &checks)

    let retried = keys.applyRemoteKeys([DebridService.torBox.rawValue: "remote-truth"], capture: capture)
    expect(retried.succeeded && retried.failedServices.isEmpty, "the pending remote slot succeeds on the next bounded retry", failures: &failures, checks: &checks)
    expect(keys.key(for: .torBox) == "remote-truth" && storage.value(account) == "remote-truth", "only the certified retry publishes remote truth", failures: &failures, checks: &checks)
}

@MainActor
private func testOwnerBindNeverCarriesPriorKeys(failures: inout [String], checks: inout Int) {
    let storage = FakeDebridCredentialStorage()
    let keys = DebridKeys(storage: storage)
    let accountA = testAccount("cccccccc-cccc-cccc-cccc-cccccccccccc")
    let accountB = testAccount("dddddddd-dddd-dddd-dddd-dddddddddddd")
    let staleCapture = CredentialScopeRegistry.shared.bind(accountA)
    keys.bind(owner: accountA)
    expect(keys.setKey("account-a", for: .realDebrid), "account A credential is accepted", failures: &failures, checks: &checks)

    _ = CredentialScopeRegistry.shared.bind(accountB)
    keys.bind(owner: accountB)
    expect(keys.key(for: .realDebrid).isEmpty, "account B never inherits account A's credential", failures: &failures, checks: &checks)
    expect(keys.owner == accountB, "the in-memory owner is the exact bound owner", failures: &failures, checks: &checks)
    keys.bind(owner: accountA, capture: staleCapture)
    expect(keys.owner == accountB && keys.key(for: .realDebrid).isEmpty, "a delayed account A bind cannot overwrite account B", failures: &failures, checks: &checks)
}

@MainActor
private func testFailedScopedReadRebindsToEmptyNewOwner(failures: inout [String], checks: inout Int) async {
    let storage = FakeDebridCredentialStorage()
    let keys = DebridKeys(storage: storage)
    let accountA = testAccount("11111111-1111-1111-1111-111111111111")
    let accountB = testAccount("22222222-2222-2222-2222-222222222222")
    let captureA = CredentialScopeRegistry.shared.bind(accountA)
    keys.bind(owner: accountA, capture: captureA)
    expect(keys.setKey("account-a", for: .realDebrid), "hostile test publishes account A credential", failures: &failures, checks: &checks)
    await drainOutboundTasks()
    let revisionA = keys.revision
    let reloadCountA = await DebridCoordinator.shared.reloadCount()

    let captureB = CredentialScopeRegistry.shared.bind(accountB)
    storage.failReads(1, for: DebridService.realDebrid.keychainAccount(owner: accountB))
    keys.bind(owner: accountB, capture: captureB)
    await drainOutboundTasks()
    let snapshot = await DebridCoordinator.shared.lastSnapshot()
    expect(keys.owner == accountB, "a failed B read still adopts the validated B owner", failures: &failures, checks: &checks)
    expect(keys.keys.isEmpty, "a failed B read clears every A credential from memory", failures: &failures, checks: &checks)
    expect(keys.revision == revisionA + 1, "a failed B read advances the owner revision", failures: &failures, checks: &checks)
    expect(snapshot?.owner == accountB && snapshot?.authorityCapture == captureB && snapshot?.keys.isEmpty == true,
           "a failed B read reloads the resolver with an empty B snapshot", failures: &failures, checks: &checks)
    expect(await DebridCoordinator.shared.reloadCount() == reloadCountA + 1,
           "a failed B read schedules exactly one resolver reload", failures: &failures, checks: &checks)
}

@MainActor
private func testPlaybackAvailabilityPublication(failures: inout [String], checks: inout Int) {
    DebridPlaybackAvailability.shared.publish(torBoxConfigured: false)
    let storage = FakeDebridCredentialStorage()
    let signedOutAccount = DebridService.torBox.keychainAccount(owner: .signedOutDevice)
    storage.seed("signed-out-key", for: signedOutAccount)
    let keys = DebridKeys(storage: storage)
    expect(DebridPlaybackAvailability.shared.canResolveUsenet,
           "initial stored signed-out TorBox load publishes availability",
           failures: &failures, checks: &checks)

    let owner = testAccount("33333333-3333-3333-3333-333333333333")
    let capture = CredentialScopeRegistry.shared.bind(owner)
    keys.bind(owner: owner, capture: capture)
    expect(!DebridPlaybackAvailability.shared.canResolveUsenet,
           "binding an empty owner revokes TorBox playback availability",
           failures: &failures, checks: &checks)

    let account = DebridService.torBox.keychainAccount(owner: owner)
    expect(keys.setKey("owner-key", for: .torBox),
           "a certified TorBox set publishes availability",
           failures: &failures, checks: &checks)
    expect(DebridPlaybackAvailability.shared.canResolveUsenet,
           "certified TorBox set makes usenet playable",
           failures: &failures, checks: &checks)

    storage.failWrites(2, for: account)
    expect(!keys.setKey("replacement-key", for: .torBox),
           "a failed TorBox write stays closed",
           failures: &failures, checks: &checks)
    expect(DebridPlaybackAvailability.shared.canResolveUsenet,
           "a failed TorBox write preserves prior availability",
           failures: &failures, checks: &checks)

    storage.mismatchReads(2, for: account)
    expect(!keys.setKey("mismatched-key", for: .torBox),
           "a mismatched TorBox readback stays closed",
           failures: &failures, checks: &checks)
    expect(DebridPlaybackAvailability.shared.canResolveUsenet,
           "a mismatched TorBox readback preserves prior availability",
           failures: &failures, checks: &checks)

    expect(keys.setKey("", for: .torBox),
           "a certified TorBox delete succeeds",
           failures: &failures, checks: &checks)
    expect(!DebridPlaybackAvailability.shared.canResolveUsenet,
           "a certified TorBox delete revokes availability",
           failures: &failures, checks: &checks)
}

@MainActor
private func testSourceContracts(failures: inout [String], checks: inout Int) {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = testsDirectory.deletingLastPathComponent()
    let keysSource = (try? String(contentsOf: root.appendingPathComponent("SourcesShared/DebridKeys.swift"), encoding: .utf8)) ?? ""
    let syncSource = (try? String(contentsOf: root.appendingPathComponent("SourcesShared/VortXSyncManager.swift"), encoding: .utf8)) ?? ""
    let resolverSource = (try? String(contentsOf: root.appendingPathComponent("SourcesShared/DebridResolver.swift"), encoding: .utf8)) ?? ""
    expect(keysSource.contains("protocol DebridCredentialStorage"), "DebridKeys exposes only a narrow injectable storage seam", failures: &failures, checks: &checks)
    expect(keysSource.contains("CredentialDurableReadResult"), "Debrid reads retain value, missing, and failure as distinct cases", failures: &failures, checks: &checks)
    expect(keysSource.contains("CredentialMutationResult"), "Debrid consumes the typed mutation result", failures: &failures, checks: &checks)
    expect(keysSource.contains("Keychain.confirmedString") && keysSource.contains("Keychain.durableString"), "the production adapter composes through typed certified Keychain reads", failures: &failures, checks: &checks)
    expect(keysSource.contains("@MainActor\nfinal class DebridKeys"), "DebridKeys mutable authority is compiler-isolated to the main actor", failures: &failures, checks: &checks)
    expect(keysSource.contains("private func publishPlaybackAvailability"), "DebridKeys owns a private availability publisher", failures: &failures, checks: &checks)
    expect(keysSource.contains("DebridPlaybackAvailability.shared.publish(") && keysSource.contains("torBoxConfigured: keys[DebridService.torBox.rawValue]?.isEmpty == false"), "DebridKeys publishes the TorBox snapshot through the shared narrow authority", failures: &failures, checks: &checks)
    expect(keysSource.contains("keys[DebridService.torBox.rawValue]?.isEmpty == false"), "availability derives only from the certified TorBox key", failures: &failures, checks: &checks)
    expect(!keysSource.contains("Set<String>"), "availability does not generalize into a provider-key set", failures: &failures, checks: &checks)
    expect(keysSource.contains("loadScope()\n        publishPlaybackAvailability()"), "initial load publishes signed-out availability synchronously", failures: &failures, checks: &checks)
    expect(keysSource.components(separatedBy: "publishPlaybackAvailability()").count - 1 == 5, "all four availability publication paths remain present", failures: &failures, checks: &checks)
    expect(syncSource.contains("restore()\n        _ = DebridKeys.shared"), "sync startup restores before bootstrapping DebridKeys", failures: &failures, checks: &checks)
    expect(syncSource.contains("applyRemoteKeys"), "remote sync uses the same certified Debrid apply path as local mutations", failures: &failures, checks: &checks)
    expect(syncSource.contains("pendingDebrid"), "remote sync retains a retryable pending Debrid apply", failures: &failures, checks: &checks)
    expect(syncSource.contains("lastSyncedVersion = max") && syncSource.contains("hasAppliedAccountDoc = true"), "remote acknowledgement remains downstream of the Debrid apply gate", failures: &failures, checks: &checks)
    expect(!syncSource.contains("debridDidMutate"), "remote sync does not reload a cache already published by setKey", failures: &failures, checks: &checks)
    expect(syncSource.contains("debrid.owner == capture.scope"), "sync merge requires the exact Debrid owner and capture scope", failures: &failures, checks: &checks)
    expect(syncSource.contains("keys.removeValue(forKey: service.rawValue)"), "sync merge removes pulled Debrid values when authority does not match", failures: &failures, checks: &checks)
    expect(resolverSource.contains("DebridCacheCheckResult"), "cache checks expose provider failure separately from an empty success", failures: &failures, checks: &checks)
    expect(resolverSource.contains("return .failure") && resolverSource.contains("case let .success"), "cache awareness can leave lastQueried untouched after provider failure", failures: &failures, checks: &checks)
    expect(resolverSource.contains("private var cacheGeneration: UInt64 = 0"), "torrent cache awareness has a monotonic request fence", failures: &failures, checks: &checks)
    expect(resolverSource.contains("private var usenetGeneration: UInt64 = 0"), "usenet cache awareness has a monotonic request fence", failures: &failures, checks: &checks)
    expect(resolverSource.contains("self.cacheGeneration == generation"), "a late torrent result cannot publish after a newer refresh", failures: &failures, checks: &checks)
    expect(resolverSource.contains("self.usenetGeneration == generation"), "a late usenet result cannot publish after a newer refresh", failures: &failures, checks: &checks)
    expect(resolverSource.contains("lastQueriedCapture != capture"), "torrent cache dedupe is owner-generation scoped", failures: &failures, checks: &checks)
    expect(resolverSource.contains("lastUsenetQueriedCapture != capture"), "usenet cache dedupe is owner-generation scoped", failures: &failures, checks: &checks)
}

@main
struct DebridCredentialSecurityTests {
    @MainActor
    static func main() async {
        var failures: [String] = []
        var checks = 0
        await testLocalDurability(failures: &failures, checks: &checks)
        testMigrationNeedsCertifiedDestinationAndCleanup(failures: &failures, checks: &checks)
        testProductionAdapterIsTypedAndSourceLinked(failures: &failures, checks: &checks)
        testRemoteDebridApplyRetriesWithoutPublishingPartialTruth(failures: &failures, checks: &checks)
        testOwnerBindNeverCarriesPriorKeys(failures: &failures, checks: &checks)
        await testFailedScopedReadRebindsToEmptyNewOwner(failures: &failures, checks: &checks)
        testPlaybackAvailabilityPublication(failures: &failures, checks: &checks)
        testSourceContracts(failures: &failures, checks: &checks)
        if failures.isEmpty {
            print("PASS: \(checks) Debrid credential security checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}

#else

/// Compile-only composition fixture: this mode links the real DebridKeys production adapter to the corrected
/// ApiKeys-lane Keychain.swift supplied on the swiftc command line. No fake Keychain type can hide a result-case
/// or return-type mismatch here.
@MainActor
final class VortXSyncManager {
    static let shared = VortXSyncManager()
    func requestSyncSoon() {}
}

actor DebridCoordinator {
    static let shared = DebridCoordinator()

    func reload(snapshot: DebridCredentialSnapshot) async {
        _ = snapshot
    }
}

@main
struct DebridProductionAdapterCompileFixture {
    @MainActor
    static func main() {
        let keys = DebridKeys()
        _ = keys.key(for: .torBox)
        let _: CredentialDurableReadResult = Keychain.confirmedString("vortx.debrid.compile.fixture")
        let _: CredentialDurableReadResult = Keychain.durableString("vortx.debrid.compile.fixture")
        let _: CredentialMutationResult = Keychain.set(nil, for: "vortx.debrid.compile.fixture")
    }
}

#endif
