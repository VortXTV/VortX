// BingeSourceMemoryRaceContractTests: a standalone, runnable proof of the complete-set decision used by
// automatic source selection. The historical gate opened on an early matching quality or preferred add-on,
// while a slower contributor could still return a superior stream. This harness drives the real
// StreamRanking.resolveSettled and proves that ranking starts only after every registered raw contributor is
// terminal, or after the shared bounded deadline.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per the repo guide), so,
// like app/Tests/SearchIdleStateContractTests.swift, this is a self-contained executable that compiles the real
// production sources plus small stubs for the peripheral types the ranker names but the settle gate never calls
// (SourcePreferences read surface, pin/health/sticky). Run:
//
//   xcrun swiftc -o /tmp/binge-race-test \
//     app/SourcesShared/DetailMetaRecoveryPolicy.swift \
//     app/SourcesShared/CatalogRowResolution.swift \
//     app/SourcesShared/SubtitleReleaseFingerprint.swift \
//     app/SourcesShared/CoreModels.swift \
//     app/SourcesShared/SourceSettlementPolicy.swift \
//     app/SourcesShared/StreamRanking.swift \
//     app/Tests/BingeSourceMemoryRaceContractTests.swift && /tmp/binge-race-test

import Foundation

// MARK: - Minimal CoreModels dependencies (mirrors SearchIdleStateContractTests' stub block)

enum DebridService: String { case torBox }
struct DebridEpisode { let season: Int; let episode: Int }

enum LastStreamStore {
    struct Entry {
        let videoId: String
        let url: String
        let type: String
        let debridService: String?
        let infoHash: String?
        let linkSavedAt: Date?
        let debridTorrentId: Int?
        let debridFileId: Int?
        let fileIdx: Int?
        let season: Int?
        let episode: Int?
    }
}

actor DebridCoordinator {
    static let shared = DebridCoordinator()
    func reresolve(service: DebridService, infoHash: String, torrentId: Int?, fileId: Int?, fileIdx: Int?,
                   episode: DebridEpisode? = nil, requiresSemanticSelection: Bool) async throws -> URL {
        throw StubError.unavailable
    }
}

enum StubError: Error { case unavailable }

enum VortXSyncManager { static let appliedAddonOrder: [String] = [] }
enum AddonTombstones { static func normalize(_ value: String) -> String { value } }

final class DebridKeys {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { false }
}

enum StremioServer {
    static let base = "http://127.0.0.1:11470"
    static let trailerResolverBase = "https://trailer.invalid"
}

enum PlaybackSettings { static let torrentsDisabled = false }

// MARK: - StreamRanking peripheral stubs (the ranker names them; the settle gate never calls them)

/// The read surface `StreamRanking` needs from source preferences at score / filter time. Mirror of the real
/// `SourcePrefsReading` protocol; only `useAddonOrder` + `typeOrder` are read by `resolveSettled`, the rest are
/// here so the whole real StreamRanking.swift (computeScore / applyUserFilters) compiles.
protocol SourcePrefsReading {
    var useAddonOrder: Bool { get }
    var typeOrder: [SourceType] { get }
    var noFiltersActive: Bool { get }
    var keywordsAreRegex: Bool { get }
    var excludeRegex: NSRegularExpression? { get }
    var includeRegex: NSRegularExpression? { get }
    var excludeTerms: [String] { get }
    var includeTerms: [String] { get }
    var preferTerms: [String] { get }
    var avoidBehavior: String { get }
    var autoPickBest: Bool { get }
    var safetyMode: String { get }
    var instantOnly: Bool { get }
    var hideDeadTorrents: Bool { get }
    var excludeAV1: Bool { get }
    var hdrOnly: Bool { get }
    var maxResolution: Int { get }
    var minResolution: Int { get }
    var hideUnknownResolution: Bool { get }
    var preferredAudioOnly: Bool { get }
    var maxFileSizeGB: Double { get }
    func tierWeight(for type: SourceType) -> Int
    func matches(_ regex: NSRegularExpression, _ text: String) -> Bool
}

enum SourceType: String, CaseIterable, Codable {
    case mediaServer, debrid, usenet, torrent, direct
}

struct StubPrefs: SourcePrefsReading {
    var useAddonOrder = false
    var typeOrder: [SourceType] = [.debrid, .usenet, .torrent, .direct]
    var noFiltersActive = true
    var keywordsAreRegex = false
    var excludeRegex: NSRegularExpression? = nil
    var includeRegex: NSRegularExpression? = nil
    var excludeTerms: [String] = []
    var includeTerms: [String] = []
    var preferTerms: [String] = []
    var avoidBehavior = "hide"
    var autoPickBest = false
    var safetyMode = "off"
    var instantOnly = false
    var hideDeadTorrents = false
    var excludeAV1 = false
    var hdrOnly = false
    var maxResolution = 0
    var minResolution = 0
    var hideUnknownResolution = false
    var preferredAudioOnly = false
    var maxFileSizeGB = 0.0
    func tierWeight(for type: SourceType) -> Int {
        let weights = [60_000, 45_000, 30_000, 15_000, 0]
        guard let idx = typeOrder.firstIndex(of: type), idx < weights.count else { return 0 }
        return weights[idx]
    }
    func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

enum SourcePreferences {
    static var stub = StubPrefs()
    static var reading: SourcePrefsReading { stub }
}

struct ResolvedPin: Equatable, Sendable {}

enum SourcePinStore {
    static func matches(_ s: CoreStream, addon: String, pin: ResolvedPin) -> Bool { false }
}

enum ProviderHealth {
    static func penaltyActive(addonName: String) -> Bool { false }
}

enum SeriesSourceSticky {
    static func preference(for key: String) -> (addon: String?, bingeGroup: String?)? { nil }
}

struct TrackPreferencesSnapshot { var audioLanguages: [String] = [] }
enum TrackPreferences { static var current = TrackPreferencesSnapshot() }

enum ProfileStore { static func activeIsKids() -> Bool { false } }

// MARK: - Assertion harness

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

// MARK: - Fixtures

private func stream(_ json: String) -> CoreStream {
    try! JSONDecoder().decode(CoreStream.self, from: Data(json.utf8))
}

private func group(_ addon: String, _ streams: [CoreStream]) -> CoreStreamSourceGroup {
    CoreStreamSourceGroup(id: addon, addon: addon, streams: streams)
}

/// A fast rival: a direct 1080p WEB stream (non-torrent, playable). It matches the remembered quality, but
/// that hint must affect ranking only after the complete contributor set settles.
private let cometDirect1080 = stream(#"{"url":"https://cdn.invalid/comet-1080p.mkv","name":"Comet 1080p WEB-DL"}"#)
/// The user's remembered aggregator, arrived: a real playable stream.
private let aioDirect = stream(#"{"url":"https://cdn.invalid/aio.mkv","name":"AIOStreams 1080p WEB"}"#)
/// The aggregator group carrying ONLY a bare trailer: present in the list, but not a real arrival.
private let bareTrailer = stream(#"{"ytId":"abc123XYZ","name":"Trailer"}"#)
/// A 1080p WEB raw torrent (movie file idx 0), for the torrent-order branch of the no-wanted path.
private let cometTorrent1080 = stream(#"{"infoHash":"deadbeefdeadbeef","name":"Comet 1080p WEB"}"#)
/// A 720p direct stream: playable, but does NOT match the 1080p remembered quality.
private let direct720 = stream(#"{"url":"https://cdn.invalid/x-720p.mkv","name":"Provider 720p WEB"}"#)

private let hint1080 = "1080p WEB"
private let wanted = "aiostreams"

// Convenience wrappers around the REAL function so the call sites read as behavior, not plumbing.
private func settledNew(_ groups: [CoreStreamSourceGroup], loaded: Int, total: Int,
                        seconds: TimeInterval, quality: String?, wantedAddon: String?) -> Bool {
    StreamRanking.resolveSettled(groups, loaded: loaded, total: total,
                                 secondsSinceRequestStart: seconds, rememberedQuality: quality,
                                 wantedAddon: wantedAddon)
}
private func settledOld(_ groups: [CoreStreamSourceGroup], loaded: Int, total: Int,
                        seconds: TimeInterval, quality: String?) -> Bool {
    StreamRanking.resolveSettled(groups, loaded: loaded, total: total,
                                 secondsSinceRequestStart: seconds, rememberedQuality: quality,
                                 wantedAddon: nil)
}

@main
enum BingeSourceMemoryRaceContractTests {
    static func main() {
        SourcePreferences.stub = StubPrefs()   // default order: debrid first (torrents NOT ranked first)

        // Sanity on the fixtures themselves (proves the real CoreStream decode + classification we rely on).
        expect(cometDirect1080.playableURL != nil && !cometDirect1080.isTorrent && !cometDirect1080.isYouTubeTrailer,
               "fixture: the rival is a playable non-torrent, non-trailer stream")
        expect(cometDirect1080.isTorrent == false && cometTorrent1080.isTorrent,
               "fixture: the torrent variant classifies as a torrent, the direct one does not")
        expect(cometTorrent1080.playableURL != nil, "fixture: a movie torrent resolves a playable (file-0) URL")
        expect(bareTrailer.isYouTubeTrailer && bareTrailer.playableURL != nil,
               "fixture: the bare trailer is playable BUT flagged a YouTube trailer (must not count as arrival)")
        expect(StreamRanking.continuityBonus(cometDirect1080, hint: hint1080) > 0,
               "fixture: the rival really matches the remembered quality (so the OLD gate would open on it)")

        // MARK: 1 - Late superior contributor cannot lose to an early matching rival
        // Only the rival has answered (1 of 3), the user's aggregator is still loading, 5s in.
        let raceGroups = [group("comet", [cometDirect1080])]
        let old = settledOld(raceGroups, loaded: 1, total: 3, seconds: 5, quality: hint1080)
        let new = settledNew(raceGroups, loaded: 1, total: 3, seconds: 5, quality: hint1080, wantedAddon: wanted)
        expect(old == false,
               "race: matching remembered quality cannot open a partial contributor set")
        expect(new == false,
               "race: a remembered source that has not arrived cannot commit off a rival")
        expect(old == new,
               "race: quality and wanted-source hints share the complete-set gate")

        // MARK: 2 - Wanted present is still partial and must wait
        let presentGroups = [group("comet", [cometDirect1080]), group("aiostreams", [aioDirect])]
        expect(settledNew(presentGroups, loaded: 2, total: 3, seconds: 1, quality: hint1080, wantedAddon: wanted) == false,
               "present: the wanted source cannot open while another contributor remains pending")
        expect(settledNew(presentGroups, loaded: 2, total: 3, seconds: 1, quality: hint1080, wantedAddon: "AIOStreams") == false,
               "present: wanted-source case does not change settlement")
        // Present in the list but only as a bare trailer: NOT an arrival, so the bounded wait still holds.
        let trailerOnlyGroups = [group("comet", [cometDirect1080]), group("aiostreams", [bareTrailer])]
        expect(settledNew(trailerOnlyGroups, loaded: 2, total: 3, seconds: 1, quality: hint1080, wantedAddon: wanted) == false,
               "present: a wanted group carrying only a trailer is not an arrival -> keep waiting")

        // MARK: 3 - Everyone answered -> commit even if the wanted source never came
        expect(settledNew(raceGroups, loaded: 3, total: 3, seconds: 0, quality: hint1080, wantedAddon: wanted),
               "everyone-answered: loaded >= total commits, so a wanted source that never returns cannot hang it")

        // MARK: 4 - Deadline: partial contributors are bounded by the shared 20 second cap
        expect(settledNew(raceGroups, loaded: 1, total: 3, seconds: 19.9, quality: hint1080, wantedAddon: wanted) == false,
               "deadline: a partial set remains closed immediately before the shared deadline")
        expect(settledNew(raceGroups, loaded: 1, total: 3, seconds: 20, quality: hint1080, wantedAddon: wanted),
               "deadline: the bounded fallback opens at the shared deadline")
        expect(settledNew(raceGroups, loaded: 1, total: 3, seconds: 20, quality: nil, wantedAddon: nil),
               "deadline: a first playable arriving late cannot reset the request-owned settlement clock")
        expect(StreamRanking.completeSetDeadline == SourceSettlementPolicy.maximumWait,
               "deadline: raw waits use the shared complete-set ceiling")

        // MARK: 5 - Fresh/resume/torrent hints all wait for full registration
        expect(settledNew([group("comet", [cometDirect1080])], loaded: 1, total: 3, seconds: 5, quality: nil, wantedAddon: nil) == false,
               "no-wanted fresh: the old four-second early-open window is closed")
        expect(settledOld([group("p", [direct720])], loaded: 1, total: 3, seconds: 1, quality: hint1080) == false,
               "no-wanted resume: a non-matching quality holds early")
        let torrentGroups = [group("comet", [cometTorrent1080])]
        expect(settledOld(torrentGroups, loaded: 1, total: 3, seconds: 1, quality: hint1080) == false,
               "no-wanted resume: a matching torrent cannot open a partial set")
        SourcePreferences.stub.typeOrder = [.torrent, .debrid, .usenet, .direct]
        expect(settledOld(torrentGroups, loaded: 1, total: 3, seconds: 1, quality: hint1080) == false,
               "no-wanted resume: torrent-first preference affects rank, not settlement")
        SourcePreferences.stub = StubPrefs()

        // MARK: guards
        expect(settledNew([], loaded: 0, total: 0, seconds: 99, quality: hint1080, wantedAddon: wanted) == false,
               "guard: an empty group set never settles")
        // A wanted source that is present remains partial until all contributors finish.
        let presentButNoQuality = [group("aiostreams", [direct720])]
        expect(settledNew(presentButNoQuality, loaded: 1, total: 3, seconds: 1, quality: hint1080, wantedAddon: wanted) == false,
               "present: wanted arrival alone cannot commit before all contributors finish")

        // Ranking sees the late superior source only after the complete-set gate opens.
        let inferior = stream(#"{"url":"https://cdn.invalid/inferior.mkv","name":"Comet 720p WEBRip"}"#)
        let superior = stream(#"{"url":"https://cdn.invalid/superior.mkv","name":"AIOStreams 2160p REMUX DV"}"#)
        let completeGroups = [group("comet", [inferior]), group("aiostreams", [superior])]
        expect(settledNew(completeGroups, loaded: 2, total: 2, seconds: 0, quality: nil, wantedAddon: nil),
               "late superior: the complete contributor set settles immediately")
        expect(StreamRanking.best(completeGroups, continuity: nil, pin: nil)?.url == superior.url,
               "late superior: ranking the complete set selects the superior late source")

        let callerPaths = [
            "app/SourcesiOS/iOSDetailView.swift",
            "app/SourcesiOS/iOSBatchDownloadCoordinator.swift",
            "app/SourcesTV/TVEpisodePanel.swift",
            "app/SourcesTV/TVPlayerView.swift",
        ]
        let callerSource = callerPaths.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .joined(separator: "\n")
        expect(callerSource.components(separatedBy: "secondsSinceRequestStart:").count - 1 == 6,
               "caller clock: every raw settle call passes request-start elapsed time")
        expect(!callerSource.contains("secondsSinceFirstPlayable"),
               "caller clock: no production raw settle loop retains the first-playable reset")
        expect(callerSource.components(separatedBy: "let settlementStartedAt = Date()").count - 1 == 6,
               "caller clock: all six raw requests own an absolute settlement start")
        let directDeadlineBreaks = callerSource.components(
            separatedBy: "if elapsed >= StreamRanking.completeSetDeadline { break }"
        ).count - 1
        expect(directDeadlineBreaks == 5 && callerSource.contains("if deadlineReached { break }"),
               "caller clock: every raw loop hard-stops on the same twenty-second request deadline")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
