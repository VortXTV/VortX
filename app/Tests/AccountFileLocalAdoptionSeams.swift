import Foundation
import CoreFoundation
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
    var nestedCheckpoint = false, localCheckpointAvailable = false
    var checkpointPlaintext: Data?, checkpointRevision: Int?, checkpointTyped = false
    var checkpointGets = 0, checkpointEffects = 0, localReopens = 0
    var providerPlan = true, failJournal = false
    var settingsDomain: [String: Any] = [:]
    var settingsEffects = 0, settingsReloads = 0, puts = 0
    var lastSettingsExclusions = Set<String>()
    var suppressionDepth = 0
    var failMedia = false, failIPTV = false, wrongProviderReceipt = false, wrongProviderOperation = false
    var mirrorProviderOverride: String?
    var allowedProviderSources = Set<Data>()
    var mediaSources: [Data] = [], iptvSources: [Data] = []
    var mediaOperations: [UUID] = [], iptvOperations: [UUID] = []
    var callback: (@MainActor (String) -> Void)?
    var paused: String?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var observers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var visited = Set<String>()
    var boundaryCounts: [String: Int] = [:]
    func visit(_ name: String) async {
        await Task.yield()
        visited.insert(name)
        boundaryCounts[name, default: 0] += 1
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
    static let schema = 1, formatTag = "vortx-backup"
    // Declared pure fixture policy: all authored keys are syncable and already migrated. Actual
    // serialization/applied-key methods are inserted unchanged. No UserDefaults is accessed.
    static func isSyncable(_ key: String) -> Bool { true }
    static func migratedKey(_ key: String) -> String { key }
    // @@ACTUAL_SETTINGS_PURE@@
    @MainActor static func restore(from: Data, skipping: Set<String>, excluding: Set<String>) throws -> Int {
        let w = AdoptionWorld.current
        w.lastSettingsExclusions = excluding
        var count = 0
        for (key, value) in try decodeDomain(from: from) where !skipping.contains(key) && !excluding.contains(key) {
            w.settingsDomain[key] = value; w.settingsEffects += 1; count += 1
        }
        return count
    }
    @MainActor static func reloadLiveStores() { AdoptionWorld.current.settingsReloads += 1 }
}
enum ProfileDiscoveryPreferencesStore { static let activeProjectionKeys = Set<String>() }
enum AddonTombstones { static func preservingLocalSyncStamps<T>(_ body: () throws -> T) rethrows -> T { try body() } }
enum LastStreamStore { static func invalidateCache() {} }
enum SearchHistoryStore { static func merge(_ terms: [String], for profileID: UUID?) {} }
// These apply methods are explicitly SYNTHETIC store boundaries. Their receipt types below are
// selected unchanged from production, but only the separate actual-store suite proves store IO.
@MainActor struct MediaServerStore {
    static let shared = Self()
    // @@ACTUAL_MEDIA_RECEIPT_TYPES@@
    func applySyncBlobSettled(_ blob: String, operationID: UUID, isCurrent: @escaping () -> Bool) -> SyncSettlement {
        let w = AdoptionWorld.current
        precondition(w.suppressionDepth > 0 && w.commits > 0, "media must settle under suppression after actual commit boundary")
        w.callback?("media.before")
        guard isCurrent() else { return .refused(.superseded) }
        w.mediaApplies += 1; w.mediaSources.append(Data(blob.utf8)); w.mediaOperations.append(operationID)
        guard w.allowedProviderSources.contains(Data(blob.utf8)), !w.failMedia else { return .refused(.persistenceUnverified) }
        let receipt = SyncSettlementReceipt(source: w.wrongProviderReceipt ? blob + " " : blob,
            operationID: w.wrongProviderOperation ? UUID() : operationID)
        w.callback?("media.after")
        return .settled(receipt)
    }
}
@MainActor struct IPTVPlaylistStore {
    static let shared = Self()
    // @@ACTUAL_IPTV_RECEIPT_TYPES@@
    func applySyncBlobSettled(_ blob: String, operationID: UUID, isCurrent: @escaping () -> Bool) -> SyncSettlement {
        let w = AdoptionWorld.current
        precondition(w.suppressionDepth > 0 && w.commits > 0, "IPTV must settle under suppression after actual commit boundary")
        w.callback?("iptv.before")
        guard isCurrent() else { return .refused(.superseded) }
        w.iptvApplies += 1; w.iptvSources.append(Data(blob.utf8)); w.iptvOperations.append(operationID)
        guard w.allowedProviderSources.contains(Data(blob.utf8)), !w.failIPTV else { return .refused(.persistenceUnverified) }
        let receipt = SyncSettlementReceipt(source: w.wrongProviderReceipt ? blob + " " : blob,
            operationID: w.wrongProviderOperation ? UUID() : operationID)
        w.callback?("iptv.after")
        return .settled(receipt)
    }
}
struct RefusingCloudParentAuthority: VortxMutationAuthority {
    func withActive(_ operation: () throws -> Void) throws { throw VortxNativeError.superseded }
}
@MainActor final class AdoptionReceiveTaskBox { var task: Task<Bool, Never>? }
enum CredentialMutationResult { case success, rejected }
@MainActor struct TraktAuth {
    static let shared = Self()
    func applyNativeCredentialClear(capture: CredentialScopeRegistry.Capture, events: [String: VortxNativeProviderCredentials.Register], sourceAuthority: (any VortxMutationAuthority)? = nil) async -> Bool { true }
    func adoptTokens(access: String, refresh: String, expiryUnix: Int, ownerCapture: CredentialScopeRegistry.Capture? = nil, mutationGuard: (@Sendable (() -> Bool) -> Bool)? = nil) async -> CredentialMutationResult { .success }
}
@MainActor struct SIMKLAuth {
    static let shared = Self()
    func applyNativeCredentialClear(capture: CredentialScopeRegistry.Capture, events: [String: VortxNativeProviderCredentials.Register], sourceAuthority: (any VortxMutationAuthority)? = nil) async -> Bool { true }
    func adoptTokens(access: String, expiryUnix: Int, ownerCapture: CredentialScopeRegistry.Capture? = nil, mutationGuard: (@Sendable (() -> Bool) -> Bool)? = nil) async -> CredentialMutationResult { .success }
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
enum SyncBackupUploadFailure { case upgradeRequired, other
    static func classify(status: Int, serverCode: String?) -> Self { .other }
    var diagnosticCode: String { "synthetic" }
}
@MainActor struct OwnerHistoryRawAccountPreparationWorker {
    static let shared = Self()
    func peerHostProjection(_ data: Data) async throws -> Data { await AdoptionWorld.current.visit("typed.projection"); return data }
}

@MainActor final class VortXSyncManager {
    struct Account { let id: String }
    // Declared owner-mutation collaborators mirror the actual property observer invalidations.
    var account: Account? = .init(id: AdoptionWorld.account) {
        willSet { if account?.id != newValue?.id { receivedProviderCloudEpoch.observe() } }
    }
    var dataKey: Data? = AdoptionWorld.key {
        willSet { if dataKey != newValue { receivedProviderCloudEpoch.observe() } }
    }
    var isSignedIn = true {
        willSet { if isSignedIn != newValue { receivedProviderCloudEpoch.observe() } }
    }
    var hasAppliedAccountDoc = false, hasPendingPush = false
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
    // Actual pending admission methods are selected with the actual receive below.
    private func withRemoteApplySuppressed(_ body: () -> Void) {
        AdoptionWorld.current.suppressionDepth += 1
        defer { AdoptionWorld.current.suppressionDepth -= 1 }
        body()
    }
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
    private func restoreOwnerHistoryPulledIfNeeded(_ received: VersionedPull, capture: CredentialScopeRegistry.Capture, selectedProfile: UUID?, generation: UInt64, cloudAuthority: ReceivedProviderCloudAuthority) async throws -> Bool { await AdoptionWorld.current.visit("cold.restore"); return false }
    private func mountOwnerHistoryPulled(plaintext: Data, version: Int, observation: UUID, capture: CredentialScopeRegistry.Capture, selectedProfile: UUID?, generation: UInt64, cloudAuthority: ReceivedProviderCloudAuthority) async throws { throw VortxNativeError.unavailable }
    private func commitOwnerHistoryPulled(plaintext: Data, version: Int, observation: UUID, capture: CredentialScopeRegistry.Capture, cloudAuthority: ReceivedProviderCloudAuthority) async throws -> (document: [String: Any], target: PlaybackMutationTarget, read: UUID) { throw VortxNativeError.unavailable }
    private static func decodeDecryptedSyncDocument(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
    private func settleNativeProviderJournal(capture: CredentialScopeRegistry.Capture) async -> Bool { await AdoptionWorld.current.visit("provider.journal"); return isCurrent(capture) && !AdoptionWorld.current.failJournal }
    private func nativeProviderState(capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { .init() }
    private func mergedNativeProviderState(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { .init() }
    private func persistMergedNativeProviders(_ providers: VortxNativeProviderCredentials, capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { providers }
    private func mirrorNativeProviderKeys(_ providers: VortxNativeProviderCredentials, original: Any?) throws -> [String: Any] {
        var mirrored = original as? [String: Any] ?? [:]
        if let replacement = AdoptionWorld.current.mirrorProviderOverride {
            mirrored["vortx.mediaServers"] = replacement; mirrored["vortx.iptv"] = replacement
        }
        return mirrored
    }
    private func commitNativePulledDocument(_ doc: [String: Any], originalPlaintext: Data, capture: CredentialScopeRegistry.Capture,
        cloudAuthority: ReceivedProviderCloudAuthority) async throws -> PlaybackMutationTarget {
        try cloudAuthority.withActive {}
        let originalTarget = CoreBridge.shared.captureNativePlaybackTarget()
        await AdoptionWorld.current.visit("native.commit")
        guard !AdoptionWorld.current.failNative else { throw VortxNativeError.unavailable }
        try cloudAuthority.withActive { AdoptionWorld.current.commits += 1 }
        return originalTarget // SYNTHETIC native receipt: real C ABI transaction is a separate gate.
    }
    private func nativeMutationDidCommit(credentialCapture: CredentialScopeRegistry.Capture) { hasPendingPush = true }
    private func retireNativeProviderApply(_ service: ProviderApplyService, capture: CredentialScopeRegistry.Capture) {}
    private func providerApplyIntent(keys: [String: String]?, capture: CredentialScopeRegistry.Capture, version: Int) -> PendingProviderApply? {
        AdoptionWorld.current.providerPlan ? .init(capture: capture, version: version, values: [.trakt: .trakt(access: "fixture", refresh: "fixture", expiryUnix: 1)], failedServices: []) : nil
    }
    nonisolated private static func withNativeProviderSnapshot(_ snapshot: VortxNativeProviderCredentials.Document, capture: CredentialScopeRegistry.Capture, mutation: () -> Bool) -> Bool { mutation() }
    private func waitForProviderRemoteApplyRetry(capture: CredentialScopeRegistry.Capture) async -> Bool { false }
    private func pullDocVersionedResult(credentialCapture: CredentialScopeRegistry.Capture) async -> VersionedPull {
        let w = AdoptionWorld.current; w.checkpointGets += 1
        let bytes = w.checkpointPlaintext ?? w.plaintext, revision = w.checkpointRevision ?? w.revision
        await w.visit("checkpoint.GET") // Declared second transport collaborator, not a source replay.
        if w.checkpointTyped { return .ownerHistory(plaintext: bytes, version: revision, observation: UUID()) }
        return .doc(doc: (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:],
                    version: revision, plaintext: bytes, observation: UUID())
    }
    private func ensureNativeCheckpoint(credentialCapture: CredentialScopeRegistry.Capture, cloudRead: ReceivedProviderCloudAuthority? = nil) async -> Bool {
        let w = AdoptionWorld.current
        await w.visit("mount")
        guard !w.failMount else { return false }
        if w.localCheckpointAvailable {
            w.localReopens += 1; CoreBridge.shared.hasNativeSession = true
            return isCurrent(credentialCapture)
        }
        if w.nestedCheckpoint {
            // The real production fallback GET + source admission method is inserted unchanged.
            // Checkpoint creation here is explicit synthetic IO; real kernel proof is separate.
            let candidate = await pullNativeCheckpointCloudSource(capture: credentialCapture, authority: cloudRead)
            guard let authority = candidate.authority else { return false }
            await w.visit("checkpoint.before_commit")
            do { try authority.withActive { w.checkpointEffects += 1; CoreBridge.shared.hasNativeSession = true } }
            catch { return false }
        } else { CoreBridge.shared.hasNativeSession = true }
        return isCurrent(credentialCapture)
    }
    private func persistLastSyncedVersion() {}
    private func stampSyncSuccess() { AdoptionWorld.current.stamps += 1 }
    private static func ownedAddons(from doc: [String: Any]) -> [String] { [] }
    private struct Roster { let profiles: [String]; let modified: Double? }
    private static func resolveRoster(from doc: [String: Any]) -> Roster? { nil }
    // These are unreachable collaborators for the actual push sender preflight negative control.
    // Reaching transport is counted; a test fails if a pending source permits any PUT.
    static let writeSyncDocV2 = true
    private func request(_ method: String, _ path: String, body: [String: Any], auth: Bool,
        credentialCapture: CredentialScopeRegistry.Capture) async -> (Int, [String: Any]?) {
        AdoptionWorld.current.puts += 1; return (500, nil)
    }
    private func rememberNativeBackup(capture: CredentialScopeRegistry.Capture) -> Bool { preconditionFailure("push acknowledgment entered") }
    private func acknowledgeNativeProviders(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) throws { preconditionFailure("push acknowledgment entered") }
    private static func markSawDocV2(_ account: String) { preconditionFailure("push stamp entered") }
    private static func documentVersion(_ value: Any?) -> Int? { preconditionFailure("push rejection entered") }
    // @@ACTUAL_LOCAL_ADOPTION_MANAGER@@
    // Read-only fixture probes. These do not fabricate a witness or invoke its initializer.
    func fixtureBoundCloudAuthority(plaintext: Data, revision: Int) throws -> any VortxMutationAuthority {
        try fixtureBoundCloudRead(plaintext: plaintext, revision: revision)
    }
    private func fixtureBoundCloudRead(plaintext: Data, revision: Int) throws -> ReceivedProviderCloudAuthority {
        let read = try captureReceivedProviderCloudAuthority(credentialAuthority.capture())
        return try requireReceivedProviderCloudSource(.doc(doc: [:], version: revision,
            plaintext: plaintext, observation: UUID()), authority: read)
    }
    func fixtureCaptureCloudAuthority(plaintext: Data, revision: Int) throws -> () throws -> Void {
        let authority = try fixtureBoundCloudRead(plaintext: plaintext, revision: revision)
        return { try authority.withActive {} }
    }
    func fixtureCloudParentIsRetained(plaintext: Data, revision: Int) -> Bool {
        guard let authority = try? fixtureBoundCloudRead(plaintext: plaintext, revision: revision) else { return false }
        return (try? authority.including(RefusingCloudParentAuthority()).withActive {}) == nil
    }
    func fixtureCloudCheckpointRead() async -> Bool {
        let read = try? captureReceivedProviderCloudAuthority(credentialAuthority.capture())
        let candidate = await pullNativeCheckpointCloudSource(capture: credentialAuthority.capture(), authority: read)
        guard let authority = candidate.authority else { return false }
        await AdoptionWorld.current.visit("checkpoint.before_commit")
        do { try authority.withActive { AdoptionWorld.current.checkpointEffects += 1 }; return true }
        catch { return false }
    }
    func fixtureHighestProviderSource() -> Data? { pendingReceivedProviderApply?.highest.plaintext }
    func fixtureReservedProviderRevision() -> Int? { pendingReceivedProviderApply?.highest.revision }
    func fixturePushIsBlocked() async -> Bool {
        if case .error = await pushSyncDocAt([:], version: lastSyncedVersion + 1, baseRevision: lastSyncedVersion) { return true }
        return false
    }
    func fixtureHasCachedReceipt() -> Bool { nativeReceiveReceipt != nil }
    func fixtureHasPendingApply() -> Bool { hasPendingAccountDocApply(for: credentialAuthority.capture()) }
    func fixtureHasReceivedPending(for capture: CredentialScopeRegistry.Capture) -> Bool {
        hasPendingReceivedProviderApply(for: capture)
    }
    func fixtureUnrelatedPendingSnapshot() -> @MainActor () -> Bool {
        let debrid = pendingDebridApply, provider = pendingProviderApply
        return { (debrid != nil || provider != nil)
            && self.pendingDebridApply == debrid && self.pendingProviderApply == provider }
    }
    func fixtureFailedProviderSource(_ name: String, latest: Bool = false) -> Data? {
        guard let source = pendingReceivedProviderApply?.carriers[name] else { return nil }
        return latest ? source.latest.plaintext : source.first.plaintext
    }

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
    static let mediaBlob = #"{ "v":1,"servers":[{"id":"30000000-0000-0000-0000-000000000001","kind":"jellyfin","name":"Exact","urls":["https://synthetic.invalid"],"addedAt":1000,"token":"synthetic-token"}],"removed":{},"unknown":1.00 }"#
    static let iptvBlob = #"{ "v":1,"playlists":[{"id":"synthetic","kind":"m3u","name":"Exact","transportUrl":"https://synthetic.invalid/list","createdAt":1000}],"removed":{},"unknown":"e\u0301" }"#
    static func providerDocument(media: String? = nil, iptv: String? = nil, settings: [String: Any]? = nil) throws -> Data {
        var keys: [String: Any] = ["metadata": ["unknown": true]]
        if let media { keys["vortx.mediaServers"] = media }
        if let iptv { keys["vortx.iptv"] = iptv }
        var doc: [String: Any] = ["nativeSync": ["schemaVersion": 5], "nativeHostPreferences": [:], "apiKeys": keys]
        if let settings { doc["settings"] = try SettingsBackup.encode(domain: settings, bundleID: "fixture", app: "fixture", now: Date(timeIntervalSince1970: 0)).base64EncodedString() }
        return try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
    }
    static func admitProviderFixtures() {
        AdoptionWorld.current.allowedProviderSources = [Data(mediaBlob.utf8), Data(iptvBlob.utf8)]
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
        // Whole production composition; store application is an explicitly synthetic boundary.
        // Actual read/CAS/defaults/coordinator algorithms remain in the separate store gate.
        // F1: an admitted original source owns the pending barrier before every early return,
        // even when the ordinary OAuth plan is empty and the account is already opened.
        for failure in ["journal", "native", "target"] {
            let manager = try reset(), w = AdoptionWorld.current
            manager.hasAppliedAccountDoc = true; w.providerPlan = false
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob)
            let original = try await retain(), exact = w.plaintext
            if failure == "journal" { w.failJournal = true }
            if failure == "native" { w.failNative = true }
            if failure == "target" { w.callback = { if $0 == "native.commit" { CoreBridge.shared.accountGeneration = UUID() } } }
            _ = await manager.syncDown(routineReceive: true)
            check(manager.fixtureHasPendingApply() && manager.fixtureHighestProviderSource() == exact
                && manager.fixtureFailedProviderSource("vortx.mediaServers") == exact,
                "early \(failure) keeps original source reservation before checked stores")
            check(w.mediaApplies == 0 && w.stamps == 0 && manager.lastSyncedVersion == 24,
                "early \(failure) creates no provider receipt or receive floor")
            w.failJournal = false; w.failNative = false; w.callback = nil
            w.revision += 1; w.plaintext = try providerDocument()
            _ = await manager.syncDown(routineReceive: true)
            check(manager.fixtureHasPendingApply() && manager.fixtureFailedProviderSource("vortx.mediaServers") == exact,
                "omission after early \(failure) conserves failed source")
            check(await manager.fixturePushIsBlocked() && w.puts == 0,
                "actual push sender preflight rejects omission after early \(failure)")
            check(try await pending(original.operationID), "early \(failure) cannot retire original file intent")
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            CoreBridge.shared.hasNativeSession = false; w.providerPlan = false
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob)
            let exact = w.plaintext; w.paused = "cold.restore"
            let receive = Task { await manager.syncDown(routineReceive: true) }
            await w.wait("cold.restore")
            check(manager.fixtureHighestProviderSource() == exact && manager.fixtureHasPendingApply(),
                "source reservation precedes first cold restoration suspension")
            receive.cancel(); w.release(); _ = await receive.value
            check(manager.fixtureHasPendingApply() && w.mediaApplies == 0 && w.stamps == 0,
                "cancelled cold restoration retains source without provider completion")
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            manager.hasAppliedAccountDoc = true; manager.lastSyncedVersion = 25
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob)
            _ = await manager.syncDown(routineReceive: false)
            check(!manager.fixtureHasPendingApply() && w.commits == 0 && w.mediaApplies == 0,
                "equal warm hydration never reserves a new provider receive or forces later adoption")
            w.revision = 24; CoreBridge.shared.hasNativeSession = false
            _ = await manager.syncDown(routineReceive: true)
            check(!manager.fixtureHasPendingApply() && w.commits == 0 && w.mediaApplies == 0,
                "stale authenticated source is rejected before cold restore or reservation")
        }
        // F2: successful siblings stay behind the entire response's causality barrier.
        do {
            let manager = try reset(), w = AdoptionWorld.current
            manager.hasAppliedAccountDoc = true; manager.lastSyncedVersion = 9
            w.providerPlan = false; w.revision = 11; w.failIPTV = true
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob, iptv: iptvBlob)
            let original = try await retain(), exact = w.plaintext
            _ = await manager.syncDown(routineReceive: true)
            check(w.mediaApplies == 1 && w.iptvApplies == 1 && manager.fixtureReservedProviderRevision() == 11
                && manager.fixtureHasPendingApply() && manager.lastSyncedVersion == 9,
                "partial rev11 settlement retains whole response above durable floor9")
            let commits = w.commits, effects = w.settingsEffects
            let changedMedia = mediaBlob.replacingOccurrences(of: "Exact", with: "Contradictory")
            w.allowedProviderSources.insert(Data(changedMedia.utf8))
            for revision in [10, 11] {
                w.revision = revision; w.plaintext = try providerDocument(media: changedMedia)
                _ = await manager.syncDown(routineReceive: true)
                check(w.commits == commits && w.settingsEffects == effects && w.mediaApplies == 1 && w.iptvApplies == 1,
                    "rev\(revision) sibling rollback is refused before native host and provider effects")
                check(manager.fixtureHighestProviderSource() == exact && manager.fixtureReservedProviderRevision() == 11,
                    "rev\(revision) contradiction cannot replace retained full-source causality")
            }
            w.revision = 11; w.plaintext = exact; w.failIPTV = false
            _ = await manager.syncDown(routineReceive: true)
            let remainsPending = try await pending(original.operationID)
            check(!manager.fixtureHasPendingApply() && manager.lastSyncedVersion == 11
                && !remainsPending, "exact same-source retry completes both stores and original file")
        }
        for shape in ["empty-list", "empty-map", "both", "nonempty", "malformed"] {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.providerPlan = false; w.failIPTV = true
            w.settingsDomain["vortx.mediaServers.list"] = Data("retained local metadata".utf8)
            w.plaintext = try providerDocument(media: mediaBlob, iptv: iptvBlob)
            _ = await manager.syncDown(routineReceive: true)
            let calls = w.iptvApplies, commits = w.commits
            w.revision += 1; w.failIPTV = false
            var settings: [String: Any] = [:]
            if shape == "empty-list" || shape == "both" { settings["vortx.mediaServers.list"] = Data("[]".utf8) }
            if shape == "empty-map" || shape == "both" { settings["vortx.mediaServers.removed"] = [String: Double]() }
            if shape == "nonempty" { settings["vortx.mediaServers.removed"] = ["30000000-0000-0000-0000-000000000001": 2000.0] }
            if shape == "malformed" { settings["vortx.mediaServers.list"] = Data("{}".utf8) }
            w.plaintext = try providerDocument(iptv: iptvBlob, settings: settings)
            _ = await manager.syncDown(routineReceive: true)
            if shape == "nonempty" || shape == "malformed" {
                check(w.iptvApplies == calls && w.commits == commits && manager.fixtureHasPendingApply(),
                    "omitted sibling \(shape) metadata remains uncovered before effects")
            } else {
                check(w.iptvApplies == calls + 1 && w.mediaApplies == 1 && !manager.fixtureHasPendingApply()
                    && w.settingsDomain["vortx.mediaServers.list"] as? Data == Data("retained local metadata".utf8),
                    "omitted settled sibling \(shape) permits present failed sibling retry and preserves local baseline")
            }
        }
        // V4 original-read lifetime: temporary owner/key changes cannot be repaired by
        // reminting a generation after an awaited collaborator returns.
        for boundary in ["GET", "provider.journal", "native.commit", "provider.settlement", "typed.projection"] {
            for change in ["key", "account", "signed-in"] {
                let manager = try reset(), w = AdoptionWorld.current
                admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob, iptv: iptvBlob)
                if boundary == "typed.projection" { w.response = .ownerHistory }
                let original = try await retain()
                w.callback = { name in
                    guard name == boundary else { return }
                    if change == "key" { manager.dataKey = Data(repeating: 0x42, count: 32); manager.dataKey = AdoptionWorld.key }
                    if change == "account" { manager.account = .init(id: "other"); manager.account = .init(id: AdoptionWorld.account) }
                    if change == "signed-in" { manager.isSignedIn = false; manager.isSignedIn = true }
                }
                _ = await manager.syncDown(routineReceive: true)
                check(w.boundaryCounts[boundary] == 1, "V4 \(change) ABA reaches actual \(boundary) receive boundary")
                check(w.mediaApplies == 0 && w.iptvApplies == 0 && w.stamps == 0 && w.publications == 0,
                    "original source revoked across \(boundary) prevents both carriers and completion for \(change) ABA")
                check(try await pending(original.operationID), "\(boundary) \(change) ABA retains unresolved original intent")
                if boundary == "typed.projection" {
                    check(w.boundaryCounts["provider.journal"] == nil && w.commits == 0,
                        "typed projection cannot reacquire current authority after \(change) ABA")
                }
            }
        }
        for boundary in ["media.before", "media.after", "iptv.before"] {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.providerPlan = false
            w.plaintext = try providerDocument(media: mediaBlob, iptv: iptvBlob)
            let original = try await retain()
            w.callback = { name in
                guard name == boundary else { return }
                manager.dataKey = Data(repeating: 0x42, count: 32); manager.dataKey = AdoptionWorld.key
            }
            _ = await manager.syncDown(routineReceive: true)
            check(w.mediaApplies == (boundary == "media.before" ? 0 : 1) && w.iptvApplies == 0,
                "two-carrier source revocation at \(boundary) prevents later sibling effects")
            check(w.stamps == 0 && w.publications == 0 && manager.lastSyncedVersion == 24,
                "two-carrier revocation at \(boundary) cannot advance floor or full success")
            check(try await pending(original.operationID), "two-carrier \(boundary) retains original journal intent")
            check(manager.fixtureFailedProviderSource("vortx.mediaServers") == w.plaintext
                && manager.fixtureFailedProviderSource("vortx.iptv") == w.plaintext,
                "two-carrier \(boundary) retains both source reservations until a fresh owned receive")
        }
        for shape in ["lower", "same-contradiction", "newer", "exact-repeat"] {
            let manager = try reset(), w = AdoptionWorld.current
            CoreBridge.shared.hasNativeSession = false; w.providerPlan = false; w.nestedCheckpoint = true
            let exact = w.plaintext
            w.checkpointRevision = shape == "lower" ? 24 : (shape == "newer" ? 26 : 25)
            w.checkpointPlaintext = shape == "same-contradiction" ? exact + Data(" ".utf8) : exact
            _ = await manager.syncDown(routineReceive: true)
            check(w.checkpointGets == 1, "no-carrier \(shape) executes the nested GET")
            check(w.checkpointEffects == (shape == "exact-repeat" ? 1 : 0),
                "nested cloud source remains original even without a pending provider marker: \(shape)")
        }
        // The actual fallback GET+admission method is invoked inside the cold collaborator. Native
        // construction remains declared synthetic; source assertions pin the real caller and commit edges.
        for shape in ["lower", "same-contradiction", "newer", "exact-repeat"] {
            let manager = try reset(), w = AdoptionWorld.current
            manager.lastSyncedVersion = 9; w.revision = 11
            CoreBridge.shared.hasNativeSession = false; w.providerPlan = false; w.nestedCheckpoint = true
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob)
            let original = try await retain(), exact = w.plaintext
            w.checkpointRevision = shape == "lower" ? 10 : (shape == "newer" ? 12 : 11)
            w.checkpointPlaintext = shape == "same-contradiction" ? exact + Data(" ".utf8) : exact
            _ = await manager.syncDown(routineReceive: true)
            check(w.checkpointGets == 1, "cold \(shape) exercises actual second-GET admission helper")
            if shape == "exact-repeat" {
                check(w.checkpointEffects == 1 && w.commits == 1 && w.mediaApplies == 1
                    && !manager.fixtureHasPendingApply(), "fresh exact repeat stays admissible through original receive completion")
                check(!(try await pending(original.operationID)), "fresh observation UUID does not invalidate same-source file coverage")
            } else {
                check(w.checkpointEffects == 0 && w.commits == 0 && w.settingsEffects == 0
                    && w.mediaApplies == 0 && w.stamps == 0 && manager.lastSyncedVersion == 9,
                    "nested \(shape) response has zero cloud checkpoint host or provider effects")
                check(manager.fixtureHighestProviderSource() == exact && manager.fixtureHasPendingApply(),
                    "auxiliary \(shape) response cannot promote or retire original pending source")
            }
        }
        for typed in [false, true] {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob); w.failMedia = true
            _ = await manager.syncDown(routineReceive: true)
            let exact = w.plaintext
            w.checkpointTyped = typed; w.checkpointRevision = w.revision - 1; w.checkpointPlaintext = exact
            check(!(await manager.fixtureCloudCheckpointRead()) && w.checkpointEffects == 0,
                "direct \(typed ? "typed" : "generic") cloud checkpoint cannot bypass pending high water")
            w.checkpointRevision = w.revision; w.checkpointPlaintext = exact + Data(" ".utf8)
            check(!(await manager.fixtureCloudCheckpointRead()) && w.checkpointEffects == 0,
                "direct \(typed ? "typed" : "generic") equal-revision contradiction has no effects")
            w.checkpointPlaintext = exact
            check(await manager.fixtureCloudCheckpointRead(), "direct exact source remains admissible for \(typed ? "typed" : "generic") checkpoint")
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob); w.failMedia = true
            _ = await manager.syncDown(routineReceive: true)
            let first = try manager.fixtureCaptureCloudAuthority(plaintext: w.plaintext, revision: w.revision)
            check((try? first()) != nil, "actual cloud epoch authority admits its original pending source")
            check(manager.fixtureCloudParentIsRetained(plaintext: w.plaintext, revision: w.revision),
                "cloud authority composition preserves an existing native source refusal")
            // A fresh exact GET does not advance the provider-source epoch.
            _ = await manager.syncDown(routineReceive: true)
            check((try? first()) != nil, "same original bytes and revision preserve pending source authority")
            w.revision += 1; w.plaintext.append(Data(" ".utf8))
            _ = await manager.syncDown(routineReceive: true)
            check((try? first()) == nil, "higher normal receive revokes older queued cloud authority")
            let newer = try manager.fixtureCaptureCloudAuthority(plaintext: w.plaintext, revision: w.revision)
            w.failMedia = false; _ = await manager.syncDown(routineReceive: true)
            check((try? newer()) == nil, "successful full-tail retirement revokes its delayed cloud conversion authority")
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob); w.failMedia = true
            _ = await manager.syncDown(routineReceive: true)
            let original = try manager.fixtureCaptureCloudAuthority(plaintext: w.plaintext, revision: w.revision)
            let capture = CredentialScopeRegistry.shared.capture(), unrelatedPendingIsRetained = manager.fixtureUnrelatedPendingSnapshot()
            check(manager.fixtureHasReceivedPending(for: capture) && unrelatedPendingIsRetained(),
                "key retirement starts with received source and independent credential work pending")
            manager.dataKey = Data(repeating: 0x42, count: 32)
            check((try? original()) == nil, "key mutation immediately revokes queued cloud authority before any pending query")
            check(!manager.fixtureHasReceivedPending(for: capture) && manager.fixtureHighestProviderSource() == nil
                && manager.fixtureFailedProviderSource("vortx.mediaServers") == nil,
                "owned key retirement clears only its pending source")
            check(manager.fixtureHasPendingApply() && unrelatedPendingIsRetained(),
                "key retirement retains exact independent credential pending markers")
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            CoreBridge.shared.hasNativeSession = false; w.providerPlan = false
            w.nestedCheckpoint = true; w.localCheckpointAvailable = true
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob)
            w.checkpointRevision = 1; w.checkpointPlaintext = Data("unusable remote".utf8)
            _ = await manager.syncDown(routineReceive: true)
            check(w.localReopens == 1 && w.checkpointGets == 0 && w.commits == 1 && w.mediaApplies == 1,
                "local-only reopen stays usable and outer original receive owns later cloud adoption")
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob); w.failMedia = true
            _ = await manager.syncDown(routineReceive: true)
            w.paused = "checkpoint.before_commit"
            let checkpoint = Task { await manager.fixtureCloudCheckpointRead() }
            await w.wait("checkpoint.before_commit")
            w.revision += 1; w.plaintext.append(Data(" ".utf8))
            _ = await manager.syncDown(routineReceive: true)
            w.release()
            check(!(await checkpoint.value) && w.checkpointEffects == 0,
                "queued auxiliary checkpoint source is revoked by higher full receive before its commit")
        }
        for boundary in ["media.after", "publication"] {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob)
            let original = try await retain()
            w.callback = { name in
                guard name == boundary else { return }
                manager.dataKey = Data(repeating: 0x42, count: 32)
                manager.dataKey = AdoptionWorld.key
            }
            _ = await manager.syncDown(routineReceive: true)
            check(try await pending(original.operationID), "key change and restoration at \(boundary) cannot mint original completion")
            check(manager.fixtureHasPendingApply(), "key ABA at \(boundary) retains recovery for a fresh receive")
        }
        // A newer row alone does not preserve an independent removal record. Both current exports
        // retain their explicit removed map, so this conservative collision remains pending.
        for media in [true, false] {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures()
            let key = media ? "vortx.mediaServers.removed" : "vortx.iptv.removed"
            let id = media ? "30000000-0000-0000-0000-000000000001" : "synthetic"
            w.plaintext = try providerDocument(media: media ? mediaBlob : nil, iptv: media ? nil : iptvBlob,
                settings: [key: [id: 500.0]])
            _ = await manager.syncDown(routineReceive: true)
            check(manager.fixtureHasPendingApply() && w.commits == 0 && w.mediaApplies == 0 && w.iptvApplies == 0,
                "newer \(media ? "media" : "IPTV") row cannot discard uncovered independent removal history")
        }

        // F3: actual SettingsBackup decoding + exclusion arguments preserve the cold store baseline.
        // The companion actual-store fixture below proves checked deletion/CAS, not this synthetic store seam.
        for media in [true, false] {
            let manager = try reset(), w = AdoptionWorld.current
            CoreBridge.shared.hasNativeSession = false; w.providerPlan = false
            let listKey = media ? "vortx.mediaServers.list" : "vortx.iptv.playlists"
            let removedKey = media ? "vortx.mediaServers.removed" : "vortx.iptv.removed"
            let localRows = Data("local planning rows with old and unrelated entries".utf8)
            w.settingsDomain = [listKey: localRows, removedKey: ["prior": 1000.0]]
            let id = media ? "30000000-0000-0000-0000-000000000001" : "synthetic"
            let blob = String(decoding: try JSONSerialization.data(withJSONObject: ["v": 1,
                media ? "servers" : "playlists": [], "removed": [id: 2000]]), as: UTF8.self)
            w.allowedProviderSources.insert(Data(blob.utf8))
            w.plaintext = try providerDocument(media: media ? blob : nil, iptv: media ? nil : blob,
                settings: [listKey: Data("[]".utf8), removedKey: [String: Double](), "fixture.global": "remote"])
            let original = try await retain()
            w.callback = { name in
                if name == (media ? "media.before" : "iptv.before") {
                    check(w.settingsDomain[listKey] as? Data == localRows
                        && (w.settingsDomain[removedKey] as? [String: Double])?["prior"] == 1000,
                        "checked provider sees original local planning rows and removals after cold restore")
                }
            }
            _ = await manager.syncDown(routineReceive: true)
            check(w.lastSettingsExclusions.contains(listKey) && w.lastSettingsExclusions.contains(removedKey)
                && !manager.appliedSettingsBaseline.contains(listKey)
                && w.settingsDomain["fixture.global"] as? String == "remote" && w.settingsReloads == 1,
                "cold baseline protects checked provider keys while retaining ordinary globals and reload")
            check(!(try await pending(original.operationID)), "empty legacy list plus checked pure tombstone can complete")
        }
        for media in [true, false] {
            for relationship in ["equal", "newer", "tombstone"] {
                let manager = try reset(), w = AdoptionWorld.current
                CoreBridge.shared.hasNativeSession = false; w.providerPlan = false
                let listKey = media ? "vortx.mediaServers.list" : "vortx.iptv.playlists"
                let id = media ? "30000000-0000-0000-0000-000000000001" : "synthetic"
                var row: [String: Any] = ["id": id, "name": "Exact", "kind": media ? "jellyfin" : "m3u",
                    media ? "addedAt" : "createdAt": Date(timeIntervalSince1970: relationship == "newer" ? 0.5 : 1).timeIntervalSinceReferenceDate]
                if media { row["urls"] = ["https://synthetic.invalid"]; row["userId"] = ""; row["needsReauth"] = true }
                else { row["transportUrl"] = "https://synthetic.invalid/list" }
                let blob: String
                if relationship == "tombstone" {
                    blob = String(decoding: try JSONSerialization.data(withJSONObject: ["v": 1,
                        media ? "servers" : "playlists": [], "removed": [id: 2000]]), as: UTF8.self)
                } else { blob = media ? mediaBlob : iptvBlob }
                w.allowedProviderSources.insert(Data(blob.utf8))
                w.plaintext = try providerDocument(media: media ? blob : nil, iptv: media ? nil : blob,
                    settings: [listKey: try JSONSerialization.data(withJSONObject: [row])])
                let original = try await retain()
                _ = await manager.syncDown(routineReceive: true)
                check(!(try await pending(original.operationID)),
                    "\(media ? "media" : "IPTV") exact settings coverage permits \(relationship) carrier completion")
            }
        }
        for media in [true, false] {
            for divergence in ["extra-row", "extra-removal"] {
                let manager = try reset(), w = AdoptionWorld.current
                CoreBridge.shared.hasNativeSession = false; w.providerPlan = false
                admitProviderFixtures()
                let listKey = media ? "vortx.mediaServers.list" : "vortx.iptv.playlists"
                let removedKey = media ? "vortx.mediaServers.removed" : "vortx.iptv.removed"
                let id = media ? "40000000-0000-0000-0000-000000000001" : "settings-only"
                var settings: [String: Any]
                if divergence == "extra-row" {
                    settings = [listKey: try JSONSerialization.data(withJSONObject: [["id": id,
                        media ? "addedAt" : "createdAt": Date(timeIntervalSince1970: 1).timeIntervalSinceReferenceDate]])]
                } else { settings = [removedKey: [id: 2000.0]] }
                settings["fixture.global"] = "must-not-apply"
                w.plaintext = try providerDocument(media: media ? mediaBlob : nil, iptv: media ? nil : iptvBlob, settings: settings)
                let original = try await retain(), exact = w.plaintext
                _ = await manager.syncDown(routineReceive: true)
                check(w.commits == 0 && w.settingsEffects == 0 && w.mediaApplies == 0 && w.iptvApplies == 0
                    && manager.fixtureHighestProviderSource() == exact && manager.fixtureHasPendingApply(),
                    "divergent \(media ? "media" : "IPTV") \(divergence) refuses before effects and retains source")
                check(try await pending(original.operationID), "divergent settings cannot receive file completion")
            }
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            CoreBridge.shared.hasNativeSession = false; w.providerPlan = false
            let key = "vortx.mediaServers.list", rows = Data("[]".utf8)
            w.plaintext = try providerDocument(settings: [key: rows, "vortx.mediaServers.removed": [String: Double](), "fixture.global": "compatible"])
            _ = await manager.syncDown(routineReceive: true)
            check(w.settingsDomain[key] as? Data == rows && !w.lastSettingsExclusions.contains(key)
                && w.settingsDomain["fixture.global"] as? String == "compatible"
                && w.mediaApplies == 0 && w.iptvApplies == 0 && !manager.fixtureHasPendingApply(),
                "ordinary settings-only receive retains existing baseline and global behavior")
        }

        for shape in ["media", "iptv", "both", "cold"] {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures()
            w.plaintext = try providerDocument(media: shape == "iptv" ? nil : mediaBlob,
                iptv: shape == "media" ? nil : iptvBlob)
            w.mirrorProviderOverride = "synthetic poisoned mirrored value"
            if shape == "cold" { CoreBridge.shared.hasNativeSession = false }
            let original = try await retain(), source = w.plaintext
            let result = await manager.finishAccountBackupFileRestore(original.operationID)
            guard case .localAdoptionRecorded(let id, let revision) = result,
                  id == original.operationID, revision == original.revision else { preconditionFailure("checked original provider receive was not completed") }
            check(w.mediaSources == (shape == "iptv" ? [] : [Data(mediaBlob.utf8)])
                && w.iptvSources == (shape == "media" ? [] : [Data(iptvBlob.utf8)]),
                "\(shape) uses exact original carrier strings despite metadata object and poisoned mirror")
            check(w.mediaApplies == (shape == "iptv" ? 0 : 1) && w.iptvApplies == (shape == "media" ? 0 : 1),
                "\(shape) invokes each checked store exactly once with no queued or duplicate Void apply")
            check(Set(w.mediaOperations + w.iptvOperations).count == 1 && w.gets == 1,
                "\(shape) binds both actual store receipts to one original receive UUID and GET")
            check(!manager.fixtureHasPendingApply() && w.stamps == 1 && w.publications == 1
                && manager.lastSyncedVersion == original.revision && w.plaintext == source,
                "\(shape) settles before ordinary bookkeeping without changing source")
        }
        for refusal in ["media", "iptv", "source", "operation"] {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob, iptv: iptvBlob)
            let original = try await retain()
            w.failMedia = refusal == "media"; w.failIPTV = refusal == "iptv"
            w.wrongProviderReceipt = refusal == "source"; w.wrongProviderOperation = refusal == "operation"
            _ = await manager.syncDown(routineReceive: true)
            check(try await pending(original.operationID), "\(refusal) refuses file completion without actual matching provider evidence")
            check(manager.fixtureHasPendingApply() && w.stamps == 0 && w.publications == 0
                && manager.lastSyncedVersion == original.baseRevision && !manager.fixtureHasCachedReceipt(),
                "\(refusal) keeps actual push/ack admission closed without advancing floor or receive cache")
            w.failMedia = false; w.failIPTV = false; w.wrongProviderReceipt = false; w.wrongProviderOperation = false
            let result = await manager.finishAccountBackupFileRestore(original.operationID)
            guard case .localAdoptionRecorded = result else { preconditionFailure("same original GET did not retry settlement") }
            check(!manager.fixtureHasPendingApply() && w.gets == 2, "\(refusal) retries the original operation through GET and real receipt readback")
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob); w.failMedia = true
            let original = try await retain(), first = w.plaintext
            _ = await manager.syncDown(routineReceive: true)
            check(manager.fixtureFailedProviderSource("vortx.mediaServers") == first, "pending marker retains original failed HTTP source")
            w.revision -= 1
            let attempted = w.mediaApplies
            _ = await manager.syncDown(routineReceive: true)
            check(w.mediaApplies == attempted && manager.fixtureFailedProviderSource("vortx.mediaServers") == first,
                "lower revision cannot apply over or replace a pending original provider source")
            w.revision = original.revision + 1; w.plaintext.append(Data(" ".utf8)); let newer = w.plaintext
            _ = await manager.syncDown(routineReceive: true)
            check(manager.fixtureFailedProviderSource("vortx.mediaServers") == first
                && manager.fixtureFailedProviderSource("vortx.mediaServers", latest: true) == newer,
                "newer failed provider retains both first and latest exact source")
            w.revision += 1; w.plaintext = try providerDocument()
            _ = await manager.syncDown(routineReceive: true)
            check(manager.fixtureHasPendingApply() && w.stamps == 0
                && manager.fixtureFailedProviderSource("vortx.mediaServers", latest: true) == newer,
                "later omission cannot erase failed provider data or open push acknowledgment")
            w.revision = original.revision + 1; w.plaintext = newer; w.failMedia = false
            let before = w.mediaApplies
            _ = await manager.syncDown(routineReceive: true)
            check(manager.fixtureHasPendingApply() && w.mediaApplies == before && w.stamps == 0,
                "omitted newer response retains whole-response high water against an older present carrier")
            w.revision = original.revision + 3
            _ = await manager.syncDown(routineReceive: true)
            check(!manager.fixtureHasPendingApply() && w.stamps == 1, "newer present carrier clears pending only after matching settlement")
            check(try await pending(original.operationID), "newer source settlement does not falsely retire a different original file")
        }
        for boundary in ["media.before", "media.after", "iptv.after"] {
            for change in ["account", "key", "epoch", "profile", "target", "cancel"] {
                let manager = try reset(), w = AdoptionWorld.current, box = AdoptionReceiveTaskBox()
                admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob, iptv: iptvBlob)
                let original = try await retain()
                w.callback = { name in
                    guard name == boundary else { return }
                    switch change {
                    case "account": manager.account = .init(id: UUID().uuidString.lowercased())
                    case "key": manager.dataKey = Data(repeating: 0x42, count: 32)
                    case "epoch": CredentialScopeRegistry.shared.establish(.account(UUID(uuidString: AdoptionWorld.account)!))
                    case "profile": ProfileStore.shared.activeID = UUID()
                    case "target": CoreBridge.shared.accountGeneration = UUID()
                    default: box.task?.cancel()
                    }
                }
                box.task = Task { await manager.syncDown(routineReceive: true) }; _ = await box.task?.value
                check(try await pending(original.operationID), "\(change) at \(boundary) cannot certify a full receive")
                check(w.stamps == 0 && w.publications == 0, "\(change) at \(boundary) cannot reach normal success bookkeeping")
            }
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob); w.failMedia = true
            _ = await manager.syncDown(routineReceive: true)
            let calls = w.mediaApplies, retired = CredentialScopeRegistry.shared.capture()
            CredentialScopeRegistry.shared.establish(.account(UUID(uuidString: AdoptionWorld.account)!))
            check(!manager.fixtureHasPendingApply() && manager.fixtureFailedProviderSource("vortx.mediaServers") == nil
                && w.mediaApplies == calls, "retired epoch clears only its process marker with no provider IO")
            _ = await manager.syncDown(routineReceive: true)
            check(manager.fixtureHasPendingApply() && !manager.fixtureHasReceivedPending(for: retired)
                && manager.fixtureHasPendingApply(), "stale marker query cannot erase a current successor pending source")
        }
        do {
            let manager = try reset(), w = AdoptionWorld.current
            admitProviderFixtures(); w.plaintext = try providerDocument(media: mediaBlob, iptv: iptvBlob)
            let original = try await retain(), hold = await holdJournal()
            let task = Task { await manager.syncDown(routineReceive: true) }
            await settle { w.publications == 1 }
            task.cancel(); hold.released.signal(); await hold.task?.value; _ = await task.value
            check(!(try await pending(original.operationID)) && w.mediaApplies == 1 && w.iptvApplies == 1,
                "post-mint cancellation may seal genuine provider-complete original historical adoption")
        }
        for key in ["vortx.mediaServers", "vortx.iptv"] {
            for value in ["\"\"", "\"malformed blob\"", "null", "{}"] {
                let manager = try reset()
                AdoptionWorld.current.plaintext = Data("{\"nativeSync\":{\"schemaVersion\":5},\"apiKeys\":{\"\(key)\":\(value)}}".utf8)
                let original = try await retain(), exact = AdoptionWorld.current.plaintext
                _ = await manager.syncDown(routineReceive: true)
                check(try await pending(original.operationID), "unsettled \(key) \(value) keeps full-tail completion pending")
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
        for (value, label) in try await ProviderCloudInstallationFixture.cases(makeManager: { try reset() }) {
            check(value, label)
        }
        for (value, label) in try await ProviderOAuthCloudClearFixture.cases(makeManager: { try reset() }) {
            check(value, label)
        }
        print("local-adoption synthetic orchestration and real journal checks: \(checks)")
    }
}
