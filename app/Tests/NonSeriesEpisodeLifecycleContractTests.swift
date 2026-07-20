// Standalone contract for the beta series-lifecycle fence and the broader physical-media identity.
//
//   xcrun swiftc -o /tmp/nonseries-episode-lifecycle-test \
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

final class DebridKeys {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { false }
}

enum StremioServer {
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

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

private func playback(type: String, season: Int?, episode: Int?, videoID: String) -> PlaybackMeta {
    PlaybackMeta(
        libraryId: "tt-lifecycle", videoId: videoID, type: type, name: "Lifecycle",
        poster: nil, season: season, episode: episode
    )
}

private func download(type: String, season: Int?, episode: Int?, videoID: String) -> DownloadRecord {
    DownloadRecord(
        id: UUID(), contentId: "tt-lifecycle", videoId: videoID, type: type,
        name: "Lifecycle", poster: nil, season: season, episode: episode,
        sourceName: nil, qualityText: nil, isTorrent: false, headers: nil,
        remoteURL: "https://media.invalid/video", localFilename: "video.mkv",
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
        bridge, from: "func loadEnginePlayer(for stream: CoreStream)",
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
    static func main() {
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
        ), "mid-series EOF cannot rewind the whole title")
        expect(EpisodePlaybackIdentity.canRewindWholeTitleAtTerminal(
            usesSeriesLifecycle: true, currentEpisodeIndex: 7, episodeCount: 8
        ), "resident list proves the final series episode may rewind the whole title")
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
        expect(scrobbleSource.contains("let isSeries = meta.usesSeriesLifecycle"),
               "external scrobble dispatch uses the lifecycle fence")
        expect(shadowSource.contains("if meta.usesSeriesLifecycle"),
               "Trakt playback shadow uses the lifecycle fence")
        expect(checkinSource.contains("EpisodePlaybackIdentity.usesSeriesLifecycle(type: meta.type)"),
               "Trakt check-in uses the lifecycle fence")
        expect(occurrences(of: "usesSeriesLifecycle: m.usesSeriesLifecycle", in: playerSource) >= 2,
               "iOS EOF and manual-close terminal paths use the lifecycle fence")
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
            bridgeSource, from: "func loadEnginePlayer(for stream: CoreStream)",
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
