import Foundation
import CryptoKit

@main
private enum VortxAccountFileRepairServiceTests {
    typealias Service = VortxAccountFileRepairService
    typealias Exact = OwnerHistoryExactJSON
    static let accountID = "10000000-0000-0000-0000-000000000001"
    static let otherAccountID = "10000000-0000-0000-0000-000000000002"
    static let ownerID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static let key = Data(repeating: 0x41, count: 32)
    static func check(_ value: Bool, _ name: String) { precondition(value, name); print("PASS: " + name) }
    static func source(owner: UUID = ownerID) throws -> Data {
        let profile = UserProfile(id: owner, name: "[RD] Synthetic Owner", avatar: "O", isOwner: true)
        var vx = try Exact.Object(Data("{}".utf8))
        vx.set("roster", try JSONEncoder().encode([profile]))
        vx.set("rosterModified", Data("1700000000".utf8))
        vx.set("library", Data("[]".utf8)); vx.set("addons", Data("[]".utf8))
        var root = try Exact.Object(Data("{}".utf8))
        root.set("vortx", try vx.encoded())
        root.set("future", Data(#"{"number":1.00,"order":[3,2,1]}"#.utf8))
        root.set("apiKeys", Data(#"{"synthetic-provider":"preserve-only"}"#.utf8))
        return try root.encoded()
    }
    static func file(_ plaintext: Data) throws -> Data {
        let document = VortXSyncCrypto.sealDocument(dataKey: key, plaintext: plaintext,
            accountId: accountID, version: 12, writeV2: false)!
        return try VortxAccountBackupFile.encode(document: document, version: 12,
            username: "Synthetic", now: Date(timeIntervalSince1970: 1_700_000_000))
    }
    static func head(_ plaintext: Data) throws -> Data {
        let document = VortXSyncCrypto.sealDocument(dataKey: key, plaintext: plaintext,
            accountId: accountID, version: 24, writeV2: false)!
        var root = try Exact.Object(Data("{}".utf8))
        root.set("document", try Exact.string(document)); root.set("version", Data("24".utf8))
        return try root.encoded()
    }
    @MainActor static func manager(_ response: Data) -> VortXSyncManager {
        _ = CredentialScopeRegistry.shared.fixtureEstablish(.account(UUID(uuidString: accountID)!))
        VortXSyncManager.fixtureSawV2 = false
        AccountRepairBoundaryHooks.afterWorker = nil
        return VortXSyncManager(accountID: accountID, key: key, response: response)
    }
    @MainActor static func reject(_ name: String, manager: VortXSyncManager, file: Data,
                                  expected: (Error) -> Bool) async {
        do { _ = try await manager.prepareAccountBackupRepair(file); preconditionFailure("accepted " + name) }
        catch { check(expected(error), name) }
        check(!manager.fixtureHasOperation(), name + " retires owned operation")
    }
    @MainActor static func main() async throws {
        let original = try file(source()), rawHead = try head(source())
        let originalSHA = Service.digest(original)
        let good = manager(rawHead)
        let preview = try await good.prepareAccountBackupRepair(original)
        check(preview.profileCount == 1 && (1...5).contains(preview.nativeSchema), "actual ABI conversion yields native preview")
        let converted = try good.takeAccountBackupRepairExport(preview.id)
        check(converted != original && Service.digest(original) == originalSHA, "separate export leaves exact input unchanged")
        check(good.getCount == 1 && !good.fixtureHasOperation(), "one actual manager GET and one consumed export")
        do { _ = try good.takeAccountBackupRepairExport(preview.id); preconditionFailure("reused export") }
        catch { check(true, "export UUID cannot be replayed") }

        let wrong = manager(try head(source(owner: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!)))
        await reject("independent server owner differs despite same key", manager: wrong, file: original) {
            if case Service.Failure.conversion(.ownerMismatch) = $0 { return true }; return false
        }
        let missing = manager(rawHead); missing.responseCode = 404
        await reject("404 cannot establish owner", manager: missing, file: original) {
            if case Service.Failure.ownerUnavailable = $0 { return true }; return false
        }
        let damaged = manager(Data(#"{"document":"bad","version":24.5}"#.utf8))
        await reject("invalid raw head rejected", manager: damaged, file: original) {
            if case Service.Failure.ownerUnavailable = $0 { return true }; return false
        }
        var nativeHead = try Exact.Object(source()); nativeHead.set("nativeSync", Data("null".utf8))
        let native = manager(try head(nativeHead.encoded()))
        await reject("present native current head cannot donate legacy owner", manager: native, file: original) {
            if case Service.Failure.currentAccountUnsupported = $0 { return true }; return false
        }
        let reimport = manager(rawHead)
        await reject("repaired file reauthenticates source then refuses reconversion", manager: reimport, file: converted) {
            if case Service.Failure.alreadyRepaired = $0 { return true }; return false
        }
        var changed = try Exact.Object(converted)
        changed.set("username", try Exact.string("Changed unsigned outer field"))
        let changedManager = manager(rawHead)
        await reject("changed preserved outer value rejects repaired copy", manager: changedManager, file: try changed.encoded()) {
            if case Service.Failure.repairedCopyChanged = $0 { return true }; return false
        }
        for boundary in ["GET", "worker"] {
            for mutation in ["account", "key", "cancel"] {
                let m = manager(rawHead)
                let mutate: @MainActor () -> Void = {
                    if mutation == "account" { m.fixtureOwnerTransition(to: otherAccountID) }
                    else if mutation == "key" { m.dataKey = Data(repeating: 0x42, count: 32) }
                    else { m.fixtureCancelCurrent() }
                }
                if boundary == "GET" { m.afterGET = mutate }
                else { AccountRepairBoundaryHooks.afterWorker = mutate }
                await reject(mutation + " changes at " + boundary + " await boundary", manager: m, file: original) {
                    if case Service.Failure.accountChanged = $0 { return true }; return false
                }
                AccountRepairBoundaryHooks.afterWorker = nil
            }
        }
        let cancelled = manager(rawHead)
        let task = FixtureTaskBox()
        AccountRepairBoundaryHooks.afterWorker = { task.value?.cancel() }
        task.value = Task { try await cancelled.prepareAccountBackupRepair(original) }
        do { _ = try await task.value!.value; preconditionFailure("cancelled task exported") }
        catch { check(error is CancellationError, "caller task cancellation after worker forbids result") }
        check(!cancelled.fixtureHasOperation(), "cancelled task releases single slot after unwind")
        AccountRepairBoundaryHooks.afterWorker = nil

        let exportManager = manager(rawHead)
        let exportPreview = try await exportManager.prepareAccountBackupRepair(original)
        exportManager.dataKey = Data(repeating: 0x43, count: 32)
        do { _ = try exportManager.takeAccountBackupRepairExport(exportPreview.id); preconditionFailure("changed export key") }
        catch { check(true, "key change before export refuses bytes") }
        exportManager.cancelAccountBackupRepair(exportPreview.id)

        let busy = manager(rawHead)
        let held = try await busy.prepareAccountBackupRepair(original)
        do { _ = try await busy.prepareAccountBackupRepair(original); preconditionFailure("parallel prepare") }
        catch { if case Service.Failure.busy = error { check(true, "prepared preview owns single operation") } else { throw error } }
        busy.cancelAccountBackupRepair(UUID())
        check(busy.fixtureHasOperation(), "stale UUID cannot cancel current operation")
        busy.cancelAccountBackupRepair(held.id)
        check(!busy.fixtureHasOperation(), "exact cancellation releases prepared file")

        let clock = FixtureClock()
        let capture = CredentialScopeRegistry.shared.fixtureEstablish(.account(UUID(uuidString: accountID)!))
        let fence = Service.Fence(capture: capture, now: { clock.read() })
        try fence.check(); clock.advance(Service.lifetimeNanoseconds)
        do { try fence.check(); preconditionFailure("expired fence") }
        catch { if case Service.Failure.expired = error { check(true, "monotonic expiry needs no sleep") } else { throw error } }
        print("All actual-source account file service boundary checks passed with the linked native ABI.")
    }
}

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ amount: UInt64) { lock.lock(); value += amount; lock.unlock() }
}

@MainActor
private final class FixtureTaskBox {
    var value: Task<VortxAccountFileRepairService.Preview, Error>?
}
