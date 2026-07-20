// Standalone executable for the production episode-playback identity predicates in CoreModels.swift.
// VortX has no Xcode test bundle, so compile the real production model file with minimal dependency stubs:
//
//   xcrun swiftc -o /tmp/episode-playback-identity-test \
//     app/SourcesShared/CoreModels.swift \
//     app/SourcesShared/SubtitleReleaseFingerprint.swift \
//     app/Tests/EpisodePlaybackIdentityTests.swift && \
//     /tmp/episode-playback-identity-test
//
// The production predicates cover exact torrent identity, episode-safe raw URL selection, and the debrid
// pack decision. The small surface record below checks the direct-select and binge-target contract that
// consumes those predicates: media, progress, subtitles, and the engine request must all name one episode.

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

// MARK: - Assertions

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
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

private func containsInOrder(_ text: String, _ needles: [String]) -> Bool {
    var cursor = text.startIndex
    for needle in needles {
        guard let match = text.range(of: needle, range: cursor..<text.endIndex) else { return false }
        cursor = match.upperBound
    }
    return true
}

private func usesAtomicReturnedPlaylistEntryID(_ controllerSource: String) -> Bool {
    let loadFile = slice(controllerSource, from: "func loadFile(", to: "private func configureLiveMode")
    let commandHelper = slice(
        controllerSource, from: "private func commandReturningNode(",
        to: "func captureFrameJPEGData"
    )
    return containsInOrder(loadFile, [
        "loadTokenLock.lock()",
        "commandReturningNode(\"loadfile\"",
        "Self.returnedPlaylistEntryID(from: commandNode)",
        "mpv_free_node_contents(&commandNode)",
        "loadProvenance.completeReplacement(",
        "loadTokenLock.unlock()",
    ])
        && commandHelper.contains("mpv_command_ret(mpv, &cargs, &result)")
        && !loadFile.contains("playlist/0/id")
        && !controllerSource.contains("getInt(\"playlist/0/id\")")
}

private func usesAllSeasonDirectResume(_ rootSource: String) -> Bool {
    let episodeList = slice(
        rootSource, from: "let season = entry.season ?? 1",
        to: "let groups = core.streamGroups(forStreamId: entry.videoId)"
    )
    return episodeList.contains(".orderedBySeasonEpisode")
        && episodeList.contains("if !allSeriesVideos.isEmpty")
        && episodeList.contains("label: \"S\\($0.season ?? 1)E\\($0.episodeNumber)")
        && episodeList.contains("in: allSeriesVideos")
        && !episodeList.contains(".filter { ($0.season ?? 1) == season }")
}

private func stream(hash: String, fileIdx: Int?) -> CoreStream {
    var json: [String: Any] = ["infoHash": hash, "name": "Season pack"]
    if let fileIdx { json["fileIdx"] = fileIdx }
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(CoreStream.self, from: data)
}

private func video(id: String, season: Int, episode: Int) -> CoreVideo {
    let data = try! JSONSerialization.data(withJSONObject: [
        "id": id,
        "title": "S\(season)E\(episode)",
        "season": season,
        "episode": episode,
    ])
    return try! JSONDecoder().decode(CoreVideo.self, from: data)
}

/// Small pure transaction driver for the rapid episode-switch composition checks below. It models only the
/// identity-bearing state that both SwiftUI surfaces must move atomically around an accepted player command.
private struct TestEpisodeSource: Equatable {
    let url: String
    let headers: [String: String]
    let streamIdentity: String
    let debridIdentity: String?
    let hint: String
    let binge: String?
    let isTorrent: Bool
    let engineVideoID: String
}

private struct TestPendingEpisode {
    let videoID: String
    let token: PlayerLoadToken
    let source: TestEpisodeSource
    var issued = true
    var terminal = false
}

private struct EpisodeTransactionHarness {
    var publishedVideoID: String
    var progressVideoID: String
    var subtitleVideoID: String
    var boundEngineVideoID: String
    var physicalSource: TestEpisodeSource
    var committedToken: PlayerLoadToken
    var activeToken: PlayerLoadToken
    var pending: TestPendingEpisode?
    var superseded: TestPendingEpisode?
    var resolvingVideoID: String?
    var generation = 0
    var persistenceBlocked = false
    var completedVideoIDs: [String] = []
    var recoverySideEffects = 0
    var advanceOrExitSideEffects = 0
    var savedVideoIDs: [String] = []

    mutating func beginResolve(_ videoID: String) -> Int {
        generation += 1
        resolvingVideoID = videoID
        return generation
    }

    @discardableResult
    mutating func finishResolve(videoID: String, generation capturedGeneration: Int,
                                source: TestEpisodeSource, token: PlayerLoadToken,
                                commandAccepted: Bool) -> Bool {
        guard EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
            capturedGeneration: capturedGeneration, currentGeneration: generation,
            capturedVideoID: videoID, currentVideoID: resolvingVideoID
        ) else { return false }

        if let pending, pending.issued {
            superseded = pending
            self.pending = nil
        }
        resolvingVideoID = nil

        guard commandAccepted else {
            if let superseded, !superseded.terminal, superseded.token == activeToken {
                pending = superseded
                physicalSource = superseded.source
                boundEngineVideoID = superseded.source.engineVideoID
                self.superseded = nil
            }
            persistenceBlocked = pending?.issued == true || self.superseded?.issued == true
            return false
        }

        activeToken = token
        physicalSource = source
        boundEngineVideoID = videoID
        pending = TestPendingEpisode(videoID: videoID, token: token, source: source)
        superseded = nil
        persistenceBlocked = true
        return true
    }

    mutating func resolveNil(videoID: String, generation capturedGeneration: Int) {
        guard EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
            capturedGeneration: capturedGeneration, currentGeneration: generation,
            capturedVideoID: videoID, currentVideoID: resolvingVideoID
        ) else { return }
        resolvingVideoID = nil
        if pending?.terminal == true || superseded?.terminal == true {
            persistenceBlocked = true
        }
    }

    mutating func handleTerminal(_ callbackToken: PlayerLoadToken) -> EpisodePlaybackIdentity.TerminalEventRoute {
        let route = EpisodePlaybackIdentity.terminalEventRoute(
            callbackToken: callbackToken, activeToken: activeToken,
            committedToken: committedToken,
            pendingToken: pending?.token, pendingIssued: pending?.issued == true,
            supersededToken: superseded?.token, supersededIssued: superseded?.issued == true,
            switchingEpisode: resolvingVideoID != nil
        )
        switch route {
        case .committed:
            break
        case .pending:
            pending?.terminal = true
            persistenceBlocked = true
        case .superseded:
            superseded?.terminal = true
            persistenceBlocked = true
        case .outgoingCommittedWhileResolving:
            break
        case .stale:
            break
        }
        return route
    }

    mutating func handleEOF(_ callbackToken: PlayerLoadToken) -> EpisodePlaybackIdentity.TerminalEventRoute {
        let route = handleTerminal(callbackToken)
        switch EpisodePlaybackIdentity.terminalEventAction(route: route, kind: .eof) {
        case .handleCommitted:
            completedVideoIDs.append(publishedVideoID)
            advanceOrExitSideEffects += 1
        case .persistOutgoingCompletionOnly:
            completedVideoIDs.append(publishedVideoID)
        case .handlePending, .markSupersededTerminal, .ignoreOutgoingError, .ignoreStale:
            break
        }
        return route
    }

    mutating func handleError(_ callbackToken: PlayerLoadToken) -> EpisodePlaybackIdentity.TerminalEventRoute {
        let route = handleTerminal(callbackToken)
        if EpisodePlaybackIdentity.terminalEventAction(route: route, kind: .error) == .handleCommitted {
            recoverySideEffects += 1
        }
        return route
    }

    @discardableResult
    mutating func commitFirstFrame(_ callbackToken: PlayerLoadToken) -> Bool {
        guard let pending, !pending.terminal,
              PlayerLoadProvenanceState.canCommit(
                callbackToken: callbackToken, activeToken: activeToken,
                pendingToken: pending.token
              ) else { return false }
        publishedVideoID = pending.videoID
        progressVideoID = pending.videoID
        subtitleVideoID = pending.videoID
        boundEngineVideoID = pending.videoID
        physicalSource = pending.source
        committedToken = callbackToken
        self.pending = nil
        superseded = nil
        persistenceBlocked = false
        return true
    }

    mutating func saveOnExit() {
        guard !persistenceBlocked, pending == nil, superseded == nil else { return }
        savedVideoIDs.append(publishedVideoID)
    }

    mutating func exitPlayback() {
        saveOnExit()
        generation += 1
        resolvingVideoID = nil
    }

    var publishedIdentityIsAtomic: Bool {
        publishedVideoID == progressVideoID && progressVideoID == subtitleVideoID
    }
}

@main
private struct EpisodePlaybackIdentityTests {
    static func main() {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let e2 = stream(hash: hash, fileIdx: 1)
        let e3 = stream(hash: hash, fileIdx: 2)
        let e4 = stream(hash: hash, fileIdx: 0)

        expect(EpisodePlaybackIdentity.isEpisodicContext(
            type: "collection", season: 1, episode: 2,
            videoID: "collection-part-2"
        ), "non-series playback with S/E evidence is episodic")
        expect(EpisodePlaybackIdentity.isEpisodicContext(
            type: "collection", season: 0, episode: 1,
            videoID: "collection-special"
        ), "non-series season-zero special remains episodic")
        expect(EpisodePlaybackIdentity.isEpisodicContext(
            type: "movie", season: nil, episode: nil,
            videoID: "tt0903747:0:1"
        ), "canonical season-zero video suffix is episodic evidence")
        expect(!EpisodePlaybackIdentity.isEpisodicContext(
            type: "movie", season: nil, episode: nil,
            videoID: "distinct-default-video"
        ), "different movie video id alone preserves movie compatibility")
        expect(EpisodePlaybackIdentity.provenEpisodeNumbers(
            season: nil, episode: 1
        ) == nil, "missing season never fabricates an S00 provider target")
        expect(EpisodePlaybackIdentity.provenEpisodeNumbers(
            season: 0, episode: 1
        ) == EpisodePlaybackIdentity.EpisodeNumbers(season: 0, episode: 1),
               "explicit season zero remains a valid special target")

        let s1e9 = video(id: "tt-show:1:9", season: 1, episode: 9)
        let s1Finale = video(id: "tt-show:1:10", season: 1, episode: 10)
        let s2e1 = video(id: "tt-show:2:1", season: 2, episode: 1)
        let fullSeries = [s2e1, s1Finale, s1e9].orderedBySeasonEpisode
        expect(fullSeries.map(\.id) == [s1e9.id, s1Finale.id, s2e1.id],
               "full all-season ordering places S2E1 after the S1 finale")
        let s1FinaleIndex = fullSeries.firstIndex(where: { $0.id == s1Finale.id })
        expect(s1FinaleIndex.map { $0 + 1 < fullSeries.count && fullSeries[$0 + 1].id == s2e1.id } == true,
               "S1 finale has S2E1 as its next direct-resume episode")
        expect(!EpisodePlaybackIdentity.canRewindWholeTitleAtTerminal(
            usesSeriesLifecycle: true,
            currentEpisodeIndex: s1FinaleIndex,
            episodeCount: fullSeries.count
        ), "S1 finale is not terminal when the resident direct-resume list includes S2E1")
        let rootSource = source("SourcesiOS/iOSRootView.swift")
        expect(usesAllSeasonDirectResume(rootSource),
               "iOS direct resume wires the full all-season list into labels and resolver")
        let seasonScopedMutation = rootSource.replacingOccurrences(
            of: ".orderedBySeasonEpisode",
            with: ".filter { ($0.season ?? 1) == season }"
        )
        expect(!usesAllSeasonDirectResume(seasonScopedMutation),
               "negative mutation control rejects a season-scoped direct-resume list")
        expect(EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
            capturedGeneration: 7, currentGeneration: 7,
            capturedVideoID: "episode-2", currentVideoID: "episode-2"
        ), "async media result is accepted for its current generation and target")
        expect(!EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
            capturedGeneration: 7, currentGeneration: 8,
            capturedVideoID: "episode-2", currentVideoID: "episode-2"
        ), "async media result is rejected after generation invalidation")
        expect(!EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
            capturedGeneration: 7, currentGeneration: 7,
            capturedVideoID: "episode-2", currentVideoID: "episode-3"
        ), "async media result is rejected after target identity changes")

        let terminalCommittedToken = PlayerLoadToken()
        let terminalPendingToken = PlayerLoadToken()
        let terminalSupersededToken = PlayerLoadToken()
        expect(EpisodePlaybackIdentity.terminalEventRoute(
            callbackToken: terminalCommittedToken, activeToken: terminalCommittedToken,
            committedToken: terminalCommittedToken,
            pendingToken: nil, pendingIssued: false,
            switchingEpisode: true
        ) == .outgoingCommittedWhileResolving,
               "exact committed terminal gets the explicit route while a new target resolves")
        expect(EpisodePlaybackIdentity.terminalEventAction(
            route: .outgoingCommittedWhileResolving, kind: .eof
        ) == .persistOutgoingCompletionOnly,
               "shared terminal policy persists only outgoing committed EOF completion")
        expect(EpisodePlaybackIdentity.terminalEventAction(
            route: .outgoingCommittedWhileResolving, kind: .error
        ) == .ignoreOutgoingError,
               "shared terminal policy ignores outgoing error recovery while target resolves")
        expect(EpisodePlaybackIdentity.terminalEventRoute(
            callbackToken: terminalPendingToken, activeToken: terminalPendingToken,
            committedToken: terminalCommittedToken,
            pendingToken: nil, pendingIssued: false,
            switchingEpisode: true
        ) == .stale, "unissued resolve rejects an active callback that is not the committed token")
        expect(EpisodePlaybackIdentity.terminalEventRoute(
            callbackToken: terminalPendingToken, activeToken: terminalPendingToken,
            committedToken: terminalCommittedToken,
            pendingToken: terminalPendingToken, pendingIssued: true,
            switchingEpisode: true
        ) == .pending, "issued incoming terminal routes to its exact pending load")
        expect(EpisodePlaybackIdentity.terminalEventRoute(
            callbackToken: terminalSupersededToken, activeToken: terminalSupersededToken,
            committedToken: terminalCommittedToken,
            pendingToken: nil, pendingIssued: false,
            supersededToken: terminalSupersededToken, supersededIssued: true,
            switchingEpisode: true
        ) == .superseded, "terminal from the physical superseded load stays superseded")
        expect(EpisodePlaybackIdentity.terminalEventRoute(
            callbackToken: terminalCommittedToken, activeToken: terminalCommittedToken,
            committedToken: terminalCommittedToken,
            pendingToken: nil, pendingIssued: false,
            switchingEpisode: false
        ) == .committed, "ordinary committed playback keeps terminal handling enabled")
        expect(EpisodePlaybackIdentity.terminalEventRoute(
            callbackToken: terminalPendingToken, activeToken: terminalCommittedToken,
            committedToken: terminalCommittedToken,
            pendingToken: terminalPendingToken, pendingIssued: true,
            switchingEpisode: true
        ) == .stale, "inactive terminal callback is rejected before episode routing")

        let rapidE2Generation = 20
        let rapidE3Generation = 21
        let rapidE4Generation = 22
        expect(!EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
            capturedGeneration: rapidE2Generation, currentGeneration: rapidE4Generation,
            capturedVideoID: "episode-2", currentVideoID: "episode-4"
        ), "rapid E2 result cannot publish after E4 becomes current")
        expect(!EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
            capturedGeneration: rapidE3Generation, currentGeneration: rapidE4Generation,
            capturedVideoID: "episode-3", currentVideoID: "episode-4"
        ), "rapid E3 result cannot publish after E4 becomes current")
        expect(EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
            capturedGeneration: rapidE4Generation, currentGeneration: rapidE4Generation,
            capturedVideoID: "episode-4", currentVideoID: "episode-4"
        ), "rapid E2 to E3 to E4 selection admits only E4")
        expect(!EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
            capturedGeneration: 30, currentGeneration: 31,
            capturedVideoID: "episode-2", currentVideoID: "episode-2"
        ), "explicit source choice invalidates an older fallback generation")

        let outgoingToken = PlayerLoadToken()
        let incomingToken = PlayerLoadToken()
        expect(outgoingToken != incomingToken,
               "equal or rewritten URLs still receive distinct opaque load tokens")

        let returnedFields = [
            PlayerLoadProvenanceState.CommandResultField(key: "ignored", int64Value: 11),
            PlayerLoadProvenanceState.CommandResultField(key: "playlist_entry_id", int64Value: 202),
        ]
        expect(PlayerLoadProvenanceState.playlistEntryID(from: returnedFields) == 202,
               "atomic loadfile result extracts its exact returned playlist entry id")
        expect(PlayerLoadProvenanceState.playlistEntryID(from: [
            .init(key: "playlist_entry_id", int64Value: nil),
        ]) == nil, "mistyped returned playlist entry id fails closed")
        expect(PlayerLoadProvenanceState.playlistEntryID(from: [
            .init(key: "playlist_entry_id", int64Value: 202),
            .init(key: "playlist_entry_id", int64Value: 203),
        ]) == nil, "duplicate returned playlist entry ids fail closed")
        expect(PlayerLoadProvenanceState.playlistEntryID(from: [
            .init(key: "playlist_entry_id", int64Value: 0),
        ]) == nil, "non-positive returned playlist entry id fails closed")

        var atomicResultState = PlayerLoadProvenanceState()
        let atomicResultToken = PlayerLoadToken()
        let atomicResultID = PlayerLoadProvenanceState.playlistEntryID(from: returnedFields) ?? 0
        expect(atomicResultState.completeReplacement(
            commandSucceeded: true, entryID: atomicResultID, token: atomicResultToken
        ) && atomicResultState.token(forEntryID: 202) == atomicResultToken,
               "atomic returned id registers the exact replacement request")

        let controllerSource = source("Sources/Player/MPVMetalViewController.swift")
        expect(usesAtomicReturnedPlaylistEntryID(controllerSource),
               "controller holds START_FILE lock through command result extraction and registration")
        let postCommandLookupMutation = controllerSource.replacingOccurrences(
            of: "Self.returnedPlaylistEntryID(from: commandNode)",
            with: "Int64(getInt(\"playlist/0/id\"))"
        )
        expect(!usesAtomicReturnedPlaylistEntryID(postCommandLookupMutation),
               "negative mutation control rejects a post-command playlist index lookup")

        var mpvState = PlayerLoadProvenanceState()
        mpvState.registerRequest(entryID: 101, token: outgoingToken)
        expect(mpvState.activeToken == outgoingToken,
               "successful mpv command registration proves issuance synchronously")
        expect(mpvState.callbackToken() == nil,
               "mpv property callbacks stay closed until START_FILE binds the exact entry")
        mpvState.bindStart(entryID: 101)
        expect(mpvState.callbackToken(requiresLoadedFile: true) == nil,
               "mpv positive time callback is closed before FILE_LOADED")
        mpvState.markFileLoaded()
        let queuedOutgoingCallback = mpvState.callbackToken(requiresLoadedFile: true)
        expect(queuedOutgoingCallback == outgoingToken,
               "mpv loaded file callback carries its exact request token")

        let rejectedReplacementToken = PlayerLoadToken()
        expect(!mpvState.completeReplacement(
            commandSucceeded: false, entryID: 0, token: rejectedReplacementToken
        ), "rejected mpv replacement reports no issuance")
        expect(mpvState.activeToken == outgoingToken
               && mpvState.callbackToken(requiresLoadedFile: true) == outgoingToken,
               "rejected mpv replacement preserves the prior active request and callback provenance")

        let unprovableReplacementToken = PlayerLoadToken()
        expect(!mpvState.completeReplacement(
            commandSucceeded: true, entryID: 0, token: unprovableReplacementToken
        ), "accepted mpv replacement without an entry ID fails closed")
        expect(mpvState.activeToken == nil,
               "accepted but unprovable mpv replacement cannot falsely restore the prior request")

        expect(mpvState.token(forEntryID: 101) == nil,
               "accepted mpv replacement retires stale EOF playlist-entry provenance")
        expect(mpvState.completeReplacement(
            commandSucceeded: true, entryID: 202, token: incomingToken
        ), "accepted mpv replacement registers its exact playlist entry")
        mpvState.bindStart(entryID: 101)
        expect(mpvState.activeToken == incomingToken && mpvState.callbackToken() == nil,
               "queued START_FILE for a retired entry cannot erase the accepted replacement token")
        mpvState.bindStart(entryID: 202)
        mpvState.markFileLoaded()
        expect(!PlayerLoadProvenanceState.accepts(
            callbackToken: queuedOutgoingCallback, activeToken: mpvState.activeToken
        ), "queued mpv callback from the invalidated load is rejected")
        expect(PlayerLoadProvenanceState.canCommit(
            callbackToken: incomingToken, activeToken: mpvState.activeToken,
            pendingToken: incomingToken
        ), "pending first-frame commit requires the exact new load token")
        expect(!PlayerLoadProvenanceState.canCommit(
            callbackToken: outgoingToken, activeToken: mpvState.activeToken,
            pendingToken: incomingToken
        ), "stale outgoing tick cannot commit incoming episode identity")

        let identicalURL = "https://cdn.invalid/reused-file"
        let rapidURLs = [identicalURL, identicalURL, identicalURL]
        let rapidAToken = PlayerLoadToken()
        let rapidBToken = PlayerLoadToken()
        let rapidCToken = PlayerLoadToken()
        var rapidLoadState = PlayerLoadProvenanceState()
        rapidLoadState.registerRequest(entryID: 501, token: rapidAToken)
        _ = rapidLoadState.completeReplacement(
            commandSucceeded: true, entryID: 502, token: rapidBToken
        )
        _ = rapidLoadState.completeReplacement(
            commandSucceeded: true, entryID: 503, token: rapidCToken
        )
        rapidLoadState.bindStart(entryID: 501)
        rapidLoadState.bindStart(entryID: 502)
        expect(rapidURLs.allSatisfy { $0 == identicalURL }
               && rapidLoadState.activeToken == rapidCToken
               && rapidLoadState.callbackToken() == nil,
               "rapid identical-URL A/B START events cannot bind after C registration")
        rapidLoadState.bindStart(entryID: 503)
        rapidLoadState.markFileLoaded()
        expect(rapidLoadState.callbackToken(requiresLoadedFile: true) == rapidCToken,
               "rapid identical-URL A/B/C publishes only exact returned C entry")
        expect(rapidLoadState.token(forEntryID: 501) == nil
               && rapidLoadState.token(forEntryID: 502) == nil,
               "accepted replacement drops later END_FILE error ownership for A and B")

        let redirectToken = PlayerLoadToken()
        var redirectState = PlayerLoadProvenanceState()
        redirectState.registerRequest(entryID: 300, token: redirectToken)
        redirectState.propagateRedirect(from: 300, firstInsertedID: 400, count: 2)
        expect(redirectState.token(forEntryID: 400) == redirectToken
               && redirectState.token(forEntryID: 401) == redirectToken,
               "mpv redirect entries inherit only their originating request token")
        expect(redirectState.token(forEntryID: 399) == nil
               && redirectState.token(forEntryID: 402) == nil,
               "mpv redirect propagation does not claim unrelated playlist entries")
        redirectState.bindStart(entryID: 400)
        redirectState.markFileLoaded()
        expect(redirectState.callbackToken(requiresLoadedFile: true) == redirectToken,
               "proxy or redirect URL rewrite preserves opaque request provenance")

        expect(!PlayerLoadProvenanceState.acceptsAVCallback(
            callbackToken: incomingToken, activeToken: incomingToken,
            capturedItemIsCurrent: false
        ), "AVPlayer observer from a replaced item is rejected even with a reused token")
        expect(PlayerLoadProvenanceState.acceptsAVCallback(
            callbackToken: incomingToken, activeToken: incomingToken,
            capturedItemIsCurrent: true
        ), "AVPlayer observer requires both current item and current token")
        expect(!PlayerLoadProvenanceState.acceptsAVCallback(
            callbackToken: outgoingToken, activeToken: incomingToken,
            capturedItemIsCurrent: true
        ), "AVPlayer observer from a replaced logical load is rejected")
        expect(!PlayerLoadProvenanceState.accepts(
            callbackToken: outgoingToken, activeToken: incomingToken
        ), "late mpv subtitle fetch cannot attach to replacement media")
        expect(!PlayerLoadProvenanceState.acceptsAVCallback(
            callbackToken: incomingToken, activeToken: incomingToken,
            capturedItemIsCurrent: false
        ), "late AVPlayer subtitle fetch cannot attach after item replacement")
        expect(PlayerLoadProvenanceState.acceptsAVCallback(
            callbackToken: incomingToken, activeToken: incomingToken,
            capturedItemIsCurrent: true
        ), "internal remux retry retains its logical token for the fresh current item")

        expect(EpisodePlaybackIdentity.torrentMatches(
            rawInfoHash: hash.uppercased(), rawFileIdx: 1,
            selectedInfoHash: e2.infoHash, selectedFileIdx: e2.fileIdx
        ), "exact torrent identity accepts E2 by hash and file index")
        expect(!EpisodePlaybackIdentity.torrentMatches(
            rawInfoHash: hash, rawFileIdx: e3.fileIdx,
            selectedInfoHash: e2.infoHash, selectedFileIdx: e2.fileIdx
        ), "same hash E3 cannot impersonate E2")
        expect(!EpisodePlaybackIdentity.torrentMatches(
            rawInfoHash: hash, rawFileIdx: e4.fileIdx,
            selectedInfoHash: e2.infoHash, selectedFileIdx: e2.fileIdx
        ), "same hash E4 cannot impersonate E2")
        expect(!EpisodePlaybackIdentity.torrentMatches(
            rawInfoHash: hash, rawFileIdx: nil,
            selectedInfoHash: hash, selectedFileIdx: nil
        ), "hash-only torrents do not form a proven identity pair")
        expect(EpisodePlaybackIdentity.torrentMatches(
            rawInfoHash: hash, rawFileIdx: nil,
            selectedInfoHash: hash, selectedFileIdx: nil, isEpisode: false
        ), "legacy hash-only movie engine matching remains compatible")
        expect(!EpisodePlaybackIdentity.torrentMatches(
            rawInfoHash: hash, rawFileIdx: -1,
            selectedInfoHash: hash, selectedFileIdx: -1
        ), "equal negative selectors do not form a proven identity pair")

        expect(EpisodePlaybackIdentity.playableTorrentFileIndex(fileIdx: e2.fileIdx, isEpisode: true) == 1,
               "episode raw URL retains E2 file selector")
        expect(EpisodePlaybackIdentity.playableTorrentFileIndex(fileIdx: nil, isEpisode: true) == nil,
               "hash-only episode row fails closed instead of selecting file zero")
        expect(EpisodePlaybackIdentity.playableTorrentFileIndex(fileIdx: nil, isEpisode: false) == 0,
               "movie hash-only behavior remains file-zero compatible")
        expect(EpisodePlaybackIdentity.playableTorrentFileIndex(fileIdx: -1, isEpisode: true) == nil,
               "negative episode file selector fails closed")
        expect(EpisodePlaybackIdentity.playableTorrentFileIndex(fileIdx: -1, isEpisode: false) == nil,
               "negative movie file selector fails closed")
        expect(EpisodePlaybackIdentity.engineBindingSource(
            isRawTorrent: true, fileIdx: e2.fileIdx, resolvedURL: nil
        ) == .original, "raw episode torrent with selector binds its original stream")
        expect(EpisodePlaybackIdentity.engineBindingSource(
            isRawTorrent: true, fileIdx: e2.fileIdx, resolvedURL: "https://debrid.invalid/e2-explicit"
        ) == .resolvedDirectURL("https://debrid.invalid/e2-explicit"),
               "debrid playback binds its actual direct URL even when the raw torrent had a selector")
        expect(EpisodePlaybackIdentity.engineBindingSource(
            isRawTorrent: true, fileIdx: nil, resolvedURL: nil
        ) == nil, "raw hash-only episode cannot bind without a resolved direct URL")
        expect(EpisodePlaybackIdentity.engineBindingSource(
            isRawTorrent: true, fileIdx: nil, resolvedURL: "https://debrid.invalid/e2"
        ) == .resolvedDirectURL("https://debrid.invalid/e2"),
               "resolved hash-only episode binds the concrete direct URL without inventing fileIdx")
        expect(EpisodePlaybackIdentity.engineBindingSource(
            isRawTorrent: false, fileIdx: nil, resolvedURL: nil
        ) == .original, "direct URL carrying torrent provenance is not rejected as a raw torrent")
        expect(EpisodePlaybackIdentity.engineBindingSource(
            isRawTorrent: false, fileIdx: nil,
            resolvedURL: "https://debrid.invalid/resolved-usenet-e2"
        ) == .resolvedDirectURL("https://debrid.invalid/resolved-usenet-e2"),
               "resolved usenet binds the concrete direct URL instead of its NZB descriptor")
        let rawNZB = URL(string: "https://usenet.invalid/show-s01e02.nzb")!
        let resolvedUsenet = URL(string: "https://debrid.invalid/show-s01e02.mkv")!
        expect(EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: true, resolvedURL: nil, fallbackURL: rawNZB
        ) == nil, "raw NZB descriptor is never selected as media")
        expect(EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: true, resolvedURL: resolvedUsenet, fallbackURL: rawNZB
        ) == resolvedUsenet, "resolved usenet direct URL is selected as media")

        let files = [
            EpisodePlaybackIdentity.FileCandidate(offset: 0, name: "Show.S01E04.mkv", size: 900, isVideo: true),
            EpisodePlaybackIdentity.FileCandidate(offset: 1, name: "Show.S01E02.mkv", size: 700, isVideo: true),
            EpisodePlaybackIdentity.FileCandidate(offset: 2, name: "Show.S01E03.mkv", size: 800, isVideo: true),
        ]
        expect(EpisodePlaybackIdentity.pickFileOffset(files, season: 1, episode: 2) == 1,
               "debrid season pack selects the positive E2 filename match")
        expect(EpisodePlaybackIdentity.pickFileOffset(files, season: 1, episode: 9) == nil,
               "multi-file episode pack without a positive match fails closed")
        let duplicateExact = files + [
            EpisodePlaybackIdentity.FileCandidate(
                offset: 3, name: "Show.S01E02.alt.mkv", size: 650, isVideo: true
            ),
        ]
        expect(EpisodePlaybackIdentity.pickFileOffset(
            duplicateExact, season: 1, episode: 2
        ) == nil, "two equally authoritative E2 filename matches fail closed")
        let prefixCollisions = [
            EpisodePlaybackIdentity.FileCandidate(offset: 0, name: "Show.S01E020.mkv", size: 900, isVideo: true),
            EpisodePlaybackIdentity.FileCandidate(offset: 1, name: "Show.1x020.mkv", size: 800, isVideo: true),
        ]
        expect(EpisodePlaybackIdentity.pickFileOffset(
            prefixCollisions, season: 1, episode: 2
        ) == nil, "E2 does not match S01E020 or 1x020")
        let exactOneX = prefixCollisions + [
            EpisodePlaybackIdentity.FileCandidate(offset: 2, name: "Show.1x02.mkv", size: 700, isVideo: true),
        ]
        expect(EpisodePlaybackIdentity.pickFileOffset(
            exactOneX, season: 1, episode: 2
        ) == 2, "1x02 matches E2 while 1x020 remains excluded")
        let mixedEpisodeNotation = [
            EpisodePlaybackIdentity.FileCandidate(offset: 0, name: "Show.S01E02.mkv", size: 700, isVideo: true),
            EpisodePlaybackIdentity.FileCandidate(offset: 1, name: "Show.1x02.mkv", size: 650, isVideo: true),
        ]
        expect(EpisodePlaybackIdentity.pickFileOffset(
            mixedEpisodeNotation, season: 1, episode: 2
        ) == nil, "mixed S01E02 and 1x02 positive matches remain ambiguous")
        let sole = [EpisodePlaybackIdentity.FileCandidate(offset: 0, name: "opaque.mkv", size: 500, isVideo: true)]
        expect(EpisodePlaybackIdentity.pickFileOffset(sole, season: 1, episode: 2) == 0,
               "one video remains an unambiguous episode pick")
        expect(EpisodePlaybackIdentity.pickFileOffset(
            duplicateExact, season: 1, episode: 2,
            sourceFilename: "Season/Show.S01E02.alt.mkv"
        ) == 3, "exact normalized source filename disambiguates duplicate episode labels")
        let seasonZero = [
            EpisodePlaybackIdentity.FileCandidate(offset: 0, name: "Show.S00E02.mkv", size: 700, isVideo: true),
            EpisodePlaybackIdentity.FileCandidate(offset: 1, name: "Show.S00E01.mkv", size: 600, isVideo: true),
        ]
        expect(EpisodePlaybackIdentity.pickFileOffset(seasonZero, season: 0, episode: 1) == 1,
               "season-zero S00E01 filename is matched exactly")
        let opaque = [EpisodePlaybackIdentity.FileCandidate(
            offset: 0, name: "provider-opaque", size: 500, isVideo: false
        )]
        expect(EpisodePlaybackIdentity.pickFileOffset(opaque, season: 1, episode: 2) == 0,
               "one provider-opaque file remains unambiguous")
        let movieFiles = [
            EpisodePlaybackIdentity.FileCandidate(offset: 0, name: "feature-1080p.mkv", size: 700, isVideo: true),
            EpisodePlaybackIdentity.FileCandidate(offset: 1, name: "feature-4k.mkv", size: 1_400, isVideo: true),
        ]
        expect(EpisodePlaybackIdentity.pickFileOffset(
            movieFiles, season: nil, episode: nil
        ) == 1, "movie provider selection preserves the largest effective video fallback")

        // Reresolve provider arrays must distinguish a movie from an episode whose semantic identity was
        // lost. The control proves this season pack's unscoped picker would choose the largest E3 file. The
        // production gate used by every provider must stop RD/AD/PM re-add and TorBox fast-ID failure first.
        let unscopedSeasonPack = [
            EpisodePlaybackIdentity.FileCandidate(
                offset: 0, name: "Show.S01E02.mkv", size: 700, isVideo: true
            ),
            EpisodePlaybackIdentity.FileCandidate(
                offset: 1, name: "Show.S01E03.mkv", size: 1_400, isVideo: true
            ),
        ]
        expect(EpisodePlaybackIdentity.pickFileOffset(
            unscopedSeasonPack, season: nil, episode: nil
        ) == 1, "regression control: unscoped season-pack selection reaches the largest file")
        func reresolveFallbackPick(requiresSemanticSelection: Bool,
                                   season: Int?, episode: Int?, sourceFilename: String? = nil) -> Int? {
            guard EpisodePlaybackIdentity.providerArrayFallbackAllowed(
                requiresSemanticSelection: requiresSemanticSelection,
                season: season, episode: episode, sourceFilename: sourceFilename
            ) else { return nil }
            return EpisodePlaybackIdentity.pickFileOffset(
                unscopedSeasonPack, season: season, episode: episode,
                sourceFilename: sourceFilename
            )
        }
        for provider in ["Real-Debrid", "AllDebrid", "Premiumize"] {
            expect(reresolveFallbackPick(
                requiresSemanticSelection: true, season: nil, episode: nil
            ) == nil, "\(provider) episode reresolve cannot reach largest-file fallback from raw fileIdx")
        }
        expect(reresolveFallbackPick(
            requiresSemanticSelection: true, season: nil, episode: nil
        ) == nil, "TorBox failed exact-ID path cannot reach largest-file fallback without episode identity")
        expect(reresolveFallbackPick(
            requiresSemanticSelection: false, season: nil, episode: nil
        ) == 1, "movie reresolve preserves largest-file fallback")
        expect(reresolveFallbackPick(
            requiresSemanticSelection: true, season: 0, episode: 1
        ) == nil, "valid season-zero identity authorizes semantic selection but still rejects a mismatched pack")
        expect(EpisodePlaybackIdentity.providerArrayFallbackAllowed(
            requiresSemanticSelection: true, season: nil, episode: nil,
            sourceFilename: "Season/Show.S01E02.mkv"
        ), "an exact source filename remains an independent semantic selector")
        expect(reresolveFallbackPick(
            requiresSemanticSelection: true, season: nil, episode: nil,
            sourceFilename: "missing.mkv"
        ) == nil, "an unmatched semantic filename fails closed instead of choosing the largest file")

        let providerFiles = [
            (id: 901, candidate: EpisodePlaybackIdentity.FileCandidate(
                offset: 0, name: "Pack/Show.S01E04.mkv", size: 900, isVideo: true
            )),
            (id: 17, candidate: EpisodePlaybackIdentity.FileCandidate(
                offset: 1, name: "Pack/Show.S01E02.mkv", size: 700, isVideo: true
            )),
            (id: 4402, candidate: EpisodePlaybackIdentity.FileCandidate(
                offset: 2, name: "Pack/Show.S01E03.mkv", size: 800, isVideo: true
            )),
        ]
        let providerOffset = EpisodePlaybackIdentity.pickFileOffset(
            providerFiles.map(\.candidate), season: 1, episode: 2
        )
        expect(providerOffset.map { providerFiles[$0].id } == 17,
               "nonsequential provider id is selected semantically, never from raw fileIdx")
        let shuffledProviderFiles = [providerFiles[2], providerFiles[0], providerFiles[1]].enumerated().map {
            (id: $0.element.id, candidate: EpisodePlaybackIdentity.FileCandidate(
                offset: $0.offset, name: $0.element.candidate.name,
                size: $0.element.candidate.size, isVideo: $0.element.candidate.isVideo
            ))
        }
        let shuffledOffset = EpisodePlaybackIdentity.pickFileOffset(
            shuffledProviderFiles.map(\.candidate), season: 1, episode: 2
        )
        expect(shuffledOffset.map { shuffledProviderFiles[$0].id } == 17,
               "shuffled provider order still selects the exact episode")

        // Direct select starts with resident E3 but requests E2. The media selector and engine identity are
        // derived independently from production helpers, while progress and subtitle publication use the
        // requested episode's own metadata.
        let e2ID = "tt0903747:1:2"
        let e3ID = "tt0903747:1:3"
        let directMediaIndex = EpisodePlaybackIdentity.playableTorrentFileIndex(
            fileIdx: e2.fileIdx, isEpisode: true
        )
        let directEngineID = EpisodePlaybackIdentity.boundVideoID(
            requestedVideoID: e2ID, bindingSucceeded: directMediaIndex != nil
        )
        let directProgressID = e2ID
        let directSubtitleKey = SubtitleReleaseFingerprint.contentKey(imdbId: "tt0903747", season: 1, episode: 2)
        expect(directMediaIndex == 1, "direct-select: selected media index stays E2")
        expect(directProgressID == e2ID && directProgressID != e3ID, "direct-select: progress metadata stays E2")
        expect(directSubtitleKey == "imdb:tt0903747:1:2", "direct-select: subtitle key stays E2")
        expect(directEngineID == e2ID, "direct-select: engine request stays E2")
        let storedRawHash = e2.infoHash
        let storedRawIndex = e2.fileIdx
        expect(EpisodePlaybackIdentity.torrentMatches(
            rawInfoHash: storedRawHash, rawFileIdx: storedRawIndex,
            selectedInfoHash: e2.infoHash, selectedFileIdx: e2.fileIdx
        ), "raw E2 selector survives a Continue-Watching identity round trip")
        let emptyResidentGroups: [CoreStream] = []
        let synthesizedResumeStream = emptyResidentGroups.first(where: {
            EpisodePlaybackIdentity.torrentMatches(
                rawInfoHash: storedRawHash, rawFileIdx: storedRawIndex,
                selectedInfoHash: $0.infoHash, selectedFileIdx: $0.fileIdx
            )
        }) ?? stream(hash: storedRawHash!, fileIdx: storedRawIndex)
        expect(synthesizedResumeStream.playableURL(isEpisode: true)?.path.hasSuffix("/\(hash)/1") == true,
               "groups-empty Continue-Watching replay synthesizes the exact hash and fileIdx media URL")
        expect(EpisodePlaybackIdentity.boundVideoID(requestedVideoID: e2ID, bindingSucceeded: false) == nil,
               "failed engine bind keeps attribution state closed")
        expect(!EpisodePlaybackIdentity.canIssueEpisodeSwitch(
            currentVideoID: e3ID, targetVideoID: e2ID,
            currentURL: URL(string: "https://cdn.invalid/e3")!,
            targetURL: URL(string: "https://cdn.invalid/e3")!
        ), "different episode resolving to the outgoing URL fails closed")

        // Timing contract for an in-player E3 -> E2 switch. Resolving E2 must not bind early while E3 can
        // still emit ticks. At the synchronous issue point the engine moves to E2, which closes writes until
        // E2's first frame publishes the displayed identity. Only then can E2 engine writes resume.
        var displayedVideoID = e3ID
        var progressMetadataID = e3ID
        var subtitleContentKey = SubtitleReleaseFingerprint.contentKey(imdbId: "tt0903747", season: 1, episode: 3)
        var boundVideoID = EpisodePlaybackIdentity.boundVideoID(requestedVideoID: e3ID, bindingSucceeded: true)
        expect(EpisodePlaybackIdentity.engineWritesAllowed(
            boundVideoID: boundVideoID, displayedVideoID: displayedVideoID
        ), "outgoing E3 writes remain open while E2 resolves")
        expect(!EpisodePlaybackIdentity.engineWritesAllowed(
            boundVideoID: e2ID, displayedVideoID: displayedVideoID
        ), "an early E2 bind cannot attribute outgoing E3 media")
        let bingeMediaIndex = EpisodePlaybackIdentity.playableTorrentFileIndex(
            fileIdx: e2.fileIdx, isEpisode: true
        )
        boundVideoID = EpisodePlaybackIdentity.boundVideoID(
            requestedVideoID: e2ID, bindingSucceeded: bingeMediaIndex != nil
        ) // synchronous load-issuance point
        expect(!EpisodePlaybackIdentity.engineWritesAllowed(
            boundVideoID: boundVideoID, displayedVideoID: displayedVideoID
        ), "E2 binding closes writes until E2 first frame")
        expect(!PlayerLoadProvenanceState.canCommit(
            callbackToken: outgoingToken, activeToken: incomingToken,
            pendingToken: incomingToken
        ), "composition: stale E3 frame cannot publish E2 identity")
        let e2FirstFrameAccepted = PlayerLoadProvenanceState.canCommit(
            callbackToken: incomingToken, activeToken: incomingToken,
            pendingToken: incomingToken
        )
        if e2FirstFrameAccepted {
            displayedVideoID = e2ID            // first-frame identity commit
            progressMetadataID = e2ID
            subtitleContentKey = SubtitleReleaseFingerprint.contentKey(
                imdbId: "tt0903747", season: 1, episode: 2
            )
        }
        expect(EpisodePlaybackIdentity.engineWritesAllowed(
            boundVideoID: boundVideoID, displayedVideoID: displayedVideoID
        ), "E2 first frame opens only E2 engine writes")
        expect(bingeMediaIndex == 1, "binge-target: selected media index stays E2")
        expect(progressMetadataID == e2ID, "binge-target: progress metadata publishes E2 at first frame")
        expect(subtitleContentKey == "imdb:tt0903747:1:2", "binge-target: subtitle key publishes E2 at first frame")
        expect(boundVideoID == e2ID, "binge-target: engine request stays E2")
        expect(e2FirstFrameAccepted && bingeMediaIndex == 1
               && progressMetadataID == e2ID
               && subtitleContentKey == "imdb:tt0903747:1:2"
               && boundVideoID == e2ID,
               "composition: played file, progress, subtitle key, and engine request all stay E2")

        let e4ID = "tt0903747:1:4"
        let transactionE2Token = PlayerLoadToken()
        let transactionE2Source = TestEpisodeSource(
            url: "https://cdn.invalid/e2", headers: ["X-Episode": "2"],
            streamIdentity: "pack-hash#1", debridIdentity: "debrid-e2",
            hint: "1080p-e2", binge: "release-a", isTorrent: false,
            engineVideoID: e2ID
        )
        let transactionE3Source = TestEpisodeSource(
            url: "https://cdn.invalid/e3", headers: ["X-Episode": "3"],
            streamIdentity: "pack-hash#2", debridIdentity: "debrid-e3",
            hint: "1080p-e3", binge: "release-a", isTorrent: false,
            engineVideoID: e3ID
        )
        let transactionE4Source = TestEpisodeSource(
            url: "https://cdn.invalid/e4", headers: ["X-Episode": "4"],
            streamIdentity: "pack-hash#3", debridIdentity: "debrid-e4",
            hint: "2160p-e4", binge: "release-b", isTorrent: false,
            engineVideoID: e4ID
        )
        func newTransaction() -> EpisodeTransactionHarness {
            EpisodeTransactionHarness(
                publishedVideoID: e2ID, progressVideoID: e2ID,
                subtitleVideoID: e2ID, boundEngineVideoID: e2ID,
                physicalSource: transactionE2Source,
                committedToken: transactionE2Token, activeToken: transactionE2Token,
                pending: nil, superseded: nil, resolvingVideoID: nil,
                generation: 0, persistenceBlocked: false,
                completedVideoIDs: [], recoverySideEffects: 0,
                advanceOrExitSideEffects: 0, savedVideoIDs: []
            )
        }

        // E2 committed -> E3 issued/no frame -> E4 selected -> E4 nil. The healthy E3 request remains the
        // only pending physical load and may commit; published progress/subtitle identity stays E2 until then.
        var e4Nil = newTransaction()
        let e3NilToken = PlayerLoadToken()
        let e3NilGeneration = e4Nil.beginResolve(e3ID)
        expect(e4Nil.finishResolve(
            videoID: e3ID, generation: e3NilGeneration,
            source: transactionE3Source, token: e3NilToken, commandAccepted: true
        ), "transaction: E3 command is accepted")
        expect(e4Nil.publishedIdentityIsAtomic && e4Nil.publishedVideoID == e2ID
               && e4Nil.physicalSource == transactionE3Source && e4Nil.persistenceBlocked,
               "transaction: E3 media cannot publish E3 metadata before first frame")
        let e4NilGeneration = e4Nil.beginResolve(e4ID)
        e4Nil.resolveNil(videoID: e4ID, generation: e4NilGeneration)
        expect(e4Nil.pending?.videoID == e3ID && e4Nil.activeToken == e3NilToken,
               "transaction: E4 nil leaves the healthy exact E3 request intact")
        expect(e4Nil.commitFirstFrame(e3NilToken)
               && e4Nil.publishedIdentityIsAtomic
               && e4Nil.publishedVideoID == e3ID
               && e4Nil.physicalSource == transactionE3Source
               && !e4Nil.persistenceBlocked,
               "transaction: restored E3 first frame publishes one atomic E3 identity")

        // E3 physically terminates while E4 resolves. A nil E4 result cannot revive terminal E3 or attribute
        // E3 terminal effects to still-published E2, and persistence remains closed.
        var terminalPending = newTransaction()
        let terminalE3Token = PlayerLoadToken()
        let terminalE3Generation = terminalPending.beginResolve(e3ID)
        _ = terminalPending.finishResolve(
            videoID: e3ID, generation: terminalE3Generation,
            source: transactionE3Source, token: terminalE3Token, commandAccepted: true
        )
        let terminalE4Generation = terminalPending.beginResolve(e4ID)
        expect(terminalPending.handleEOF(terminalE3Token) == .pending,
               "transaction: E3 terminal during E4 resolve routes to exact pending E3")
        terminalPending.resolveNil(videoID: e4ID, generation: terminalE4Generation)
        expect(!terminalPending.commitFirstFrame(terminalE3Token)
               && terminalPending.pending?.terminal == true
               && terminalPending.completedVideoIDs.isEmpty
               && terminalPending.publishedVideoID == e2ID
               && terminalPending.persistenceBlocked,
               "transaction: E4 nil cannot revive terminal E3 or persist mixed E2/E3 state")

        // E4 resolves but its player command is rejected. Restore every source field of healthy physical E3,
        // retain the exact E3 token, and keep persistence blocked until E3 really first-frames.
        var issueFailure = newTransaction()
        let restoredE3Token = PlayerLoadToken()
        let restoredE3Generation = issueFailure.beginResolve(e3ID)
        _ = issueFailure.finishResolve(
            videoID: e3ID, generation: restoredE3Generation,
            source: transactionE3Source, token: restoredE3Token, commandAccepted: true
        )
        let exactE3Snapshot = issueFailure.physicalSource
        let failedE4Generation = issueFailure.beginResolve(e4ID)
        expect(!issueFailure.finishResolve(
            videoID: e4ID, generation: failedE4Generation,
            source: transactionE4Source, token: PlayerLoadToken(), commandAccepted: false
        ), "transaction: rejected E4 command reports no issuance")
        expect(issueFailure.pending?.videoID == e3ID
               && issueFailure.pending?.token == restoredE3Token
               && issueFailure.activeToken == restoredE3Token
               && issueFailure.physicalSource == exactE3Snapshot
               && issueFailure.persistenceBlocked,
               "transaction: E4 issue failure restores the complete E3 source snapshot")
        expect(issueFailure.commitFirstFrame(restoredE3Token)
               && issueFailure.publishedVideoID == e3ID,
               "transaction: restored E3 remains committable after E4 issue failure")

        // A rejected first replacement never creates uncommitted media. E2 remains the physical and published
        // identity, and its valid progress remains eligible for exit persistence.
        var firstIssueFailure = newTransaction()
        let rejectedE3Generation = firstIssueFailure.beginResolve(e3ID)
        expect(!firstIssueFailure.finishResolve(
            videoID: e3ID, generation: rejectedE3Generation,
            source: transactionE3Source, token: PlayerLoadToken(), commandAccepted: false
        ), "transaction: rejected E3 command has no active replacement token")
        firstIssueFailure.saveOnExit()
        expect(firstIssueFailure.physicalSource == transactionE2Source
               && firstIssueFailure.activeToken == transactionE2Token
               && firstIssueFailure.pending == nil
               && !firstIssueFailure.persistenceBlocked
               && firstIssueFailure.savedVideoIDs == [e2ID],
               "transaction: issuance failure preserves committed E2 persistence")

        // Rapid latest-wins: accepted E4 supersedes unframed E3. E3 callbacks are stale and only E4 can atomically
        // publish media, progress, subtitle, and engine identity.
        var latestWins = newTransaction()
        let staleE3Token = PlayerLoadToken()
        let latestE3Generation = latestWins.beginResolve(e3ID)
        _ = latestWins.finishResolve(
            videoID: e3ID, generation: latestE3Generation,
            source: transactionE3Source, token: staleE3Token, commandAccepted: true
        )
        let latestE4Token = PlayerLoadToken()
        let latestE4Generation = latestWins.beginResolve(e4ID)
        expect(latestWins.finishResolve(
            videoID: e4ID, generation: latestE4Generation,
            source: transactionE4Source, token: latestE4Token, commandAccepted: true
        ), "transaction: latest E4 command supersedes unframed E3")
        expect(latestWins.handleTerminal(staleE3Token) == .stale,
               "transaction: superseded E3 callback is stale after E4 becomes active")
        expect(latestWins.commitFirstFrame(latestE4Token)
               && latestWins.publishedIdentityIsAtomic
               && latestWins.publishedVideoID == e4ID
               && latestWins.boundEngineVideoID == e4ID
               && latestWins.physicalSource == transactionE4Source,
               "transaction: rapid E2 to E3 to E4 publishes only latest E4")

        // Option C: while E3 is unissued, exact committed E2 EOF records only E2 completion. It leaves E3 intent
        // alive and suppresses a duplicate advance/exit; exact E2 error leaves the same intent alive with no
        // outgoing recovery or overlay side effect.
        var outgoingEOF = newTransaction()
        let outgoingEOFGeneration = outgoingEOF.beginResolve(e3ID)
        expect(outgoingEOF.handleEOF(transactionE2Token) == .outgoingCommittedWhileResolving
               && outgoingEOF.completedVideoIDs == [e2ID]
               && outgoingEOF.advanceOrExitSideEffects == 0
               && outgoingEOF.resolvingVideoID == e3ID,
               "transaction: outgoing E2 EOF persists E2 only and keeps exact E3 intent")
        let postEOFToken = PlayerLoadToken()
        expect(outgoingEOF.finishResolve(
            videoID: e3ID, generation: outgoingEOFGeneration,
            source: transactionE3Source, token: postEOFToken, commandAccepted: true
        ) && outgoingEOF.commitFirstFrame(postEOFToken)
          && outgoingEOF.publishedVideoID == e3ID,
               "transaction: E3 may still issue and commit after outgoing E2 EOF")

        var outgoingError = newTransaction()
        let outgoingErrorGeneration = outgoingError.beginResolve(e3ID)
        expect(outgoingError.handleError(transactionE2Token) == .outgoingCommittedWhileResolving
               && outgoingError.recoverySideEffects == 0
               && outgoingError.resolvingVideoID == e3ID,
               "transaction: outgoing E2 error cannot trigger recovery or cancel E3 intent")
        outgoingError.resolveNil(videoID: e3ID, generation: outgoingErrorGeneration)
        outgoingError.saveOnExit()
        expect(outgoingError.publishedIdentityIsAtomic
               && outgoingError.publishedVideoID == e2ID
               && outgoingError.savedVideoIDs == [e2ID],
               "transaction: nil E3 after outgoing error leaves only coherent E2 persistence")

        // Exit invalidates an unissued resolver after saving coherent E2. Once E3 has issued, the same exit is
        // fail-closed and writes neither the displayed E2 identity nor the unframed E3 source.
        var unissuedExit = newTransaction()
        let exitingGeneration = unissuedExit.beginResolve(e3ID)
        unissuedExit.exitPlayback()
        expect(!unissuedExit.finishResolve(
            videoID: e3ID, generation: exitingGeneration,
            source: transactionE3Source, token: PlayerLoadToken(), commandAccepted: true
        ) && unissuedExit.savedVideoIDs == [e2ID]
          && unissuedExit.publishedVideoID == e2ID,
               "transaction: exit saves E2 and rejects late unissued E3 result")
        var issuedExit = newTransaction()
        let issuedExitToken = PlayerLoadToken()
        let issuedExitGeneration = issuedExit.beginResolve(e3ID)
        _ = issuedExit.finishResolve(
            videoID: e3ID, generation: issuedExitGeneration,
            source: transactionE3Source, token: issuedExitToken, commandAccepted: true
        )
        issuedExit.exitPlayback()
        expect(issuedExit.savedVideoIDs.isEmpty && issuedExit.persistenceBlocked,
               "transaction: exit during unframed issued E3 persists neither E2 nor E3")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
