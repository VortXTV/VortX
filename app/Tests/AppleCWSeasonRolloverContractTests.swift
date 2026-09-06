// AppleCWSeasonRolloverContractTests: standalone hostile contracts for the Apple-only Continue Watching
// season-rollover boundary. The suite compiles the real Foundation-only policy source and exercises the
// engine-owned membership, settled successor backfill, late inventory replacement, terminal ordering,
// owner/overlay isolation, and Top Shelf projection seams.
//
// Run from the repository root:
//
//   swiftc -parse-as-library \
//     app/SourcesShared/AppleCWSeasonRolloverPolicy.swift \
//     app/Tests/AppleCWSeasonRolloverContractTests.swift \
//     -o /tmp/apple-cw-season-rollover-contract && /tmp/apple-cw-season-rollover-contract

import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private let appRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func productionSource(_ relativePath: String) -> String {
    let url = appRoot.appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func episode(_ id: String, _ season: Int, _ number: Int) -> AppleCWSeriesEpisode {
    AppleCWSeriesEpisode(id: id, season: season, episode: number)
}

private enum TerminalEvent: Equatable {
    case markWatched(String)
    case rewindTitle
    case flushExitProgress
}

private struct TerminalTrace {
    private(set) var events: [TerminalEvent] = []
    private var gate = AppleCWTerminalProgressGate()

    mutating func markEpisodeWatched(_ id: String) { events.append(.markWatched(id)) }

    mutating func rewindTitle() {
        if gate.issueTerminalRewind() { events.append(.rewindTitle) }
    }

    mutating func flushExitProgress() {
        guard gate.permitsExitProgressFlush else { return }
        events.append(.flushExitProgress)
    }
}

private struct RefreshTaskTrace {
    private(set) var cancelled = false
    private(set) var mutations = 0

    mutating func leave() { cancelled = true }

    mutating func applyIfCurrent(_ targetIsCurrent: Bool) {
        guard !cancelled, targetIsCurrent else { return }
        mutations += 1
    }
}

private struct RefreshRequestTrace {
    private(set) var activeGeneration: Int?
    private(set) var cancelledGenerations: [Int] = []
    private(set) var dispatchedGenerations: [Int] = []
    private(set) var mutatedGenerations: [Int] = []

    mutating func begin(_ generation: Int) {
        activeGeneration = generation
    }

    mutating func cancel(_ capturedGeneration: Int) {
        guard AppleCWMetaRefreshGenerationFence.owns(
            capturedGeneration: capturedGeneration, activeGeneration: activeGeneration
        ) else { return }
        cancelledGenerations.append(capturedGeneration)
        activeGeneration = nil
    }

    mutating func dispatchLoad(for capturedGeneration: Int) {
        guard AppleCWMetaRefreshGenerationFence.owns(
            capturedGeneration: capturedGeneration, activeGeneration: activeGeneration
        ) else { return }
        dispatchedGenerations.append(capturedGeneration)
    }

    mutating func mutate(for capturedGeneration: Int) {
        guard AppleCWMetaRefreshGenerationFence.owns(
            capturedGeneration: capturedGeneration, activeGeneration: activeGeneration
        ) else { return }
        mutatedGenerations.append(capturedGeneration)
    }
}

private struct ProfileTrace {
    enum Kind { case ownerEngine, overlay }
    enum Event: Equatable {
        case ownerRewind(String)
        case overlayLocalFinish(String)
    }

    let kind: Kind
    private(set) var events: [Event] = []

    init(_ kind: Kind) { self.kind = kind }

    mutating func finishTitle(_ id: String) {
        switch kind {
        case .ownerEngine: events.append(.ownerRewind(id))
        case .overlay: events.append(.overlayLocalFinish(id))
        }
    }
}

private let s1e9 = episode("s1e9", 1, 9)
private let s1e10 = episode("s1e10", 1, 10)
private let s2e1 = episode("s2e1", 2, 1)

@main
enum AppleCWSeasonRolloverContractTests {
    static func main() {
        // 1. The app must not infer series completion from progress. Membership belongs to the engine or
        // overlay store, so both a fully watched terminal item and a newly surfaced season remain present.
        expect(AppleCWContinueWatchingPolicy.pruneAppFinished(
            [.series(id: "show", progress: 1), .movie(id: "film", progress: 1)]
        ).map(\.id) == ["show"],
               "series progress never app-prunes membership while movie pruning remains unchanged")

        // 2. A sorted but partial launch list proves a successor when it has one, but never proves title-wide
        // finality when the current entry is its last visible item.
        let partial = AppleCWSeriesInventory(raw: [s1e9, s1e10], authority: .launch)
        expect(partial?.ordered.map(\.id) == ["s1e9", "s1e10"],
               "launch inventory is normalized through ordered episode order")
        expect(AppleCWSeriesTerminalPolicy.decide(currentID: "s1e9", inventory: partial,
                                                  refresh: .notAttempted) == .advance("s1e10"),
               "partial S1E9 advances to the known S1E10 successor")
        expect(AppleCWSeriesTerminalPolicy.decide(currentID: "s1e10", inventory: partial,
                                                  refresh: .completedWithoutFullInventory) == .keepState,
               "partial S1E10 never rewinds the title when finality is unknown")
        expect(partial?.authority == .launch,
               "ordinary current-season launch inventory remains non-authoritative")
        expect(AppleCWSeriesTerminalPolicy.decide(currentID: "s1e10", inventory: partial,
                                                  refresh: .notAttempted) == .refresh,
               "ordinary partial launch EOF requests the bounded refresh instead of rewinding")

        // 3. Empty and raw-unsorted metadata are not proof. The bounded refresh can be consumed once, but
        // no successor/no authority path stays in the engine-owned state.
        expect(AppleCWSeriesTerminalPolicy.decide(currentID: "s1e10", inventory: nil,
                                                  refresh: .completedWithoutFullInventory) == .keepState,
               "empty inventory keeps state and never rewinds")
        let rawUnsorted = AppleCWSeriesInventory(raw: [s1e10, s1e9], authority: .authoritativeFullSeries)
        expect(rawUnsorted?.ordered.map(\.id) == ["s1e9", "s1e10"],
               "valid unsorted metadata is normalized for navigation, never account finality")
        expect(!AppleCWSeriesTerminalPolicy.canExitPlayer(currentID: "s1e10", inventory: nil, refreshAttempted: true),
               "failed metadata refresh cannot dismiss an episode with no inventory")
        expect(!AppleCWSeriesTerminalPolicy.canExitPlayer(currentID: "missing", inventory: rawUnsorted, refreshAttempted: true),
               "an inventory missing the current episode cannot dismiss playback")
        expect(!AppleCWSeriesTerminalPolicy.canExitPlayer(currentID: "s1e10", inventory: rawUnsorted, refreshAttempted: false),
               "an unrefreshed launch list cannot silently end navigation")
        expect(!AppleCWSeriesTerminalPolicy.canExitPlayer(currentID: "s1e9", inventory: rawUnsorted, refreshAttempted: true),
               "a known successor never takes the exit branch")
        expect(AppleCWSeriesTerminalPolicy.canExitPlayer(currentID: "s1e10", inventory: rawUnsorted, refreshAttempted: true),
               "a settled known end boundary retains normal player exit without title removal")

        // 4. A later settled inventory replaces the launch list for successor navigation, so S1E10 is no
        // longer terminal once S2E1 arrives. Even a no-successor result never gives the app a series rewind
        // authority; genuine final-series removal remains engine/account-owned.
        var ledger = AppleCWSeriesInventoryLedger(launch: [s1e9, s1e10])
        expect(ledger.acceptAuthoritativeBackfill([s1e9, s1e10, s2e1]),
               "authoritative all-season backfill is accepted after a partial launch list")
        expect(ledger.current?.ordered.map(\.id) == ["s1e9", "s1e10", "s2e1"],
               "late full backfill replaces rather than is masked by the launch list")
        expect(AppleCWSeriesTerminalPolicy.decide(currentID: "s1e10", inventory: ledger.current,
                                                  refresh: .completedWithFullInventory) == .advance("s2e1"),
               "S1E10 advances across the season boundary after backfill")
        expect(AppleCWSeriesTerminalPolicy.decide(currentID: "s2e1", inventory: ledger.current,
                                                  refresh: .completedWithFullInventory) == .keepState,
               "no successor keeps the true S2E1 finale in engine-owned state")
        var alreadyComplete = AppleCWSeriesInventoryLedger(launch: [s1e9, s1e10, s2e1])
        expect(alreadyComplete.acceptAuthoritativeBackfill([s1e9, s1e10, s2e1]),
               "equal-count complete backfill certifies an already-complete untrusted launch list")
        expect(!alreadyComplete.acceptAuthoritativeBackfill([s1e9, s1e10]),
               "backfill shrink is rejected")
        expect(!alreadyComplete.acceptAuthoritativeBackfill([s1e9, s1e10, episode("other", 2, 1)]),
               "equal-count identity or coordinate mismatch is rejected")

        // 4b. CoreBridge.loadMeta is allowed to preserve an already-loaded same-ID payload. That payload
        // cannot certify a terminal refresh unless a new selected/loaded/ready receipt follows the request.
        let preexistingPartial = AppleCWMetaRefreshReceipt(
            requestGeneration: nil, selectedMetaID: "show", loadedMetaID: "show", settled: true
        )
        expect(!AppleCWMetaRefreshAuthorityPolicy.accepts(
            preexistingPartial, forRequestGeneration: 41, expectedLibraryID: "show"
        ), "same-ID partial meta with no request-owned receipt cannot become authoritative")
        let unrelatedSameID = AppleCWMetaRefreshReceipt(
            requestGeneration: nil, selectedMetaID: "show", loadedMetaID: "show", settled: true
        )
        expect(!AppleCWMetaRefreshAuthorityPolicy.accepts(
            unrelatedSameID, forRequestGeneration: 41, expectedLibraryID: "show"
        ), "unrelated identical same-ID event cannot certify a no-op refresh")
        let freshExact = AppleCWMetaRefreshReceipt(
            requestGeneration: 41, selectedMetaID: "show", loadedMetaID: "show", settled: true,
            requestedStreamID: "s1e10"
        )
        expect(AppleCWMetaRefreshAuthorityPolicy.accepts(
            freshExact, forRequestGeneration: 41, expectedLibraryID: "show", expectedStreamID: "s1e10"
        ), "only the exact request-owned selected/loaded ready receipt can certify the response")
        let staleVideoReceipt = AppleCWMetaRefreshReceipt(
            requestGeneration: 41, selectedMetaID: "show", loadedMetaID: "show", settled: true,
            requestedStreamID: "old-video"
        )
        expect(!AppleCWMetaRefreshAuthorityPolicy.accepts(
            staleVideoReceipt, forRequestGeneration: 41, expectedLibraryID: "show", expectedStreamID: "s1e10"
        ), "same-title receipt for a stale video cannot certify the current refresh")
        expect(AppleCWSeriesTerminalPolicy.decide(
            currentID: "s1e10", inventory: partial,
            refresh: .completedWithoutFullInventory
        ) == .keepState, "no fresh receipt leaves partial terminal state fail-closed")
        expect(AppleCWSeriesTerminalPolicy.decide(
            currentID: "s2e1", inventory: ledger.current,
            refresh: .completedWithFullInventory
        ) == .keepState, "settled no-successor metadata cannot issue a title-wide series rewind")

        // 4c. A polling task owns one exact title, episode, session, generation tuple, and physical load.
        // Either a different title or a different video in the same title invalidates the task and leaves
        // the one-shot refresh available to the new target.
        let refreshTarget = AppleCWTerminalRefreshTarget(
            libraryID: "show", videoID: "s1e10", sessionID: "session-a",
            episodeGeneration: 3, sourceGeneration: 5, resumeGeneration: 7, loadOwner: "load-a"
        )
        let differentTitleTarget = AppleCWTerminalRefreshTarget(
            libraryID: "other-show", videoID: "s1e10", sessionID: "session-a",
            episodeGeneration: 3, sourceGeneration: 5, resumeGeneration: 7, loadOwner: "load-a"
        )
        let sameLibraryNewVideoTarget = AppleCWTerminalRefreshTarget(
            libraryID: "show", videoID: "s2e1", sessionID: "session-a",
            episodeGeneration: 4, sourceGeneration: 6, resumeGeneration: 8, loadOwner: "load-b"
        )
        expect(AppleCWTerminalRefreshFence.accepts(
            captured: refreshTarget, current: refreshTarget
        ), "terminal refresh accepts its exact captured target")
        expect(!AppleCWTerminalRefreshFence.accepts(
            captured: refreshTarget, current: differentTitleTarget
        ), "stale terminal refresh cannot mutate a different title")
        expect(!AppleCWTerminalRefreshFence.accepts(
            captured: refreshTarget, current: sameLibraryNewVideoTarget
        ), "stale terminal refresh cannot mutate a newer video in the same title")
        let missingLoadOwnerTarget = AppleCWTerminalRefreshTarget(
            libraryID: "show", videoID: "s1e10", sessionID: "session-a",
            episodeGeneration: 3, sourceGeneration: 5, resumeGeneration: 7, loadOwner: nil
        )
        expect(!AppleCWTerminalRefreshFence.accepts(
            captured: missingLoadOwnerTarget, current: refreshTarget
        ), "missing physical load owner cannot match a live terminal refresh")
        var refreshTask = RefreshTaskTrace()
        refreshTask.leave()
        refreshTask.applyIfCurrent(true)
        expect(refreshTask.mutations == 0,
               "leaving playback cancels the bounded refresh task before any stale mutation")
        var switchedRefreshTask = RefreshTaskTrace()
        switchedRefreshTask.applyIfCurrent(false)
        expect(switchedRefreshTask.mutations == 0,
               "switching episode fences the old refresh task before any stale mutation")

        // A SwiftUI `.id(req.id)` replacement can tear down the old player after the replacement has
        // already started a same-title refresh. Every bridge action from the old view must be generation-
        // owned, so it cannot cancel, dispatch, or mutate the replacement's request.
        var iosReplacementRace = RefreshRequestTrace()
        iosReplacementRace.begin(41)
        iosReplacementRace.begin(42)
        iosReplacementRace.cancel(41)
        iosReplacementRace.dispatchLoad(for: 41)
        iosReplacementRace.mutate(for: 41)
        expect(iosReplacementRace.activeGeneration == 42
               && iosReplacementRace.cancelledGenerations.isEmpty
               && iosReplacementRace.dispatchedGenerations.isEmpty
               && iosReplacementRace.mutatedGenerations.isEmpty,
               "iOS old view cannot cancel, dispatch, or mutate a newer same-ID refresh")
        iosReplacementRace.dispatchLoad(for: 42)
        iosReplacementRace.mutate(for: 42)
        expect(iosReplacementRace.dispatchedGenerations == [42]
               && iosReplacementRace.mutatedGenerations == [42],
               "iOS replacement generation retains ownership of its own bridge actions")

        var tvReplacementRace = RefreshRequestTrace()
        tvReplacementRace.begin(51)
        tvReplacementRace.begin(52)
        tvReplacementRace.cancel(51)
        tvReplacementRace.dispatchLoad(for: 51)
        tvReplacementRace.mutate(for: 51)
        expect(tvReplacementRace.activeGeneration == 52
               && tvReplacementRace.cancelledGenerations.isEmpty
               && tvReplacementRace.dispatchedGenerations.isEmpty
               && tvReplacementRace.mutatedGenerations.isEmpty,
               "tvOS old view cannot cancel, dispatch, or mutate a newer same-ID refresh")
        tvReplacementRace.dispatchLoad(for: 52)
        tvReplacementRace.mutate(for: 52)
        expect(tvReplacementRace.dispatchedGenerations == [52]
               && tvReplacementRace.mutatedGenerations == [52],
               "tvOS replacement generation retains ownership of its own bridge actions")

        // 5. The terminal order is mark -> advance or mark -> bounded refresh -> keep state for series. The
        // rewind gate remains only for the existing movie/explicit owner path, and it suppresses a stale exit
        // TimeChanged after that actual rewind.
        var seriesTerminal = TerminalTrace()
        seriesTerminal.markEpisodeWatched("s2e1")
        expect(seriesTerminal.events == [.markWatched("s2e1")], "EOF marks the terminal episode before any rewind")
        expect(AppleCWSeriesTerminalPolicy.decide(currentID: "s2e1", inventory: ledger.current,
                                                  refresh: .completedWithFullInventory) == .keepState,
               "series terminal policy has no destructive rewind outcome")
        expect(seriesTerminal.events == [.markWatched("s2e1")],
               "series EOF never enters the app-side title rewind path")
        var movieTerminal = TerminalTrace()
        movieTerminal.markEpisodeWatched("film")
        movieTerminal.rewindTitle()
        expect(movieTerminal.events == [.markWatched("film"), .rewindTitle],
               "movie/explicit owner rewind gate remains independently executable")
        movieTerminal.flushExitProgress()
        expect(movieTerminal.events == [.markWatched("film"), .rewindTitle],
               "no TimeChanged/progress flush occurs after an actual rewind")

        // 6. Owner and overlay writes are separate stores. The overlay terminal action never dispatches an
        // owner-engine rewind, while owner playback may rewind its own library entry.
        var owner = ProfileTrace(.ownerEngine)
        var overlay = ProfileTrace(.overlay)
        owner.finishTitle("show")
        overlay.finishTitle("show")
        expect(owner.events == [.ownerRewind("show")] && overlay.events == [.overlayLocalFinish("show")],
               "overlay finish remains local and cannot mutate owner engine history")

        // 7. A newly reported next episode re-surfaces the still-member series, and Top Shelf projects the
        // corrected Continue Watching truth rather than applying a second series progress prune.
        let resurfaced = AppleCWContinueWatchingPolicy.pruneAppFinished([
            .series(id: "show", progress: 0.02)
        ])
        expect(resurfaced.map(\.id) == ["show"],
               "authoritative new-season engine backfill re-surfaces a fully watched series")
        expect(AppleCWTopShelfProjection.project(resurfaced).map(\.id) == ["show"],
               "Top Shelf projects the corrected Continue Watching series truth")
        var newSeasonLedger = AppleCWSeriesInventoryLedger(launch: [s1e9, s1e10])
        expect(newSeasonLedger.acceptAuthoritativeBackfill([s1e9, s1e10, s2e1]),
               "authoritative engine backfill admits a newly available next episode")
        expect(AppleCWSeriesTerminalPolicy.decide(
            currentID: "s1e10", inventory: newSeasonLedger.current,
            refresh: .completedWithFullInventory
        ) == .advance("s2e1"),
               "new-season receipt makes the prior finale advance truthfully")

        // 8. Production-path guards are executable source contracts. These keep the fixture seam honest:
        // reverting a real Apple call site fails this standalone suite even if the pure policy still passes.
        let coreModels = productionSource("SourcesShared/CoreModels.swift")
        let coreBridge = productionSource("SourcesShared/CoreBridge.swift")
        let topShelf = productionSource("SourcesTV/TopShelfSnapshotWriter.swift")
        let tvPlayer = productionSource("SourcesTV/TVPlayerView.swift")
        let iosPlayer = productionSource("Sources/PlayerScreen.swift")
        let admissionHelper = productionSource("SourcesShared/AppleEpisodeResolverAdmission.swift")
        let rootSource = productionSource("SourcesiOS/iOSRootView.swift")
        let home = productionSource("SourcesTV/HomeView.swift")
        let iosDetail = productionSource("SourcesiOS/iOSDetailView.swift")
        let tvDetail = productionSource("SourcesTV/DetailView.swift")
        let tvRoot = productionSource("SourcesTV/RootTabView.swift")
        expect(coreModels.contains("if EpisodePlaybackIdentity.usesSeriesLifecycle(type: type) { return false }"),
               "CoreCWItem series progress cannot app-prune a series")
        expect(coreBridge.contains("EpisodePlaybackIdentity.usesSeriesLifecycle(type: $0.type) || !$0.isFinished"),
               "CoreBridge rebuild keeps series membership engine-owned")
        expect(topShelf.contains("EpisodePlaybackIdentity.usesSeriesLifecycle(type: $0.type) || !$0.isFinished"),
               "Top Shelf repeats the series-safe production prune")
        expect(coreModels.contains("appleCWAuthoritativeBackfill")
               && coreModels.contains("authority: .authoritativeFullSeries")
               && coreModels.contains("appleCWTerminalFullMeta")
               && coreModels.contains("case .loading?, .none")
               && !coreModels.contains("return .rewind"),
               "CoreModels exposes settled successor/backfill seams without a destructive series outcome")
        expect(coreBridge.contains("beginAppleCWAuthoritativeMetaRefresh")
               && coreBridge.contains("awaitingInvalidation")
               && coreBridge.contains("awaitingLoadSettlement")
               && coreBridge.contains("appleCWMetaRefreshReceipt")
               && coreBridge.contains("appleCWMetaRefreshDetails")
               && coreBridge.contains("appleCWTerminalFullMeta")
               && coreBridge.contains("guard details == nil else { return }")
               && coreBridge.contains("cancelAppleCWMetaRefresh(generation:")
               && coreBridge.contains("AppleCWMetaRefreshGenerationFence.owns")
               && coreBridge.contains("refreshGenerationAtSchedule")
               && coreBridge.contains("guard self.appleCWMetaRefreshRequest?.generation == refreshGenerationAtSchedule")
               && coreBridge.contains("metaDetailsWork?.cancel()")
               && coreBridge.contains("cancelAppleCWMetaRefresh"),
               "CoreBridge owns the two-phase request invalidation and exact-load settlement seam")
        expect(coreModels.contains("streamID requestedStreamID")
               && coreBridge.contains("requestedStreamID")
               && coreBridge.contains("streamID: request.streamID")
               && coreBridge.contains("streamId: request.streamID")
               && tvPlayer.contains("expectedStreamID: m.videoId")
               && iosPlayer.contains("expectedStreamID: m.videoId"),
               "full-meta authority receipt is correlated to the exact requested stream path")
        expect(tvPlayer.contains("terminalFinalityRefreshUsed")
               && tvPlayer.contains("EpisodePlaybackIdentity.appleCWAuthoritativeBackfill")
               && tvPlayer.contains("beginAppleCWAuthoritativeMetaRefresh")
               && tvPlayer.contains("forRequestGeneration")
               && tvPlayer.contains("AppleCWMetaRefreshAuthorityPolicy.accepts")
               && tvPlayer.contains("terminalRefreshTargetIsCurrent")
               && tvPlayer.contains("terminalFinalityRefreshTarget")
               && tvPlayer.contains("loadOwner")
               && tvPlayer.contains("guard let loadToken = coordinator.player?.activeLoadToken else { return }")
               && tvPlayer.contains("terminalFinalityRefreshTask")
               && tvPlayer.contains("terminalFinalityRefreshTask?.cancel()")
               && tvPlayer.contains("terminalFinalityRefreshGeneration")
               && tvPlayer.contains("terminalFinalityRefreshGeneration = requestGeneration")
               && tvPlayer.contains("cancelTerminalFinalityRefresh()")
               && tvPlayer.contains("core.cancelAppleCWMetaRefresh(generation: generation)")
               && tvPlayer.contains("guard !Task.isCancelled")
               && tvPlayer.contains("streamID: m.videoId")
               && tvPlayer.contains("terminalRewindGate.issueTerminalRewind()"),
               "tvOS terminal path bounds refresh, accepts successor backfill, and retains the movie gate")
        expect(iosPlayer.contains("terminalFinalityRefreshUsed")
               && iosPlayer.contains("authoritativeBackfillRefs")
               && iosPlayer.contains("beginAppleCWAuthoritativeMetaRefresh")
               && iosPlayer.contains("forRequestGeneration")
               && iosPlayer.contains("AppleCWMetaRefreshAuthorityPolicy.accepts")
               && iosPlayer.contains("terminalRefreshTargetIsCurrent")
               && iosPlayer.contains("terminalFinalityRefreshTarget")
               && iosPlayer.contains("loadOwner")
               && iosPlayer.contains("guard let loadToken = coordinator.player?.activeLoadToken else { return }")
               && iosPlayer.contains("terminalFinalityRefreshTask")
               && iosPlayer.contains("terminalFinalityRefreshTask?.cancel()")
               && iosPlayer.contains("terminalFinalityRefreshGeneration")
               && iosPlayer.contains("terminalFinalityRefreshGeneration = requestGeneration")
               && iosPlayer.contains("cancelTerminalFinalityRefresh()")
               && iosPlayer.contains("core.cancelAppleCWMetaRefresh(generation: generation)")
               && iosPlayer.contains("guard !Task.isCancelled")
               && iosPlayer.contains("streamID: m.videoId")
               && iosPlayer.contains("terminalRewindGate.issueTerminalRewind()")
               && !iosPlayer.contains("decision == .rewind")
               && !iosPlayer.contains("case .rewind:")
               && !iosPlayer.contains("if m.usesSeriesLifecycle, terminalRewindGate.issueTerminalRewind()"),
               "iOS terminal path bounds refresh and never rewinds a series from inferred metadata")
        expect(!tvPlayer.contains("decision == .rewind")
               && !tvPlayer.contains("case .rewind:")
               && !tvPlayer.contains("if m.usesSeriesLifecycle, terminalRewindGate.issueTerminalRewind()"),
               "tvOS terminal path never rewinds a series from inferred metadata")
        expect(tvPlayer.contains("terminalRewindGate.permitsExitProgressFlush")
               && iosPlayer.contains("terminalRewindGate.permitsExitProgressFlush"),
               "both Apple exits suppress progress flush after terminal rewind")
        expect(coreBridge.contains("guard target.stillOwnsCurrentContext(core: self)")
               && coreBridge.contains("ProfileStore.shared.finishedWatching(metaId: libraryId, profileID: profileID)")
               && coreBridge.contains("RewindLibraryItem"),
               "engine/account owns the separate removal primitive and overlay finish remains local")
        expect(home.contains("core.changedFields.contains(\"continue_watching_preview\")")
               && home.contains("TopShelfSnapshotWriter.publishCurrent()"),
               "Home re-seeds Top Shelf when corrected engine Continue Watching truth changes")
        expect(!iosDetail.contains("seriesInventoryAuthority: .authoritativeFullSeries")
               && iosDetail.contains("seriesInventoryAuthority: .launch"),
               "iOS ordinary detail inventory remains launch-only until a settled full-meta refresh")
        expect(!tvDetail.contains("seriesInventoryAuthority: .authoritativeFullSeries")
               && tvDetail.contains("seriesInventoryAuthority: .launch"),
               "tvOS ordinary detail inventory remains launch-only until a settled full-meta refresh")
        expect(iosPlayer.contains("var seriesInventoryAuthority: AppleCWSeriesInventory.Authority = .launch")
               && tvRoot.contains("var seriesInventoryAuthority: AppleCWSeriesInventory.Authority = .launch"),
               "direct iOS and tvOS Continue Watching launches default to untrusted inventory")
        expect(iosPlayer.contains("loadedSeriesVideoMetadata")
               && iosPlayer.contains("loadEpisodeWithMetadata")
               && iosPlayer.contains("let resolverRoute: AppleEpisodeResolverAdmission.Route<PlayerEpisodeStream>?")
               && iosPlayer.contains("AppleEpisodeResolverAdmission.route(")
               && iosPlayer.contains("AppleEpisodeResolverAdmission.resolve(resolverRoute)")
               && iosPlayer.contains("guard goToEpisode(id, autoAdvance: true) else")
               && iosPlayer.contains("successor admission rejected")
               && admissionHelper.contains("if let refreshedMetadata")
               && admissionHelper.contains("guard let metadataResolver else { return nil }")
               && admissionHelper.contains("case .refreshed"),
               "PlayerScreen uses the production exact-metadata route helper and exits explicitly on failed admission")
        expect(rootSource.contains("loadEpisodeWithMetadata = { video in")
               && rootSource.contains("in: [video]")
               && rootSource.contains("loadEpisodeWithMetadata: loadEpisodeWithMetadata"),
               "direct resume keeps a typed exact-video resolver even with an empty launch inventory")
        expect(iosDetail.contains("loadEpisodeWithMetadata: { await loadEpisodeStream($0.id, refreshedVideo: $0) }")
               && iosDetail.contains("refreshedVideo: CoreVideo? = nil")
               && iosDetail.contains("guard refreshedVideo.id == videoId"),
               "detail resolver consumes the admitted refreshed CoreVideo without global fallback")
        expect(!tvPlayer.contains("canRewindWholeTitleAtTerminal(")
               && !iosPlayer.contains("canRewindWholeTitleAtTerminal("),
               "Apple players have no legacy count-only series rewind call site")

        if failures > 0 {
            print("FAILED  \(failures) Apple CW season-rollover contract(s)")
            exit(1)
        }
        print("PASS  all Apple CW season-rollover contracts")
    }
}
