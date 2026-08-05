// BingeSourceMemoryRaceContractTests: a standalone, runnable proof of the DECISION LOGIC in the diag-22
// binge source-memory race fix. Wave-1 recorded the user's remembered source correctly but auto-next still
// committed off a faster rival, because `StreamRanking.resolveSettled`'s gate opened on quality-from-ANY
// provider: a fast comet|torbox 1080p matched the remembered quality ~1-2s after EOF while the user's
// aggregator (aiostreams/debridio, ~9s to answer) was still loading, and the sticky +6000 bonus cannot
// bonus an ABSENT stream, so the list was ranked ~66% loaded and the rival won. This file drives the REAL
// `resolveSettled` (and the REAL `continuityBonus` behind it, via the real StreamRanking.swift + CoreModels.swift)
// and proves the new wanted-source gate.
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
//     app/SourcesShared/StreamRanking.swift \
//     app/Tests/BingeSourceMemoryRaceContractTests.swift && /tmp/binge-race-test
//
// The load-bearing proof is the OLD-vs-NEW divergence: because the fix makes `wantedAddon: nil` byte-identical
// to the pre-fix gate, calling the SAME real function with `wantedAddon: nil` reproduces the old behavior and
// with `wantedAddon: X` exercises the new one - on one shared fixture, no mirror.

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

/// A fast rival: a direct 1080p WEB stream (non-torrent, playable). Matches the remembered quality, so under
/// the OLD quality-only gate it opened the gate on its own.
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
                                 secondsSinceFirstPlayable: seconds, rememberedQuality: quality,
                                 wantedAddon: wantedAddon)
}
/// The pre-fix behavior, reached through the SAME real function: the fix guarantees `wantedAddon: nil` is
/// byte-identical to the old gate.
private func settledOld(_ groups: [CoreStreamSourceGroup], loaded: Int, total: Int,
                        seconds: TimeInterval, quality: String?) -> Bool {
    StreamRanking.resolveSettled(groups, loaded: loaded, total: total,
                                 secondsSinceFirstPlayable: seconds, rememberedQuality: quality,
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

        // MARK: 1 - RACE REPRODUCED: the old-vs-new divergence on ONE shared fixture
        // Only the rival has answered (1 of 3), the user's aggregator is still loading, 5s in.
        let raceGroups = [group("comet", [cometDirect1080])]
        let old = settledOld(raceGroups, loaded: 1, total: 3, seconds: 5, quality: hint1080)
        let new = settledNew(raceGroups, loaded: 1, total: 3, seconds: 5, quality: hint1080, wantedAddon: wanted)
        expect(old == true,
               "race: the OLD quality-only gate OPENS on the fast rival (this is exactly the diag-22 bug)")
        expect(new == false,
               "race: the NEW gate WAITS - a remembered source that has not arrived does not commit off a rival")
        expect(old != new,
               "race: the wanted-source param is what changed the decision, on an otherwise identical call")

        // MARK: 2 - Wanted PRESENT-and-playable in a partial list -> commit immediately, no needless wait
        let presentGroups = [group("comet", [cometDirect1080]), group("aiostreams", [aioDirect])]
        expect(settledNew(presentGroups, loaded: 2, total: 3, seconds: 1, quality: hint1080, wantedAddon: wanted),
               "present: the wanted source has arrived (loaded < total, only 1s in) -> gate opens at once")
        expect(settledNew(presentGroups, loaded: 2, total: 3, seconds: 1, quality: hint1080, wantedAddon: "AIOStreams"),
               "present: the wanted-source match is case-insensitive, like stickyBonus / the pin match")
        // Present in the list but only as a bare trailer: NOT an arrival, so the bounded wait still holds.
        let trailerOnlyGroups = [group("comet", [cometDirect1080]), group("aiostreams", [bareTrailer])]
        expect(settledNew(trailerOnlyGroups, loaded: 2, total: 3, seconds: 1, quality: hint1080, wantedAddon: wanted) == false,
               "present: a wanted group carrying only a trailer is not an arrival -> keep waiting")

        // MARK: 3 - Everyone answered -> commit even if the wanted source never came
        expect(settledNew(raceGroups, loaded: 3, total: 3, seconds: 0, quality: hint1080, wantedAddon: wanted),
               "everyone-answered: loaded >= total commits, so a wanted source that never returns cannot hang it")

        // MARK: 4 - Deadline: wanted absent, past the 12s cap -> bounded fallback commits
        expect(settledNew(raceGroups, loaded: 1, total: 3, seconds: 11, quality: hint1080, wantedAddon: wanted) == false,
               "deadline: 11s in (< 12) with the wanted source still absent, the gate is still holding")
        expect(settledNew(raceGroups, loaded: 1, total: 3, seconds: 13, quality: hint1080, wantedAddon: wanted),
               "deadline: 13s in (> 12) the bounded fallback opens the gate - the wait can never hang")
        expect(StreamRanking.wantedSourceDeadline == 12,
               "deadline: the cap is the documented 12s, under the commit loop's own ~20s hard cap")

        // MARK: 5 - No-wanted case is byte-identical to before
        // 5a fresh play (no remembered quality): the original snappy 4s window.
        expect(settledNew([group("comet", [cometDirect1080])], loaded: 1, total: 3, seconds: 5, quality: nil, wantedAddon: nil),
               "no-wanted fresh: 5s (> 4) opens the fresh-play window")
        expect(settledNew([group("comet", [cometDirect1080])], loaded: 1, total: 3, seconds: 3, quality: nil, wantedAddon: nil) == false,
               "no-wanted fresh: 3s (< 4) is still too early")
        // 5b resume, quality-only gate: the remembered quality present opens it; absent, it holds to the 16s ceiling.
        expect(settledOld([group("comet", [cometDirect1080])], loaded: 1, total: 3, seconds: 1, quality: hint1080),
               "no-wanted resume: the remembered quality is present -> the quality gate opens")
        expect(settledOld([group("p", [direct720])], loaded: 1, total: 3, seconds: 1, quality: hint1080) == false,
               "no-wanted resume: a non-matching quality holds early")
        expect(settledOld([group("p", [direct720])], loaded: 1, total: 3, seconds: 17, quality: hint1080),
               "no-wanted resume: the 16s ceiling still releases a quality that never returned")
        // 5c the torrent-order branch exercises the real SourcePreferences read surface.
        let torrentGroups = [group("comet", [cometTorrent1080])]
        expect(settledOld(torrentGroups, loaded: 1, total: 3, seconds: 1, quality: hint1080) == false,
               "no-wanted resume: with the default order a matching TORRENT is held (user's stream lands later)")
        SourcePreferences.stub.typeOrder = [.torrent, .debrid, .usenet, .direct]
        expect(settledOld(torrentGroups, loaded: 1, total: 3, seconds: 1, quality: hint1080),
               "no-wanted resume: a torrent-first user's matching torrent opens the gate (torrentOK true)")
        SourcePreferences.stub = StubPrefs()

        // MARK: guards
        expect(settledNew([], loaded: 0, total: 0, seconds: 99, quality: hint1080, wantedAddon: wanted) == false,
               "guard: an empty group set never settles")
        // A wanted source that IS present short-circuits even when quality never matched the remembered hint.
        let presentButNoQuality = [group("aiostreams", [direct720])]
        expect(settledNew(presentButNoQuality, loaded: 1, total: 3, seconds: 1, quality: hint1080, wantedAddon: wanted),
               "present: the wanted source arriving commits even before its quality is judged (best() ranks within it)")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
