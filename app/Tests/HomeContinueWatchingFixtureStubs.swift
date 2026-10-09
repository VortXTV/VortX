import Foundation

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
    var eligible = true
    func capture() -> Capture { .init(namespace: "inert-account", generation: generation) }
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

final class CoreBridge {
    static let shared = CoreBridge()
    var usesNativeProfileState = true
    var continueWatching: [CoreCWItem] = []
    var library: CoreLibrary?
    var nativeBinding: PlaybackMutationOwnershipPolicy.NativeBinding?
    var beforeNativeCurrentCheck: (() -> Void)?

    func captureNativePlaybackTarget() -> PlaybackMutationTarget { .native(nativeBinding) }
    func nativePlaybackTargetIsCurrent(_ target: PlaybackMutationTarget) -> Bool {
        beforeNativeCurrentCheck?()
        return PlaybackMutationOwnershipPolicy.allowsNative(target, binding: nativeBinding)
    }
}

final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID?
    var activeUsesEngineHistory = true
    var cwItems: [CoreCWItem] = []
    var active: UserProfile?
}
struct UserProfile {
    struct PlaybackPrefs: Equatable {}
    let id: UUID
    var usesEngineHistory: Bool = true
    var discovery: ProfileDiscoveryPreferences? = nil
    var playback: PlaybackPrefs? = nil
}

struct CoreLibrary { let catalog: [CoreCWItem] }
struct CoreCWItem {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let state: CoreLibState
    var resumeSeconds: Double { state.timeOffset / 1000 }
    var progress: Double { state.duration > 0 ? state.timeOffset / state.duration : 0 }
    var isFinished: Bool { progress >= 0.95 }
    var removed: Bool? { nil }
    var temp: Bool? { nil }
}
enum EpisodePlaybackIdentity { static func usesSeriesLifecycle(type: String) -> Bool { type == "series" } }
enum TopShelfSnapshot {
    static let maxItems = 8
    struct Item { let id: String; let type: String; let title: String; let poster: String?; let progress: Double }
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
