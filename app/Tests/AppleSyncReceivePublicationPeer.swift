import Foundation
import CryptoKit
import CoreFoundation
import os

// External environment only. The extractor appends the production receive, merge,
// projection and main-queue publication functions without replacing their bodies.
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
}
final class CredentialScopeRegistry: @unchecked Sendable {
    enum Scope: Hashable, Sendable { case account, signedOutDevice }
    struct Capture: Hashable, Sendable {
        let generation: UInt64
        var namespace: String { "synthetic.receive-publication" }
        var scope: Scope { .account }
    }
    static let shared = CredentialScopeRegistry()
    private let lock = NSLock()
    private var generation: UInt64 = 1
    func capture() -> Capture { lock.withLock { .init(generation: generation) } }
    func isCurrent(_ capture: Capture) -> Bool { self.capture() == capture }
    func retire() { lock.withLock { generation &+= 1 } }
}
typealias PlaybackMutationTarget = PlaybackMutationOwnershipPolicy.Target

// ProfileStore is the presentation sink; actual CoreBridge.refreshNativeProfiles
// performs production native/host decoding and chooses the acknowledged active UUID.
@MainActor
final class ProfileStore {
    static let shared = ProfileStore()
    var profiles: [UserProfile] = [] {
        willSet { ProfileSelectionRead.beginMutation() }
        didSet { ProfileSelectionRead.endMutation(selectionReadSnapshot()) }
    }
    var activeID: UUID? = UUID(uuidString: AppleSyncReceivePublicationPeer.owner) {
        willSet { ProfileSelectionRead.beginMutation() }
        didSet { ProfileSelectionRead.endMutation(selectionReadSnapshot()) }
    }
    // One singleton per peer process, first accessed by @MainActor receive setup. The real
    // namespace/projector and these fileprivate writer callsites share Combined.swift.
    private init() { ProfileSelectionRead.publishInitial(selectionReadSnapshot()) }
    var active: UserProfile? { profiles.first { $0.id == activeID } }
    var activeUsesEngineHistory: Bool { active?.usesEngineHistory ?? true }
    var activeKeychainAccount: String { "synthetic.account" }
    var cwItems: [CoreCWItem] = []
    func applyNativeProfiles(_ incoming: [UserProfile], activeID: UUID, projectionTarget: PlaybackMutationTarget?) {
        profiles = incoming; self.activeID = activeID
        // The production discovery persistence bridge runs, but full ProfileStore
        // dirty/quarantine admission and view reloads are not supplied by this sink.
        ProfileDiscoveryPreferencesStore.apply(active?.discovery, resetUnset: true)
    }
    func mergeInRoster(_ incoming: [UserProfile], incomingModified: Date?) { fatalError("legacy roster was entered") }
    func applyLocalTombstones() { fatalError("legacy roster was entered") }
    func reloadFromDefaults() { fatalError("legacy defaults were entered") }
    func captureDiscovery() { fatalError("remote reload must not recapture discovery as a local edit") }
}
@MainActor final class CollectionsHubModel {
    static let shared = CollectionsHubModel()
    func load() {}
}
enum LibraryAutoAdd { static let watchlistChangedNote = Notification.Name("synthetic.watchlistChanged") }
enum Keychain {
    enum Confirmed { case missing, value(String), unavailable }
    static func confirmedString(_ key: String) -> Confirmed { .missing }
}
struct VortxNativeCredentialSelectionRelay {
    static let shared = Self()
    func publish(_ permitted: () -> Bool) { _ = permitted() }
}
enum EpisodePlaybackIdentity { static func usesSeriesLifecycle(type: String) -> Bool { type == "series" } }

final class CoreBridge: @unchecked Sendable {
    static let shared = CoreBridge()
    let nativeFacadeLock = NSLock()
    var nativeFacadeStorage: VortxNativeCoreFacade?
    var nativeCredentialCapture: CredentialScopeRegistry.Capture?
    var nativeInstallGeneration = UUID()
    var nativePublishedAccountGeneration: UUID?
    var nativePublishedCredentialSlot: String?
    var nativeProfileBaseline: [UserProfile] = []
    var nativeFacade: VortxNativeCoreFacade? { nativeFacadeLock.withLock { nativeFacadeStorage } }
    var hasNativeSession: Bool { nativeFacade?.isAvailable == true }
    var usesNativeProfileState = true
    var continueWatching: [CoreCWItem] = []
    var library: CoreLibrary?
    let continueWatchingRebuildLock = NSLock()
    var continueWatchingRebuildGeneration: Int = 0
    struct PublicationToken: Equatable, Sendable { let epoch: UInt64 }
    let publicationEpochState = OSAllocatedUnfairLock(initialState: UInt64(1))
    let nativeCallbackLifetime = NativeCallbackLifetime()
    var nativeCallbackGeneration = UUID()
    let nativePlaybackReadLifetime = NativePlaybackReadLifetime()
    let nativeMetadataAdmissionFence = VortxNativeMetadataAdmissionFence()
    @MainActor
    var acceptedHistoryReceiptRevision = 0
    @MainActor
    var lastAcceptedHistoryReceipt: BecauseYouWatchedHistoryPolicy.Snapshot?
    var localHistoryDeviceReceiptPending = true
    struct LocalRecommendationHistory { let library: [CoreCWItem]; let continueWatching: [CoreCWItem]; let receipt: BecauseYouWatchedHistoryPolicy.Snapshot }
    struct LocalRecommendationHistoryState {
        let snapshot: LocalRecommendationHistory; let context: Int?
        let credentialCapture: CredentialScopeRegistry.Capture; let publicationToken: PublicationToken
    }
    @MainActor
    var localRecommendationHistoryState: LocalRecommendationHistoryState?
    var changedFields: Set<String> = []
    var revision = 0
    var addons: [CoreDescriptor] = []
    var rawAddonsByUrl: [String: [String: Any]] = [:]
    var addonNamesCache: [String: String]?
    @MainActor
    var logoutAccountMutationPending = false
    var boardRowsLoaded = 30
    var boardCatalogTotal = 0
    var boardPageInFlight = false
    var boardRowPageInFlight: [Int: Int] = [:]
    var deferredBoardRangeDepth: Int?
    let playerActiveSnapshotState = OSAllocatedUnfairLock(initialState: false)
    @MainActor
    func settledActiveAccountBinding() -> PlaybackMutationOwnershipPolicy.SettledAccountBinding? { nil }
    @MainActor
    func settledLocalHistoryOwner(credentialCapture: CredentialScopeRegistry.Capture) -> BecauseYouWatchedHistoryPolicy.Owner? {
        guard CredentialScopeRegistry.shared.isCurrent(credentialCapture), let id = ProfileStore.shared.activeID else { return nil }
        return .init(profileID: id, keychainAccount: ProfileStore.shared.activeKeychainAccount, uid: nil, generation: credentialCapture.generation)
    }
    func nativeAccountMode(profileID: UUID) -> String? { "shared" }
    func nativeCredentialSlot(profileID: UUID) -> String? { nil }
    func dispatchCtx(_ value: [String: Any]) -> Bool { fatalError("legacy add-on hydration was entered") }
    func dispatch(action: [String: Any], field: String) { fatalError("board resources were entered") }
    func catalogOrderDidChange() {}
    func rebuildBoardRows() {}
}

// Unrelated provider/legacy collaborators are inert and reject any unexpected use.
enum DebridService: String, CaseIterable { case realDebrid, allDebrid, premiumize, torBox }
struct DebridKeys {
    struct Result { let succeeded: Bool; let failedServices: Set<DebridService> }
    static let shared = Self()
    func applyRemoteKeys(_ values: [String: String], capture: CredentialScopeRegistry.Capture) -> Result { fatalError("provider key apply was entered") }
}
final class ApiKeys: @unchecked Sendable { static let shared = ApiKeys(); var tmdb = ""; var mdblist = ""; var fanart = "" }
enum ApiKeySlots {
    static func tmdb(_ scope: CredentialScopeRegistry.Scope) -> String { "inert.tmdb" }
    static func mdblist(_ scope: CredentialScopeRegistry.Scope) -> String { "inert.mdblist" }
    static func fanart(_ scope: CredentialScopeRegistry.Scope) -> String { "inert.fanart" }
}
enum SettingsBackup {
    static func restore(from: Data, skipping: Set<String>, excluding: Set<String>) throws -> Int { fatalError("legacy settings were entered") }
    static func appliedKeys(from: Data, excluding: Set<String>) -> Set<String> { [] }
    static func reloadLiveStores() { fatalError("legacy stores were entered") }
}
enum AddonTombstones {
    static func preservingLocalSyncStamps<T>(_ body: () throws -> T) rethrows -> T { try body() }
    static func all() -> Set<String> { [] } // Legacy carrier is absent; native removal clocks are tested.
    static func normalize(_ value: String) -> String { value }
}
enum LastStreamStore { static func invalidateCache() {} }
enum SearchHistoryStore { static func merge(_ terms: [String], for profileID: UUID?) { fatalError("search history was entered") } }
struct MediaServerStore { static let shared = Self(); func applySyncBlob(_ blob: String) { fatalError("media server apply was entered") } }
struct IPTVPlaylistStore { static let shared = Self(); func applySyncBlob(_ blob: String) { fatalError("IPTV apply was entered") } }
enum CredentialMutationResult { case success, rejected }
struct TraktSessionID: Hashable, Sendable { let rawValue: String }
struct SIMKLSessionID: Hashable, Sendable { let rawValue: String }
struct TraktAuth {
    static let shared = Self(); static let storedSessionID: TraktSessionID? = nil; static let isConfigured = false
    func applyNativeCredentialClear(capture: CredentialScopeRegistry.Capture, events: [String: VortxNativeProviderCredentials.Register]) async -> Bool { fatalError("Trakt clear was entered") }
    @MainActor func adoptTokens(access: String, refresh: String, expiryUnix: Int, ownerCapture: CredentialScopeRegistry.Capture, mutationGuard: (@MainActor () -> Void) -> Bool) async -> CredentialMutationResult { fatalError("Trakt adoption was entered") }
}
struct SIMKLAuth {
    static let shared = Self(); static let storedSessionID: SIMKLSessionID? = nil; static let isConfigured = false
    func applyNativeCredentialClear(capture: CredentialScopeRegistry.Capture, events: [String: VortxNativeProviderCredentials.Register]) async -> Bool { fatalError("SIMKL clear was entered") }
    @MainActor func adoptTokens(access: String, expiryUnix: Int, ownerCapture: CredentialScopeRegistry.Capture, mutationGuard: (@MainActor () -> Void) -> Bool) async -> CredentialMutationResult { fatalError("SIMKL adoption was entered") }
}
struct TraktArtworkPolicy {
    struct Candidate { let id: String; let type: String; let poster: String? }
    static func matchedCandidate(seedID: String, seedAliases: [String], seedType: String, candidates: [Candidate]) -> Candidate? { fatalError("provider artwork was entered") }
}
struct SIMKLContinueWatchingFold { static func unavailableReason(id: String, type: String, videoID: String?) -> String? { nil } }
final class TraktPlaybackShadow: @unchecked Sendable {
    static let shared = TraktPlaybackShadow()
    struct ContinueWatchingSelection {
        var items: [CoreCWItem]; let source: ContinueWatchingService; let sessionID: TraktSessionID?
        var simklSessionID: SIMKLSessionID? = nil; var status: String? = nil
        var displayProgress: [String: Double] = [:]; var captions: [String: String] = [:]
    }
    func continueWatchingSelection(fallback: [CoreCWItem], libraryItems: [CoreCWItem]) -> ContinueWatchingSelection { fatalError("provider selection was entered") }
    func refreshIfStale() { fatalError("provider refresh was entered") }
}
struct SIMKLContinueWatchingShadow {
    static let shared = Self()
    struct Seed { let id: String; let type: String; let name: String; let aliases: [String]; let videoID: String?; let activity: String?; let progress: Double?; let caption: String? }
    struct Snapshot { let items: [Seed]; let failed: Bool; let hasSnapshot: Bool }
    func snapshot(context: HomeContinueWatchingSelection.Context, session: SIMKLSessionID) -> Snapshot { fatalError("provider snapshot was entered") }
    func refresh(context: HomeContinueWatchingSelection.Context) { fatalError("provider refresh was entered") }
}

@MainActor final class VortXSyncManager {
    static var shared: VortXSyncManager!
    struct Account { let id: String }
    let directory: URL; let baseURL: URL
    let credentialAuthority = CredentialScopeRegistry.shared
    var account: Account? = .init(id: AppleSyncReceivePublicationPeer.account)
    var dataKey: Data? = AppleSyncReceivePublicationPeer.key
    var isSignedIn = true; var hasAppliedAccountDoc = false; var hasPendingPush = false
    var activeSyncDown: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    var activeSyncUp: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    private var nativeReceiveReceipt: NativeReceiveReceipt?
    var lastSyncedVersion = 0; var stamped = 0
    var pollTask: Task<Void, Never>?
    let pollIntervalNanos: UInt64 = 20_000_000
    var backupUploadFailure: SyncBackupUploadFailure?
    var failPreparation = false
    var pendingApplyFixture = false
    var afterResponse: (() throws -> Void)?
    var replaceMountBeforeAcknowledgement = false
    var providerSnapshotReads = 0
    var dirtySettings: [String: Double] = [:]; var appliedSettingsBaseline: Set<String> = []
    private var pendingDebridApply: PendingDebridApply?
    private var pendingProviderApply: PendingProviderApply?
    enum ConflictResolutionOutcome: String { case completed, pending, failed }
    init(directory: URL, baseURL: URL) { self.directory = directory; self.baseURL = baseURL; Self.shared = self }
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { credentialAuthority.isCurrent(capture) }
    func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool { pendingApplyFixture }
    func withRemoteApplySuppressed(_ body: () -> Void) { body() }
    func settleNativeProviderJournal(capture: CredentialScopeRegistry.Capture) async -> Bool { isCurrent(capture) }
    func nativeProviderState(capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials {
        providerSnapshotReads += 1
        if replaceMountBeforeAcknowledgement && providerSnapshotReads == 2 {
            CoreBridge.shared.nativeInstallGeneration = UUID()
            try CoreBridge.shared.refreshProfilesForFixture()
        }
        return try VortxNativeProviderCredentials(scope: capture.namespace, actor: AppleSyncReceivePublicationPeer.actor)
    }
    func mergedNativeProviderState(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { try nativeProviderState(capture: capture) }
    func persistMergedNativeProviders(_ providers: VortxNativeProviderCredentials, capture: CredentialScopeRegistry.Capture) throws -> VortxNativeProviderCredentials { providers }
    func mirrorNativeProviderKeys(_ providers: VortxNativeProviderCredentials, original: Any?) throws -> [String: Any] { [:] }
    private func prepareNativeLegacyMaterial(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) async throws -> NativeLegacyPreparation {
        if failPreparation { throw VortxNativeError.invalidSnapshot }
        guard isCurrent(capture),
              Set(doc.keys).isSubset(of: ["nativeSync", "nativeHostPreferences", "nativeProviderCredentials",
                  "profileEditResults", "apiKeys", "causalFixtureSibling"]) else { throw VortxNativeError.invalidSnapshot }
        // Genuine converter and receipt replay, limited to the empty synthetic legacy
        // input imported at first creation. Never manufacture or reset an existing baseline.
        let material = try AppleSyncReceivePublicationPeer.legacyMaterial(document: doc)
        guard material == (try AppleSyncReceivePublicationPeer.legacyMaterial()) else { throw VortxNativeError.invalidSnapshot }
        return NativeLegacyPreparation(material: material, authority: nil, sourceArchive: nil)
    }
    static func nativeWebsiteEvents(_ doc: [String: Any]) throws -> [VortxJSON] { [] }
    static func nativeWebsiteAddonEvents(_ doc: [String: Any]) throws -> [VortxJSON] { [] }
    func nativeLegacyWatchlists(_ doc: [String: Any]) throws -> [UUID: [VortxNativeWatchlist.Entry]] { [:] }
    func publishNativeWebsiteOutcome(_ value: VortxJSON, capture: CredentialScopeRegistry.Capture) throws {}
    func nativeMutationDidCommit(credentialCapture: CredentialScopeRegistry.Capture) { hasPendingPush = true }
    func rememberNativeBackup(capture: CredentialScopeRegistry.Capture) -> Bool { isCurrent(capture) }
    func acknowledgeNativeProviders(_ doc: [String: Any], capture: CredentialScopeRegistry.Capture) throws {}
    func persistLastSyncedVersion() {}
    static let writeSyncDocV2 = true
    func stampSyncSuccess() { stamped += 1 }
    func ensureNativeCheckpoint(credentialCapture: CredentialScopeRegistry.Capture) async -> Bool { CoreBridge.shared.hasCertifiedNativeSession(capture: credentialCapture, profileID: ProfileStore.shared.activeID) }
    struct Roster { let profiles: [UserProfile]; let modified: Double? }
    static func resolveRoster(from doc: [String: Any], fullOnly: Bool = false) -> Roster? { nil }
    static let appliedAddonOrder: [String] = [] // No legacy add-on carrier in this test.
    private func retireNativeProviderApply(_ service: ProviderApplyService, capture: CredentialScopeRegistry.Capture) {}
    private func providerApplyIntent(keys: [String: String]?, capture: CredentialScopeRegistry.Capture, version: Int) -> PendingProviderApply? { nil }
    static func withNativeProviderSnapshot(_ snapshot: VortxNativeProviderCredentials.Document, capture: CredentialScopeRegistry.Capture, mutation: @MainActor () -> Void) -> Bool { fatalError("provider snapshot was entered") }
    let providerRemoteApplyMaximumAttempts = 1
    func waitForProviderRemoteApplyRetry(capture: CredentialScopeRegistry.Capture) async -> Bool { false }
    func publishNativeWatchedPending(_ archive: Data?, scope: VortxAccountScope,
        capture: CredentialScopeRegistry.Capture, isCurrentSource: @escaping @Sendable () -> Bool) throws {}
    func publishNativeOwnOverlayPending(_ pending: VortxJSON, capture: CredentialScopeRegistry.Capture) throws {}
    func updateNativeOwnAccountAvailability(missing: [UUID], profiles: [UserProfile], capture: CredentialScopeRegistry.Capture) {}
    func request(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool, credentialCapture: CredentialScopeRegistry.Capture,
                 ifNoneMatch: Int? = nil, receiveETag: ((String?) -> Void)? = nil) async -> (Int, [String: Any]?) {
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent(path)); request.httpMethod = method
            if let ifNoneMatch { request.setValue("\"\(ifNoneMatch)\"", forHTTPHeaderField: "If-None-Match") }
            request.setValue("Bearer synthetic-fixture-only", forHTTPHeaderField: "Authorization")
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            let callback = afterResponse; afterResponse = nil; try callback?()
            receiveETag?((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
            if (response as? HTTPURLResponse)?.statusCode == 304 { return (304, nil) }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                    data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data) as? [String: Any])
        } catch { return (0, nil) }
    }
}

@main @MainActor enum AppleSyncReceivePublicationPeer {
    nonisolated static let account = "synthetic.receive-publication"
    nonisolated static let owner = "10000000-0000-0000-0000-000000000041"
    nonisolated static let actor = "00000000-0000-4000-8000-000000000041"
    nonisolated static let viewer = "10000000-0000-0000-0000-000000000042"
    nonisolated static let addonA = "https://synthetic.invalid/a/manifest.json"
    nonisolated static let addonB = "https://synthetic.invalid/b/manifest.json"
    nonisolated static let addonC = "https://synthetic.invalid/c/manifest.json"
    nonisolated static let addonD = "https://synthetic.invalid/d/manifest.json"
    nonisolated static let key = Data(repeating: 41, count: 32)
    static func legacyMaterial(document: [String: Any] = [:]) throws -> Data {
        let ownerProfile = UserProfile(id: UUID(uuidString: owner)!, name: "Synthetic Owner", avatar: "fixture-owner", isOwner: true)
        return try VortxLegacyBootstrapMaterial.encode(document: JSONSerialization.data(withJSONObject: document),
            roster: [ownerProfile], ownerProfileID: ownerProfile.id, rosterModifiedSeconds: 0, deferProfileEdits: true)
    }
    static func makeCheckpoint(directory: URL) throws -> VortxEncryptedCheckpointStore {
        let archive = try VortxNativeBootstrapArchive.encode(document: Data("{}".utf8), material: legacyMaterial())
        return try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(data: key),
            installationKey: SymmetricKey(data: Data(repeating: 42, count: 32)), bootstrap: archive,
            bootstrapScope: .init(account: account, ownerProfileID: owner))
    }
    static func makeSession(checkpoint: VortxEncryptedCheckpointStore, hostActor: String) throws -> VortxNativeSession {
        let material = try legacyMaterial()
        let action: VortxJSON = .object(["type": .string("import_legacy_sync"), "scope": .string(account),
            "ownerProfileId": .string(owner), "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
        return try VortxNativeSession(scope: .init(account: account, ownerProfileID: owner), ownerName: "Synthetic Owner",
            abi: VortxCABI(), store: checkpoint, transport: NoResources(), allowNewAccount: true,
            initialActions: [String(decoding: JSONEncoder().encode(action), as: UTF8.self)], hostActor: hostActor,
            initialLegacyMaterial: material)
    }
    struct Command: Decodable { let mode: String; let directory: String; let baseURL: String; let stage: Int?; let version: Int? }
    struct NoResources: VortxResourceTransport {
        final class Cancellation: VortxResourceCancellation, @unchecked Sendable { func cancel() {} }
        func makeCancellation() throws -> any VortxResourceCancellation { Cancellation() }
        func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String { throw VortxNativeError.invalidResponse }
    }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    static func emit(_ value: [String: Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    static func patch(_ id: String, _ fields: [String: VortxJSON]) -> VortxJSON {
        .object(["type": .string("patch_profile"), "id": .string(id), "edits": .array(fields.keys.sorted().map {
            .object(["field": .string($0), "value": fields[$0]!])
        })])
    }
    static func install(_ url: String) -> VortxJSON {
        .object(["type": .string("install_addon"), "profileId": .string(owner), "addon": .object([
            "transportUrl": .string(url), "manifest": .object(["id": .string(url), "name": .string("Synthetic " + url),
                "version": .string("1.0.0"), "types": .array([.string("movie")]), "resources": .array([.string("catalog")]),
                "catalogs": .array([.object(["type": .string("movie"), "id": .string("popular"), "name": .string("Popular")])])])])])
    }
    static func stageMutation(_ stage: Int, session: VortxNativeSession) async throws {
        let seriesField = try VortxNativeWatchlist.field(id: "tt-receive-fixture", type: "series")
        let movieField = try VortxNativeWatchlist.field(id: "tt-receive-movie", type: "movie")
        let now = UInt64(stage * 1000)
        var actions: [VortxJSON] = []
        var membership: [String: VortxJSON] = [:]
        var order: [String] = []
        var hidden: [String] = []
        if stage == 1 {
            actions = [.object(["type": .string("add_profile"), "id": .string(viewer), "name": .string("Sequence Viewer")]),
                install(addonA), install(addonB), install(addonC), patch(owner, ["disabledAddons": .array([.string(addonB)])]),
                patch(viewer, ["disabledAddons": .array([.string(addonA)])]),
                .object(["type": .string("add_library_item"), "profileId": .string(owner), "item": .object([
                    "kind": .string("standard"), "id": .string("tt-receive-fixture"), "type": .string("series"),
                    "name": .string("Synthetic Series"), "poster": .null])])]
            order = [addonC, addonA, addonB]; hidden = [addonB]
            membership[seriesField] = try VortxNativeWatchlist.value(.init(id: "tt-receive-fixture", type: "series", name: "Synthetic Series", poster: nil, addedAt: 1000.5))
        } else if stage == 2 {
            actions = [.object(["type": .string("remove_addon"), "profileId": .string(owner), "transportUrl": .string(addonA)]),
                install(addonD), patch(owner, ["disabledAddons": .array([.string(addonC)])]),
                patch(viewer, ["name": .string("Edited Viewer"), "kids": .bool(true), "disabledAddons": .array([.string(addonD)])]),
                .object(["type": .string("add_library_item"), "profileId": .string(owner), "item": .object([
                    "kind": .string("standard"), "id": .string("tt-receive-movie"), "type": .string("movie"),
                    "name": .string("Synthetic Movie"), "poster": .null])])]
            order = [addonD, addonC, addonB]; hidden = [addonB]
            membership[seriesField] = .null
            membership[movieField] = try VortxNativeWatchlist.value(.init(id: "tt-receive-movie", type: "movie", name: "Synthetic Movie", poster: nil, addedAt: 2000.75))
        } else {
            // Newer activity after B has accepted v2; no reinstallation of removed A.
            actions = [patch(owner, ["disabledAddons": .array([])]),
                .object(["type": .string("remove_library_item"), "profileId": .string(owner), "key": .string("movie:tt-receive-movie")])]
            order = [addonC, addonD, addonB]; hidden = [addonD]
            membership[seriesField] = try VortxNativeWatchlist.value(.init(id: "tt-receive-fixture", type: "series", name: "Synthetic Series", poster: nil, addedAt: 3000.25))
        }
        actions.append(.object(["type": .string("reorder_addons"), "profileId": .string(owner), "transportUrls": .array(order.map(VortxJSON.string))]))
        actions.append(.object(["type": .string("report_progress"), "metaId": .string("tt-receive-fixture"),
            "videoId": .string(stage == 3 ? "tt-receive-fixture:1:8" : "tt-receive-fixture:1:7"), "name": .string("Synthetic Series"),
            "positionMs": .integer(stage == 1 ? 234000 : stage == 2 ? 678000 : 345000), "durationMs": .integer(1200000),
            "metadata": .object(["type": .string("series")])]))
        membership["discovery"] = .object(["catalogOrder": .array(order.map { .string($0 + "|movie|popular") }),
            "hiddenCatalogs": .array(hidden.map { .string($0 + "|movie|popular") }),
            "continueWatchingSource": .string("local"), "continueWatchingWindow": .string("20")])
        _ = try await session.dispatch(actions.map(raw), now: now, hostEdits: [.init(profileID: owner, fields: membership),
            .init(profileID: viewer, fields: ["avatar": .string(stage == 1 ? "🐱" : "🐯")]),
            .init(profileID: nil, fields: ["vortx.home.layout": .string(stage == 2 ? "wall" : "rails"),
                "stremiox.catalog.landscapeCards": .bool(stage != 2),
                "stremiox.catalog.posterWidthPreset": .string(stage == 2 ? "large" : "compact"),
                "stremiox.catalog.posterRadiusPreset": .string(stage == 2 ? "pill" : "sharp"),
                "stremiox.catalog.hidePosterLabels": .bool(stage == 2),
                "vortx.home.railOrder": .array([.string("addonCatalogs"), .string("topPicks")]),
                "vortx.home.railHidden": .array([.string(stage == 3 ? "topPicks" : "collectionsHub")])])])
    }
    static func snapshot(manager: VortXSyncManager, session: VortxNativeSession, facade: VortxNativeCoreFacade, checkpoint: VortxEncryptedCheckpointStore,
                         outcome: VortXSyncManager.ConflictResolutionOutcome, restored: Bool) async throws -> [String: Any] {
        let core = CoreBridge.shared
        let selected = HomeContinueWatchingSelection.current(core: core, profiles: .shared)
        let watchlist = try core.nativeWatchlist()
        let inventory = try await session.addonSnapshot().inventories[owner] ?? []
        let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
        let removed = state["nativeSync"]?["addons"]?[owner]?["records"]?[addonA]
        let viewerProfile = ProfileStore.shared.profiles.first { $0.id.uuidString == viewer }
        let catalogKeys = [addonA, addonB, addonC, addonD].map { $0 + "|movie|popular" }
        let host = try await session.hostPreferencesDocument()
        let hostDocument = try host.decode(VortxNativeHostPreferences.Document.self)
        let sealed = try checkpoint.readHostPreferences(scope: .init(account: account, ownerProfileID: owner))
        let localHost = try sealed.map { try JSONDecoder().decode(VortxNativeHostPreferences.Local.self, from: $0) }
        return ["version": manager.lastSyncedVersion, "stamped": manager.stamped, "hasApplied": manager.hasAppliedAccountDoc,
            "pendingPush": manager.hasPendingPush, "outcome": outcome.rawValue, "restored": restored,
            "profileID": ProfileStore.shared.activeID!.uuidString, "viewerName": viewerProfile?.name ?? "",
            "viewerAvatar": viewerProfile?.avatar ?? "", "viewerKids": viewerProfile?.isKids ?? false,
            "viewerDisabled": viewerProfile?.disabledAddons ?? [], "ownerDisabled": ProfileStore.shared.active?.disabledAddons ?? [],
            "library": core.library?.catalog.map(\.id) ?? [], "cw": core.continueWatching.map(\.id),
            "watchlist": watchlist.map(\.id), "watchlistAddedAt": watchlist.map(\.addedAt),
            "selection": selected.selection.items.map { ["id": $0.id, "type": $0.type, "videoId": $0.state.videoId ?? "", "offset": $0.state.timeOffset, "duration": $0.state.duration] },
            "selectionCurrent": selected.intent.isCurrent(core: core, profiles: .shared),
            "historyReceipts": core.acceptedHistoryReceiptRevision, "revision": core.revision,
            "accountGeneration": facade.accountGeneration.uuidString, "certified": core.nativePublishedAccountGeneration == facade.accountGeneration,
            "inventory": inventory.compactMap { try? $0["transportUrl"]?.decode(String.self) }, "addons": core.addons.map(\.transportUrl),
            "rawAddons": core.rawAddonsByUrl.keys.sorted(), "removedAtPresent": removed?["removedAt"] != nil && removed?["removedAt"] != .null,
            "removedClockDistinct": removed?["removedAt"] != removed?["addedAt"],
            "catalogOrder": CatalogPrefsStore.order(), "catalogHidden": Array(CatalogPrefsStore.hidden()).sorted(),
            "catalogRanks": catalogKeys.map { CatalogPrefsStore.rank($0) }, "homeLayout": CatalogPrefsStore.homeLayout().rawValue,
            "visibleHomeLayout": CatalogPreferences.shared.homeLayout.rawValue,
            "visibleLandscape": CatalogPreferences.shared.landscapeCards,
            "visiblePosterWidth": CatalogPreferences.shared.posterWidth.rawValue,
            "visiblePosterRadius": CatalogPreferences.shared.posterRadius.rawValue,
            "visibleHideLabels": CatalogPreferences.shared.hidePosterLabels,
            "pendingWidthEdit": manager.dirtySettings[CatalogPrefsStore.widthKey] != nil,
            "homeStoredOrder": HomeRailStore.order(), "homeSavedOrder": HomeRailPreferences.shared.order,
            "homeStoredHidden": Array(HomeRailStore.hidden()).sorted(),
            "homeRails": HomeRailPreferences.shared.arrange(HomeRail.iOSDefaultOrder).map(\.rawValue),
            "homeHidden": Array(HomeRailPreferences.shared.hidden).sorted(), "hostActor": hostDocument.globals.fields.values.first?.actor ?? "",
            "installationActor": localHost?.actor ?? ""]
    }
    static func main() async {
        do {
            let command = try JSONDecoder().decode(Command.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let manager = VortXSyncManager(directory: URL(fileURLWithPath: command.directory), baseURL: URL(string: command.baseURL)!)
            let checkpoint = try makeCheckpoint(directory: manager.directory)
            let hostActor = command.mode.hasPrefix("upload") ? actor : "00000000-0000-4000-8000-000000000042"
            let session = try makeSession(checkpoint: checkpoint, hostActor: hostActor)
            let core = CoreBridge.shared
            if command.mode == "seed-empty" {
                let accepted = await manager.uploadForFixture([:], version: 0)
                try emit(["accepted": accepted, "version": manager.lastSyncedVersion, "stamped": manager.stamped])
            } else if command.mode == "upload-sequence" {
                let document: [String: Any]
                let earlierCarrier = manager.directory.appendingPathComponent("earlier-synthetic-carrier.json")
                if command.stage == 4 {
                    // Retained, authenticated peer-A carrier deliberately predates its removal/progress.
                    document = try JSONSerialization.jsonObject(with: Data(contentsOf: earlierCarrier)) as! [String: Any]
                } else {
                    try await stageMutation(command.stage!, session: session)
                    let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
                    let native = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state["nativeSync"]!))
                    let host = try JSONSerialization.jsonObject(with: JSONEncoder().encode(await session.hostPreferencesDocument()))
                    document = ["nativeSync": native, "nativeHostPreferences": host]
                    if command.stage == 1 { try JSONSerialization.data(withJSONObject: document).write(to: earlierCarrier) }
                }
                let accepted = await manager.uploadForFixture(document, version: command.version!)
                try emit(["accepted": accepted, "version": manager.lastSyncedVersion, "stamped": manager.stamped, "actor": hostActor])
            } else if command.mode == "receive-sequence" {
                let facade = try await VortxNativeCoreFacade.create(session: session, registry: [], sourceEvent: core.makeHistorySourceCallbackForFixture(), changed: { _ in })
                core.installHistoryFacadeForFixture(facade)
                core.nativePublishedAccountGeneration = facade.accountGeneration
                try core.refreshProfilesForFixture()
                // Seed the real observable cache before any receive. Reading defaults alone
                // would pass the old implementation while the open screen stayed stale.
                _ = CatalogPreferences.shared
                let home = HomeRailPreferences.shared
                try emit(["ready": true, "actor": hostActor,
                    "homeOrderBeforeReceive": home.order, "homeHiddenBeforeReceive": Array(home.hidden).sorted()])
                while let instruction = readLine() {
                    if instruction == "close" { break }
                    if instruction == "broadcast-while-pending" {
                        let expectedVersion = manager.lastSyncedVersion + 1
                        let priorVersion = manager.lastSyncedVersion
                        UserDefaults.standard.set("malformed-bool", forKey: "stremiox.autoSkip")
                        manager.dirtySettings["stremiox.autoSkip"] = 91
                        manager.hasPendingPush = true
                        manager.activeSyncUp = (UUID(), manager.credentialAuthority.capture())
                        manager.broadcastForFixture(version: expectedVersion)
                        manager.pollForFixture()
                        try await Task.sleep(nanoseconds: 80_000_000)
                        let busyDeferred = manager.lastSyncedVersion == priorVersion
                        manager.activeSyncUp = nil
                        try await Task.sleep(nanoseconds: 60_000_000)
                        let queuedDeferred = manager.lastSyncedVersion == priorVersion
                        // The actual manager queue drain/export is covered by the companion
                        // malformed-global harness; this injects its accepted transport state.
                        manager.hasPendingPush = false
                        for _ in 0..<100 where manager.lastSyncedVersion < expectedVersion {
                            try await Task.sleep(nanoseconds: 10_000_000)
                        }
                        manager.pollTask?.cancel(); await manager.pollTask?.value
                        await drainMainQueue()
                        var result = try await snapshot(manager: manager, session: session, facade: facade, checkpoint: checkpoint,
                            outcome: .completed, restored: manager.lastSyncedVersion == expectedVersion)
                        result["broadcastDeferredDuringUpload"] = busyDeferred
                        result["pollDeferredWhileQueued"] = queuedDeferred
                        result["pollCaughtUpAfterQueueDrained"] = manager.lastSyncedVersion == expectedVersion
                        result["malformedStampRetained"] = manager.dirtySettings["stremiox.autoSkip"] == 91
                            && UserDefaults.standard.string(forKey: "stremiox.autoSkip") == "malformed-bool"
                        try emit(result)
                        continue
                    }
                    if instruction == "dirty-appearance" {
                        CatalogPreferences.shared.posterWidth = .comfort
                        manager.dirtySettings[CatalogPrefsStore.widthKey] = 4000
                        try emit(["dirty": true, "width": CatalogPreferences.shared.posterWidth.rawValue])
                        continue
                    }
                    if instruction == "clear-pending" {
                        manager.hasPendingPush = false; try emit(["cleared": true]); continue
                    }
                    if instruction == "persisted-highwater" {
                        // A persisted push/previous-process version is not this mount's receive receipt.
                        manager.lastSyncedVersion = 1; manager.hasAppliedAccountDoc = true
                        try emit(["seededHighwater": true]); continue
                    }
                    if instruction == "stale" {
                        let selected = HomeContinueWatchingSelection.current(core: core, profiles: .shared)
                        let receipts = core.acceptedHistoryReceiptRevision
                        core.library = nil; core.continueWatching = []; core.addons = []; core.rawAddonsByUrl = [:]
                        core.handleHistoryFields(["library", "continue_watching_preview", "ctx"])
                        CredentialScopeRegistry.shared.retire()
                        await drainMainQueue()
                        try emit(["staleLibraryRejected": core.library == nil, "staleCWRejected": core.continueWatching.isEmpty,
                            "staleAddonsRejected": core.addons.isEmpty && core.rawAddonsByUrl.isEmpty,
                            "staleReceiptRejected": core.acceptedHistoryReceiptRevision == receipts,
                            "staleSelectionRejected": !selected.intent.isCurrent(core: core, profiles: .shared)])
                        continue
                    }
                    let conditionalInstructions = ["conditional", "forced", "fail-prepare", "pending-apply", "replace-mount", "mount-during", "aba-during", "pending-during", "mount-before-ack"]
                    guard instruction == "pull" || conditionalInstructions.contains(instruction) else { throw VortxNativeError.invalidResponse }
                    manager.failPreparation = instruction == "fail-prepare"
                    if manager.failPreparation { manager.invalidateConversionReceiptForFixture() }
                    manager.pendingApplyFixture = instruction == "pending-apply"
                    manager.providerSnapshotReads = 0
                    manager.replaceMountBeforeAcknowledgement = instruction == "mount-before-ack"
                    if instruction == "replace-mount" { core.nativeInstallGeneration = UUID(); try core.refreshProfilesForFixture() }
                    if instruction == "mount-during" {
                        manager.afterResponse = { core.nativeInstallGeneration = UUID(); try core.refreshProfilesForFixture() }
                    }
                    if instruction == "aba-during" {
                        manager.afterResponse = {
                            manager.dataKey = Data(repeating: 99, count: 32); CredentialScopeRegistry.shared.retire()
                            manager.dataKey = key; CredentialScopeRegistry.shared.retire()
                            core.nativeCredentialCapture = CredentialScopeRegistry.shared.capture()
                            try core.refreshProfilesForFixture()
                        }
                    }
                    if instruction == "pending-during" { manager.afterResponse = { manager.hasPendingPush = true } }
                    var outcome = VortXSyncManager.ConflictResolutionOutcome.failed
                    let restored = await manager.syncDown(force: instruction == "forced" || instruction == "fail-prepare" || instruction == "mount-before-ack",
                        reportOutcome: { outcome = $0 }, routineReceive: instruction != "pull")
                    manager.failPreparation = false; manager.pendingApplyFixture = false; manager.replaceMountBeforeAcknowledgement = false
                    await drainMainQueue()
                    try emit(try await snapshot(manager: manager, session: session, facade: facade, checkpoint: checkpoint, outcome: outcome, restored: restored))
                }
                await facade.shutdown()
            } else if command.mode == "upload" {
                let field = try VortxNativeWatchlist.field(id: "tt-receive-fixture", type: "series")
                let actions: [VortxJSON] = [
                    .object(["type": .string("add_profile"), "id": .string("10000000-0000-0000-0000-000000000042"), "name": .string("Received Viewer")]),
                    .object(["type": .string("add_library_item"), "profileId": .string(owner), "item": .object(["kind": .string("standard"), "id": .string("tt-receive-fixture"), "type": .string("series"), "name": .string("Synthetic Series"), "poster": .null])]),
                    .object(["type": .string("report_progress"), "metaId": .string("tt-receive-fixture"), "videoId": .string("tt-receive-fixture:1:7"), "name": .string("Synthetic Series"), "positionMs": .integer(234000), "durationMs": .integer(1200000), "metadata": .object(["type": .string("series")])])]
                _ = try await session.dispatch(actions.map(raw), now: 200, hostEdits: [.init(profileID: owner, fields: [field: .object(["id": .string("tt-receive-fixture"), "type": .string("series"), "name": .string("Synthetic Series"), "addedAt": .number(200.5)])])])
                let state = try JSONDecoder().decode(VortxJSON.self, from: Data(try await session.stateJSON().utf8))
                let native = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state["nativeSync"]!))
                let host = try JSONSerialization.jsonObject(with: JSONEncoder().encode(await session.hostPreferencesDocument()))
                let uploaded = await manager.uploadForFixture(["nativeSync": native, "nativeHostPreferences": host], version: 1)
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["accepted": uploaded, "stamped": manager.stamped, "version": manager.lastSyncedVersion]), as: UTF8.self))
            } else {
                let facade = try await VortxNativeCoreFacade.create(session: session, registry: [], sourceEvent: core.makeHistorySourceCallbackForFixture(), changed: { _ in })
                core.installHistoryFacadeForFixture(facade)
                core.nativePublishedAccountGeneration = facade.accountGeneration
                try core.refreshProfilesForFixture()
                let originalAccountGeneration = facade.accountGeneration
                var outcome = VortXSyncManager.ConflictResolutionOutcome.failed
                _ = await manager.syncDown(reportOutcome: { outcome = $0 })
                await drainMainQueue()
                let selected = HomeContinueWatchingSelection.current(core: core, profiles: .shared)
                let watchlist = try core.nativeWatchlist()
                let values: [[String: Any]] = selected.selection.items.map { ["id": $0.id, "type": $0.type, "videoId": $0.state.videoId ?? "", "offset": $0.state.timeOffset, "duration": $0.state.duration] }
                let acceptedReceipt = core.acceptedHistoryReceiptRevision
                let result: [String: Any] = ["profileID": ProfileStore.shared.activeID!.uuidString,
                    "receivedViewer": ProfileStore.shared.profiles.first { $0.id.uuidString == "10000000-0000-0000-0000-000000000042" }?.name ?? "",
                    "accountGenerationAdvanced": originalAccountGeneration != facade.accountGeneration,
                    "accountGenerationCertified": core.nativePublishedAccountGeneration == facade.accountGeneration,
                    "library": core.library?.catalog.map(\.id) ?? [], "watchlist": watchlist.map(\.id),
                    "cw": core.continueWatching.map(\.id), "selection": values,
                    "selectionCurrent": selected.intent.isCurrent(core: core, profiles: .shared),
                    "stamped": manager.stamped, "version": manager.lastSyncedVersion, "hasApplied": manager.hasAppliedAccountDoc,
                    "outcome": outcome.rawValue, "historyReceipts": acceptedReceipt,
                    "watchlistAddedAt": watchlist.first { $0.id == "tt-receive-fixture" }?.addedAt ?? -1,
                    "revision": core.revision, "changedFields": Array(core.changedFields).sorted()]
                // Capture a real production callback before a credential owner changes, then
                // let its main-queue closures arrive after that change. Epoch remains unchanged.
                core.library = nil; core.continueWatching = []
                core.handleHistoryFields(["library", "continue_watching_preview"])
                CredentialScopeRegistry.shared.retire()
                await drainMainQueue()
                var final = result
                final["staleLibraryRejected"] = core.library == nil
                final["staleCWRejected"] = core.continueWatching.isEmpty
                final["staleReceiptRejected"] = core.acceptedHistoryReceiptRevision == acceptedReceipt
                final["staleSelectionRejected"] = !selected.intent.isCurrent(core: core, profiles: .shared)
                print(String(decoding: try JSONSerialization.data(withJSONObject: final), as: UTF8.self))
                await facade.shutdown()
            }
            await session.close()
        } catch { FileHandle.standardError.write(Data("Receive/publication fixture failed: \(error)\n".utf8)); exit(1) }
    }
}
