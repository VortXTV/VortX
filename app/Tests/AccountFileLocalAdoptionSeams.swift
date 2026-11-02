import Foundation
import CryptoKit
import Darwin

// DECLARED SYNTHETIC transport/native/provider collaborators. The extractor inserts the actual
// whole syncDown and completion/status/Finish methods with zero body rewrites. The encrypted journal
// below is the actual production actor. This suite cannot prove the real native kernel, checkpoint
// transaction, provider services, SDK or device. Those remain separately maintained proof layers.
@MainActor final class AdoptionWorld {
    static var current = AdoptionWorld()
    static let account = "10000000-0000-0000-0000-000000000001"
    static let owner = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static let key = Data(repeating: 0x41, count: 32)
    var plaintext = Data(#"{ "nativeSync":{"schemaVersion":5,"familyFixture":{"kids":true,"pin":"retained"}},"nativeHostPreferences":{},"unknown":1.00 }"#.utf8)
    var revision = 25
    var observation: UUID? = UUID()
    enum Response { case document, empty, unchanged, failed, ownerHistory }
    var response = Response.document
    var gets = 0, commits = 0, publications = 0, stamps = 0, mediaApplies = 0, iptvApplies = 0
    var failNative = false, failProvider = false, failMount = false, causalRepublish = false
    var providerPlan = true
    var callback: (@MainActor (String) -> Void)?
    var paused: String?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var observers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var visited = Set<String>()
    func visit(_ name: String) async {
        await Task.yield()
        visited.insert(name)
        observers.removeValue(forKey: name)?.forEach { $0.resume() }
        callback?(name)
        if paused == name { await withCheckedContinuation { releaseContinuation = $0 } }
    }
    func wait(_ name: String) async {
        if visited.contains(name) { return }
        await withCheckedContinuation { observers[name, default: []].append($0) }
    }
    func release() { paused = nil; let continuation = releaseContinuation; releaseContinuation = nil; continuation?.resume() }
}
enum VortxNativeStorage {
    // An explicit root owned by the future runner, never Application Support or customer state.
    static func root(create: Bool) throws -> URL {
        precondition(!create)
        guard CommandLine.arguments.count == 2 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
}
@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID? = AdoptionWorld.owner
    func mergeInRoster(_ profiles: [String], incomingModified: Date?) {}
    func applyLocalTombstones() {}
    func reloadFromDefaults() {}
}
@MainActor final class CoreBridge {
    static let shared = CoreBridge()
    struct Registry { let scope: VortxAccountScope; let profileID: String; let generation: UUID }
    var hasNativeSession = true, hasOwnerHistorySession = false
    var session = UUID(), accountGeneration = UUID(), registryGeneration = UUID()
    var wrongScope = false, wrongOwner = false
    var nativeRegistryBinding: Registry? {
        guard hasNativeSession, let id = ProfileStore.shared.activeID else { return nil }
        return .init(scope: .init(account: wrongScope ? "wrong" : CredentialScopeRegistry.shared.capture().namespace,
            ownerProfileID: wrongOwner ? UUID().uuidString : AdoptionWorld.owner.uuidString),
            profileID: id.uuidString, generation: registryGeneration)
    }
    func captureNativePlaybackTarget() -> PlaybackMutationTarget {
        guard hasNativeSession, let profile = ProfileStore.shared.activeID else { return .native(nil) }
        return .native(.init(profileID: profile, credential: CredentialScopeRegistry.shared.capture(),
            sessionGeneration: session, accountGeneration: accountGeneration))
    }
    func nativePlaybackTargetIsCurrent(_ target: PlaybackMutationTarget) -> Bool { hasNativeSession && target == captureNativePlaybackTarget() }
    func hasCertifiedNativeSession(capture: CredentialScopeRegistry.Capture, profileID: UUID?) -> Bool {
        hasNativeSession && capture == CredentialScopeRegistry.shared.capture() && profileID == ProfileStore.shared.activeID && profileID != nil
    }
    func rebuildContinueWatching() { AdoptionWorld.current.publications += 1; AdoptionWorld.current.callback?("publication") }
    func hydrateAddonsFromAccount(_ value: [String]) {}
    func cancelNativeOwnerHistoryRead(_ id: UUID) {}
}
struct VortxNativeProviderCredentials {
    struct Register: Equatable { let value: VortxJSON }
    struct Document: Equatable { var fields: [String: Register] = [:] }
    struct Local { var document = Document() }
    static let groups: [[String]] = [["traktAccess"], ["simklAccess"]]
    var local = Local()
    var hasPreparedMutation = false
    @MainActor func requiresCausalRepublish(pulled: VortxJSON?) throws -> Bool { AdoptionWorld.current.causalRepublish }
}
enum DebridService: String, CaseIterable { case realDebrid, allDebrid, premiumize, torBox }
@MainActor struct DebridKeys {
    struct Result { let succeeded: Bool; let failedServices: Set<DebridService> }
    static let shared = Self()
    func applyRemoteKeys(_ values: [String: String], capture: CredentialScopeRegistry.Capture) -> Result { .init(succeeded: true, failedServices: []) }
}
@MainActor final class ApiKeys { static let shared = ApiKeys(); var tmdb = "", mdblist = "", fanart = "" }
enum ApiKeySlots {
    static func tmdb(_ scope: CredentialScope) -> String { "tmdb" }
    static func mdblist(_ scope: CredentialScope) -> String { "mdblist" }
    static func fanart(_ scope: CredentialScope) -> String { "fanart" }
}
@MainActor enum Keychain {
    enum Read { case missing, value(String), unavailable }
    static func confirmedString(_ slot: String) -> Read {
        switch slot { case "tmdb": return .value(ApiKeys.shared.tmdb); case "mdblist": return .value(ApiKeys.shared.mdblist); default: return .value(ApiKeys.shared.fanart) }
    }
}
enum SettingsBackup {
    static func restore(from: Data, skipping: Set<String>, excluding: Set<String>) throws -> Int { 0 }
    static func appliedKeys(from: Data, excluding: Set<String>) -> Set<String> { [] }
    static func reloadLiveStores() {}
}
enum ProfileDiscoveryPreferencesStore { static let activeProjectionKeys = Set<String>() }
enum AddonTombstones { static func preservingLocalSyncStamps<T>(_ body: () throws -> T) rethrows -> T { try body() } }
enum LastStreamStore { static func invalidateCache() {} }
enum SearchHistoryStore { static func merge(_ terms: [String], for profileID: UUID?) {} }
@MainActor struct MediaServerStore { static let shared = Self(); func applySyncBlob(_ blob: String) { AdoptionWorld.current.mediaApplies += 1 } }
@MainActor struct IPTVPlaylistStore { static let shared = Self(); func applySyncBlob(_ blob: String) { AdoptionWorld.current.iptvApplies += 1 } }
enum CredentialMutationResult { case success, rejected }
@MainActor struct TraktAuth {
    static let shared = Self()
    func applyNativeCredentialClear(capture: CredentialScopeRegistry.Capture, events: [String: VortxNativeProviderCredentials.Register]) async -> Bool { true }
    func adoptTokens(access: String, refresh: String, expiryUnix: Int, ownerCapture: CredentialScopeRegistry.Capture, mutationGuard: (@MainActor () -> Void) -> Bool) async -> CredentialMutationResult { .success }
}
@MainActor struct SIMKLAuth {
    static let shared = Self()
    func applyNativeCredentialClear(capture: CredentialScopeRegistry.Capture, events: [String: VortxNativeProviderCredentials.Register]) async -> Bool { true }
    func adoptTokens(access: String, expiryUnix: Int, ownerCapture: CredentialScopeRegistry.Capture, mutationGuard: (@MainActor () -> Void) -> Bool) async -> CredentialMutationResult { .success }
}
struct CredentialProviderRetryOutcome {
    let firstCompleted: Bool, secondCompleted: Bool, superseded: Bool
    var completed: Bool { firstCompleted && secondCompleted && !superseded }
}
@MainActor enum CredentialRetryCoordinator {
    static func finalizeProviders<A, B>(maximumAttempts: Int, isCurrent: () -> Bool,
        firstClaim: () -> A, firstClaimSucceeded: (A) -> Bool, firstNeedsFinalization: (A) -> Bool,
        firstFinalize: () async -> Bool, secondClaim: () -> B, secondClaimSucceeded: (B) -> Bool,
        secondNeedsFinalization: (B) -> Bool, secondFinalize: () async -> Bool,
        sleepBeforeRetry: () async -> Bool) async -> CredentialProviderRetryOutcome {
        await AdoptionWorld.current.visit("provider.settlement")
        return .init(firstCompleted: !AdoptionWorld.current.failProvider,
            secondCompleted: !AdoptionWorld.current.failProvider, superseded: !isCurrent())
    }
}
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
enum SyncBackupUploadFailure { case upgradeRequired }
@MainActor struct OwnerHistoryRawAccountPreparationWorker {
    static let shared = Self()
    func peerHostProjection(_ data: Data) async throws -> Data { data }
}

@MainActor final class VortXSyncManager {
    struct Account { let id: String }
    var account: Account? = .init(id: AdoptionWorld.account)
    var dataKey: Data? = AdoptionWorld.key
    var isSignedIn = true, hasAppliedAccountDoc = false, hasPendingPush = false
    var accountFileRestoreBusy = false
    var accountFileRepairOperation: UUID?
    var activeSyncDown: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    var activeSyncUp: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    var lastSyncedVersion = 24
    var nativeCheckpointGeneration: UInt64 = 0
    var backupUploadFailure: SyncBackupUploadFailure?
    private var nativeReceiveReceipt: NativeReceiveReceipt?
    private var pendingDebridApply: PendingDebridApply?
    private var pendingProviderApply: PendingProviderApply?
    var dirtySettings: [String: Double] = [:]
    var appliedSettingsBaseline = Set<String>()
    let credentialAuthority = CredentialScopeRegistry.shared
    let providerRemoteApplyMaximumAttempts = 1
    enum ConflictResolutionOutcome { case completed, pending, failed }
    private func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { credentialAuthority.isCurrent(capture) }
    private func accountReconnectRequired(for capture: CredentialScopeRegistry.Capture) -> Bool { false }
    private func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool {
        pendingDebridApply?.capture == capture || pendingProviderApply?.capture == capture
    }
    private func withRemoteApplySuppressed(_ body: () -> Void) { body() }
    private func pullDocVersionedRetrying(credentialCapture: CredentialScopeRegistry.Capture, ifNoneMatch: Int?) async -> VersionedPull {
        let w = AdoptionWorld.current; w.gets += 1
        let plain = w.plaintext, revision = w.revision, observation = w.observation
        await w.visit("GET") // Deliberately noncooperative; the production receive must fence it.
        switch w.response {
        case .document: return .doc(doc: (try? JSONSerialization.jsonObject(with: plain) as? [String: Any]) ?? [:], version: revision, plaintext: plain, observation: observation)
        case .empty: return .empty
        case .unchanged: return .unchanged(version: revision)
        case .failed: return .failed(retryable: false)
        case .ownerHistory: return .ownerHistory(plaintext: plain, version: revision, observation: observation ?? UUID())
        }
    }
    private func restoreOwnerHistoryPulledIfNeeded(_ received: VersionedPull, capture: CredentialScopeRegistry.Capture, selectedProfile: UUID?, generation: UInt64) async throws -> Bool { false }
    private func mountOwnerHistoryPulled(plaintext: Data, observation: UUID, capture: CredentialScopeRegistry.Capture, selectedProfile: UUID?, generation: UInt64) async throws { throw VortxNativeError.unavailable }
    private func commitOwnerHistoryPulled(plaintext: Data, version: Int, observation: UUID, capture: CredentialScopeRegistry.Capture) async throws -> (document: [String: Any], target: PlaybackMutationTarget, read: UUID) { throw VortxNativeError.unavailable }
    private static func decodeDecryptedSyncDocument(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
    private func settleNativeProviderJournal(capture: CredentialScopeRegistry.Capture) async -> Bool { await AdoptionWorld.current.visit("provider.journal"); return isCurrent(capture) }
    private func nativeProviderState(capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { .init() }
    private func mergedNativeProviderState(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { .init() }
    private func persistMergedNativeProviders(_ providers: VortxNativeProviderCredentials, capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { providers }
    private func mirrorNativeProviderKeys(_ providers: VortxNativeProviderCredentials, original: Any?) throws -> [String: Any] { original as? [String: Any] ?? [:] }
    private func commitNativePulledDocument(_ doc: [String: Any], originalPlaintext: Data, capture: CredentialScopeRegistry.Capture) async throws -> PlaybackMutationTarget {
        let originalTarget = CoreBridge.shared.captureNativePlaybackTarget()
        await AdoptionWorld.current.visit("native.commit")
        guard !AdoptionWorld.current.failNative else { throw VortxNativeError.unavailable }
        AdoptionWorld.current.commits += 1
        return originalTarget // SYNTHETIC native receipt: real C ABI transaction is a separate gate.
    }
    private func nativeMutationDidCommit(credentialCapture: CredentialScopeRegistry.Capture) { hasPendingPush = true }
    private func retireNativeProviderApply(_ service: ProviderApplyService, capture: CredentialScopeRegistry.Capture) {}
    private func providerApplyIntent(keys: [String: String]?, capture: CredentialScopeRegistry.Capture, version: Int) -> PendingProviderApply? {
        AdoptionWorld.current.providerPlan ? .init(capture: capture, version: version, values: [.trakt: .trakt(access: "fixture", refresh: "fixture", expiryUnix: 1)], failedServices: []) : nil
    }
    private static func withNativeProviderSnapshot(_ snapshot: VortxNativeProviderCredentials.Document, capture: CredentialScopeRegistry.Capture, mutation: @MainActor () -> Void) -> Bool { mutation(); return true }
    private func waitForProviderRemoteApplyRetry(capture: CredentialScopeRegistry.Capture) async -> Bool { false }
    private func ensureNativeCheckpoint(credentialCapture: CredentialScopeRegistry.Capture) async -> Bool {
        await AdoptionWorld.current.visit("mount")
        guard !AdoptionWorld.current.failMount else { return false }
        CoreBridge.shared.hasNativeSession = true
        return isCurrent(credentialCapture)
    }
    private func persistLastSyncedVersion() {}
    private func stampSyncSuccess() { AdoptionWorld.current.stamps += 1 }
    private static func ownedAddons(from doc: [String: Any]) -> [String] { [] }
    private struct Roster { let profiles: [String]; let modified: Double? }
    private static func resolveRoster(from doc: [String: Any]) -> Roster? { nil }
    // @@ACTUAL_LOCAL_ADOPTION_MANAGER@@
    // Read-only fixture probes. These do not fabricate a witness or invoke its initializer.
    func fixtureHasCachedReceipt() -> Bool { nativeReceiveReceipt != nil }

}

// Fixture-only actor occupancy: no production journal body is changed. Holding its executor
// queues the actual status/readback or completion write so the original MainActor owner can retire.
final class JournalQueueHold: @unchecked Sendable {
    let released = DispatchSemaphore(value: 0)
    var task: Task<Void, Never>?
}
extension VortxAccountFileRestoreJournal {
    func fixtureOccupyQueue(_ entered: CheckedContinuation<Void, Never>, release: DispatchSemaphore) {
        entered.resume()
        release.wait()
    }
}

@main @MainActor enum AccountFileLocalAdoptionTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1; print("PASS \(label)") }
    static var journal: VortxAccountFileRestoreJournal { .shared }
    static func reset() throws -> VortXSyncManager {
        // Only disposable fixture files in the explicit runner root are removed between test cases.
        let root = try VortxNativeStorage.root(create: false)
        precondition(root.path.contains("/app/build/") && root.path.contains("local-adoption"))
        let child = root.appendingPathComponent("VortX")
        if FileManager.default.fileExists(atPath: child.path) { try FileManager.default.removeItem(at: child) }
        AdoptionWorld.current = AdoptionWorld()
        CredentialScopeRegistry.shared.establish(.account(UUID(uuidString: AdoptionWorld.account)!))
        ProfileStore.shared.activeID = AdoptionWorld.owner
        CoreBridge.shared.hasNativeSession = true; CoreBridge.shared.hasOwnerHistorySession = false
        CoreBridge.shared.session = UUID(); CoreBridge.shared.accountGeneration = UUID()
        CoreBridge.shared.registryGeneration = UUID(); CoreBridge.shared.wrongScope = false; CoreBridge.shared.wrongOwner = false
        return VortXSyncManager()
    }
    static func retain(operationID: UUID = UUID(), verdict: VortxAccountFileRestore.Verdict = .serverConfirmed) async throws -> VortxAccountFileRestore.Intent {
        let w = AdoptionWorld.current, capture = CredentialScopeRegistry.shared.capture()
        let intent = VortxAccountFileRestore.Intent(format: "vortx-account-file-restore-intent-v1", sourceKind: "user_selected_file",
            operationID: operationID, accountID: AdoptionWorld.account, ownerProfileID: AdoptionWorld.owner.uuidString,
            selectedFile: Data("retained-original-selected".utf8), candidateFile: Data("retained-original-candidate".utf8),
            replacedHeadResponse: Data("retained-original-head".utf8), plaintextSHA256: VortxAccountFileRestore.digest(w.plaintext),
            baseRevision: w.revision - 1, revision: w.revision,
            submittedDocument: VortXSyncCrypto.sealDocument(dataKey: AdoptionWorld.key, plaintext: w.plaintext,
                accountId: AdoptionWorld.account, version: w.revision, writeV2: true)!)
        try await journal.retain(intent, key: AdoptionWorld.key, fence: .init(capture: capture))
        try await journal.record(.init(operationID: intent.operationID, verdict: verdict, revision: intent.revision), account: AdoptionWorld.account, key: AdoptionWorld.key)
        return intent
    }
    static func pending(_ id: UUID) async throws -> Bool { try await journal.unresolved(account: AdoptionWorld.account, key: AdoptionWorld.key) == id }
    static func holdJournal() async -> JournalQueueHold {
        let hold = JournalQueueHold(), journalActor = journal
        await withCheckedContinuation { entered in
            hold.task = Task.detached { await journalActor.fixtureOccupyQueue(entered, release: hold.released) }
        }
        return hold
    }
    static func settle(_ predicate: () -> Bool) async {
        let limit = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < limit { await Task.yield() }
        precondition(predicate(), "fixture boundary never reached")
    }
    static func main() async throws {
        do {
            let manager = try reset(), original = try await retain()
            let before = try await journal.load(account: original.accountID, id: original.operationID, key: AdoptionWorld.key)
            let result = await manager.finishAccountBackupFileRestore(original.operationID)
            guard case .localAdoptionRecorded(let id, revision: 25) = result else { preconditionFailure("Finish did not read real record") }
            check(id == original.operationID && AdoptionWorld.current.gets == 1, "restart-discovered original UUID completes through normal GET only")
            check(AdoptionWorld.current.commits == 1 && AdoptionWorld.current.publications == 1, "whole actual syncDown reaches commit and publication before receipt")
            check(!(try await pending(id)), "authenticated local completion retires exact unresolved intent")
            let after = try await journal.load(account: original.accountID, id: id, key: AdoptionWorld.key)
            check(before.selectedFile == after.selectedFile && before.candidateFile == after.candidateFile && before.replacedHeadResponse == after.replacedHeadResponse, "all immutable recovery evidence survives")
            try await journal.record(.init(operationID: id, verdict: .uploadAccepted, revision: 25), account: original.accountID, key: AdoptionWorld.key)
            check(!(try await pending(id)), "later transport receipt cannot downgrade adoption history")
            let again = await manager.finishAccountBackupFileRestore(id)
            guard case .localAdoptionRecorded = again else { preconditionFailure("idempotent status lost") }
            check(AdoptionWorld.current.gets == 1, "authenticated historical readback needs no replay")
            let stem = VortxAccountFileRestore.digest(Data(original.accountID.utf8))
            let completion = try VortxNativeStorage.root(create: false).appendingPathComponent("VortX/account-file-restores/local-adoption-\(stem)-\(id.uuidString.lowercased()).sealed")
            let sealedBefore = try Data(contentsOf: completion)
            AdoptionWorld.current.observation = UUID()
            _ = await manager.syncDown(force: true, routineReceive: true)
            check(try Data(contentsOf: completion) == sealedBefore, "repeat genuine receive is idempotent and does not replace sealed historical receipt")
        }
        do {
            let manager = try reset(), exactSource = AdoptionWorld.current.plaintext
            let previous = try await retain(operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, verdict: .notSubmitted)
            let ambiguous = try await retain(operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, verdict: .deliveryUnconfirmed)
            let current = try await retain(operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, verdict: .serverConfirmed)
            AdoptionWorld.current.plaintext = Data(#"{"nativeSync":{"schemaVersion":5},"unrelatedHealthyIntent":true}"#.utf8)
            let unrelated = try await retain(operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, verdict: .notSubmitted)
            AdoptionWorld.current.plaintext = exactSource
            let matching = [previous, ambiguous, current], all = matching + [unrelated]
            let root = try VortxNativeStorage.root(create: false)
            let directory = root.appendingPathComponent("VortX/account-file-restores")
            let stem = VortxAccountFileRestore.digest(Data(current.accountID.utf8))
            func file(_ prefix: String, _ id: UUID) -> URL {
                directory.appendingPathComponent("\(prefix)-\(stem)-\(id.uuidString.lowercased()).sealed")
            }
            let immutableBefore = try Dictionary(uniqueKeysWithValues: all.map { ($0.operationID, try Data(contentsOf: file("intent", $0.operationID))) })
            let transportBefore = try Dictionary(uniqueKeysWithValues: all.map { ($0.operationID, try Data(contentsOf: file("receipt", $0.operationID))) })
            let before = try await journal.status(account: current.accountID, key: AdoptionWorld.key)
            check(before.map(\.operationID) == all.map(\.operationID) && before.first?.state == .notSubmitted,
                  "multi-intent regression puts prior no-send intent before current server-confirmed UUID")
            let result = await manager.finishAccountBackupFileRestore(current.operationID)
            guard case .localAdoptionRecorded(let id, revision: 25) = result else { preconditionFailure("same-descriptor readback stranded current nonfirst intent") }
            check(id == current.operationID && AdoptionWorld.current.gets == 1 && AdoptionWorld.current.commits == 1,
                  "actual whole Finish/syncDown records current nonfirst UUID through real journal after three matching intents")
            let firstReadback = try await journal.status(account: current.accountID, key: AdoptionWorld.key)
            let independentJournal = VortxAccountFileRestoreJournal(root: root)
            let secondReadback = try await independentJournal.status(account: current.accountID, key: AdoptionWorld.key)
            check(firstReadback == secondReadback && firstReadback.count == 4,
                  "second independently opened complete status scan authenticates every retained entry")
            for original in matching {
                check(firstReadback.first(where: { $0.operationID == original.operationID })?.state == .localAdoptionRecorded,
                      "each same-source intent has authenticated completion after serial installed readbacks")
            }
            check(firstReadback.first(where: { $0.operationID == unrelated.operationID })?.state == .notSubmitted,
                  "unrelated healthy retained intent stays unchanged")
            check(try await independentJournal.unresolved(account: current.accountID, key: AdoptionWorld.key) == nil,
                  "all matching operations retire without hiding unrelated healthy history")
            let completedBefore = try Dictionary(uniqueKeysWithValues: matching.map { ($0.operationID, try Data(contentsOf: file("local-adoption", $0.operationID))) })
            AdoptionWorld.current.observation = UUID()
            _ = await manager.syncDown(force: true, routineReceive: true)
            let thirdReadback = try await independentJournal.status(account: current.accountID, key: AdoptionWorld.key)
            check(thirdReadback == firstReadback && AdoptionWorld.current.gets == 2 && AdoptionWorld.current.commits == 2,
                  "repeat genuine receive rereads the whole same-directory inventory idempotently")
            for original in all {
                check(try Data(contentsOf: file("intent", original.operationID)) == immutableBefore[original.operationID],
                      "every original sealed intent remains byte-identical across multi-intent completion and retry")
                check(try Data(contentsOf: file("receipt", original.operationID)) == transportBefore[original.operationID],
                      "completion does not replace any original transport receipt")
                let loaded = try await independentJournal.load(account: original.accountID, id: original.operationID, key: AdoptionWorld.key)
                check(loaded.selectedFile == original.selectedFile && loaded.candidateFile == original.candidateFile && loaded.replacedHeadResponse == original.replacedHeadResponse,
                      "all selected/candidate/replaced-head recovery bytes remain intact")
            }
            for original in matching {
                check(try Data(contentsOf: file("local-adoption", original.operationID)) == completedBefore[original.operationID],
                      "idempotent multi-intent retry preserves each completion ciphertext")
            }
            check(try await journal.unresolved(account: current.accountID, key: AdoptionWorld.key) == nil,
                  "second unresolved scan remains clear after repeat receive and independent status reads")
            // A later orphan must invalidate the WHOLE inventory, even after healthy completed
            // entries. Neither a second scan nor the corrected descriptor may skip this name.
            let orphan = file("local-adoption", UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!)
            try Data(repeating: 0x43, count: 40).write(to: orphan)
            for scan in [journal, independentJournal] {
                do {
                    _ = try await scan.status(account: current.accountID, key: AdoptionWorld.key)
                    preconditionFailure("healthy earlier entries hid a lexically later orphan")
                } catch { check(true, "complete repeated inventory rejects lexically later orphan after healthy entries") }
                do {
                    _ = try await scan.unresolved(account: current.accountID, key: AdoptionWorld.key)
                    preconditionFailure("later orphan released unresolved gate")
                } catch { check(true, "later orphan keeps unresolved discovery fail-closed") }
            }
            _ = await manager.syncDown(force: true, routineReceive: true)
            for original in matching {
                check(try Data(contentsOf: file("local-adoption", original.operationID)) == completedBefore[original.operationID],
                      "failed inventory on genuine retry neither replaces healthy completion nor discards orphan")
            }
            check(FileManager.default.fileExists(atPath: orphan.path), "unsafe later evidence remains retained")
        }
        do {
            let manager = try reset(); CoreBridge.shared.hasNativeSession = false
            let original = try await retain()
            _ = await manager.syncDown(routineReceive: true)
            check(!(try await pending(original.operationID)), "late cold commit target completes although earlier nativeDocumentCommitted Boolean stays false")
        }
        do {
            let manager = try reset(); AdoptionWorld.current.causalRepublish = true
            let original = try await retain()
            let restored = await manager.syncDown(routineReceive: true)
            let remainsPending = try await pending(original.operationID)
            check(!restored && manager.hasPendingPush && !remainsPending, "receive Boolean false and pending causal republish still permit genuine completed adoption")
            check(!manager.fixtureHasCachedReceipt(), "conditional receive cache remains stricter about pending causal push")
        }
        for boundary in ["GET", "provider.journal", "native.commit", "provider.settlement", "publication"] {
            for change in ["epoch", "account", "key", "profile", "session", "generation"] {
                // Before a commit starts, a profile/session change can legitimately be the new
                // transaction target. Test retirement only after the target was actually captured.
                if ["profile", "session", "generation"].contains(change) && ["GET", "provider.journal"].contains(boundary) { continue }
                let manager = try reset(), original = try await retain()
                AdoptionWorld.current.callback = { name in
                    guard name == boundary else { return }
                    switch change {
                    case "epoch": CredentialScopeRegistry.shared.establish(.account(UUID(uuidString: AdoptionWorld.account)!))
                    case "account": manager.account = .init(id: UUID().uuidString.lowercased())
                    case "key": manager.dataKey = Data(repeating: 0x42, count: 32)
                    case "profile": ProfileStore.shared.activeID = UUID()
                    case "session": CoreBridge.shared.session = UUID()
                    default: CoreBridge.shared.accountGeneration = UUID()
                    }
                }
                _ = await manager.syncDown(routineReceive: true)
                check(try await pending(original.operationID), "\(change) at \(boundary) prevents witness")
            }
        }
        for boundary in ["GET", "native.commit", "provider.settlement", "mount"] {
            let manager = try reset(); if boundary == "mount" { CoreBridge.shared.hasNativeSession = false }
            let original = try await retain(); AdoptionWorld.current.paused = boundary
            let task = Task { await manager.syncDown(routineReceive: true) }
            await AdoptionWorld.current.wait(boundary); task.cancel()
            check(manager.activeSyncDown != nil, "cancelled noncooperative \(boundary) retains receive ownership")
            AdoptionWorld.current.release(); _ = await task.value
            check(try await pending(original.operationID), "cancelled \(boundary) cannot mint after noncooperative return")
        }
        for change in ["epoch", "key", "cancel"] {
            let manager = try reset(), original = try await retain(), hold = await holdJournal()
            var started = false
            let task = Task { started = true; return await manager.finishAccountBackupFileRestore(original.operationID) }
            await settle { started }
            if change == "epoch" { CredentialScopeRegistry.shared.establish(.account(UUID(uuidString: AdoptionWorld.account)!)) }
            if change == "key" { manager.dataKey = Data(repeating: 0x42, count: 32) }
            if change == "cancel" { task.cancel() }
            hold.released.signal(); await hold.task?.value
            guard case .accountChanged = await task.value else { preconditionFailure("journal load retargeted") }
            let remainsPending = try await pending(original.operationID)
            check(AdoptionWorld.current.gets == 0 && remainsPending, "\(change) while original Finish journal load waits prevents receive")
        }
        for change in ["epoch", "key", "session", "profile", "cancel"] {
            let manager = try reset(), original = try await retain(), hold = await holdJournal()
            var outcome = VortXSyncManager.ConflictResolutionOutcome.failed
            let task = Task { await manager.syncDown(reportOutcome: { outcome = $0 }, routineReceive: true) }
            // On this MainActor, this observation is possible only after the full tail minted and
            // suspended on the actor write. No copied finalizer or hand-constructed witness is used.
            await settle { AdoptionWorld.current.publications == 1 }
            switch change {
            case "epoch": CredentialScopeRegistry.shared.establish(.account(UUID(uuidString: AdoptionWorld.account)!))
            case "key": manager.dataKey = Data(repeating: 0x42, count: 32)
            case "session": CoreBridge.shared.session = UUID()
            case "profile": ProfileStore.shared.activeID = UUID()
            default: task.cancel()
            }
            hold.released.signal(); await hold.task?.value; _ = await task.value
            check(!(try await pending(original.operationID)), "\(change) after true witness may seal original historical completion")
            check(outcome != .completed, "\(change) after witness cannot publish completed receive into replacement session")
        }
        for failure in ["native", "provider", "mount", "304", "404", "warm", "old", "different", "newer", "schema6", "observation", "scope", "owner"] {
            let manager = try reset(), original = try await retain(), w = AdoptionWorld.current
            switch failure {
            case "native": w.failNative = true
            case "provider": w.failProvider = true
            case "mount": CoreBridge.shared.hasNativeSession = false; w.failMount = true
            case "304": w.response = .unchanged
            case "404": w.response = .empty
            case "warm": manager.hasAppliedAccountDoc = true; manager.lastSyncedVersion = w.revision
            case "old": manager.lastSyncedVersion = w.revision + 1
            case "different": w.plaintext.append(Data(" ".utf8))
            case "newer": w.revision += 1
            case "schema6": w.plaintext = Data(#"{"nativeSync":{"schemaVersion":6}}"#.utf8)
            case "observation": w.observation = nil
            case "scope": CoreBridge.shared.wrongScope = true
            default: CoreBridge.shared.wrongOwner = true
            }
            _ = await manager.syncDown(routineReceive: failure != "warm")
            check(try await pending(original.operationID), "\(failure) never substitutes for exact full successful source")
        }
        for key in ["vortx.mediaServers", "vortx.iptv"] {
            for value in ["\"\"", "\"malformed blob\"", "null", "{}"] {
                let manager = try reset()
                AdoptionWorld.current.plaintext = Data("{\"nativeSync\":{\"schemaVersion\":5},\"apiKeys\":{\"\(key)\":\(value)}}".utf8)
                let original = try await retain(), exact = AdoptionWorld.current.plaintext
                _ = await manager.syncDown(routineReceive: true)
                check(try await pending(original.operationID), "unacknowledged \(key) \(value) keeps full-tail completion pending")
                check(AdoptionWorld.current.plaintext == exact, "provider refusal does not strip source carrier")
                let result = await manager.finishAccountBackupFileRestore(original.operationID)
                guard case .pending(_, reason: .legacyProviderSettlementUnavailable) = result else { preconditionFailure("typed provider scope missing") }
            }
        }
        do {
            let manager = try reset(); manager.hasAppliedAccountDoc = true; manager.hasPendingPush = true
            let original = try await retain(); _ = await manager.finishAccountBackupFileRestore(original.operationID)
            let remainsPending = try await pending(original.operationID)
            check(AdoptionWorld.current.gets == 0 && remainsPending, "Finish preserves actual pending-edit guard")
        }

        do {
            let manager = try reset(), original = try await retain()
            AdoptionWorld.current.callback = { boundary in
                guard boundary == "publication" else { return }
                let dir = try! VortxNativeStorage.root(create: false).appendingPathComponent("VortX/account-file-restores")
                let stem = VortxAccountFileRestore.digest(Data(original.accountID.utf8))
                try! Data(repeating: 0x43, count: 40).write(to: dir.appendingPathComponent(".local-adoption-\(stem).stage"))
            }
            _ = await manager.syncDown(routineReceive: true)
            check(AdoptionWorld.current.commits == 1 && AdoptionWorld.current.publications == 1,
                  "failed completion persistence does not undo genuine native commit/publication")
            let status = await manager.accountBackupFileRestoreStatus()
            guard case .recoveryUnavailable = status else { preconditionFailure("surviving stage claimed completion") }
        }
        for damage in ["corrupt", "orphan", "stage", "unsafe", "symlink", "wrong-key", "wrong-intent", "wrong-owner", "wrong-revision", "wrong-hash", "unknown-format"] {
            let manager = try reset(), original = try await retain()
            _ = await manager.syncDown(routineReceive: true)
            let dir = try VortxNativeStorage.root(create: false).appendingPathComponent("VortX/account-file-restores")
            let stem = VortxAccountFileRestore.digest(Data(original.accountID.utf8))
            let completion = dir.appendingPathComponent("local-adoption-\(stem)-\(original.operationID.uuidString.lowercased()).sealed")
            let intent = dir.appendingPathComponent("intent-\(stem)-\(original.operationID.uuidString.lowercased()).sealed")
            switch damage {
            case "corrupt": try Data(repeating: 0x43, count: 40).write(to: completion)
            case "orphan": try FileManager.default.removeItem(at: intent)
            case "stage": try Data(repeating: 0x43, count: 40).write(to: dir.appendingPathComponent(".local-adoption-\(stem).stage"))
            case "unsafe": _ = chmod(completion.path, 0o644)
            case "symlink": try FileManager.default.removeItem(at: completion); try FileManager.default.createSymbolicLink(at: completion, withDestinationURL: intent)
            case "wrong-intent": var bytes = try Data(contentsOf: intent); bytes[0] ^= 1; try bytes.write(to: intent)
            case "wrong-owner", "wrong-revision", "wrong-hash", "unknown-format":
                let aad = Data(("vortx-account-file-local-adoption-v1" + "\u{0}" + original.accountID + "\u{0}" + original.operationID.uuidString.lowercased()).utf8)
                let encrypted = try Data(contentsOf: completion)
                let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: AdoptionWorld.key), authenticating: aad)
                var object = try JSONSerialization.jsonObject(with: plaintext) as! [String: Any]
                if damage == "wrong-owner" { var scope = object["scope"] as! [String: Any]; scope["ownerProfileID"] = UUID().uuidString; object["scope"] = scope }
                if damage == "wrong-revision" { object["revision"] = 26 }
                if damage == "wrong-hash" { object["plaintextSHA256"] = String(repeating: "0", count: 64) }
                if damage == "unknown-format" { object["format"] = "future-format" }
                let resealed = try AES.GCM.seal(JSONSerialization.data(withJSONObject: object), using: SymmetricKey(data: AdoptionWorld.key), authenticating: aad).combined!
                try resealed.write(to: completion)
            default: break
            }
            do {
                _ = try await journal.unresolved(account: original.accountID, key: damage == "wrong-key" ? Data(repeating: 0x42, count: 32) : AdoptionWorld.key)
                preconditionFailure("\(damage) journal inventory was not refused")
            } catch { check(true, "\(damage) fails closed without releasing retained source") }
        }
        print("local-adoption synthetic orchestration and real journal checks: \(checks)")
    }
}
