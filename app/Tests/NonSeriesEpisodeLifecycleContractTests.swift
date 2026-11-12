// Standalone contract for the beta series-lifecycle fence and the broader physical-media identity.
//
//   xcrun swiftc -o /tmp/nonseries-episode-lifecycle-test \
//     app/SourcesShared/DetailMetaRecoveryPolicy.swift \
//     app/SourcesShared/CatalogRowResolution.swift \
//     app/SourcesShared/AppleCWSeasonRolloverPolicy.swift \
//     app/SourcesShared/UsenetStreamValidation.swift \
//     app/SourcesShared/DebridPlaybackAvailability.swift \
//     app/SourcesShared/ProfileAddonPreferences.swift \
//     app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift \
//     app/SourcesShared/CoreModels.swift \
//     app/SourcesShared/SubtitleReleaseFingerprint.swift \
//     app/SourcesShared/DownloadModels.swift \
//     app/Tests/NonSeriesEpisodeLifecycleContractTests.swift && \
//     /tmp/nonseries-episode-lifecycle-test

import Foundation

// MARK: - Minimal CoreModels dependencies

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

enum ProfileStore {
    static func activeDisabledAddons() -> Set<String> { [] }
    static func activeAddonOrder(accountOrder: [String]) -> [String] { accountOrder }
}

// This executable exercises the model's identity and local download resolver, not provider transport.
struct CommunityStreamGateway: Sendable {
    static let shared = Self()
    func localURLIfReady(for stream: CoreStream, upstream: URL) -> URL? { nil }
}

final class DebridKeys: Sendable {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { false }
}

enum UsenetProviderStore { static let isConfigured = false }

enum StremioServer {
    static let usenetNodeBase: String? = nil
    static let base = "http://127.0.0.1:11470"
    static let trailerResolverBase = "https://trailer.invalid"
}

enum PlaybackSettings { static let torrentsDisabled = false }

struct PlaybackMeta: Hashable {
    let libraryId: String
    let videoId: String
    let type: String
    let name: String
    let poster: String?
    let season: Int?
    let episode: Int?

    var usesSeriesLifecycle: Bool {
        EpisodePlaybackIdentity.usesSeriesLifecycle(type: type)
    }
}

// MARK: - Assertions and fixtures

@MainActor private var failures = 0

@MainActor private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

private func playback(type: String, season: Int?, episode: Int?, videoID: String) -> PlaybackMeta {
    PlaybackMeta(
        libraryId: "tt-lifecycle", videoId: videoID, type: type, name: "Lifecycle",
        poster: nil, season: season, episode: episode
    )
}

private func download(type: String, season: Int?, episode: Int?, videoID: String,
                      managedFilename: Bool = false, contentID: String = "tt-lifecycle") -> DownloadRecord {
    let id = UUID()
    return DownloadRecord(
        id: id, contentId: contentID, videoId: videoID, type: type,
        name: "Lifecycle", poster: nil, season: season, episode: episode,
        sourceName: nil, qualityText: nil, isTorrent: false, headers: nil,
        remoteURL: "https://media.invalid/video", localFilename: managedFilename ? "\(id.uuidString).mkv" : "video.mkv",
        bytesTotal: 100, bytesDone: 100, state: .completed,
        addedAt: Date(timeIntervalSince1970: 1)
    )
}

private func continueWatching(type: String, videoID: String, progress: Double) -> CoreCWItem {
    CoreCWItem(
        id: "tt-lifecycle", type: type, name: "Lifecycle", poster: nil,
        state: CoreLibState(
            timeOffset: progress * 100_000, duration: 100_000, videoId: videoID,
            flaggedWatched: 1, timesWatched: 1
        )
    )
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func source(_ relativePath: String) -> String {
    let url = repositoryRoot.appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func slice(_ text: String, from start: String, to end: String) -> String {
    guard let lower = text.range(of: start),
          let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else { return "" }
    return String(text[lower.lowerBound..<upper.lowerBound])
}

private func occurrences(of needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var cursor = text.startIndex
    while let match = text.range(of: needle, range: cursor..<text.endIndex) {
        count += 1
        cursor = match.upperBound
    }
    return count
}

private func hasBroadPhysicalWiring(coreModels: String, bridge: String,
                                    iosRoot: String, tvHome: String,
                                    qualityPicker: String) -> Bool {
    let cwResume = slice(coreModels, from: "static func resolvedURL(for entry", to: "// MARK:")
    let engineBinding = slice(
        bridge, from: "func loadEnginePlayer(for stream: CoreStream, sourceGroupID:",
        to: "func loadEnginePlayer(for stream: CoreStream, videoId: String"
    )
    let iosDirectResume = slice(
        iosRoot, from: "private func iOSDirectResume(for item", to: "private func iOSDirectStream"
    )
    let tvDirectResume = slice(
        tvHome, from: "private func directResume(_ item: CoreCWItem)", to: "private func resumeSource"
    )
    let downloadLaunch = slice(
        qualityPicker, from: "private func launch(_ candidates", to: "private func handleFailures"
    )
    return cwResume.contains("EpisodePlaybackIdentity.isEpisodicContext(")
        && engineBinding.contains("EpisodePlaybackIdentity.isEpisodicContext(")
        && iosDirectResume.contains(
            "let hasEpisodicPhysicalIdentity = EpisodePlaybackIdentity.isEpisodicContext("
        )
        && iosDirectResume.contains("if hasEpisodicPhysicalIdentity, let cwVideo")
        && iosDirectResume.contains("if hasEpisodicPhysicalIdentity, entry.torrent == true")
        && tvDirectResume.contains(
            "let hasEpisodicPhysicalIdentity = EpisodePlaybackIdentity.isEpisodicContext("
        )
        && tvDirectResume.contains("if hasEpisodicPhysicalIdentity, let cwVideo")
        && tvDirectResume.contains(
            "hasEpisodicPhysicalIdentity: hasEpisodicPhysicalIdentity"
        )
        && downloadLaunch.contains(
            "episode != nil || EpisodePlaybackIdentity.isEpisodicContext("
        )
}

@main
private struct NonSeriesEpisodeLifecycleContractTests {
    @MainActor static func main() {
        let collection = playback(
            type: "collection", season: 1, episode: 2, videoID: "tt-lifecycle:1:2"
        )
        let series = playback(
            type: "series", season: 1, episode: 2, videoID: "tt-lifecycle:1:2"
        )
        let canonicalMovieEpisode = playback(
            type: "movie", season: nil, episode: nil, videoID: "tt-lifecycle:2:3"
        )
        let movie = playback(
            type: "movie", season: nil, episode: nil, videoID: "tt-lifecycle"
        )

        let collectionPhysicalIdentity = EpisodePlaybackIdentity.isEpisodicContext(
            type: collection.type, season: collection.season, episode: collection.episode,
            videoID: collection.videoId
        )
        expect(collectionPhysicalIdentity,
               "paired collection S/E fixture retains broad physical episode identity")
        expect(!collection.usesSeriesLifecycle,
               "paired collection S/E fixture is outside beta series lifecycle")
        let collectionSpecial = playback(
            type: "collection", season: 0, episode: 1, videoID: "tt-lifecycle:0:1"
        )
        expect(EpisodePlaybackIdentity.isEpisodicContext(
            type: collectionSpecial.type,
            season: collectionSpecial.season,
            episode: collectionSpecial.episode,
            videoID: collectionSpecial.videoId
        ) && !collectionSpecial.usesSeriesLifecycle,
               "collection S0E1 is physical-only under the same beta fence")
        expect(series.usesSeriesLifecycle,
               "literal series remains inside beta series lifecycle")
        expect(EpisodePlaybackIdentity.isEpisodicContext(
            type: canonicalMovieEpisode.type,
            season: canonicalMovieEpisode.season,
            episode: canonicalMovieEpisode.episode,
            videoID: canonicalMovieEpisode.videoId
        ) && !canonicalMovieEpisode.usesSeriesLifecycle,
               "canonical movie-typed episode stays physical-only during beta")
        expect(!EpisodePlaybackIdentity.isEpisodicContext(
            type: movie.type, season: movie.season, episode: movie.episode, videoID: movie.videoId
        ) && !movie.usesSeriesLifecycle,
               "normal movie remains non-episodic in both domains")

        let semanticFiles = [
            EpisodePlaybackIdentity.FileCandidate(
                offset: 0, name: "Collection.S01E01.mkv", size: 900, isVideo: true
            ),
            EpisodePlaybackIdentity.FileCandidate(
                offset: 1, name: "Collection.S01E02.mkv", size: 800, isVideo: true
            ),
        ]
        expect(EpisodePlaybackIdentity.pickFileOffset(
            semanticFiles, season: collection.season, episode: collection.episode
        ) == 1 && !EpisodePlaybackIdentity.providerArrayFallbackAllowed(
            requiresSemanticSelection: collectionPhysicalIdentity,
            season: nil,
            episode: nil
        ), "physical protection 1: collection S/E requires semantic selection and blocks unscoped fallback")

        let collectionHash = "0123456789abcdef0123456789abcdef01234567"
        expect(!EpisodePlaybackIdentity.torrentMatches(
            rawInfoHash: collectionHash,
            rawFileIdx: nil,
            selectedInfoHash: collectionHash,
            selectedFileIdx: nil,
            isEpisode: collectionPhysicalIdentity
        ), "physical protection 2: collection S/E rejects hash-only torrent identity")

        let savedCollectionVideoID = "tt-lifecycle:1:1"
        let physicalStaleResumeRejected = collectionPhysicalIdentity
            && savedCollectionVideoID != collection.videoId
        expect(physicalStaleResumeRejected,
               "physical protection 3: collection S/E rejects a stale saved episode")

        expect(EpisodePlaybackIdentity.isEpisodicContext(
            type: collection.type,
            season: nil,
            episode: nil,
            videoID: collection.videoId
        ), "physical protection 4: collection canonical video id remains episodic without decoded S/E")

        expect(EpisodePlaybackIdentity.savedResumeTargetsDifferentEpisode(
            usesSeriesLifecycle: series.usesSeriesLifecycle,
            savedVideoID: "tt-lifecycle:1:1",
            requestedVideoID: series.videoId
        ), "series resume rejects a different saved episode")
        expect(!EpisodePlaybackIdentity.savedResumeTargetsDifferentEpisode(
            usesSeriesLifecycle: collection.usesSeriesLifecycle,
            savedVideoID: "tt-lifecycle:1:1",
            requestedVideoID: collection.videoId
        ), "collection S/E resume stays outside beta episode lifecycle")

        expect(!EpisodePlaybackIdentity.canRewindWholeTitleAtTerminal(
            usesSeriesLifecycle: true, currentEpisodeIndex: 1, episodeCount: 8
        ), "legacy series terminal helper stays fail-closed without authority")
        expect(!EpisodePlaybackIdentity.canRewindWholeTitleAtTerminal(
            usesSeriesLifecycle: true, currentEpisodeIndex: 7, episodeCount: 8
        ), "resident count alone cannot prove the final series episode")
        expect(EpisodePlaybackIdentity.canRewindWholeTitleAtTerminal(
            usesSeriesLifecycle: collection.usesSeriesLifecycle,
            currentEpisodeIndex: 1,
            episodeCount: 8
        ), "collection S/E keeps beta non-series terminal behavior")
        expect(EpisodePlaybackIdentity.canRewindWholeTitleAtTerminal(
            usesSeriesLifecycle: movie.usesSeriesLifecycle,
            currentEpisodeIndex: nil,
            episodeCount: 0
        ), "normal movie terminal behavior remains unchanged")

        expect(!continueWatching(
            type: "series", videoID: "tt-lifecycle:1:2", progress: 0
        ).isFinished, "series watched counters do not prune a live title")
        expect(continueWatching(
            type: "collection", videoID: "tt-lifecycle:1:2", progress: 0
        ).isFinished, "collection S/E keeps beta non-series Continue Watching behavior")
        expect(continueWatching(
            type: "movie", videoID: "tt-lifecycle", progress: 0
        ).isFinished, "normal watched movie still leaves Continue Watching")

        let oldCollection = download(
            type: "collection", season: 1, episode: 2, videoID: "tt-lifecycle:1:2"
        )
        expect(!oldCollection.usesSeriesLifecycle,
               "old non-series DownloadRecord with S/E stays outside beta series lifecycle")
        expect(oldCollection.displayTitle == "Lifecycle"
               && oldCollection.groupingKey == "movie:tt-lifecycle:1:2",
               "old non-series S/E download keeps beta non-series display and grouping")
        let roundTrip = try! JSONDecoder().decode(
            DownloadRecord.self,
            from: JSONEncoder().encode(oldCollection)
        )
        expect(roundTrip.type == "collection" && !roundTrip.usesSeriesLifecycle,
               "DownloadRecord fence preserves raw type without an index migration")
        let seriesDownload = download(
            type: "series", season: 1, episode: 2, videoID: "tt-lifecycle:1:2"
        )
        expect(seriesDownload.usesSeriesLifecycle
               && seriesDownload.displayTitle.contains("S1E2")
               && seriesDownload.groupingKey == "series:tt-lifecycle",
               "literal series download keeps episode display and grouping")
        let movieDownload = download(
            type: "movie", season: nil, episode: nil, videoID: "tt-movie"
        )
        expect(!movieDownload.usesSeriesLifecycle
               && movieDownload.displayTitle == "Lifecycle"
               && movieDownload.groupingKey == "movie:tt-movie",
               "normal movie download behavior remains unchanged")

        let e1 = download(type: "series", season: 1, episode: 1, videoID: "tt-lifecycle:1:1")
        let e3 = download(type: "series", season: 1, episode: 3, videoID: "tt-lifecycle:1:3")
        let season2 = download(type: "series", season: 2, episode: 1, videoID: "tt-lifecycle:2:1")
        var incomplete = download(type: "series", season: 1, episode: 2, videoID: "tt-lifecycle:1:2")
        incomplete.state = .downloading
        let alias = download(type: "series", season: 1, episode: 2, videoID: "other-provider-id")
        expect(DownloadRecord.playableCopy(
            of: seriesDownload.playbackMeta, in: [e1, incomplete, alias, seriesDownload], fileExists: { $0.id == seriesDownload.id }
        )?.id == seriesDownload.id, "exact download requires completed identity and actual file")
        expect(DownloadRecord.playableCopy(
            of: seriesDownload.playbackMeta, in: [incomplete, alias], fileExists: { _ in true }
        ) == nil, "no coordinate-only replacement for explicit playback")
        expect(DownloadRecord.playableSuccessor(
            after: e1.playbackMeta, in: [e3, seriesDownload], fileExists: { _ in true }
        )?.id == seriesDownload.id, "download autoplay chooses immediate E+1")
        expect(DownloadRecord.playableSuccessor(
            after: e1.playbackMeta, in: [incomplete, e3, season2], fileExists: { _ in true }
        ) == nil, "missing E+1 cannot jump a gap or season")
        expect(DownloadRecord.playableSuccessor(
            after: e1.playbackMeta, in: [alias, seriesDownload], fileExists: { _ in true }
        ) == nil, "ambiguous local successor identities are refused")
        expect(DownloadRecord.playableSuccessor(
            after: e1.playbackMeta, in: [seriesDownload], fileExists: { _ in false }
        ) == nil, "evicted immediate successor is not playable")
        expect(DownloadRecord.playableSuccessor(
            after: e3.playbackMeta, in: [season2], fileExists: { _ in true }
        ) == nil, "download inventory alone cannot prove cross-season adjacency")
        let boundaryTitle = "tt1234567"
        var finale = download(type: "series", season: 1, episode: 2, videoID: "tt1234567:1:2", contentID: boundaryTitle)
        let following = download(type: "series", season: 2, episode: 1, videoID: "tt1234567:2:1", contentID: boundaryTitle)
        let immediate = download(type: "series", season: 1, episode: 3, videoID: "tt1234567:1:3", contentID: boundaryTitle)
        var later = download(type: "series", season: 1, episode: 4, videoID: "tt1234567:1:4", contentID: boundaryTitle)
        later.state = .failed
        let followingAlias = download(type: "series", season: 2, episode: 1, videoID: "other:2:1", contentID: boundaryTitle)
        let proof = DownloadSeasonBoundary(libraryID: boundaryTitle, finaleVideoID: finale.videoId,
                                           successorVideoID: following.videoId, season: 1, finaleEpisode: 2,
                                           tmdbSeriesID: 100, tmdbFinaleID: 102, tmdbSuccessorID: 201)
        let refreshedProof = DownloadSeasonBoundary(libraryID: boundaryTitle, finaleVideoID: finale.videoId,
                                                    successorVideoID: following.videoId, season: 1, finaleEpisode: 2,
                                                    tmdbSeriesID: 100, tmdbFinaleID: 102, tmdbSuccessorID: 202)
        expect(DownloadSeasonBoundary.Refresh.unavailable.replacement(for: proof) == proof,
               "unavailable or inconsistent metadata retains the last verified evidence")
        expect(DownloadSeasonBoundary.Refresh.contradicted.replacement(for: proof) == nil,
               "a definitive canonical correction removes the stale proof")
        expect(DownloadSeasonBoundary.Refresh.verified(refreshedProof).replacement(for: proof) == refreshedProof,
               "new verified evidence replaces the prior proof")
        var partialObservation = DownloadSeasonBoundary.RefreshObservations(saved: proof)
        partialObservation.observe(seriesID: 100, finaleEpisode: 2, finaleID: nil, successorID: 201)
        expect(partialObservation.incompleteResult.replacement(for: proof) == proof,
               "a missing outgoing season and unchanged observed successor preserve the proof")
        var changedNext = partialObservation
        changedNext.observe(successorID: 202)
        expect(changedNext.incompleteResult.replacement(for: proof) == nil,
               "a changed authenticated next E1 revokes the proof with the outgoing season unavailable")
        var changedTitle = DownloadSeasonBoundary.RefreshObservations(saved: proof)
        changedTitle.observe(seriesID: 101)
        expect(changedTitle.incompleteResult.replacement(for: proof) == nil,
               "a changed unique TV match revokes the proof even without TV details")
        var changedCount = DownloadSeasonBoundary.RefreshObservations(saved: proof)
        changedCount.observe(seriesID: 100, finaleEpisode: 3)
        expect(changedCount.incompleteResult.replacement(for: proof) == nil,
               "a canonical count contradicts the finale even without either season response")
        let legacyIndex = try! JSONEncoder().encode([finale, following])
        let legacyRows = try! JSONDecoder().decode([DownloadRecord].self, from: legacyIndex)
        expect(legacyRows.map(\.id) == [finale.id, following.id] && legacyRows[0].seasonBoundary == nil,
               "indexes without season proof retain every local record")
        var malformedRows = try! JSONSerialization.jsonObject(with: legacyIndex) as! [[String: Any]]
        malformedRows[0]["seasonBoundary"] = ["tmdbSeriesID": "invalid"]
        malformedRows[1]["seasonBoundary"] = true
        let recovered = try! JSONDecoder().decode([DownloadRecord].self,
            from: JSONSerialization.data(withJSONObject: malformedRows))
        expect(recovered.map(\.id) == [finale.id, following.id] && recovered.allSatisfy { $0.seasonBoundary == nil },
               "bad optional proof must not erase existing downloaded files from the index")
        finale.seasonBoundary = proof
        let upgradedIndex = try! JSONEncoder().encode([finale, following])
        let upgraded = try! JSONDecoder().decode([DownloadRecord].self, from: upgradedIndex)
        struct LegacyIdentity: Decodable { let id: UUID; let videoId: String }
        let rollback = try! JSONDecoder().decode([LegacyIdentity].self, from: upgradedIndex)
        expect(upgraded[0].seasonBoundary == proof && rollback.map(\.videoId) == [finale.videoId, following.videoId],
               "valid proof round-trips; rollback readers ignore the additive key")
        expect(DownloadRecord.playableSuccessor(after: finale.playbackMeta, seasonBoundary: proof,
            in: [following], fileExists: { _ in true })?.id == following.id,
            "a proven season boundary can launch the exact local successor")
        expect(DownloadRecord.playableSuccessor(after: finale.playbackMeta, seasonBoundary: proof,
            in: [following, immediate], fileExists: { _ in true })?.id == immediate.id,
            "same-season E+1 keeps priority")
        for indexed in [[following, later], [following, followingAlias]] {
            expect(DownloadRecord.playableSuccessor(after: finale.playbackMeta, seasonBoundary: proof,
                in: indexed, fileExists: { _ in true }) == nil,
                "later same-season records or ambiguous boundary identities veto rollover")
        }
        expect(DownloadRecord.playableSuccessor(after: finale.playbackMeta, seasonBoundary: proof,
            in: [following], fileExists: { _ in false }) == nil,
            "a verified successor with an evicted file remains unavailable")
        expect(DownloadRecord.playableSuccessor(after: immediate.playbackMeta, seasonBoundary: proof,
            in: [following], fileExists: { _ in true }) == nil,
            "the proof cannot authorize a different outgoing episode")
        let witness = DownloadSeasonRolloverWitness(originID: finale.id, originMeta: finale.playbackMeta,
                                                     proof: proof, successorID: following.id)
        expect(witness.accepts(following, in: [finale, following], fileExists: { _ in true }),
               "final mount re-admits the exact original proof and candidate")
        var revised = finale
        revised.seasonBoundary = refreshedProof
        var revoked = finale
        revoked.seasonBoundary = nil
        for indexed in [[following], [revoked, following], [revised, following],
                        [finale, following, later], [finale, following, immediate]] {
            expect(!witness.accepts(following, in: indexed, fileExists: { _ in true }),
                   "a missing origin, proof revocation or replacement, or newly conflicting row rejects the old mount")
        }
        expect(!witness.accepts(following, in: [finale, following], fileExists: { _ in false }),
               "a selected file removed during deferred preparation cannot mount")
        expect(later.contradictsSeasonBoundary(of: finale) && !following.contradictsSeasonBoundary(of: finale)
               && !later.contradictsSeasonBoundary(of: revoked),
               "only an indexed later canonical same-season record retires an existing proof")

        let boundaryDecoder = JSONDecoder()
        boundaryDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let seriesData = Data(#"{"id":100,"seasons":[{"id":10,"season_number":1,"episode_count":2},{"id":20,"season_number":2,"episode_count":1}],"external_ids":{"imdb_id":"tt1234567"}}"#.utf8)
        let boundarySeries = try! boundaryDecoder.decode(DownloadSeasonSeries.self, from: seriesData)
        let fromSeason = boundarySeries.season(1)!
        let toSeason = boundarySeries.season(2)!
        expect(boundarySeries.matches(.imdb(boundaryTitle), requestedID: 100)
               && !boundarySeries.matches(.imdb("tt1234568"), requestedID: 100)
               && !boundarySeries.matches(.tmdb(101), requestedID: 100),
               "the TV response corroborates the exact original canonical identity")
        let first = DownloadSeasonDetails.Episode(id: 101, showId: 100, seasonNumber: 1, episodeNumber: 1)
        let last = DownloadSeasonDetails.Episode(id: 102, showId: 100, seasonNumber: 1, episodeNumber: 2)
        let foreign = DownloadSeasonDetails.Episode(id: 102, showId: 200, seasonNumber: 1, episodeNumber: 2)
        let gap = DownloadSeasonDetails.Episode(id: 103, showId: 100, seasonNumber: 1, episodeNumber: 3)
        let providerDetails = DownloadSeasonDetails(id: 10, seasonNumber: 1, episodes: [last, first])
        expect(providerDetails.completeEpisodes(seriesID: 100, season: fromSeason)?.last?.id == 102,
               "only a complete canonical season confirms its exact finale")
        for rejected in [[last], [first, gap], [first, foreign], [first, first]] {
            let incomplete = DownloadSeasonDetails(id: 10, seasonNumber: 1, episodes: rejected)
            expect(incomplete.completeEpisodes(seriesID: 100, season: fromSeason) == nil,
                   "count mismatch, gap, foreign show and duplicate episode all fail closed")
        }
        expect(providerDetails.completeEpisodes(seriesID: 100, season: toSeason) == nil,
               "response season identity must match the series summary")

        expect(DownloadRecord.permitsDownloadedAdvance(position: 2_160, duration: 2_400),
               "a valid local EOF at the 90 percent boundary admits handoff")
        expect(!DownloadRecord.permitsDownloadedAdvance(position: 10, duration: 2_400)
               && !DownloadRecord.permitsDownloadedAdvance(position: 2_159, duration: 2_400),
               "a premature local EOF never advances")
        expect(!DownloadRecord.permitsDownloadedAdvance(position: nil, duration: 2_400)
               && !DownloadRecord.permitsDownloadedAdvance(position: .infinity, duration: 2_400)
               && !DownloadRecord.permitsDownloadedAdvance(position: 10, duration: 0)
               && !DownloadRecord.permitsDownloadedAdvance(position: 10, duration: .nan),
               "missing, non-finite or non-positive EOF evidence never advances")
        var evidence = PlaybackCompletionEvidence<Int>()
        evidence.begin(owner: 1, mountGeneration: 1)
        evidence.recordDuration(2_400, owner: 1)
        evidence.recordPosition(2_395, owner: 1, transportSettled: false)
        expect(evidence.settledProgress(owner: 1) == nil
               && evidence.consumeEOF(owner: 1, isLive: false, isTrailer: false) == .allowCompletion,
               "optimistic near-end clock cannot advance a download; ordinary EOF policy is unchanged")
        evidence.recordPosition(2_395, owner: 1, transportSettled: true)
        let localEOF = evidence.settledProgress(owner: 1)
        expect(evidence.consumeEOF(owner: 1, isLive: false, isTrailer: false) == .allowCompletion
               && DownloadRecord.permitsDownloadedAdvance(
                   position: localEOF?.position, duration: localEOF?.duration ?? 0),
               "owned settled near-end clock and native duration admit normal downloaded EOF")
        evidence.invalidateSettledPosition(owner: 1)
        expect(evidence.settledProgress(owner: 1) == nil, "unsettled Aether event retires prior local witness")
        evidence.recordPosition(2_395, owner: 1, transportSettled: true)
        evidence.begin(owner: 1, mountGeneration: 2)
        expect(evidence.settledProgress(owner: 1) == nil && evidence.settledProgress(owner: 2) == nil,
               "new physical mount and unrelated owner cannot reuse local EOF evidence")
        expect(DownloadRecord.playableSuccessor(
            after: oldCollection.playbackMeta, in: [e3], fileExists: { _ in true }
        ) == nil, "non-series remains outside download autoplay")

        let generatedName = "\(seriesDownload.id.uuidString).mkv"
        expect(DownloadRecord.isManagedProgressiveFilename(generatedName, id: seriesDownload.id),
               "managed progressive filename binds the exact record UUID")
        expect(!DownloadRecord.isManagedProgressiveFilename("../" + generatedName, id: seriesDownload.id),
               "relative traversal is refused for progressive playback")
        expect(!DownloadRecord.isManagedProgressiveFilename(generatedName, id: UUID()),
               "foreign record file cannot be mounted")
        expect(DownloadRecord.isSafeHLSPackageRelativePath("Library/OSAssetFolder/digest.movpkg"),
               "HLS playback accepts Apple's variable parent")
        expect(!DownloadRecord.isSafeHLSPackageRelativePath("Library/../foreign.movpkg")
               && !DownloadRecord.isSafeHLSPackageRelativePath("/Library/foreign.movpkg"),
               "HLS playback rejects traversal and absolute paths")

        let remembered = download(type: "series", season: 1, episode: 2,
                                  videoID: "tt-lifecycle:1:2", managedFilename: true)
        let otherEdition = download(type: "series", season: 1, episode: 2,
                                     videoID: remembered.videoId, managedFilename: true)
        let rememberedPath = URL(fileURLWithPath: "/old-container/Library/Application Support/Downloads")
            .appendingPathComponent(remembered.localFilename)
        expect(DownloadRecord.rememberedPlayableCopy(of: remembered.playbackMeta,
            rememberedFile: rememberedPath, in: [otherEdition, remembered], fileExists: { _ in true })?.id == remembered.id,
            "a relocated container still selects the exact stored edition instead of the first same-video copy")
        expect(DownloadRecord.rememberedPlayableCopy(of: remembered.playbackMeta,
            rememberedFile: rememberedPath, in: [otherEdition], fileExists: { _ in true }) == nil,
            "an absent indexed file does not fall through to another completed edition")
        expect(DownloadRecord.rememberedPlayableCopy(of: remembered.playbackMeta,
            rememberedFile: rememberedPath, in: [otherEdition, remembered], fileExists: { $0.id != remembered.id }) == nil,
            "an evicted remembered file does not fall through to another completed edition")
        expect(DownloadRecord.rememberedPlayableCopy(of: e3.playbackMeta,
            rememberedFile: rememberedPath, in: [remembered], fileExists: { _ in true }) == nil,
            "a filename hint cannot authorize the wrong title or episode coordinates")
        let unrelatedPath = URL(fileURLWithPath: "/elsewhere").appendingPathComponent(remembered.localFilename)
        expect(DownloadRecord.rememberedPlayableCopy(of: remembered.playbackMeta,
            rememberedFile: unrelatedPath, in: [remembered], fileExists: { _ in true }) == nil,
            "an unrelated file with the same basename is not a managed-path hint")
        var hls = remembered
        hls.hlsRelativePath = "Library/OSAssetFolder/package.movpkg"
        let hlsPath = URL(fileURLWithPath: "/old-container/Library/OSAssetFolder/package.movpkg")
        expect(DownloadRecord.rememberedPlayableCopy(of: hls.playbackMeta,
            rememberedFile: hlsPath, in: [hls], fileExists: { _ in true })?.id == hls.id,
            "HLS selects its exact indexed relative package from a relocated container")
        var ambiguousHLS = otherEdition
        ambiguousHLS.hlsRelativePath = hls.hlsRelativePath
        expect(DownloadRecord.rememberedPlayableCopy(of: hls.playbackMeta,
            rememberedFile: hlsPath, in: [hls, ambiguousHLS], fileExists: { _ in true }) == nil,
            "ambiguous HLS package ownership is refused")

        let coreModelsSource = source("SourcesShared/CoreModels.swift")
        let accountSource = source("SourcesShared/StremioAccount.swift")
        let bridgeSource = source("SourcesShared/CoreBridge.swift")
        let profilesSource = source("SourcesShared/Profiles.swift")
        let scrobbleSource = source("SourcesShared/ScrobbleCoordinator.swift")
        let shadowSource = source("SourcesShared/TraktPlaybackShadow.swift")
        let checkinSource = source("SourcesShared/TraktCheckinChip.swift")
        let playerSource = source("Sources/PlayerScreen.swift")
        let tvPlayerSource = source("SourcesTV/TVPlayerView.swift")
        let detailSource = source("SourcesTV/DetailView.swift")
        let downloadModelsSource = source("SourcesShared/DownloadModels.swift")
        let downloadStoreSource = source("SourcesShared/DownloadStore.swift")
        let downloadManagerSource = source("SourcesShared/DownloadManager.swift")
        let autoAddSource = source("SourcesShared/LibraryAutoAdd.swift")

        expect(coreModelsSource.contains("static func usesSeriesLifecycle(type: String?)")
               && coreModelsSource.contains("INS-260720-03 dissolves this fence"),
               "lifecycle fence is named once and documents its removal order")
        expect(accountSource.contains("var usesSeriesLifecycle: Bool"),
               "PlaybackMeta delegates to the beta lifecycle fence")
        expect(accountSource.contains("usesSeriesLifecycle: meta.usesSeriesLifecycle"),
               "account resume uses the beta lifecycle fence")
        expect(bridgeSource.contains("if meta.usesSeriesLifecycle"),
               "engine watched dispatch uses the lifecycle fence")
        expect(occurrences(of: "usesSeriesLifecycle: meta.usesSeriesLifecycle", in: bridgeSource) >= 3,
               "all three engine resume stores use the lifecycle fence")
        expect(profilesSource.contains("let usesSeriesLifecycle = EpisodePlaybackIdentity.usesSeriesLifecycle"),
               "profile Continue Watching prune uses the lifecycle fence")
        expect(profilesSource.contains("usesSeriesLifecycle: meta.usesSeriesLifecycle"),
               "profile resume uses the lifecycle fence")
        // 8faf9f4 moved the per-dispatch locals into a Sendable `DispatchContext` captured synchronously at
        // enqueue time, so the fence read moved from a local `let isSeries` to the context's stored property.
        // Same seam, same fence: the pin follows the value, not the old variable name.
        expect(scrobbleSource.contains("isSeries: meta.usesSeriesLifecycle"),
               "external scrobble dispatch uses the lifecycle fence")
        expect(shadowSource.contains("if meta.usesSeriesLifecycle"),
               "Trakt playback shadow uses the lifecycle fence")
        expect(checkinSource.contains("EpisodePlaybackIdentity.usesSeriesLifecycle(type: meta.type)"),
               "Trakt check-in uses the lifecycle fence")
        expect(playerSource.contains("terminalSeriesDecision(for: m)")
               && playerSource.contains("terminalRewindGate.issueTerminalRewind()"),
               "iOS EOF and manual-close terminal paths use the fail-closed lifecycle policy")
        expect(tvPlayerSource.contains("m.usesSeriesLifecycle"),
               "tvOS navigation and finale paths use the lifecycle fence")
        expect(detailSource.contains("meta?.usesSeriesLifecycle == true"),
               "detail auto-pick and last-source paths use the lifecycle fence")
        expect(downloadModelsSource.contains("var usesSeriesLifecycle: Bool"),
               "DownloadRecord delegates to the lifecycle fence")
        expect(downloadStoreSource.contains("head.usesSeriesLifecycle")
               && downloadStoreSource.contains("records.first?.usesSeriesLifecycle"),
               "download sorting and grouping use the lifecycle fence")
        expect(downloadManagerSource.contains("record.usesSeriesLifecycle"),
               "download reclamation uses the lifecycle fence")
        expect(autoAddSource.contains("meta.usesSeriesLifecycle ? \"series\" : \"movie\""),
               "auto-add fallback request type uses the lifecycle fence")

        let lifecycleSources = [
            coreModelsSource, accountSource, bridgeSource, profilesSource, scrobbleSource,
            shadowSource, checkinSource, playerSource, tvPlayerSource, detailSource,
            downloadModelsSource, downloadStoreSource, downloadManagerSource, autoAddSource,
        ]
        expect(lifecycleSources.allSatisfy { !$0.contains("isEpisodicPlayback") },
               "rejected broad lifecycle property is absent from all fourteen consumers")
        expect(lifecycleSources.allSatisfy { !$0.contains("provenPlaybackKind") },
               "rejected broad check-in classifier is absent from all fourteen consumers")

        let iosResume = source("SourcesiOS/iOSRootView.swift")
        let tvHome = source("SourcesTV/HomeView.swift")
        let qualityPicker = source("SourcesiOS/DownloadQualityPickerView.swift")
        let cwResumeSource = slice(
            coreModelsSource, from: "static func resolvedURL(for entry", to: "// MARK:"
        )
        expect(cwResumeSource.contains("EpisodePlaybackIdentity.isEpisodicContext("),
               "physical consumer 1: CW semantic reresolve keeps broad identity")
        let engineBindingSource = slice(
            bridgeSource, from: "func loadEnginePlayer(for stream: CoreStream, sourceGroupID:",
            to: "func loadEnginePlayer(for stream: CoreStream, videoId: String"
        )
        expect(engineBindingSource.contains("EpisodePlaybackIdentity.isEpisodicContext("),
               "physical consumer 2: engine pair matching keeps broad identity")
        expect(iosResume.contains(
            "let hasEpisodicPhysicalIdentity = EpisodePlaybackIdentity.isEpisodicContext("
        ) && tvHome.contains(
            "let hasEpisodicPhysicalIdentity = EpisodePlaybackIdentity.isEpisodicContext("
        ), "physical consumer 3: both stale-episode resume guards keep broad identity")
        expect(qualityPicker.contains(
            "episode != nil || EpisodePlaybackIdentity.isEpisodicContext("
        ), "physical consumer 4: canonical-ID download selection keeps broad identity")
        let broadIdentityMutation = "EpisodePlaybackIdentity.isEpisodicContext("
        expect(!hasBroadPhysicalWiring(
            coreModels: coreModelsSource.replacingOccurrences(
                of: broadIdentityMutation, with: "EpisodePlaybackIdentity.usesSeriesLifecycle(type:"
            ),
            bridge: bridgeSource.replacingOccurrences(
                of: broadIdentityMutation, with: "EpisodePlaybackIdentity.usesSeriesLifecycle(type:"
            ),
            iosRoot: iosResume.replacingOccurrences(
                of: broadIdentityMutation, with: "EpisodePlaybackIdentity.usesSeriesLifecycle(type:"
            ),
            tvHome: tvHome.replacingOccurrences(
                of: broadIdentityMutation, with: "EpisodePlaybackIdentity.usesSeriesLifecycle(type:"
            ),
            qualityPicker: qualityPicker.replacingOccurrences(
                of: broadIdentityMutation, with: "EpisodePlaybackIdentity.usesSeriesLifecycle(type:"
            )
        ), "negative mutation control detects removal of broad physical identity")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
