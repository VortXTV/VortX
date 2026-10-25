import Foundation
import os

// PRODUCTION_HOME_PROFILE_SELECTION_READ

// Shadow Foundation's persistence API with RAM only. These executable fixtures cannot
// edit the installed app's UserDefaults, Keychain, credentials, or watch-history cache.
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func reset() { values = [:] }
}
enum TabBarPrefs {
    static let hideLive = "fixture.hideLive", hideDiscover = "fixture.hideDiscover"
    static let hideLibrary = "fixture.hideLibrary", hideSearch = "fixture.hideSearch"
}

// Isolated fixtures for the production selector/shadow. No live Keychain, cache path,
// account, native library, or provider transport is linked into this executable.
final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    var generation: UInt64 = 1
    var namespace = "inert-account"
    var eligible = true
    func capture() -> Capture { .init(namespace: namespace, generation: generation) }
    func isCurrent(_ value: Capture) -> Bool { value == capture() }
    func isMigrationEligible(_ value: Capture) -> Bool { eligible && isCurrent(value) }
    struct Capture: Hashable, Sendable {
        let namespace: String
        let generation: UInt64
    }
}

typealias PlaybackMutationTarget = PlaybackMutationOwnershipPolicy.Target

extension PlaybackMutationTarget {
    static func capture(core: CoreBridge) -> Self { core.captureNativePlaybackTarget() }
    func stillOwnsCurrentContext(core: CoreBridge) -> Bool { core.nativePlaybackTargetIsCurrent(self) }
}

// The exact production capability and Facade binding declarations are materialized below.
// The installation/epoch store and immutable Facade are explicit RAM collaborators only;
// they exercise read predicates without asserting the real B/F capture or SDK protocol.
struct VortxAccountScope: Equatable, Sendable {
    let account: String
    let ownerProfileID: String
}
final class VortxNativeCoreFacade: Sendable {
    // PRODUCTION_HOME_NATIVE_FACADE_BINDINGS
    let sourceID = UUID()
    let isAvailable = true
    let registryBinding: RegistryBinding?
    let watchlistBinding: WatchlistBinding?
    init(binding: PlaybackMutationOwnershipPolicy.NativeBinding, account: UUID) {
        let scope = VortxAccountScope(account: binding.credential.namespace, ownerProfileID: binding.profileID.uuidString)
        registryBinding = .init(scope: scope, profileID: binding.profileID.uuidString, generation: UUID())
        watchlistBinding = .init(scope: scope, profileID: binding.profileID.uuidString,
            accountGeneration: account, profileGeneration: UUID())
    }
}
final class HomeFixtureNativeReadAdmission: Sendable {
    private struct State: Sendable {
        var binding: PlaybackMutationOwnershipPolicy.NativeBinding?
        var facade: VortxNativeCoreFacade?
        var installation = UUID()
        var epoch: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func install(_ binding: PlaybackMutationOwnershipPolicy.NativeBinding?) {
        state.withLock { value in
            value.binding = binding
            value.facade = binding.flatMap { binding in
                binding.accountGeneration.map { VortxNativeCoreFacade(binding: binding, account: $0) }
            }
            value.installation = UUID(); value.epoch &+= 1
        }
    }
    func capture(_ binding: PlaybackMutationOwnershipPolicy.NativeBinding) -> (UUID, UInt64, VortxNativeCoreFacade)? {
        state.withLock { value in
            guard value.binding == binding, let facade = value.facade else { return nil }
            return (value.installation, value.epoch, facade)
        }
    }
    func acceptsInstallation(_ original: UUID, binding: PlaybackMutationOwnershipPolicy.NativeBinding) -> Bool {
        state.withLock { $0.installation == original && $0.binding == binding }
    }
    func acceptsEpoch(_ original: UInt64) -> Bool { state.withLock { $0.epoch == original } }
}
final class CoreBridge {
    static let shared = CoreBridge()
    // PRODUCTION_HOME_NATIVE_READ_CAPABILITY
    private let nativeReadAdmission = HomeFixtureNativeReadAdmission()
    var usesNativeProfileState = true {
        didSet { if oldValue != usesNativeProfileState { nativeReadAdmission.install(nativeBinding) } }
    }
    var continueWatching: [CoreCWItem] = []
    var library: CoreLibrary?
    var nativeBinding: PlaybackMutationOwnershipPolicy.NativeBinding? {
        didSet { nativeReadAdmission.install(nativeBinding) }
    }
    var beforeNativeCurrentCheck: (() -> Void)?

    func captureNativePlaybackTarget() -> PlaybackMutationTarget { .native(nativeBinding) }
    @MainActor
    func captureNativePlaybackReadCapability(_ target: PlaybackMutationTarget) -> NativePlaybackReadCapability? {
        guard usesNativeProfileState, case .native(let binding?) = target,
              PlaybackMutationOwnershipPolicy.allowsNative(target, binding: nativeBinding),
              let account = binding.accountGeneration,
              let (installation, epoch, facade) = nativeReadAdmission.capture(binding) else { return nil }
        let admission = nativeReadAdmission
        guard let facadeBinding = facade.watchlistBinding else { return nil }
        let owner = NativePlaybackReadCapability(binding: binding, publishedAccount: account,
            facadeBinding: facadeBinding, publicationEpoch: epoch, sourceID: facade.sourceID, facade: facade,
            originalInstallationIsCurrent: { admission.acceptsInstallation(installation, binding: binding) },
            originalEpochIsCurrent: { admission.acceptsEpoch(epoch) })
        return owner.isCurrent() ? owner : nil
    }
    func nativePlaybackTargetIsCurrent(_ target: PlaybackMutationTarget) -> Bool {
        beforeNativeCurrentCheck?()
        return PlaybackMutationOwnershipPolicy.allowsNative(target, binding: nativeBinding)
    }
}

#if CW_BASELINE || CW_SERVICE_BASELINE
// Interface adaptation ONLY for the frozen historical selector's obsolete call shape.
// Its selection body remains exact. Candidate GREEN has no no-owner shadow overload.
extension TraktPlaybackShadow {
    @MainActor
    func continueWatchingSelection(fallback: [CoreCWItem], libraryItems: [CoreCWItem] = []) -> ContinueWatchingSelection {
        guard let context = HomeContinueWatchingSelection.captureContext(core: .shared),
              let target = context.nativeTarget,
              let owner = CoreBridge.shared.captureNativePlaybackReadCapability(target),
              context.isCurrent(owner: owner) else {
            return .init(items: fallback, source: .local, sessionID: nil)
        }
        return continueWatchingSelection(fallback: fallback, libraryItems: libraryItems,
            context: context, owner: owner)
    }
}
#endif

@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    var profiles: [UserProfile] = [] {
        willSet { ProfileSelectionRead.beginMutation() }
        didSet { ProfileSelectionRead.endMutation(selectionReadSnapshot()) }
    }
    var activeID: UUID? {
        willSet { ProfileSelectionRead.beginMutation() }
        didSet { ProfileSelectionRead.endMutation(selectionReadSnapshot()) }
    }
    private var unboundFixtureEligibility = true
    var activeUsesEngineHistory: Bool {
        get { active?.usesEngineHistory ?? unboundFixtureEligibility }
        set {
            unboundFixtureEligibility = newValue
            if var profile = active { profile.usesEngineHistory = newValue; active = profile }
        }
    }
    var cwItems: [CoreCWItem] = []
    var active: UserProfile? {
        get { profiles.first { $0.id == activeID } }
        set {
            if let profile = newValue {
                if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
                else { profiles.append(profile) }
            } else if let id = activeID { profiles.removeAll { $0.id == id } }
        }
    }
    private init() { ProfileSelectionRead.publishInitial(selectionReadSnapshot()) }
    // PRODUCTION_HOME_PROFILE_SELECTION_PROJECTOR
}
struct UserProfile: Equatable {   // Equatable like the real profile (applyNativeProfiles compares rosters)
    struct PlaybackPrefs: Equatable {}
    let id: UUID
    var usesEngineHistory: Bool = true
    // Compatibility with the real scalar projector; old fixtures model eligibility as one flag.
    var isOwner: Bool { usesEngineHistory }
    var usesOwnAccount: Bool { false }
    var discovery: ProfileDiscoveryPreferences? = nil
    var playback: PlaybackPrefs? = nil
    var addonPreferences: ProfileAddonPreferences? = nil
    var accentID = "ember"
    var oled = false
    var textScale = 1.0
}
struct ProfileAddonPreferences: Equatable {}

struct CoreLibrary { let catalog: [CoreCWItem] }
// Next-episode behavior is outside this broad selector fixture; this inert collaborator
// accepts the current original-owner signature and never manufactures a next-episode offer.
struct TraktNextEpisodeOffer {}
final class TraktHomeNextEpisodeProducer {
    static let shared = TraktHomeNextEpisodeProducer()
    func requestRefresh(intent: HomeContinueWatchingSelection.Intent, core: CoreBridge) {}
    func offers(intent: HomeContinueWatchingSelection.Intent, owner: CoreBridge.NativePlaybackReadCapability, paused: [CoreCWItem], now: Date) -> [TraktNextEpisodeOffer] { [] }
}
struct CoreCWItem {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let state: CoreLibState
    var resumeSeconds: Double { state.timeOffset / 1000 }
    var progress: Double { state.duration > 0 ? state.timeOffset / state.duration : 0 }
    var isFinished: Bool { progress >= 0.95 }
    var isUpNext: Bool { false }   // fixtures carry no watched flag
    var removed: Bool? { nil }
    var temp: Bool? { nil }
}
enum EpisodePlaybackIdentity { static func usesSeriesLifecycle(type: String) -> Bool { type == "series" } }
enum TopShelfSnapshot {
    static let maxItems = 8
    struct Item: Equatable { let id: String; let type: String; let title: String; let poster: String?; let progress: Double }
}
struct CoreLibState {
    let timeOffset: Double
    let duration: Double
    let videoId: String?
    var lastWatched: String? = nil
}
struct PlaybackMeta {
    let libraryId: String
    let usesSeriesLifecycle: Bool
    let season: Int?
    let episode: Int?
}

enum ExternalSyncToggle {
    static let traktContinueWatching = "vortx.trakt.continueWatching"
    static let traktResumeSuggestion = "fixture.trakt.resumeSuggestion"
    static var enabled = true
    static func isOn(_ key: String, default defaultOn: Bool = true) -> Bool { enabled }
}

actor TraktAuth {
    static let shared = TraktAuth()
    static var isConfigured: Bool { false }
    static var clientID: String { "fixture" }
    static var apiBase: String { "https://provider.invalid" }
    nonisolated(unsafe) static var storedSessionID: TraktSessionID?
    var sessionID: TraktSessionID? { Self.storedSessionID }
    func validToken(for sessionID: TraktSessionID) async throws -> String {
        fatalError("Offline CW fixture must never request a provider credential")
    }
    func signOut(ifCurrent sessionID: TraktSessionID) async {
        fatalError("Offline CW fixture must never mutate provider authentication")
    }
}

struct AuthenticatedHTTPResponse {
    let statusCode: Int
    let data: Data
}
struct AuthenticatedHTTPTransport {
    static let shared = AuthenticatedHTTPTransport()
    static let snapshotResponseLimit = 1
    func send(_ request: URLRequest, allowedHosts: Set<String>, maxResponseBytes: Int) async throws -> AuthenticatedHTTPResponse {
        fatalError("Offline CW fixture must never reach provider transport")
    }
    static func jsonObject(from data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data) }
}

struct TraktPlaybackCacheSnapshot {
    let sessionID: TraktSessionID
    var progress: [String: Double]
    var stamp: String?
    var activity: TraktPlaybackActivityStamps?
    var items: [TraktContinueWatchingSeed]
    var hasSnapshot: Bool
}
enum TraktPlaybackCacheError: String, Error { case fixture }
struct TraktPlaybackCacheStorage {
    static var snapshot: TraktPlaybackCacheSnapshot?
    static func live() throws -> Self { Self() }
    func load(for sessionID: TraktSessionID) throws -> TraktPlaybackCacheSnapshot? {
        Self.snapshot.flatMap { $0.sessionID == sessionID ? $0 : nil }
    }
    func reset() throws {}
    func save(_ snapshot: TraktPlaybackCacheSnapshot) throws {
        Self.snapshot = snapshot // RAM only, not the production cache/storage implementation
    }
}
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }

struct SIMKLSessionID: RawRepresentable, Codable, Hashable, Sendable { let rawValue: String }
enum SIMKLError: Error { case decoding, sessionChanged, badURL, fixture }
enum SIMKLAuth {
    static var isConfigured = true
    static var storedSessionID: SIMKLSessionID?
    static let apiBase = "https://api.simkl.com"
    static let clientID = "inert-client", userAgent = "inert-fixture"
    static let requiredQueryItems = [URLQueryItem(name: "extended", value: "full")]
}
enum SIMKLAuthBoundary {
    private static var observers: [String: (SIMKLSessionID?) -> Void] = [:]
    static func observe(key: String, _ callback: @escaping (SIMKLSessionID?) -> Void) { observers[key] = callback }
    static func emit(_ session: SIMKLSessionID?) { observers.values.forEach { $0(session) } }
}
// Implements the real reader's transport seam, returning only explicit fixture bytes.
actor SIMKLService: SIMKLContinueWatchingTransport {
    static let shared = SIMKLService()
    struct Request: Equatable { let path: String; let query: [String: String] }
    var requests: [Request] = []
    private var responses: [String: Data] = [:]
    private var failure: String?
    func configure(_ responses: [String: String], failure: String? = nil) {
        self.responses = responses.mapValues { Data($0.utf8) }; self.failure = failure; requests = []
    }
    nonisolated func continueWatchingSessionIsCurrent(_ session: SIMKLSessionID) -> Bool { SIMKLAuth.storedSessionID == session }
    func continueWatchingRead(path: String, query: [String: String], session: SIMKLSessionID) async throws -> Data {
        guard continueWatchingSessionIsCurrent(session) else { throw SIMKLError.sessionChanged }
        requests.append(.init(path: path, query: query))
        if path == failure { throw SIMKLError.fixture }
        guard let data = responses[path] else { fatalError("Unscripted fixture transport leg: \(path)") }
        return data
    }
}
