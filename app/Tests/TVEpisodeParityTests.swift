import Foundation

struct CoreVideo { let id: String }
struct FixtureDetailTarget { var id: String; var type: String }
struct FixtureMeta { var id: String; var type: String }
struct FixtureMetaDetails { var meta: FixtureMeta? }
@MainActor final class FixtureProfiles { var activeID = UUID() }
@MainActor final class FixturePresenter { var request: String? }

@MainActor struct PlaybackMutationTarget: Equatable {
    let generation: Int
    static func capture(core: HeldCore) -> Self { .init(generation: core.generation) }
    func stillOwnsCurrentContext(core: HeldCore) -> Bool { generation == core.generation }
}

@MainActor final class HeldCore {
    var generation = 1
    var metaDetails: FixtureMetaDetails? = .init(meta: .init(id: "show", type: "series"))
    var starts = 0
    var watched: Set<String> = []
    var acceptedValues: [Bool] = []
    private var pending: [CheckedContinuation<Bool, Never>] = []
    enum Rejected: Error { case storage, stale }

    func markNativeVideoWatched(_ video: CoreVideo, _ value: Bool, expected: FixtureDetailTarget,
                               target: PlaybackMutationTarget) async throws {
        guard target.stillOwnsCurrentContext(core: self), expected.id == metaDetails?.meta?.id,
              expected.type == metaDetails?.meta?.type else { throw Rejected.stale }
        starts += 1
        let accepted = await withCheckedContinuation { pending.append($0) }
        guard accepted else { throw Rejected.storage }
        guard target.stillOwnsCurrentContext(core: self), expected.id == metaDetails?.meta?.id,
              expected.type == metaDetails?.meta?.type else { throw Rejected.stale }
        acceptedValues.append(value)
        if value { watched.insert(video.id) } else { watched.remove(video.id) }
    }

    func finish(_ accepted: Bool) {
        precondition(!pending.isEmpty)
        pending.removeFirst().resume(returning: accepted)
    }
}

@main @MainActor enum TVEpisodeParityTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        checks += 1
    }
    static func settle(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        precondition(condition(), "held production action did not settle")
    }

    static func main() async {
        let now = Date(timeIntervalSince1970: 1_791_676_800)
        expect(TVEpisodeInitialPositionPolicy.isEligible(releasedDate: now, released: nil, asOf: now),
               "a release at the reference instant is aired")
        expect(!TVEpisodeInitialPositionPolicy.isEligible(releasedDate: now.addingTimeInterval(1), released: nil, asOf: now),
               "future ISO release is ineligible")
        expect(!TVEpisodeInitialPositionPolicy.isEligible(releasedDate: nil, released: "2099-01-01", asOf: now),
               "bare future calendar day is ineligible")
        expect(TVEpisodeInitialPositionPolicy.isEligible(releasedDate: nil, released: "2020-01-01", asOf: now),
               "bare historical calendar day is aired")
        expect(TVEpisodeInitialPositionPolicy.isEligible(releasedDate: nil, released: nil, asOf: now)
            && TVEpisodeInitialPositionPolicy.isEligible(releasedDate: nil, released: "unknown", asOf: now),
               "an older inventory without dates remains usable")
        let ids = (1...100).map { "ep\($0)" }
        let aired = Set(ids.prefix(90))
        let watched = Set(ids.prefix(43))
        func index(_ local: Set<String>, current: String? = nil, inProgress: Bool = false,
                   eligible: Set<String>? = nil) -> Int? {
            TVEpisodeInitialPositionPolicy.preferredIndex(ids: ids, eligibleIDs: eligible ?? aired,
                watched: local, currentID: current, currentInProgress: inProgress)
        }
        expect(index(watched) == 43, "43 completed episodes selects episode 44 in a long lazy list")
        expect(index(Set(ids)) == 0, "all watched selects the first aired episode")
        expect(index(Set(ids.prefix(90))) == 0, "unwatched future episodes do not pull focus past an aired finale")
        expect(index([], current: "ep55", inProgress: true) == 54, "current local in-progress episode wins over an earlier gap")
        expect(index(["ep55", "ep56"], current: "ep55", inProgress: true) == 56,
               "completed current episode moves to the next aired unwatched episode")
        expect(index(["ep55"], current: "ep55", eligible: ["ep1", "ep55", "ep57"]) == 56,
               "next after current skips an unaired intervening episode")
        expect(index([], current: "ep95", inProgress: true) == 0, "future resume metadata cannot select an unaired row")
        expect(index([], eligible: []) == nil, "future-only inventory waits without consuming initial placement")
        expect(TVEpisodeInitialPositionPolicy.preferredIndex(ids: [], eligibleIDs: [], watched: [],
            currentID: nil, currentInProgress: false) == nil, "empty metadata cannot fabricate a target")

        var position = TVEpisodeInitialPositionPolicy()
        func claim(_ scope: String = "profileA:credential1:series:show", season: Int = 1,
                   ready: Bool = true, eligible: Set<String>? = nil) -> Int? {
            position.claim(scope: scope, season: season, ids: ids, eligibleIDs: eligible ?? aired,
                watched: watched, currentID: nil, currentInProgress: false, ready: ready)
        }
        expect(claim(ready: false) == nil, "missing native restored history does not mean unwatched")
        expect(claim() == 43, "ready history claims exactly one initial placement")
        expect(claim() == nil, "late watched or metadata arrival cannot move an already positioned list")
        expect(claim(season: 2) == 43, "a new selected season owns its own initial placement")
        position.userInteracted(scope: "profileA:credential1:series:show", season: 3)
        expect(claim(season: 3) == nil, "remote interaction before history arrives consumes the pending placement")
        expect(claim("profileB:credential1:series:show") == 43, "a new active profile owns a fresh placement")
        expect(claim("profileB:credential2:series:show") == 43, "new credentials cannot reuse a retired placement")
        expect(claim("profileB:credential2:series:other", eligible: []) == nil,
               "future-only metadata keeps the placement available for aired content")
        expect(claim("profileB:credential2:series:other") == 43,
               "same title can position once eligible metadata arrives")

        // Execute the actual request, interaction and deferred-focus admission functions. The UI
        // keeps its existing bounded scroll-then-focus retry; only a current request may enter it.
        let focus = ProductionTVEpisodeFocus()
        focus.requestEpisodeFocus("ep44")
        let first = focus.pendingFocusEpisode!
        expect(focus.focusRequestIsCurrent(first), "initial row request owns its exact captured target")
        focus.requestEpisodeFocus("ep44")
        let replacement = focus.pendingFocusEpisode!
        expect(!focus.focusRequestIsCurrent(first) && focus.focusRequestIsCurrent(replacement),
               "a same-row replacement still retires the old lazy focus callbacks")
        focus.presenter.request = "live player"
        expect(!focus.focusRequestIsCurrent(replacement), "a visible player keeps remote input ownership")
        focus.presenter.request = nil
        focus.core.generation += 1
        expect(!focus.focusRequestIsCurrent(replacement), "a replaced native session rejects the deferred focus")
        focus.requestEpisodeFocus("ep44")
        let scoped = focus.pendingFocusEpisode!
        focus.episodeScope = "profileB:credential1:series:show"
        expect(!focus.focusRequestIsCurrent(scoped), "profile/title scope change rejects deferred focus")
        focus.episodeScope = scoped.scope
        focus.season = 2
        expect(!focus.focusRequestIsCurrent(scoped), "explicit season selection rejects the old focus request")
        focus.season = 1
        focus.episodes.removeAll { $0.id == "ep44" }
        expect(!focus.focusRequestIsCurrent(scoped), "same-sized metadata replacement cannot focus an absent episode")
        focus.episodes.append(CoreVideo(id: "ep44"))
        focus.noteEpisodeInteraction()
        expect(focus.pendingFocusEpisode == nil && focus.didApplyInitial && focus.focusInteractionGeneration == 1,
               "remote interaction retires deferred focus and preferred-season ownership")
        expect(focus.initialPosition.claim(scope: focus.episodeScope, season: 1, ids: ids, eligibleIDs: aired,
            watched: watched, currentID: nil, currentInProgress: false, ready: true) == nil,
               "late restored history cannot reclaim focus after a remote interaction")

        // This method is extracted unchanged from CoreSeasonedEpisodes. Only the transport waits
        // below are held fixtures; the UI coordinator, captured fences and error mapping are production.
        let view = ProductionTVWatchedAction()
        let video = CoreVideo(id: "ep44")
        view.markEpisodeWatched(video, isWatched: false)
        expect(view.manualWatchedAction.isRunning, "watched action becomes busy immediately")
        await settle { view.core.starts == 1 }
        expect(!view.core.watched.contains(video.id), "pending acknowledgement never shows an optimistic watched tick")
        view.markEpisodeWatched(video, isWatched: false)
        await Task.yield()
        expect(view.core.starts == 1, "duplicate gestures cannot enqueue a second native write")
        view.core.finish(false)
        await settle { !view.manualWatchedAction.isRunning }
        expect(view.manualWatchedAction.errorMessage?.contains("Long-press") == true,
               "failed persistence gives the focused episode a retry instruction")
        expect(view.core.watched.isEmpty, "failure does not change watched projection")
        view.markEpisodeWatched(video, isWatched: false)
        await settle { view.core.starts == 2 }
        expect(view.manualWatchedAction.errorMessage == nil, "retry clears the previous error")
        view.core.finish(true)
        await settle { !view.manualWatchedAction.isRunning }
        expect(view.core.watched == [video.id] && view.core.acceptedValues == [true],
               "accepted retry changes watched status once")
        view.markEpisodeWatched(video, isWatched: true)
        await settle { view.core.starts == 3 }
        view.core.finish(true)
        await settle { !view.manualWatchedAction.isRunning }
        expect(view.core.watched.isEmpty && view.core.acceptedValues == [true, false],
               "unwatched uses the same acknowledged route")

        view.markEpisodeWatched(video, isWatched: false)
        await settle { view.core.starts == 4 }
        let originalProfile = view.profiles.activeID
        view.profiles.activeID = UUID()
        view.core.generation += 1
        view.profiles.activeID = originalProfile // A -> B -> A cannot revive the captured session.
        view.core.finish(true)
        await settle { !view.manualWatchedAction.isRunning }
        expect(view.manualWatchedAction.errorMessage?.contains("Profile or title changed") == true,
               "session change rejects a late success even after returning to the same profile")
        expect(view.core.watched.isEmpty, "retired native target cannot update the watched projection")

        view.markEpisodeWatched(video, isWatched: false)
        view.core.metaDetails?.meta?.type = "movie"
        await settle { !view.manualWatchedAction.isRunning }
        expect(view.core.starts == 4, "same ID with a replaced type is rejected before dispatch")
        view.core.metaDetails?.meta?.type = "series"
        view.markEpisodeWatched(video, isWatched: false)
        view.manualWatchedAction.cancel()
        for _ in 0..<10 { await Task.yield() }
        expect(view.core.starts == 4 && !view.manualWatchedAction.isRunning,
               "dismissal before admission prevents a deferred write")

        view.markEpisodeWatched(video, isWatched: false)
        await settle { view.core.starts == 5 }
        view.manualWatchedAction.cancel()
        view.markEpisodeWatched(video, isWatched: false)
        await settle { view.core.starts == 6 }
        view.core.finish(false)
        for _ in 0..<10 { await Task.yield() }
        expect(view.manualWatchedAction.isRunning && view.manualWatchedAction.errorMessage == nil,
               "retired failure cannot replace a new action's busy state")
        view.core.finish(true)
        await settle { !view.manualWatchedAction.isRunning }
        expect(view.manualWatchedAction.errorMessage == nil, "only the current acknowledgement completes presentation")
        print("TVEpisodeParityTests: \(checks) production policy/action checks passed; no native storage or device proof")
    }
}
