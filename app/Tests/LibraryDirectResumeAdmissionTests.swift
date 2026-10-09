import Foundation

// Dependency fixtures only: the runner mechanically extracts and compiles the entire production
// iOSDirectResume helper. Counters stand in for external side effects; no player/provider is invoked.
final class CredentialScopeRegistry {
    struct Capture: Hashable { let namespace: String; let generation: UInt64 }
}
typealias PlaybackMutationTarget = PlaybackMutationOwnershipPolicy.Target
struct TraktSessionID: Equatable { let value: String }
enum TraktAuth { static var storedSessionID: TraktSessionID? }
final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID? = LibraryDirectResumeAdmissionTests.profileA
}
enum HomeContinueWatchingSelection {
    struct Intent {
        let target: PlaybackMutationTarget
        func isCurrent(core: CoreBridge, profiles: ProfileStore) -> Bool {
            PlaybackMutationOwnershipPolicy.allowsNative(target, binding: core.binding)
                && core.binding.profileID == profiles.activeID
        }
    }
}
struct RailItem { let id: String; var cwVideoId: String?; var resumeSeconds: Double? }
struct PlaybackMeta {
    let libraryId: String; let videoId: String; let type: String; let name: String; let poster: String?
    let season: Int?; let episode: Int?
}
struct CoreStream { var url: String?; var infoHash: String?; var fileIdx: Int? }
struct CoreVideo {
    let id: String; let season: Int?; let episode: Int?
    var episodeNumber: Int { episode ?? 0 }; var episodeTitle: String { id }
}
extension Array where Element == CoreVideo { var orderedBySeasonEpisode: [CoreVideo] { self } }
struct CoreMeta { let id: String; let videos: [CoreVideo]? }
struct StreamGroup {
    struct Request { struct Path { var id: String }; var path: Path }
    var request: Request; var streams: [CoreStream]
}
struct MetaDetails {
    var meta: CoreMeta?; var allStreamGroups: [StreamGroup] = []
    func appleCWNavigationMeta(for id: String, streamID: String) -> CoreMeta? { meta?.id == id ? meta : nil }
}
final class CoreBridge {
    var binding = LibraryDirectResumeAdmissionTests.binding()
    var metaDetails: MetaDetails?
    var appleCWMetaRefreshDetails: MetaDetails?
    var groups: [StreamGroup] = []
    var metaLoads = 0; var playerLoads = 0
    func engineResumeSeconds(for meta: PlaybackMeta) -> Double? { nil }
    func streamGroups(forStreamId id: String) -> [StreamGroup] { groups }
    func loadMeta(type: String, id: String, streamType: String, streamId: String) { metaLoads += 1 }
    func loadEnginePlayer(for source: CoreStream, videoId: String, base: String, resolvedURL: URL?) -> Bool { playerLoads += 1; return true }
}
final class StremioAccount {
    var credentialBoundaryGeneration: UInt64 = 1
    var streamSources: [String] = []
    var resumeRead: (() -> Void)?
    func resumeOffset(for meta: PlaybackMeta) async -> Double { resumeRead?(); return 120 }
}
enum LastStreamStore {
    struct Entry {
        var url = "https://fixture.invalid/episode.mkv"; var type = "series"; var videoId = "show:2:3"
        var name = "Show"; var title = "Show episode"; var poster: String?; var torrent: Bool? = false
        var season: Int? = 2; var episode: Int? = 3; var headers: [String: String]?
        var qualityText: String?; var bingeGroup: String?; var infoHash: String?; var fileIdx: Int?
        var debridService: String?; var debridTorrentId: String?; var debridFileId: String?
    }
    static var stored = Entry()
    static func entry(for id: String, profileID: UUID?) -> Entry? { stored }
    static func logResume(_ event: String, libraryId: String, profileID: UUID?) {}
}
enum PlaybackSettings { static var torrentsDisabled = false }
enum EpisodePlaybackIdentity {
    static func isEpisodicContext(type: String, season: Int?, episode: Int?, videoID: String) -> Bool { type == "series" }
    static func usesSeriesLifecycle(type: String) -> Bool { type == "series" }
    static func boundVideoID(requestedVideoID: String, bindingSucceeded: Bool) -> String? { bindingSucceeded ? requestedVideoID : nil }
}
enum CWResume {
    static var read: (() -> Void)?; static var calls = 0
    static func resolvedURL(for entry: LastStreamStore.Entry) async -> (url: URL, refreshed: Bool) {
        calls += 1; read?(); return (URL(string: entry.url)!, false)
    }
}
enum SourceIndexClient {
    static func resumeContentID(itemID: String, videoID: String, season: Int?, episode: Int?) -> String? { nil }
}
enum DebridService: String { case fixture }
struct DebridPlaybackRef {
    var url: URL; var service: DebridService; var infoHash: String
    var torrentId: String?; var fileId: String?; var fileIdx: Int?
}
enum StremioServer { static var calls = 0; static func primeTorrent(hash: String) { calls += 1 } }
struct PlayerEpisodeRef { var id: String; var label: String; var season: Int?; var episode: Int? }
struct PlayerEpisodeStream {}
struct NextEpisodePreparationRequest {}
struct SourcePinContext { var metaId: String; var isSeries: Bool }
final class SourcePinStore {
    static let shared = SourcePinStore()
    func effectivePin(_ context: SourcePinContext) -> String? { nil }
}
final class VortXSyncManager { static let shared = VortXSyncManager(); var isSignedIn = false }
struct iOSNextEpisodePreparationContext {
    var seriesID: String; var seriesName: String; var defaultSeason: Int; var defaultVideoID: String?
    var poster: String?; var sources: [String]; var continuity: String?; var binge: String?; var pin: String?
    var cachedHashes: [String]; var signedInToVortX: Bool; var videos: () -> [CoreVideo]
    var resumeOffset: (PlaybackMeta) async -> Double; var isCurrent: () -> Bool
}
final class iOSNextEpisodePreparer {
    func cancel() {}
    func warm(_ request: NextEpisodePreparationRequest, context: iOSNextEpisodePreparationContext) async -> PlayerEpisodeStream? { nil }
}
func iOSResolveEpisodeStream(videoId: String, in videos: [CoreVideo], seriesId: String, seriesName: String,
    defaultSeason: Int, fallbackPoster: String?, continuity: String?, binge: String?, preserveChosenRelease: Bool,
    core: CoreBridge, account: StremioAccount) async -> PlayerEpisodeStream? { nil }
func iOSDirectStream(url: URL, name: String) -> CoreStream? { .init(url: url.absoluteString) }
func iOSRawTorrentStream(infoHash: String, fileIdx: Int, name: String) -> CoreStream? { .init(infoHash: infoHash, fileIdx: fileIdx) }
func iOSEngineAddonBase(for stream: CoreStream, in groups: [StreamGroup]) -> String { "fixture" }
struct iOSPlayerLaunch {
    var url: URL; var title: String; var headers: [String: String]?; var resume: Double; var meta: PlaybackMeta
    var qualityText: String?; var bingeGroup: String?; var isTorrent: Bool; var debridRef: DebridPlaybackRef?
    var sourceStream: CoreStream?; var enginePlayerVideoId: String?; var wasExplicitPick: Bool; var wasResume: Bool
    var episodes: [PlayerEpisodeRef]; var loadEpisode: ((String) async -> PlayerEpisodeStream?)?
    var loadEpisodeWithMetadata: ((CoreVideo) async -> PlayerEpisodeStream?)?
    var warmNextEpisode: ((NextEpisodePreparationRequest) async -> PlayerEpisodeStream?)?
    var cancelNextEpisodePreparation: (() -> Void)?; var resumeHoardContentID: String?; var resumeHoardStreamID: String?
}

@main
enum LibraryDirectResumeAdmissionTests {
    static let profileA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let profileB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static var checks = 0; static var failures: [String] = []
    static func binding(profile: UUID = profileA, epoch: UUID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
                        session: UUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!) -> PlaybackMutationOwnershipPolicy.NativeBinding {
        .init(profileID: profile, credential: .init(namespace: "account-a", generation: 1), sessionGeneration: session, accountGeneration: epoch)
    }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !value() { failures.append(message) }
    }
    static func configure() -> (CoreBridge, StremioAccount, HomeContinueWatchingSelection.Intent) {
        ProfileStore.shared.activeID = profileA; CWResume.calls = 0; CWResume.read = nil; StremioServer.calls = 0
        LastStreamStore.stored = .init()
        let core = CoreBridge()
        let videos = [CoreVideo(id: "show:2:3", season: 2, episode: 3), CoreVideo(id: "show:3:1", season: 3, episode: 1)]
        core.groups = [.init(request: .init(path: .init(id: "show:2:3")), streams: [.init(url: LastStreamStore.stored.url)])]
        core.metaDetails = .init(meta: .init(id: "show", videos: videos), allStreamGroups: core.groups)
        return (core, StremioAccount(), .init(target: .native(core.binding)))
    }
    static func effects(_ core: CoreBridge) -> Int { core.metaLoads + core.playerLoads + StremioServer.calls }
    @MainActor static func main() async {
        let item = RailItem(id: "show", cwVideoId: "show:2:3", resumeSeconds: 120)
        let (valid, account, intent) = configure()
        let launch = await iOSDirectResume(for: item, core: valid, account: account, expectedTraktSession: nil, expectedIntent: intent)
        require(launch?.meta.videoId == "show:2:3" && launch?.resume == 120, "valid captured resume retains exact video and displayed seconds")
        require(launch?.episodes.map(\.id) == ["show:2:3", "show:3:1"] && launch?.enginePlayerVideoId == "show:2:3",
                "valid resume retains full all-season episode inventory and engine binding")
        require(valid.playerLoads == 1 && CWResume.calls == 1, "valid resume still admits existing exact-source flow")
        let (late, lateAccount, lateIntent) = configure()
        let scheduled = Task { @MainActor in
            await iOSDirectResume(for: item, core: late, account: lateAccount, expectedTraktSession: nil, expectedIntent: lateIntent)
        }
        late.binding = binding(epoch: UUID())
        let lateLaunch = await scheduled.value
        require(lateLaunch == nil && effects(late) == 0 && CWResume.calls == 0, "late Task cannot borrow a new same-profile account epoch or invoke side effects")
        let (reopened, reopenedAccount, reopenedIntent) = configure()
        reopened.binding = binding(session: UUID())
        let reopenedLaunch = await iOSDirectResume(for: item, core: reopened, account: reopenedAccount, expectedTraktSession: nil, expectedIntent: reopenedIntent)
        require(reopenedLaunch == nil && effects(reopened) == 0 && CWResume.calls == 0, "same-account native reopen retires the captured resume")
        let (drift, driftAccount, driftIntent) = configure()
        CWResume.read = { drift.binding = binding(epoch: UUID()) }
        let driftLaunch = await iOSDirectResume(for: item, core: drift, account: driftAccount, expectedTraktSession: nil, expectedIntent: driftIntent)
        require(driftLaunch == nil && effects(drift) == 0, "account epoch change during exact-source await denies subsequent engine effects")
        let (profile, profileAccount, profileIntent) = configure()
        CWResume.read = { ProfileStore.shared.activeID = profileB }
        let profileLaunch = await iOSDirectResume(for: item, core: profile, account: profileAccount, expectedTraktSession: nil, expectedIntent: profileIntent)
        require(profileLaunch == nil && effects(profile) == 0, "profile switch during exact-source await denies subsequent engine effects")
        let (offset, offsetAccount, offsetIntent) = configure()
        offsetAccount.resumeRead = { offset.binding = binding(epoch: UUID()) }
        let offsetLaunch = await iOSDirectResume(for: .init(id: "show", cwVideoId: "show:2:3", resumeSeconds: nil),
            core: offset, account: offsetAccount, expectedTraktSession: nil, expectedIntent: offsetIntent)
        require(offsetLaunch == nil && effects(offset) == 0, "account epoch change during resume offset await denies subsequent engine effects")
        let (compat, compatAccount, _) = configure()
        compat.binding = binding(epoch: UUID())
        let compatLaunch = await iOSDirectResume(for: item, core: compat, account: compatAccount, expectedTraktSession: nil)
        require(compatLaunch != nil && compat.playerLoads == 1, "default nil intent preserves the existing Home caller contract")
        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: \(checks) extracted production Library resume admission checks")
    }
}
