import Foundation

// Isolated fixtures for the production selector/shadow. No live Keychain, cache path,
// account, native library, or provider transport is linked into this executable.
enum CredentialScopeRegistry {
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
}

struct CoreLibrary { let catalog: [CoreCWItem] }
struct CoreCWItem {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let state: CoreLibState
    var resumeSeconds: Double { state.timeOffset / 1000 }
}
struct CoreLibState {
    let timeOffset: Double
    let duration: Double
    let videoId: String?
}
struct PlaybackMeta {
    let libraryId: String
    let usesSeriesLifecycle: Bool
    let season: Int?
    let episode: Int?
}

enum ExternalSyncToggle {
    static let traktContinueWatching = "fixture.trakt.continueWatching"
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
        fatalError("Offline CW fixture must not author a playback snapshot")
    }
}
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
