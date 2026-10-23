// PRIVATE — G5 legacy/no-native source-unit collaborators. UNCOMPILED / UNRUN.
import Foundation
import Combine

#if VORTX_NATIVE_DATA_ENGINE
#error("This fixture is legacy/no-native only; native requires a separate reviewed source unit.")
#endif

// Every type below is synthetic. LegacyWatchOwnership and Combine are separate REAL inputs.
struct UserProfile {
    let id: UUID
    var isOwner: Bool
    var usesOwnAccount: Bool
    var name = "fixture"
}

struct WatchEntry {
    var type = "movie"
    var name: String
    var poster: String? = nil
    var durationMs: Int
    var watchedVideoIds: Set<String> = []
    var progress = 1.0
    var videoId: String? = nil
    var timeOffsetMs = 0
    var lastWatched: String?
}

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()
    private var rosterRetirements: [Bool] = []
    private var selectionRetirements: [Bool] = []
    @Published private(set) var profiles: [UserProfile] = [] {
        willSet {
            let retire = Self.binding(profiles, activeID) != Self.binding(newValue, activeID)
            rosterRetirements.append(retire)
            LegacyWatchOwnership.beginProfileMutation(retire: retire)
        }
        didSet {
            _ = rosterRetirements.removeLast()
            LegacyWatchOwnership.endProfileMutation()
        }
    }
    @Published private(set) var activeID: UUID? {
        willSet {
            let retire = activeID != newValue
            selectionRetirements.append(retire)
            LegacyWatchOwnership.beginProfileMutation(retire: retire)
        }
        didSet {
            _ = selectionRetirements.removeLast()
            LegacyWatchOwnership.endProfileMutation()
        }
    }
    private static func binding(_ roster: [UserProfile], _ active: UUID?) -> LegacyWatchOwnership.ProfileBinding? {
        roster.first { $0.id == active }.map { .init(id: $0.id, isOwner: $0.isOwner, usesOwnAccount: $0.usesOwnAccount) }
    }
    var active: UserProfile? { profiles.first { $0.id == activeID } }
    var activeUsesEngineHistory: Bool { active.map { $0.isOwner || $0.usesOwnAccount } ?? true }
    var activeKeychainAccount = "fixture-account"
    var watch: [String: WatchEntry] = [:]
    func fixtureRoster(_ value: [UserProfile]) { profiles = value }
    func fixtureSelect(_ value: UUID?) { activeID = value }
}

@MainActor
final class CredentialScopeRegistry {
    struct Capture: Equatable, Sendable { let generation: UUID }
    static let shared = CredentialScopeRegistry()
    private var generation = UUID()
    func capture() -> Capture { .init(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
    func fixtureRebind() { generation = UUID() }
}

struct CoreCWItem: Sendable {
    struct State: Sendable {
        var duration: Double
        var timeOffset: Double
        var timesWatched: Int
    }
    let id: String
    var type = "movie"
    var name: String
    var poster: String? = nil
    var state: State
    var isWatched = true
    var resumeSeconds: Double { state.timeOffset / 1000 }
}
struct FixtureLibrary { var catalog: [CoreCWItem] }
struct CoreMeta { var id: String; var genres: [String]? }
struct FixtureRow { var items: [CoreMeta] }
struct FixtureHints { var defaultVideoId: String? }
struct FixtureDetailedMeta { var id: String; var genres: [String]; var behaviorHints: FixtureHints? }
struct FixtureDetails { var meta: FixtureDetailedMeta }

@MainActor
final class FixtureSignal {
    private(set) var isFinished = false
    private var waiter: CheckedContinuation<Void, Never>?
    func finish() {
        precondition(!isFinished)
        isFinished = true
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
    func wait() async {
        if isFinished { return }
        await withCheckedContinuation { continuation in
            precondition(waiter == nil)
            waiter = continuation
        }
    }
}

@MainActor
final class FixtureLibraryWait {
    let entered = FixtureSignal()
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
            entered.finish()
        }
    }
    func release() {
        guard let pending = continuation else { preconditionFailure("library wait did not enter") }
        continuation = nil
        pending.resume()
    }
    func releaseIfHeld() { if continuation != nil { release() } }
}

@MainActor
final class CoreBridge {
    static let shared = CoreBridge()
    // Only immutable disposable packet JSON is read. No app storage directory is consulted.
    nonisolated static let storageDirURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("repair-20261018-watchstats-owner-fixture-v1-buckets", isDirectory: true)
    var fixtureUID: String? = "fixture-owner-a"
    // Unlike actual currentUID(), this getter does not serialize engine ctx on the UI actor.
    // Its cost is deliberately NOT representative and cannot support a performance claim.
    func currentUID() -> String? { fixtureUID }
    var library: FixtureLibrary?
    var continueWatching: [CoreCWItem] = []
    var boardRows: [FixtureRow] = []
    var discover: FixtureRow?
    var searchResults: [CoreMeta] = []
    var metaDetails: FixtureDetails?
    private var waits: [FixtureLibraryWait] = []
    private(set) var waitCallCount = 0
    func planLibraryWait() -> FixtureLibraryWait {
        let hold = FixtureLibraryWait()
        waits.append(hold)
        return hold
    }
    func loadLibraryAndAwait() async {
        precondition(!waits.isEmpty, "unplanned library read")
        let hold = waits.removeFirst()
        waitCallCount += 1
        // Cancellation deliberately does not release the continuation; the original post-await
        // Task cancellation/request guards must reject a released obsolete wait.
        await hold.suspend()
    }
}
