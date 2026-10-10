import Foundation
import CryptoKit

private final class PreferenceCheckpointGate: VortxCheckpointStore, @unchecked Sendable {
    let backing: VortxEncryptedCheckpointStore
    private let condition = NSCondition()
    private var holdRequests = 0
    private var entryCount = 0
    private var releasedCount = 0

    init(_ backing: VortxEncryptedCheckpointStore) { self.backing = backing }

    func holdNext() { condition.withLock { holdRequests += 1 } }
    func release() {
        condition.withLock {
            guard releasedCount < entryCount else { return }
            releasedCount += 1
            condition.broadcast()
        }
    }

    func waitUntilEntered(after: Int = 0) async throws -> Int {
        for _ in 0..<400 {
            let current = condition.withLock { entryCount }
            if current > after { return current }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw VortxNativeError.superseded
    }

    private func wait() {
        condition.lock(); defer { condition.unlock() }
        guard holdRequests > 0 else { return }
        holdRequests -= 1
        entryCount += 1
        let myEntry = entryCount
        while releasedCount < myEntry { condition.wait() }
    }

    func entryCountSnapshot() -> Int {
        condition.withLock { entryCount }
    }

    func drain() {
        condition.withLock {
            releasedCount = entryCount
            holdRequests = 0
            condition.broadcast()
        }
    }

    func read(scope: VortxAccountScope) throws -> String? { try backing.read(scope: scope) }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { try backing.readHostPreferences(scope: scope) }
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data? { try backing.readLegacyMaterial(scope: scope) }
    func readLegacyProfileEdits(scope: VortxAccountScope) throws -> VortxJSON? { try backing.readLegacyProfileEdits(scope: scope) }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws {
        wait()
        try backing.commit(snapshot, scope: scope)
    }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        wait()
        try backing.commit(snapshot, scope: scope, hostPreferences: hostPreferences)
    }
}

// This file is the fixture boundary for the live admission harness.  The Node extractor appends
// the immutable production UserProfile/converter inputs and exact production method bodies to a
// generated file; nothing below reaches the application container, Keychain, or real account.

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
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
}

enum DiagnosticsLog {
    static func log(_ category: String, _ message: String) {}
}

final class CredentialScopeRegistry: @unchecked Sendable {
    enum Scope: Hashable, Sendable { case account, signedOutDevice }
    struct Capture: Hashable, Sendable {
        let generation: UInt64
        var namespace: String { NativeProfileSwitchAdmissionEnvironment.account }
        var scope: Scope { .account }
    }

    static let shared = CredentialScopeRegistry()
    private let lock = NSLock()
    private var generation: UInt64 = 1
    func capture() -> Capture { lock.withLock { .init(generation: generation) } }
    func isCurrent(_ capture: Capture) -> Bool { self.capture() == capture }
    func retire() { lock.withLock { generation &+= 1 } }
    func isMigrationEligible(_ capture: Capture) -> Bool { false }
}

typealias PlaybackMutationTarget = PlaybackMutationOwnershipPolicy.Target

extension PlaybackMutationTarget {
    func stillOwnsCurrentContext(core: CoreBridge) -> Bool {
        core.nativePlaybackTargetIsCurrent(self)
    }
}

enum ContinueWatchingService: String, Codable, CaseIterable, Sendable { case local, trakt, simkl }
enum ContinueWatchingWindow: String, Codable, CaseIterable, Sendable {
    case last90Days, twenty = "20", forty = "40", sixty = "60", eighty = "80", hundred = "100"
}

enum ContinueWatchingPreferences {
    static let sourceKey = "vortx.home.continueWatching.source"
    static let windowKey = "vortx.home.continueWatching.window"
    static let changedNote = Notification.Name("vortx.home.continueWatching.preferenceChanged")
    struct Value: Hashable, Sendable {
        let source: ContinueWatchingService
        let window: ContinueWatchingWindow
        var isSupported = true
    }
    static func current(_ defaults: UserDefaults = .standard) -> Value {
        value(source: defaults.string(forKey: sourceKey), window: defaults.string(forKey: windowKey))
    }
    static func value(source: String?, window: String?) -> Value {
        .init(source: ContinueWatchingService(rawValue: source ?? "") ?? .local,
              window: ContinueWatchingWindow(rawValue: window ?? "") ?? .twenty,
              isSupported: source == nil || ContinueWatchingService(rawValue: source!) != nil)
    }
    static func retireSelection() {}
}

enum ExternalSyncToggle { static let traktContinueWatching = "vortx.trakt.continueWatching" }
struct TraktSessionID: Hashable, Sendable { let rawValue: String }
enum TraktAuth { static let storedSessionID: TraktSessionID? = nil }

enum TabBarPrefs {
    static let hideLive = "vortx.tabs.hide.live"
    static let hideDiscover = "vortx.tabs.hide.discover"
    static let hideLibrary = "vortx.tabs.hide.library"
    static let hideSearch = "vortx.tabs.hide.search"
}

enum LibraryAutoAdd { static let watchlistChangedNote = Notification.Name("synthetic.watchlist.changed") }
final class CatalogPreferences: @unchecked Sendable {
    static let shared = CatalogPreferences()
    func reloadFromDefaults() {}
}
final class CollectionsHubModel: @unchecked Sendable {
    static let shared = CollectionsHubModel()
    func reloadFromProfilePreferences() {}
}

enum KeychainValue { case value(String); case missing }
enum Keychain { static func confirmedString(_ account: String) -> KeychainValue { .missing } }

@MainActor
final class VortxNativeCredentialSelectionRelay {
    static let shared = VortxNativeCredentialSelectionRelay()
    func publish(isCurrent: @MainActor () -> Bool) {}
}

enum ThemeManager {
    static let shared = ThemeState()
    final class ThemeState: @unchecked Sendable {
        var accentID = "ember"
        var oled = false
        var textScale = 1.0
    }
}

enum TrackPreferences {
    enum Key {
        static let audio = "stremiox.tracks.audioLangs"
        static let subtitle = "stremiox.tracks.subLangs"
        static let forced = "stremiox.tracks.forced"
    }
    enum ForcedPolicy: String { case forced = "auto" }
    static let deviceLanguages = ["en"]
}

enum SubtitleStyle {
    enum Key {
        static let font = "stremiox.sub.font"
        static let size = "stremiox.sub.size"
        static let color = "stremiox.sub.color"
        static let background = "stremiox.sub.background"
        static let sizeScale = "stremiox.sub.sizeScale"
        static let brightness = "stremiox.sub.brightness"
    }
    static let defaultFont = "modern"
    static let defaultSize = "m"
    static let defaultColor = "white"
    static let defaultBackground = "outline"
    static let defaultBrightness = "100"
}

enum SourceType: String, CaseIterable { case mediaServer, debrid, usenet, torrent, direct }

final class SourcePreferences: @unchecked Sendable {
    static let shared = SourcePreferences()
    static let orderKey = "stremiox.streaming.sourceTypeOrder"
    static let addonOrderKey = "stremiox.streaming.useAddonOrder"
    static let excludeKey = "stremiox.streaming.excludeKeywords"
    static let includeKey = "stremiox.streaming.includeKeywords"
    static let safetyKey = "stremiox.streaming.safetyMode"
    static let hideDeadKey = "stremiox.streaming.hideDeadTorrents"
    static let instantOnlyKey = "stremiox.streaming.instantOnly"
    static let maxResolutionKey = "stremiox.streaming.maxResolution"
    static let minResolutionKey = "stremiox.streaming.minResolution"
    static let hideUnknownResKey = "stremiox.streaming.hideUnknownResolution"
    static let preferredAudioKey = "stremiox.streaming.preferredAudioOnly"
    static let maxFileSizeKey = "stremiox.streaming.maxFileSizeGB"
    static let hdrOnlyKey = "stremiox.streaming.hdrOnly"
    static let excludeAV1Key = "stremiox.streaming.excludeAV1"
    static let regexKey = "stremiox.streaming.keywordsAreRegex"
    static let preferKey = "vortx.streaming.preferKeywords"
    static let avoidBehaviorKey = "vortx.streaming.avoidBehavior"
    static let autoPickBestKey = "vortx.streaming.autoPickBest"
    static let defaultSafetyMode = "off"
    static let defaultInstantOnly = false
    static let defaultHideDeadTorrents = false
    static let defaultHDROnly = false
    static let defaultExcludeAV1 = false
    static let defaultExcludeKeywords = ""
    static let defaultIncludeKeywords = ""
    static let defaultKeywordsAreRegex = false
    static let defaultMaxResolution = 0
    static let defaultMaxFileSizeGB = 0.0
    static let defaultMinResolution = 0
    static let defaultHideUnknownResolution = false
    static let defaultPreferredAudioOnly = false
    static let defaultUseAddonOrder = false
    static let defaultPreferKeywords = ""
    static let defaultAvoidBehavior = "hide"
    static let defaultAutoPickBest = false
    static let defaultTypeOrder: [SourceType] = SourceType.allCases
    var typeOrder: [SourceType] = defaultTypeOrder
    var useAddonOrder = false
    var safetyMode = "balanced"
    var instantOnly = false
    var hideDeadTorrents = false
    var hdrOnly = false
    var excludeAV1 = false
    var excludeKeywords: String?
    var includeKeywords: String?
    var keywordsAreRegex = false
    var maxResolution = 0
    var maxFileSizeGB = 0.0
    var minResolution = 0
    var hideUnknownResolution = false
    var preferredAudioOnly = false
    var preferKeywords: String?
    var avoidBehavior = "hide"
    var autoPickBest = false
    func reload() {
        let d = UserDefaults.standard
        let order = (d.string(forKey: Self.orderKey) ?? "").split(separator: ",").compactMap { SourceType(rawValue: String($0)) }
        if !order.isEmpty { typeOrder = order }
        useAddonOrder = d.object(forKey: Self.addonOrderKey) as? Bool ?? Self.defaultUseAddonOrder
        safetyMode = d.string(forKey: Self.safetyKey) ?? Self.defaultSafetyMode
        instantOnly = d.object(forKey: Self.instantOnlyKey) as? Bool ?? Self.defaultInstantOnly
        hideDeadTorrents = d.object(forKey: Self.hideDeadKey) as? Bool ?? Self.defaultHideDeadTorrents
        hdrOnly = d.object(forKey: Self.hdrOnlyKey) as? Bool ?? Self.defaultHDROnly
        excludeAV1 = d.object(forKey: Self.excludeAV1Key) as? Bool ?? Self.defaultExcludeAV1
        excludeKeywords = d.string(forKey: Self.excludeKey) ?? Self.defaultExcludeKeywords
        includeKeywords = d.string(forKey: Self.includeKey) ?? Self.defaultIncludeKeywords
        keywordsAreRegex = d.object(forKey: Self.regexKey) as? Bool ?? Self.defaultKeywordsAreRegex
        maxResolution = d.object(forKey: Self.maxResolutionKey) as? Int ?? Self.defaultMaxResolution
        maxFileSizeGB = d.object(forKey: Self.maxFileSizeKey) as? Double ?? Self.defaultMaxFileSizeGB
        minResolution = d.object(forKey: Self.minResolutionKey) as? Int ?? Self.defaultMinResolution
        hideUnknownResolution = d.object(forKey: Self.hideUnknownResKey) as? Bool ?? Self.defaultHideUnknownResolution
        preferredAudioOnly = d.object(forKey: Self.preferredAudioKey) as? Bool ?? Self.defaultPreferredAudioOnly
        preferKeywords = d.string(forKey: Self.preferKey) ?? Self.defaultPreferKeywords
        avoidBehavior = d.string(forKey: Self.avoidBehaviorKey) ?? Self.defaultAvoidBehavior
        autoPickBest = d.object(forKey: Self.autoPickBestKey) as? Bool ?? Self.defaultAutoPickBest
    }
}
final class SourcePinStore: @unchecked Sendable {
    static let shared = SourcePinStore()
    func reload() {}
}
enum StreamRanking { static func invalidateCaches() {} }

final class ProfileStore: @unchecked Sendable {
    static let shared = ProfileStore()
    var profiles: [UserProfile] = []
    var activeID: UUID?
    var nativeProfileError: String?
    var pickedThisLaunch = false

    var active: UserProfile? { profiles.first { $0.id == activeID } }
    var activeUsesEngineHistory: Bool { active?.usesEngineHistory ?? true }
    var activeKeychainAccount: String { "synthetic.profile-switch" }

    var nativeProjectionTarget: PlaybackMutationTarget?
    var nativePublishedPlayback: UserProfile.PlaybackPrefs?
    var nativePublishedDiscovery: ProfileDiscoveryPreferences?
    // The extractor injects the exact production NativeSwitchPreferenceCapture property shell
    // when the current production source provides that bounded-switch witness.
    // NATIVE_SWITCH_PREFERENCE_CAPTURE_PROPERTY_SHELL
    struct NativePlaybackProjectionSource: Equatable { let playback: UserProfile.PlaybackPrefs?; let addonPreferences: ProfileAddonPreferences? }
    struct NativeDiscoveryProjectionSource: Equatable { let discovery: ProfileDiscoveryPreferences? }
    var nativePublishedPlaybackSource: NativePlaybackProjectionSource?
    var nativePublishedDiscoverySource: NativeDiscoveryProjectionSource?
    struct NativeThemeProjection: Equatable { let accentID: String; let oled: Bool; let textScale: Double }
    var nativePublishedTheme: NativeThemeProjection?
    struct ContinueWatchingMigrationWitness { let profileID: UUID; let target: PlaybackMutationTarget; let session: TraktSessionID }
    var continueWatchingMigration: ContinueWatchingMigrationWitness?
    var continueWatchingMigrationInFlight = false
    let continueWatchingLegacyAccount = CredentialScopeRegistry.shared.capture()

    static let activeDisabledAddonsKey = "stremiox.profile.disabledAddons"
    static let activeAddonOrderOverrideKey = "stremiox.profile.addonOrderOverride"
    static let activeKidsKey = "stremiox.profile.isKids"

    static var nativePlaybackProjectionKeys: Set<String> {
        [TrackPreferences.Key.audio, TrackPreferences.Key.subtitle, TrackPreferences.Key.forced,
         SubtitleStyle.Key.font, SubtitleStyle.Key.size, SubtitleStyle.Key.color, SubtitleStyle.Key.background,
         SubtitleStyle.Key.sizeScale, SubtitleStyle.Key.brightness, SourcePreferences.orderKey,
         SourcePreferences.addonOrderKey, SourcePreferences.excludeKey, SourcePreferences.includeKey,
         SourcePreferences.safetyKey, SourcePreferences.hideDeadKey, SourcePreferences.instantOnlyKey,
         SourcePreferences.maxResolutionKey, SourcePreferences.minResolutionKey, SourcePreferences.hideUnknownResKey,
         SourcePreferences.preferredAudioKey, SourcePreferences.maxFileSizeKey, SourcePreferences.hdrOnlyKey,
         SourcePreferences.excludeAV1Key, SourcePreferences.regexKey, SourcePreferences.preferKey,
         SourcePreferences.avoidBehaviorKey, SourcePreferences.autoPickBestKey]
    }
    static let nativeThemeProjectionKeys: Set<String> = ["stremiox.theme.accent", "stremiox.theme.oled", "stremiox.theme.textScale"]

    func persist(touch: Bool) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: "stremiox.profiles")
        if let activeID { UserDefaults.standard.set(activeID.uuidString, forKey: "stremiox.profiles.active") }
    }
    func applyTheme(_ profile: UserProfile) {
        ThemeManager.shared.accentID = profile.accentID; ThemeManager.shared.oled = profile.oled; ThemeManager.shared.textScale = profile.textScale
    }
    func rebuildBoardRows() {}
    func notifyAddonPreferencesDidChange(profileID: UUID) {}
    func migrateContinueWatchingIfQualified(_ profile: UserProfile) {}
}

final class CoreBridge: @unchecked Sendable {
    static let shared = CoreBridge()
    let nativeFacadeLock = NSLock()
    var nativeFacadeStorage: VortxNativeCoreFacade?
    var nativeCredentialCapture: CredentialScopeRegistry.Capture?
    var nativeInstallGeneration = UUID()
    var nativeProfileBaseline: [UserProfile] = []
    var nativeAccountEditRequests: [UUID: (CredentialScopeRegistry.Capture, VortxNativeProfiles.AccountRebindRequest)] = [:]
    var nativePublishedCredentialSlot: String?
    var nativePublishedAccountGeneration: UUID?
    var nativeFacade: VortxNativeCoreFacade? { nativeFacadeLock.withLock { nativeFacadeStorage } }
    var nativeRegistryBinding: VortxNativeCoreFacade.RegistryBinding? { nativeFacade?.registryBinding }
    var hasNativeSession: Bool { nativeFacade?.isAvailable == true }
    var nativeProfileRecoveryMessage: String { "profile admission failed" }
    struct NativeProfileActionAdmission { let credential: CredentialScopeRegistry.Capture; let profileID: UUID?; let target: PlaybackMutationTarget }
    struct PublicationToken: Equatable { let epoch: UInt64 }
    private var publicationEpoch: UInt64 = 1

    func stateData(_ field: String) -> Data? { nativeFacade?.stateData(field) }
    func capturePublicationToken() -> PublicationToken { nativeFacadeLock.withLock { .init(epoch: publicationEpoch) } }
    func invalidatePublicationEpoch() { nativeFacadeLock.withLock { publicationEpoch &+= 1 } }
    func clearNativePublishedState() {}
    func refreshAddons(capturedPublicationToken: PublicationToken) {}
    func rebuildContinueWatching(capturedPublicationToken: PublicationToken) {}
    func rebuildBoardRows() {}
    func addonOrderDidChange() {}
    func loadBoard() {}
    func loadLibrary() {}
    func reportNativeProfileFailure(_ operation: String, error: Error? = nil) {
        // This executable has only synthetic state; retain failure categories for live evidence.
        print("synthetic profile failure operation=\(operation) error=\(String(describing: error))")
    }
    func install(_ facade: VortxNativeCoreFacade, capture: CredentialScopeRegistry.Capture) {
        nativeFacadeLock.withLock {
            nativeFacadeStorage = facade
            nativeCredentialCapture = capture
            nativeInstallGeneration = UUID()
            nativePublishedAccountGeneration = facade.accountGeneration
        }
    }
    var enginePublicationBlocked = false
    func nativeAccountMode(profileID: UUID) -> String? { nil }
    func nativeCredentialSlot(profileID: UUID) -> String? { "synthetic.profile-switch.\(profileID.uuidString)" }
    @MainActor func refreshNativeProfilesForHarness() throws { try refreshNativeProfiles() }
}

@MainActor final class VortXSyncManager {
    static var shared: VortXSyncManager!
    struct Account { let id: String }
    let credentialAuthority = CredentialScopeRegistry.shared
    var account: Account?
    var dataKey: Data?
    var isSignedIn = true
    var isApplyingRemote = false
    var dirtySettings: [String: Double] = [:]
    var nativePreferenceIntentStatus = "idle"
    var nativeCheckpointStatus = "ready"
    struct NativePreferenceLocalAdmission { let target: PlaybackMutationTarget; let intent: NativePreferenceIntentStore.Intent }
    var nativePreferenceLocalAdmissions: [UUID: [NativePreferenceIntentStore.Group: NativePreferenceLocalAdmission]] = [:]
    let nativePreferenceAdmissionGate = NativePreferenceIntentStore.AdmissionGate()
    let directory: URL
    init(directory: URL) { self.directory = directory; self.account = .init(id: NativeProfileSwitchAdmissionEnvironment.account); Self.shared = self }
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { credentialAuthority.isCurrent(capture) }
    func noteLocalSettingsChange() -> Bool { true }
    func requestSyncSoon() {}
    func withRemoteApplySuppressed(_ body: () -> Void) { let old = isApplyingRemote; isApplyingRemote = true; body(); isApplyingRemote = old }
    static nonisolated func suppressHousekeeping(_ writes: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { shared.withRemoteApplySuppressed(writes) } }
        else { DispatchQueue.main.sync { shared.withRemoteApplySuppressed(writes) } }
    }
    func restoreNativeCheckpoint(credentialCapture: CredentialScopeRegistry.Capture? = nil) async -> Bool { true }
    func publishNativeWatchedPending(_ archive: Data?, capture: CredentialScopeRegistry.Capture) throws {}
    func publishNativeOwnOverlayPending(_ pending: VortxJSON, capture: CredentialScopeRegistry.Capture) throws {}
    func updateNativeOwnAccountAvailability(missing: [UUID], profiles: [UserProfile], capture: CredentialScopeRegistry.Capture) {}
    func preferenceSnapshotForHarness(profileID: UUID, group: NativePreferenceIntentStore.Group) throws -> NativePreferenceIntentStore.Snapshot {
        let context = try nativePreferenceContext(profileID: profileID, target: CoreBridge.shared.captureNativePlaybackTarget())
        return try Self.nativePreferenceSnapshot(context, group: group)
    }
}

enum NativeProfileSwitchAdmissionEnvironment {
    static let account = "synthetic.profile-switch-admission"
    static nonisolated(unsafe) var journalRoot = URL(fileURLWithPath: "/nonexistent/native-profile-switch-journal", isDirectory: true)
    static let owner = UUID(uuidString: "10000000-0000-0000-0000-000000000041")!
    static let viewer = UUID(uuidString: "10000000-0000-0000-0000-000000000042")!
    static let key = Data(repeating: 41, count: 32)
}

@main @MainActor enum NativeProfileSwitchAdmissionLiveTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
    }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func decode(_ data: Data?) throws -> VortxJSON {
        guard let data else { throw Failure.assertion("missing native field") }
        return try JSONDecoder().decode(VortxJSON.self, from: data)
    }
    static func quarantinedPlist(_ projection: NativePreferenceIntentStore.QuarantinedProjection) throws -> Any {
        guard case .string(let encoded) = projection.value["binaryPropertyList"],
              let data = Data(base64Encoded: encoded) else {
            throw Failure.assertion("quarantined projection was not a binary plist carrier")
        }
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
    static func journalBytes() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
            at: NativeProfileSwitchAdmissionEnvironment.journalRoot, includingPropertiesForKeys: nil).map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
    }
    static func checkPendingGeneration(_ intent: NativePreferenceIntentStore.Intent,
                                       store: NativePreferenceIntentStore, manager: VortXSyncManager,
                                       stamps: [String: Double]) throws {
        // pending() authenticates the encrypted document and the exact generation payload.
        try check(intent.generationAuthentication?.count == 32, "pending edit has no authenticated generation")
        try check(try store.pending().contains(intent), "native completion cleared or changed the pending generation")
        try check(intent.projectionStamps == stamps, "pending generation lost its exact dirty stamps")
        try check(manager.nativePreferenceAdmissionGate.admits([intent]) { true }, "current generation lost admission")
        try check(try JSONEncoder().encode(intent).count <= NativePreferenceIntentStore.maximumRecordBytes,
                  "pending generation exceeded its bounded record size")
        try check(try journalBytes().values.allSatisfy { $0.count <= NativePreferenceIntentStore.maximumFileBytes },
                  "pending journal exceeded its bounded file size")
    }
    static func checkRetiredGeneration(_ retired: NativePreferenceIntentStore.Intent,
                                       successor: NativePreferenceIntentStore.Intent,
                                       store: NativePreferenceIntentStore, manager: VortXSyncManager) throws {
        try check(retired.generationAuthentication?.count == 32 && successor.generationAuthentication?.count == 32,
                  "generation retirement lacks authenticated receipts")
        try check(retired.id != successor.id && retired.generationAuthentication != successor.generationAuthentication,
                  "new edit reused the retired generation")
        try check(!successor.supersededIDs.contains(retired.id), "retired signed generation retained replay authority")
        // The successor's immutable base was captured from the actual native context after the
        // predecessor committed. Use it unchanged so rejection cannot pass on value mismatch.
        try check(successor.base.value == retired.desired, "retirement proof did not capture the committed predecessor")
        let pending = try store.pending()
        let bytes = try journalBytes()
        let stamps = manager.dirtySettings
        try check(!manager.nativePreferenceAdmissionGate.admits([retired]) { true }, "retired generation regained FIFO admission")
        try check(try store.recordCommitted(retired, current: successor.base), "authenticated retired completion was not idempotent")
        try check(try !store.authorizesAcknowledgement(retired, current: successor.base), "retired cloud receipt authorized acknowledgement")
        try check(try !store.acknowledge(retired, current: successor.base), "retired cloud receipt cleared the current generation")
        try check(try store.pending() == pending && journalBytes() == bytes,
                  "retired completion or cloud receipt changed the pending journal")
        try check(manager.dirtySettings == stamps, "retired receipt changed dirty stamps")
    }
    static func main() async {
        do { try await run(); print("GREEN native profile switch admission") }
        catch { print("FAIL native profile switch admission: \(error)"); exit(1) }
    }

    static func run() async throws {
        guard CommandLine.arguments.count >= 2 else { throw Failure.assertion("filesystem root argument required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkpoint = root.appendingPathComponent("checkpoint", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        let intentParent = root.appendingPathComponent("intent-parent", isDirectory: false)
        try Data("regular-file-parent".utf8).write(to: intentParent)
        NativeProfileSwitchAdmissionEnvironment.journalRoot = intentParent
        _ = UserDefaults.standard

        let manager = VortXSyncManager(directory: root)
        manager.dataKey = NativeProfileSwitchAdmissionEnvironment.key
        let scope = VortxAccountScope(account: NativeProfileSwitchAdmissionEnvironment.account,
                                      ownerProfileID: NativeProfileSwitchAdmissionEnvironment.owner.uuidString)
        let store = try VortxEncryptedCheckpointStore(directory: checkpoint, key: SymmetricKey(data: NativeProfileSwitchAdmissionEnvironment.key),
                                                       installationKey: SymmetricKey(data: Data(repeating: 7, count: 32)))
        let checkpointGate = PreferenceCheckpointGate(store)
        let session = try VortxNativeSession(scope: scope, ownerName: "Synthetic Owner", abi: VortxCABI(), store: checkpointGate,
                                             transport: NoResources(), allowNewAccount: true)
        let getState: VortxJSON = .object(["type": .string("get_state")])
        _ = try await session.dispatch([try raw(getState)], now: 100,
            hostEdits: [.init(profileID: scope.ownerProfileID, fields: ["playback": .null, "discovery": .null, "addonPreferences": .null])])
        let addViewer: VortxJSON = .object(["type": .string("add_profile"), "id": .string(NativeProfileSwitchAdmissionEnvironment.viewer.uuidString), "name": .string("Viewer")])
        let library: VortxJSON = .object(["type": .string("add_library_item"), "profileId": .string(scope.ownerProfileID),
                                          "item": .object(["kind": .string("standard"), "id": .string("synthetic-library"), "type": .string("movie"), "name": .string("Library item")])])
        let progress: VortxJSON = .object(["type": .string("report_progress"), "metaId": .string("synthetic-movie"), "videoId": .string("synthetic-movie"), "name": .string("Synthetic movie"),
                                            "positionMs": .integer(12_000), "durationMs": .integer(100_000), "metadata": .object(["type": .string("movie")])])
        _ = try await session.dispatch([try raw(addViewer), try raw(library), try raw(progress)], now: 101)
        let explicitViewerAddons = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(ProfileAddonPreferences()))
        _ = try await session.dispatch([], now: 102,
            hostEdits: [.init(profileID: NativeProfileSwitchAdmissionEnvironment.viewer.uuidString,
                              fields: ["playback": .null, "discovery": .null, "addonPreferences": explicitViewerAddons])])
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: [], changed: { _ in })
        guard let watchlistBinding = facade.watchlistBinding else { throw Failure.assertion("real native watchlist binding missing") }
        let watchEntry = VortxNativeWatchlist.Entry(id: "tt-synthetic-watch", type: "movie", name: "Synthetic watch", poster: nil, addedAt: 103)
        let watchlistSeeded = try await facade.setWatchlist(watchEntry, present: true, expected: watchlistBinding)
        try check(watchlistSeeded, "real native watchlist seed rejected")
        await facade.settled()
        let watchlistBefore = try VortxNativeWatchlist.entries(host: await session.hostPreferencesDocument(), profileID: NativeProfileSwitchAdmissionEnvironment.owner)
        let transportStateBefore = try decode(facade.stateData("native_state"))
        try check(transportStateBefore["libraries"]?[scope.ownerProfileID]?["items"]?.array?.isEmpty == false,
                  "real native library seed was not present")
        try check(transportStateBefore["libraries"]?[scope.ownerProfileID]?["watchContexts"]?["synthetic-movie"]?["durationMs"] == .integer(100_000),
                  "real native watch-progress seed was not present")
        let playbackStateBefore = try await session.playbackProjection()
        try check(playbackStateBefore["continueWatching"]?.array?.isEmpty == false,
                  "real native continue-watching projection was not present")
        try check(playbackStateBefore["resumeById"]?["synthetic-movie"]?["offsetMs"] == .integer(12_000),
                  "real native resume projection did not retain the seeded offset")
        let capture = CredentialScopeRegistry.shared.capture()
        CoreBridge.shared.install(facade, capture: capture)

        // Unknown flat values plus attributed-looking stamps exist before the first admitted mount.
        UserDefaults.standard.set("unknown-audio", forKey: TrackPreferences.Key.audio)
        UserDefaults.standard.set(["unknown-catalog"], forKey: ProfileDiscoveryPreferencesStore.Key.catalogOrder)
        manager.dirtySettings[TrackPreferences.Key.audio] = 111
        manager.dirtySettings[ProfileDiscoveryPreferencesStore.Key.catalogOrder] = 222
        let hostBeforeFailure = try await session.hostPreferencesDocument()
        try CoreBridge.shared.refreshNativeProfilesForHarness()
        try check(ProfileStore.shared.activeID == NativeProfileSwitchAdmissionEnvironment.owner, "owner roster did not mount")
        try check(ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.owner }?.addonPreferences == nil,
                  "owner nil add-on carrier was manufactured")
        try check(ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.viewer }?.addonPreferences != nil,
                  "explicit viewer add-on carrier was lost")
        try check(ProfileStore.shared.nativeProjectionTarget == nil, "failed journal parent mounted a preference projection")
        try check(UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) == "unknown-audio", "quarantine failure overwrote unknown playback")
        try check(UserDefaults.standard.stringArray(forKey: ProfileDiscoveryPreferencesStore.Key.catalogOrder) == ["unknown-catalog"], "quarantine failure overwrote unknown discovery")

        let admission = CoreBridge.shared.captureNativeProfileActionAdmission()
        try check(CoreBridge.shared.nativePlaybackTargetIsCurrent(admission.target), "actual picker admission did not capture the live native binding")
        try check(ProfileStore.shared.nativeProjectionTarget == nil, "picker admission manufactured a preference projection")
        let opened = await ProfileStore.shared.selectNative(ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.viewer }!, admission: admission, finishPicker: true)
        try check(opened, "fresh picker admission did not switch after quarantine failure")
        try check(ProfileStore.shared.pickedThisLaunch, "fresh picker did not finish")
        let hostAfterFailureSwitch = try await session.hostPreferencesDocument()
        try check(hostAfterFailureSwitch == hostBeforeFailure, "pure profile switch wrote host preferences")
        try check(UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) == "unknown-audio", "pure profile switch wrote native playback defaults")
        try check(UserDefaults.standard.stringArray(forKey: ProfileDiscoveryPreferencesStore.Key.catalogOrder) == ["unknown-catalog"], "pure profile switch wrote native discovery defaults")

        try FileManager.default.removeItem(at: intentParent)
        try FileManager.default.createDirectory(at: NativeProfileSwitchAdmissionEnvironment.journalRoot, withIntermediateDirectories: true)
        try CoreBridge.shared.refreshNativeProfilesForHarness()
        let recoveredJournalRoot = NativeProfileSwitchAdmissionEnvironment.journalRoot
        var recoveredStore = NativePreferenceIntentStore(directoryURL: recoveredJournalRoot, key: NativeProfileSwitchAdmissionEnvironment.key, namespace: capture.namespace)
        let quarantined = try recoveredStore.quarantined()
        try check(quarantined.count == 2, "successful retry did not preserve both flat projection evidences")
        let quarantinedByKey = Dictionary(uniqueKeysWithValues: quarantined.map { ($0.key, $0) })
        try check(quarantinedByKey[TrackPreferences.Key.audio]?.stamp == 111, "quarantined audio stamp changed")
        try check(quarantinedByKey[ProfileDiscoveryPreferencesStore.Key.catalogOrder]?.stamp == 222, "quarantined discovery stamp changed")
        guard let audioProjection = quarantinedByKey[TrackPreferences.Key.audio],
              let catalogProjection = quarantinedByKey[ProfileDiscoveryPreferencesStore.Key.catalogOrder] else {
            throw Failure.assertion("quarantined projection keys were not retained")
        }
        let audioEvidence = try quarantinedPlist(audioProjection)
        let catalogEvidence = try quarantinedPlist(catalogProjection)
        try check((audioEvidence as? String) == "unknown-audio", "quarantined audio value was not retained verbatim")
        try check((catalogEvidence as? [String]) == ["unknown-catalog"], "quarantined discovery value was not retained verbatim")
        try check(ProfileStore.shared.nativeProjectionTarget != nil, "successful quarantine retry did not mount projection")

        // Explicit nil/inherited fields remain nil over a pure away/back transition; the native
        // host group registers are the stronger clock witness than the UI projection.
        let hostBeforeNilCycle = try await session.hostPreferencesDocument()
        let viewerTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let owner = ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.owner }!
        let away = await ProfileStore.shared.selectNative(owner, target: viewerTarget, finishPicker: false)
        try check(away, "switch away from recovered viewer failed")
        let backTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let viewer = ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.viewer }!
        let back = await ProfileStore.shared.selectNative(viewer, target: backTarget, finishPicker: false)
        try check(back, "switch back to recovered viewer failed")
        let hostAfterNilCycle = try await session.hostPreferencesDocument()
        try check(hostAfterNilCycle == hostBeforeNilCycle, "nil/inherited switch changed host group clocks")

        // A failed outgoing save leaves both the active owner and its host registers untouched.
        // The edit remains in the flat carrier until the journal root is repaired; it is never
        // silently converted into an unauthenticated profile mutation.
        let ownerFailureTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let switchedToOwnerForFailure = await ProfileStore.shared.selectNative(owner, target: ownerFailureTarget, finishPicker: false)
        try check(switchedToOwnerForFailure, "switch to owner before failed-save proof failed")
        let failedSaveTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let failedSaveBaselineAudio = UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) ?? "en"
        let failedSaveParent = root.appendingPathComponent("failed-save-parent", isDirectory: false)
        try Data("regular-file-parent".utf8).write(to: failedSaveParent)
        NativeProfileSwitchAdmissionEnvironment.journalRoot = failedSaveParent
        let failedSaveHost = try await session.hostPreferencesDocument()
        let failedSavePending = try recoveredStore.pending()
        UserDefaults.standard.set("failed-audio", forKey: TrackPreferences.Key.audio)
        let failedSaveResult = await ProfileStore.shared.selectNative(viewer, target: failedSaveTarget, finishPicker: false)
        try check(!failedSaveResult, "failed journal save reached the native switch")
        try check(ProfileStore.shared.activeID == owner.id, "failed journal save changed the active owner")
        try check(try await session.hostPreferencesDocument() == failedSaveHost,
                  "failed journal save changed native host registers")
        try check(try recoveredStore.pending() == failedSavePending,
                  "failed journal save changed pending lineage")
        try check(UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) == "failed-audio",
                  "failed journal save discarded the flat edit")
        try FileManager.default.removeItem(at: failedSaveParent)
        NativeProfileSwitchAdmissionEnvironment.journalRoot = recoveredJournalRoot
        UserDefaults.standard.set(failedSaveBaselineAudio, forKey: TrackPreferences.Key.audio)
        let recoveredViewerAfterFailure = await ProfileStore.shared.selectNative(viewer,
                                                                                  target: failedSaveTarget,
                                                                                  finishPicker: false)
        try check(recoveredViewerAfterFailure, "repaired journal root did not permit a pure retry switch")

        // The first checkpoint ACK is deliberately held while a new flat edit is made. Normal
        // capture must reject the temporarily unbound target; selectNative then re-evaluates the
        // live flats and admits the newer value through the same durable save path.
        let stressOwnerTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let stressOwner = ProfileStore.shared.profiles.first { $0.id == owner.id }!
        let switchedToOwnerForStress = await ProfileStore.shared.selectNative(stressOwner, target: stressOwnerTarget, finishPicker: false)
        try check(switchedToOwnerForStress, "switch to owner before checkpoint stress failed")
        let stressTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let stressOwnerProfile = ProfileStore.shared.profiles.first { $0.id == owner.id }!
        UserDefaults.standard.set("it", forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 1001
        let stressHostBefore = try await session.hostPreferencesDocument()
        let stressEntryBefore = checkpointGate.entryCountSnapshot()
        checkpointGate.holdNext()
        let stressSelection = Task { @MainActor in
            await ProfileStore.shared.selectNative(viewer, target: stressTarget, finishPicker: false)
        }
        _ = try await checkpointGate.waitUntilEntered(after: stressEntryBefore)
        try check(!CoreBridge.shared.nativePlaybackTargetIsCurrent(stressTarget),
                  "native target remained current while outgoing checkpoint ACK was held")
        UserDefaults.standard.set("es", forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 1002
        let rejectedDuringStress = (try? manager.prepareNativePreferenceIntents(stressOwnerProfile,
                                                                                  target: stressTarget,
                                                                                  editedGroups: [.playback])) == nil
        try check(rejectedDuringStress, "normal preference capture admitted a target while its switch save was pending")
        try CoreBridge.shared.refreshNativeProfilesForHarness()
        try check(UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) == "es",
                  "authoritative native publication overwrote the newer flat edit")
        try check(try decode(facade.stateData("native_host_preferences")) == stressHostBefore,
                  "held outgoing checkpoint published host registers before ACK")
        let stressPendingDuring = try recoveredStore.pending()
        guard let firstStressIntent = stressPendingDuring.first(where: { $0.group == .playback }) else {
            throw Failure.assertion("held outgoing save did not prepare a playback receipt")
        }
        checkpointGate.release()
        let stressResult = await stressSelection.value
        try check(stressResult, "newer flat edit did not complete after checkpoint ACK")
        let stressPendingAfter = try recoveredStore.pending()
        guard let latestStressIntent = stressPendingAfter.first(where: { $0.group == .playback }) else {
            throw Failure.assertion("newer flat edit playback receipt was lost")
        }
        try check(latestStressIntent.desired["playback"]?["audioLang"] == .string("es"),
                  "newer flat edit was not the final admitted playback value")
        try checkPendingGeneration(latestStressIntent, store: recoveredStore, manager: manager,
                                   stamps: [TrackPreferences.Key.audio: 1002])
        try checkRetiredGeneration(firstStressIntent, successor: latestStressIntent, store: recoveredStore, manager: manager)
        let stressHostAfter = try await session.hostPreferencesDocument()
        try check(stressHostAfter["profiles"]?[scope.ownerProfileID]?["fields"]?["playback"]?["value"]?["audioLang"] == .string("es"),
                  "newer flat edit did not persist to the native host")

        // Repeat with an edit that returns to the old published value. The mutable capture witness
        // must keep that revert from being mistaken for stale inherited defaults while the first
        // save is in flight, and the bounded loop must journal the final value before switching.
        let revertOwnerTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let revertOwner = ProfileStore.shared.profiles.first { $0.id == owner.id }!
        let switchedToOwnerForRevertStress = await ProfileStore.shared.selectNative(revertOwner,
                                                                                     target: revertOwnerTarget,
                                                                                     finishPicker: false)
        try check(switchedToOwnerForRevertStress, "switch to owner before baseline-revert stress failed")
        let revertTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let revertOwnerProfile = ProfileStore.shared.profiles.first { $0.id == owner.id }!
        let publishedBaselineAudio = UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) ?? "en"
        UserDefaults.standard.set("de", forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 1101
        let revertHostBefore = try await session.hostPreferencesDocument()
        let revertEntryBefore = checkpointGate.entryCountSnapshot()
        checkpointGate.holdNext()
        let revertSelection = Task { @MainActor in
            await ProfileStore.shared.selectNative(viewer, target: revertTarget, finishPicker: false)
        }
        _ = try await checkpointGate.waitUntilEntered(after: revertEntryBefore)
        try check(!CoreBridge.shared.nativePlaybackTargetIsCurrent(revertTarget),
                  "baseline-revert target remained current while checkpoint ACK was held")
        UserDefaults.standard.set(publishedBaselineAudio, forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 1102
        let rejectedRevertCapture = (try? manager.prepareNativePreferenceIntents(revertOwnerProfile,
                                                                                   target: revertTarget,
                                                                                   editedGroups: [.playback])) == nil
        try check(rejectedRevertCapture, "baseline-revert normal capture admitted a pending target")
        try CoreBridge.shared.refreshNativeProfilesForHarness()
        try check(UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) == publishedBaselineAudio,
                  "authoritative publication overwrote the baseline revert")
        try check(try decode(facade.stateData("native_host_preferences")) == revertHostBefore,
                  "held baseline-revert checkpoint published host registers before ACK")
        let revertPendingDuring = try recoveredStore.pending()
        guard let firstRevertIntent = revertPendingDuring.first(where: { $0.group == .playback }) else {
            throw Failure.assertion("baseline-revert held save did not prepare a playback receipt")
        }
        checkpointGate.release()
        let revertResult = await revertSelection.value
        try check(revertResult, "baseline-revert edit did not complete after checkpoint ACK")
        let revertPendingAfter = try recoveredStore.pending()
        guard let latestRevertIntent = revertPendingAfter.first(where: { $0.group == .playback }) else {
            throw Failure.assertion("baseline-revert playback receipt was lost")
        }
        try check(latestRevertIntent.desired["playback"]?["audioLang"] == .string(publishedBaselineAudio),
                  "baseline-revert final value was not the published baseline")
        try checkPendingGeneration(latestRevertIntent, store: recoveredStore, manager: manager,
                                   stamps: [TrackPreferences.Key.audio: 1102])
        try checkRetiredGeneration(firstRevertIntent, successor: latestRevertIntent, store: recoveredStore, manager: manager)
        let revertHostAfter = try await session.hostPreferencesDocument()
        try check(revertHostAfter["profiles"]?[scope.ownerProfileID]?["fields"]?["playback"]?["value"]?["audioLang"] == .string(publishedBaselineAudio),
                  "baseline-revert final value did not persist to the native host")

        // Three admitted saves are the bounded retry budget. A fourth edit is still prepared in
        // the journal, but the active owner remains mounted and the native switch is refused.
        let exhaustionOwnerTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let exhaustionOwner = ProfileStore.shared.profiles.first { $0.id == owner.id }!
        let switchedToOwnerForExhaustion = await ProfileStore.shared.selectNative(exhaustionOwner,
                                                                                   target: exhaustionOwnerTarget,
                                                                                   finishPicker: false)
        try check(switchedToOwnerForExhaustion, "switch to owner before bounded retry proof failed")
        let exhaustionTarget = CoreBridge.shared.captureNativePlaybackTarget()
        UserDefaults.standard.set("ja", forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 1201
        checkpointGate.holdNext()
        let exhaustionSelection = Task { @MainActor in
            await ProfileStore.shared.selectNative(viewer, target: exhaustionTarget, finishPicker: false)
        }
        let firstExhaustionEntryBefore = checkpointGate.entryCountSnapshot()
        let firstExhaustionEntry = try await checkpointGate.waitUntilEntered(after: firstExhaustionEntryBefore)
        let firstExhaustionPending = try recoveredStore.pending()
        guard let firstExhaustionIntent = firstExhaustionPending.first(where: { $0.group == .playback }) else {
            throw Failure.assertion("bounded retry first playback receipt was not prepared")
        }
        UserDefaults.standard.set("ko", forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 1202
        checkpointGate.holdNext()
        checkpointGate.release()
        let secondExhaustionEntry = try await checkpointGate.waitUntilEntered(after: firstExhaustionEntry)
        guard let secondExhaustionIntent = try recoveredStore.pending().first(where: { $0.group == .playback }) else {
            throw Failure.assertion("bounded retry second generation was not prepared")
        }
        UserDefaults.standard.set("pt", forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 1203
        checkpointGate.holdNext()
        checkpointGate.release()
        let thirdExhaustionEntry = try await checkpointGate.waitUntilEntered(after: secondExhaustionEntry)
        guard let thirdExhaustionIntent = try recoveredStore.pending().first(where: { $0.group == .playback }) else {
            throw Failure.assertion("bounded retry third generation was not prepared")
        }
        UserDefaults.standard.set("nl", forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 1204
        checkpointGate.release()
        _ = thirdExhaustionEntry
        let exhaustionResult = await exhaustionSelection.value
        try check(!exhaustionResult, "continuous flat edits exceeded the bounded switch retry budget")
        try check(ProfileStore.shared.activeID == owner.id,
                  "bounded retry failure changed the active owner")
        let exhaustionPending = try recoveredStore.pending()
        guard let latestExhaustionIntent = exhaustionPending.first(where: { $0.group == .playback }) else {
            throw Failure.assertion("bounded retry latest playback receipt was lost")
        }
        try check(latestExhaustionIntent.desired["playback"]?["audioLang"] == .string("nl"),
                  "bounded retry did not retain the latest flat value")
        try check(Set([firstExhaustionIntent.id, secondExhaustionIntent.id, thirdExhaustionIntent.id, latestExhaustionIntent.id]).count == 4,
                  "bounded retry did not retain evidence of three distinct saves and the final pending edit")
        try checkPendingGeneration(latestExhaustionIntent, store: recoveredStore, manager: manager,
                                   stamps: [TrackPreferences.Key.audio: 1204])
        try checkRetiredGeneration(firstExhaustionIntent, successor: secondExhaustionIntent, store: recoveredStore, manager: manager)
        try checkRetiredGeneration(secondExhaustionIntent, successor: thirdExhaustionIntent, store: recoveredStore, manager: manager)
        try checkRetiredGeneration(thirdExhaustionIntent, successor: latestExhaustionIntent, store: recoveredStore, manager: manager)
        let exhaustionHost = try await session.hostPreferencesDocument()
        try check(exhaustionHost["profiles"]?[scope.ownerProfileID]?["fields"]?["playback"]?["value"]?["audioLang"] == .string("pt"),
                  "bounded retry failure wrote the unadmitted fourth value to the native host")
        try check(UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) == "nl",
                  "bounded retry failure discarded the latest flat value")

        // Ordinary edit/ABA scenarios are independent of the cumulative stress journal's byte
        // budget. Retain that journal verbatim; do not clear its unacknowledged intent, fabricate
        // a cloud ACK, or change production bounds to make the following scenarios fit.
        let retainedStressStore = recoveredStore
        let retainedStressQuarantine = try retainedStressStore.quarantined()
        try check(quarantined.allSatisfy(retainedStressQuarantine.contains),
                  "stress scenarios lost the original unknown projection evidence")
        let retainedStressFiles = try Dictionary(uniqueKeysWithValues:
            FileManager.default.contentsOfDirectory(at: recoveredJournalRoot, includingPropertiesForKeys: nil).map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
        let ordinaryJournalRoot = root.appendingPathComponent("ordinary-edit-intents", isDirectory: true)
        NativeProfileSwitchAdmissionEnvironment.journalRoot = ordinaryJournalRoot
        recoveredStore = NativePreferenceIntentStore(directoryURL: ordinaryJournalRoot,
            key: NativeProfileSwitchAdmissionEnvironment.key, namespace: capture.namespace)
        try check(try recoveredStore.pending().isEmpty, "independent ordinary-edit journal was not fresh")

        // A real flat edit follows the ordinary prepare -> saveNative -> CoreBridge mutation path.
        let ownerAdmissionTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let switchedToOwner = await ProfileStore.shared.selectNative(owner, target: ownerAdmissionTarget, finishPicker: false)
        try check(switchedToOwner, "switch to owner before genuine edit failed")
        let activeOwnerTarget = CoreBridge.shared.captureNativePlaybackTarget()
        UserDefaults.standard.set("fr", forKey: TrackPreferences.Key.audio)
        UserDefaults.standard.set(["fr-catalog"], forKey: ProfileDiscoveryPreferencesStore.Key.catalogOrder)
        manager.dirtySettings[TrackPreferences.Key.audio] = 2001
        manager.dirtySettings[ProfileDiscoveryPreferencesStore.Key.catalogOrder] = 2002
        let switchedToViewer = await ProfileStore.shared.selectNative(viewer, target: activeOwnerTarget, finishPicker: false)
        if !switchedToViewer {
            let diagnostics = try recoveredStore.pending().map {
                "group=\($0.group) lineage=\($0.supersededIDs.count) accepted=\($0.acceptedBases.count) conflict=\($0.requiresResolution)"
            }
            print("synthetic owned-edit diagnostics \(diagnostics.joined(separator: "; "))")
        }
        try check(switchedToViewer, "genuine owned edit did not admit switch")
        let pendingAfterSave = try recoveredStore.pending()
        for (group, stamps) in [(NativePreferenceIntentStore.Group.playback, [TrackPreferences.Key.audio: 2001.0]),
                                (.discovery, [ProfileDiscoveryPreferencesStore.Key.catalogOrder: 2002.0])] {
            guard let pending = pendingAfterSave.first(where: { $0.group == group }) else {
                throw Failure.assertion("native save cleared a group before its matching cloud acknowledgement")
            }
            try checkPendingGeneration(pending, store: recoveredStore, manager: manager, stamps: stamps)
            let snapshot = try manager.preferenceSnapshotForHarness(profileID: owner.id, group: group)
            try check(snapshot.value == pending.desired, "saved group differs from its pending desired value")
            try check(try recoveredStore.authorizesAcknowledgement(pending, current: snapshot),
                      "exact current cloud receipt was not authorized")
            try check(try recoveredStore.pending() == pendingAfterSave, "read-only cloud acknowledgement preflight consumed the pending edit")
        }
        let hostAfterSave = try await session.hostPreferencesDocument()
        try check(hostAfterSave["profiles"]?[scope.ownerProfileID]?["fields"]?["playback"]?["value"]?["audioLang"] == .string("fr"),
                  "normal save did not persist the edited playback value in the native host")
        try check(hostAfterSave["profiles"]?[scope.ownerProfileID]?["fields"]?["discovery"]?["value"]?["catalogOrder"] == .array([.string("fr-catalog")]),
                  "normal save did not persist the edited discovery value in the native host")

        // Same-group playback revert is positive local evidence, not a no-op profile switch.
        let ownerAfterEdit = ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.owner }!
        let ownerForRevertTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let switchedToOwnerForRevert = await ProfileStore.shared.selectNative(ownerAfterEdit, target: ownerForRevertTarget, finishPicker: false)
        try check(switchedToOwnerForRevert, "switch to owner before local revert failed")
        let ownerTarget = CoreBridge.shared.captureNativePlaybackTarget()
        let mountedOwner = ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.owner }!
        var playbackDraft = mountedOwner
        guard var draftPlayback = playbackDraft.playback else { throw Failure.assertion("owner playback edit did not mount") }
        draftPlayback.audioLang = "de"
        playbackDraft.playback = draftPlayback
        UserDefaults.standard.set("de", forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 2003
        let draft = try manager.prepareNativePreferenceIntents(playbackDraft, target: ownerTarget, editedGroups: [.playback])
        guard let draftIntent = draft.first(where: { $0.group == .playback }) else { throw Failure.assertion("playback draft did not prepare") }
        UserDefaults.standard.set("fr", forKey: TrackPreferences.Key.audio)
        manager.dirtySettings[TrackPreferences.Key.audio] = 2004
        try check(manager.nativePreferenceIsLocalRevert(mountedOwner, group: .playback, target: ownerTarget), "same-group playback local revert was not recognized")
        let switchedAfterRevert = await ProfileStore.shared.selectNative(
            ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.viewer }!,
            target: ownerTarget, finishPicker: false)
        try check(switchedAfterRevert, "playback revert switch did not complete")
        let pendingAfterRevert = try recoveredStore.pending()
        guard let reverted = pendingAfterRevert.first(where: { $0.group == .playback }) else {
            throw Failure.assertion("playback revert receipt was lost")
        }
        try check(reverted.id != draftIntent.id && !reverted.supersededIDs.contains(draftIntent.id),
                  "playback revert did not retire the draft generation")
        try check(reverted.desired["playback"]?["audioLang"] == .string("fr"), "playback revert desired value was not the acknowledged fr projection")
        try checkPendingGeneration(reverted, store: recoveredStore, manager: manager,
                                   stamps: [TrackPreferences.Key.audio: 2004])
        try check(!manager.nativePreferenceAdmissionGate.admits([draftIntent]) { true }, "uncommitted draft regained admission after revert")

        // The original target is now stale after the next switch; rejected ABA admission must not
        // erase the pending receipt prepared above.
        let staleTarget = ownerTarget
        let pendingBeforeABA = try recoveredStore.pending()
        let viewerTargetForABA = CoreBridge.shared.captureNativePlaybackTarget()
        let switchedBackToOwner = await ProfileStore.shared.selectNative(
            ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.owner }!,
            target: viewerTargetForABA, finishPicker: false)
        try check(switchedBackToOwner, "B-to-A ABA setup switch failed")
        let credentialTarget = CoreBridge.shared.captureNativePlaybackTarget()
        try check(CoreBridge.shared.nativePlaybackTargetIsCurrent(credentialTarget), "B-to-A target was not current before credential retirement")
        let rejected = (try? manager.nativePreferenceAdmission([draftIntent], profile: playbackDraft, target: staleTarget)) == nil
        try check(rejected, "stale profile/account target admitted old preference receipt")
        let pendingAfterABA = try recoveredStore.pending()
        try check(pendingAfterABA == pendingBeforeABA, "stale target admission changed pending journal lineage")
        let hostBeforeStaleSelection = try await session.hostPreferencesDocument()
        let rejectedStaleSelection = await ProfileStore.shared.selectNative(
            ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.viewer }!,
            target: staleTarget, finishPicker: false)
        try check(!rejectedStaleSelection, "stale profile target reached the native switch")
        let hostAfterStaleSelection = try await session.hostPreferencesDocument()
        try check(hostAfterStaleSelection == hostBeforeStaleSelection,
                  "stale profile selection changed the native host")
        let pendingAfterStaleSelection = try recoveredStore.pending()
        try check(pendingAfterStaleSelection == pendingBeforeABA,
                  "stale profile selection changed pending journal lineage")

        // A same-namespace credential reinstall is a distinct ownership generation. Reusing the
        // original target must fail closed while its encrypted pending receipt remains recoverable.
        let pendingBeforeCredentialABA = pendingAfterABA
        let hostBeforeCredentialSelection = try await session.hostPreferencesDocument()
        CredentialScopeRegistry.shared.retire()
        let freshCapture = CredentialScopeRegistry.shared.capture()
        CoreBridge.shared.install(facade, capture: freshCapture)
        let freshTarget = CoreBridge.shared.captureNativePlaybackTarget()
        try check(freshTarget != credentialTarget, "credential generation ABA did not change the native target")
        let credentialRejected = (try? manager.nativePreferenceAdmission([draftIntent], profile: playbackDraft, target: credentialTarget)) == nil
        try check(credentialRejected, "retired credential generation admitted an old preference receipt")
        let rejectedCredentialSelection = await ProfileStore.shared.selectNative(
            ProfileStore.shared.profiles.first { $0.id == NativeProfileSwitchAdmissionEnvironment.viewer }!,
            target: credentialTarget, finishPicker: false)
        try check(!rejectedCredentialSelection, "retired credential target reached the native switch")
        let hostAfterCredentialSelection = try await session.hostPreferencesDocument()
        try check(hostAfterCredentialSelection == hostBeforeCredentialSelection,
                  "retired credential selection changed the native host")
        let pendingAfterCredentialSelection = try recoveredStore.pending()
        try check(pendingAfterCredentialSelection == pendingBeforeCredentialABA, "credential ABA admission changed pending journal lineage")

        // An actual peer merge retires the current native target while its checkpoint is pending.
        // A genuine local receipt prepared before that transition remains durable and its flat
        // value remains recoverable; ProfileStore must reject the stale picker action.
        try CoreBridge.shared.refreshNativeProfilesForHarness()
        let peerTarget = CoreBridge.shared.captureNativePlaybackTarget()
        try check(ProfileStore.shared.nativePreferenceProjectionMatches(peerTarget),
                  "fresh credential installation did not remount the native preference projection")
        let peerOwnerProfile = ProfileStore.shared.profiles.first { $0.id == owner.id }!
        var peerLocalProfile = peerOwnerProfile
        guard var peerLocalPlayback = peerLocalProfile.playback else {
            throw Failure.assertion("peer-publication proof requires the acknowledged owner playback")
        }
        peerLocalPlayback.audioLang = "peer-local"
        peerLocalProfile.playback = peerLocalPlayback
        UserDefaults.standard.set("peer-local", forKey: TrackPreferences.Key.audio)
        let peerIntents = try manager.prepareNativePreferenceIntents(peerLocalProfile,
                                                                      target: peerTarget,
                                                                      editedGroups: [.playback])
        guard let peerIntent = peerIntents.first(where: { $0.group == .playback }) else {
            throw Failure.assertion("peer-publication local receipt did not prepare")
        }
        let peerPendingBefore = try recoveredStore.pending()
        let peerHostBefore = try await session.hostPreferencesDocument()
        guard let peerNativeRemote = try decode(facade.stateData("native_state"))["nativeSync"] else {
            throw Failure.assertion("peer transition requires the actual acknowledged native sync carrier")
        }
        var peerCarrier = try VortxNativeHostPreferences(scope: scope,
                                                          actor: "30000000-0000-0000-0000-000000000043")
        try peerCarrier.merge(peerHostBefore, scope: scope)
        try peerCarrier.edit(profileID: scope.ownerProfileID, fields: ["playback": .null], scope: scope)
        let peerHostRemote = try peerCarrier.document
        let peerEntryBefore = checkpointGate.entryCountSnapshot()
        checkpointGate.holdNext()
        let peerPublication = Task { try await facade.mergeAccountDocument(peerNativeRemote,
                                                                            hostRemote: peerHostRemote,
                                                                            legacyMaterial: nil) }
        _ = try await checkpointGate.waitUntilEntered(after: peerEntryBefore)
        try check(!CoreBridge.shared.nativePlaybackTargetIsCurrent(peerTarget),
                  "actual peer transition did not retire the native target")
        let peerSelectionResult = await ProfileStore.shared.selectNative(viewer, target: peerTarget, finishPicker: false)
        try check(!peerSelectionResult, "peer transition stale picker action reached the native switch")
        try check(ProfileStore.shared.activeID == owner.id, "peer transition stale picker changed the active owner")
        try check(try recoveredStore.pending() == peerPendingBefore,
                  "peer transition stale picker changed local journal lineage")
        try check(UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) == "peer-local",
                  "peer transition stale picker discarded the local flat value")
        checkpointGate.release()
        _ = try await peerPublication.value
        try CoreBridge.shared.refreshNativeProfilesForHarness()
        let peerHostAfter = try await session.hostPreferencesDocument()
        try check(peerHostAfter["profiles"]?[scope.ownerProfileID]?["fields"]?["playback"]?["value"] == .null,
                  "actual peer transition did not install the nil/inherited register")
        try check(try recoveredStore.pending() == peerPendingBefore,
                  "peer transition publication discarded the prepared local receipt")
        let retainedPeerIntent = try recoveredStore.pending().first(where: { $0.id == peerIntent.id })
        try check(retainedPeerIntent?.id == peerIntent.id,
                  "peer transition publication replaced the prepared local receipt")
        try check(UserDefaults.standard.string(forKey: TrackPreferences.Key.audio) == "peer-local",
                  "peer transition publication overwrote the local flat value")

        try check(try retainedStressStore.pending() == exhaustionPending,
                  "independent scenarios changed the retained stress intent")
        try check(try retainedStressStore.quarantined() == retainedStressQuarantine,
                  "independent scenarios changed the retained projection evidence")
        let finalStressFiles = try Dictionary(uniqueKeysWithValues:
            FileManager.default.contentsOfDirectory(at: recoveredJournalRoot, includingPropertiesForKeys: nil).map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
        try check(finalStressFiles == retainedStressFiles, "independent scenarios changed the stress journal bytes")

        // Native transport carriers seeded before the profile work must remain byte-identical.
        let finalState = try decode(facade.stateData("native_state"))
        let initialState = transportStateBefore
        try check(finalState["libraries"]?[scope.ownerProfileID]?["items"] == initialState["libraries"]?[scope.ownerProfileID]?["items"],
                  "seeded native library carrier changed")
        try check(finalState["libraries"]?[scope.ownerProfileID]?["watchContexts"] == initialState["libraries"]?[scope.ownerProfileID]?["watchContexts"],
                  "seeded native watch-progress carrier changed")
        let playbackStateAfter = try await session.playbackProjection()
        try check(playbackStateAfter["continueWatching"] == playbackStateBefore["continueWatching"],
                  "seeded native continue-watching projection changed")
        try check(playbackStateAfter["resumeById"]?["synthetic-movie"]?["offsetMs"] == .integer(12_000),
                  "seeded native resume projection changed")
        let watchlistAfter = try VortxNativeWatchlist.entries(host: await session.hostPreferencesDocument(), profileID: NativeProfileSwitchAdmissionEnvironment.owner)
        try check(watchlistAfter == watchlistBefore, "seeded native watchlist carrier changed")
        await facade.shutdown()
    }

    struct NoResources: VortxResourceTransport {
        final class Cancellation: VortxResourceCancellation, @unchecked Sendable { func cancel() {} }
        func makeCancellation() throws -> any VortxResourceCancellation { Cancellation() }
        func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String { throw VortxNativeError.unavailable }
    }
}
