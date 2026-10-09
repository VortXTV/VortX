import Foundation

// Offline dependency fixtures. The runner compiles the actual CoreCW models, ownership policy,
// CoreBridge nativeHistorySnapshot method and LibraryLandingSnapshot implementation.
enum EpisodePlaybackIdentity { static func usesSeriesLifecycle(type: String) -> Bool { type == "series" } }
final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    struct Capture: Hashable { let namespace: String; let generation: UInt64 }
    var current = Capture(namespace: "account-a", generation: 1)
    func capture() -> Capture { current }
    func isCurrent(_ value: Capture) -> Bool { value == current }
}
typealias PlaybackMutationTarget = PlaybackMutationOwnershipPolicy.Target
extension PlaybackMutationTarget {
    static func capture(core: CoreBridge) -> Self { .native(core.binding) }
    func stillOwnsCurrentContext(core: CoreBridge) -> Bool { core.nativePlaybackBinding(self) != nil }
}
struct WatchEntry {
    var videoId: String?; var timeOffsetMs: Int; var durationMs: Int; var lastWatched: String
    var name: String; var type: String; var poster: String?; var watchedVideoIds: [String] = []
}
final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID? = LibraryLandingSnapshotTests.profileA
    var activeUsesEngineHistory = true
    var watch: [String: WatchEntry] = [:]
    var libraryItems: [CoreCWItem] = []
}
enum HomeContinueWatchingSelection {
    struct Snapshot { let items: [CoreCWItem] }
    static func current(core: CoreBridge, profiles: ProfileStore) -> Snapshot { .init(items: core.continueWatching) }
}
enum BecauseYouWatchedHistoryPolicy {
    struct Owner { var profileID: UUID; var keychainAccount: String; var uid: String?; var generation: UInt64 }
    struct Snapshot { var owner: Owner? }
}
enum OwnerHistoryStore { static func validRows() -> [[String: Any]] { [] } }
final class HistoryFacade {
    var fields: [String: Data] = [:]
    var onRead: ((String) -> Void)?
    func stateData(_ field: String) -> Data? { onRead?(field); return fields[field] }
}
final class CoreBridge {
    var usesNativeProfileState = true
    var binding: PlaybackMutationOwnershipPolicy.NativeBinding? = LibraryLandingSnapshotTests.binding()
    let facade = HistoryFacade()
    var continueWatching: [CoreCWItem] = []
    struct Library { var catalog: [CoreCWItem] }
    var library: Library?
    struct Board { var items: [CoreMeta] }
    var boardRows: [Board] = []
    struct MetaDetails { var meta: CoreMetaItem? }
    var metaDetails: MetaDetails?
    struct LocalRecommendationHistory { var library: [CoreCWItem]; var continueWatching: [CoreCWItem]; var receipt: BecauseYouWatchedHistoryPolicy.Snapshot }
    var lastAcceptedHistoryReceipt: BecauseYouWatchedHistoryPolicy.Snapshot?
    func acceptedLocalRecommendationHistory() -> LocalRecommendationHistory? { nil }
    func settledActiveAccountBinding() -> PlaybackMutationOwnershipPolicy.SettledAccountBinding? { nil }
    func nativePlaybackBinding(_ target: PlaybackMutationTarget) -> (HistoryFacade, UUID)? {
        guard PlaybackMutationOwnershipPolicy.allowsNative(target, binding: binding), let binding,
              binding.profileID == ProfileStore.shared.activeID,
              CredentialScopeRegistry.shared.isCurrent(binding.credential) else { return nil }
        return (facade, binding.profileID)
    }
}
struct CoreMeta {}
struct CoreMetaItem {}
struct RailItem { let id: String }
func cinemaHistoryRailItem(_ item: CoreCWItem, catalog: [CoreMeta], residentMeta: CoreMetaItem?, includesResume: Bool = true) -> RailItem { .init(id: item.id) }

@main
enum LibraryLandingSnapshotTests {
    static let profileA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let profileB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static var checks = 0
    static var failures: [String] = []
    static func binding(profile: UUID = profileA, session: UUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                        epoch: UUID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!) -> PlaybackMutationOwnershipPolicy.NativeBinding {
        .init(profileID: profile, credential: CredentialScopeRegistry.shared.capture(), sessionGeneration: session, accountGeneration: epoch)
    }
    static func item(_ id: String, video: String? = nil, watched: Int = 1) -> CoreCWItem {
        .init(id: id, type: video == nil ? "movie" : "series", name: id, poster: nil,
              state: .init(timeOffset: 0, duration: 2_400_000, videoId: video, lastWatched: "2026-10-09T12:00:00Z", timesWatched: watched))
    }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !value() { failures.append(message) }
    }
    static func configure(_ history: [CoreCWItem] = [item("watched-unsaved")]) throws -> CoreBridge {
        ProfileStore.shared.activeID = profileA; ProfileStore.shared.activeUsesEngineHistory = true
        CredentialScopeRegistry.shared.current = .init(namespace: "account-a", generation: 1)
        let core = CoreBridge()
        core.library = .init(catalog: [item("saved-unwatched", watched: 0)])
        core.continueWatching = [item("resume", video: "resume:2:3", watched: 0)]
        core.facade.fields["native_history"] = try JSONSerialization.data(withJSONObject: ["items": history.map(wire)])
        core.facade.fields["native_playback"] = try JSONSerialization.data(withJSONObject: [
            "profileId": profileA.uuidString, "history": history.map { ["metaId": $0.id] }])
        return core
    }
    static func wire(_ item: CoreCWItem) -> [String: Any] {
        ["_id": item.id, "type": item.type, "name": item.name, "state": [
            "timeOffset": item.state.timeOffset, "duration": item.state.duration,
            "video_id": item.state.videoId as Any? ?? NSNull(), "lastWatched": item.state.lastWatched as Any? ?? NSNull(),
            "timesWatched": item.state.timesWatched]]
    }
    @MainActor static func main() throws {
        #if LIBRARY_HISTORY_BASELINE
        let core = try configure()
        let rendered = BaselineIOSLibrary(core: core, profiles: .shared).libraryItems
        require(rendered.contains { $0.id == "watched-unsaved" }, "Previously Watched retains unsaved native history")
        #else
        let core = try configure()
        let snapshot = LibraryLandingSnapshot.current(core: core, profiles: .shared)
        require(snapshot.history?.map { $0.item.id } == ["watched-unsaved"], "unsaved native history is independent of the saved library")
        require(snapshot.continueWatching.items.map(\.id) == ["resume"], "Library keeps the same Continue Watching read selection")
        require(snapshot.history?.contains { $0.item.id == "saved-unwatched" } == false, "saved unwatched titles do not become history")
        core.binding = binding(epoch: UUID())
        let rebound = LibraryLandingSnapshot.current(core: core, profiles: .shared)
        require(snapshot.context != rebound.context && !snapshot.context.isCurrent(core: core, profiles: .shared),
                "same-profile account replacement changes the Watchlist cache identity and denies captured navigation")
        core.binding = binding(session: UUID())
        let reopenedContext = LibraryLandingSnapshot.current(core: core, profiles: .shared).context
        require(rebound.context != reopenedContext && !rebound.context.isCurrent(core: core, profiles: .shared),
                "native session reopen remounts cached Watchlist and rejects old detail or autoplay intent")
        let episodes = LibraryLandingSnapshot.completeHistory([item("show", video: "show:2:1"), item("show", video: "show:2:2"), item("show", video: "show:2:1")])!
        require(episodes.count == 2 && Set(episodes.map(\.id)).count == 2, "physical episode identity survives while exact duplicates fold")
        require(episodes.map(\.episodeCaption) == ["S2 · E1", "S2 · E2"], "episode caption uses exact canonical video coordinates")
        require(LibraryLandingSnapshot.Entry(item: item("show", video: "other:2:1")).episodeCaption == nil, "unrelated or opaque video identity has no invented episode metadata")
        let invalid = CoreCWItem(id: "broken", type: "movie", name: "broken", poster: nil,
            state: .init(timeOffset: .nan, duration: 10, videoId: nil))
        require(LibraryLandingSnapshot.completeHistory([item("valid"), invalid]) == nil, "invalid row rejects a partial successful history")
        let empty = LibraryLandingSnapshot.current(core: try configure([]), profiles: .shared)
        require(empty.history?.isEmpty == true, "successful complete empty history stays distinguishable from unavailable")
        let missing = try configure(); missing.facade.fields.removeValue(forKey: "native_history")
        require(LibraryLandingSnapshot.current(core: missing, profiles: .shared).history == nil, "missing history never falls back to saved catalog")
        let malformed = try configure(); malformed.facade.fields["native_history"] = Data("{\"items\": [{\"_id\":\"broken\"}]}".utf8)
        require(LibraryLandingSnapshot.current(core: malformed, profiles: .shared).history == nil, "malformed projection is unavailable")
        let partial = try configure(); partial.facade.fields["native_history"] = Data("{\"items\": []}".utf8)
        require(LibraryLandingSnapshot.current(core: partial, profiles: .shared).history == nil, "projected cardinality must match the complete native history")
        let mismatch = try configure(); mismatch.facade.fields["native_playback"] = try JSONSerialization.data(withJSONObject: ["profileId": profileB.uuidString, "history": []])
        require(LibraryLandingSnapshot.current(core: mismatch, profiles: .shared).history == nil, "native projection names the captured profile")
        let accountDrift = try configure(); accountDrift.facade.onRead = { field in
            if field == "native_history" { accountDrift.binding = binding(epoch: UUID()) }
        }
        require(LibraryLandingSnapshot.current(core: accountDrift, profiles: .shared).history == nil, "account epoch retirement during read rejects history")
        let sessionDrift = try configure(); sessionDrift.facade.onRead = { field in
            if field == "native_history" { sessionDrift.binding = binding(session: UUID()) }
        }
        require(LibraryLandingSnapshot.current(core: sessionDrift, profiles: .shared).history == nil, "same-account session reopen during read rejects history")
        let credentialDrift = try configure(); credentialDrift.facade.onRead = { field in
            if field == "native_history" { CredentialScopeRegistry.shared.current = .init(namespace: "account-b", generation: 2) }
        }
        require(LibraryLandingSnapshot.current(core: credentialDrift, profiles: .shared).history == nil, "credential owner drift never relabels old history")
        let profileDrift = try configure(); profileDrift.facade.onRead = { field in
            if field == "native_history" { ProfileStore.shared.activeID = profileB }
        }
        require(LibraryLandingSnapshot.current(core: profileDrift, profiles: .shared).history == nil, "profile drift during read rejects old history")
        let overlay = LibraryLandingSnapshot.overlayHistory([
            "saved": .init(videoId: nil, timeOffsetMs: 0, durationMs: 0, lastWatched: "today", name: "Saved", type: "movie", poster: nil),
            "watched": .init(videoId: "watched:1:4", timeOffsetMs: 0, durationMs: 0, lastWatched: "today", name: "Watched", type: "series", poster: nil, watchedVideoIds: ["watched:1:4"])
        ])
        require(overlay.map(\.id) == ["watched"] && overlay.first?.state.videoId == "watched:1:4", "overlay saved-only entries stay out and watched episode identity survives")
        #endif
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: \(checks) offline Apple Library production method checks")
    }
}
