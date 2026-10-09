import Foundation

@main
enum TVQuickViewDiscoverPolicyTests {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        for enabled in [false, true] {
            for catalog in [false, true] {
                for direct in [false, true] {
                    for resume in [false, true] {
                        for privateIntent in [false, true] {
                            for owner in [false, true] {
                                expect(TVQuickViewPolicy.presents(enabled: enabled, catalog: catalog,
                                    hasDirectPlay: direct, hasResume: resume, privateIntent: privateIntent,
                                    ownerCurrent: owner) == (enabled && catalog && !direct && !resume && !privateIntent && owner),
                                    "only an enabled/current ordinary catalog can preview")
                            }
                        }
                    }
                }
            }
        }
        for merged in [false, true] {
            for hiddenSearch in [false, true] {
                for hiddenDiscover in [false, true] {
                    expect(TVDiscoverSearchPolicy.showsSeparateSearch(merged: merged, hideSearch: hiddenSearch)
                        == (!merged && !hiddenSearch), "separate Search respects merge and hidden preference")
                    expect(TVDiscoverSearchPolicy.selectionAfterMerge(4, merged: merged, hideDiscover: hiddenDiscover)
                        == (merged ? (hiddenDiscover ? 0 : 1) : 4), "merge never routes to hidden Discover")
                    expect(TVDiscoverSearchPolicy.selectionAfterMerge(2, merged: merged, hideDiscover: hiddenDiscover) == 2,
                           "merge cannot retarget Library or another current tab")
                }
            }
        }
        expect(!TVDiscoverSearchPolicy.hasQuery(" a ") && TVDiscoverSearchPolicy.hasQuery(" ab "), "trimmed query threshold")
        let searchProfile = UUID()
        func acceptsResults(submitted: String = "query", pending: Bool = false,
                            profile: UUID? = searchProfile, account: UInt64? = 3) -> Bool {
            TVDiscoverSearchPolicy.acceptsResults(query: " query ", submittedQuery: submitted,
                debouncePending: pending, capturedProfile: profile, currentProfile: searchProfile,
                capturedAccountBoundary: account, currentAccountBoundary: 3)
        }
        expect(acceptsResults(), "current query/profile publication admits real partial matches without waiting for every add-on")
        expect(!acceptsResults(submitted: "old") && !acceptsResults(pending: true), "old query and debounce publications cannot paint current results")
        expect(!acceptsResults(profile: UUID()) && !acceptsResults(profile: nil) && !acceptsResults(account: 4), "missing/replaced owner and credential boundary reject search publications")
        var details = TVQuickViewWatchState()
        expect(!details.begin(enabled: false), "ordinary Details cannot start explicit Watch")
        expect(details.decide(ownerCurrent: true, cancelled: false, playbackPresent: false, settled: true, hasBest: true) == .retired,
               "an unstarted state cannot dispatch")
        var watch = TVQuickViewWatchState()
        expect(watch.begin(enabled: true), "explicit Watch begins once")
        expect(!watch.begin(enabled: true), "recomposition cannot start a second request")
        expect(watch.decide(ownerCurrent: true, cancelled: false, playbackPresent: false, settled: false, hasBest: true) == .waiting,
               "a ranked best without settled provenance cannot play")
        expect(watch.decide(ownerCurrent: true, cancelled: false, playbackPresent: false, settled: true, hasBest: true) == .play,
               "current settled source dispatches once")
        expect(watch.decide(ownerCurrent: true, cancelled: false, playbackPresent: false, settled: true, hasBest: true) == .retired,
               "no double dispatch after first acceptance")
        for failure in 0..<3 {
            var cancelled = TVQuickViewWatchState()
            _ = cancelled.begin(enabled: true)
            expect(cancelled.decide(ownerCurrent: failure != 0, cancelled: failure == 1,
                playbackPresent: failure == 2, settled: true, hasBest: true) == .retired,
                "owner replacement, Back cancellation and another play retire pending intent")
            expect(!cancelled.begin(enabled: true), "owner ABA or later source publication cannot restart retired intent")
        }
        var empty = TVQuickViewWatchState()
        _ = empty.begin(enabled: true)
        expect(empty.decide(ownerCurrent: true, cancelled: false, playbackPresent: false, settled: true, hasBest: false) == .unavailable,
               "settled empty sources report unavailable")
        empty.retire()
        expect(!empty.begin(enabled: true), "timeout/disappear retirement is permanent")
        let lifetime = TVQuickViewWatchOwner()
        expect(lifetime.begin(enabled: true), "Detail-owned lifetime admits first child")
        let replacementChild = lifetime
        expect(!replacementChild.begin(enabled: true), "a metadata branch/source-child remount cannot repeat Watch")
        lifetime.retire()
        expect(!replacementChild.begin(enabled: true) && replacementChild.generation == 1,
               "shared owner preserves cancellation across child remount and owner ABA")
        let scope = CinemaQuickWatchScope(titleID: "tt123", titleType: "series", episodeID: "tt123:1:2",
            profileID: "profile", accountBoundaryGeneration: 7, traktSessionID: "session", routeGeneration: 4)
        func accepts(_ title: String = "tt123", type: String = "series", episode: String? = "tt123:1:2",
                     profile: String? = "profile", account: UInt64 = 7, trakt: String? = "session",
                     route: Int = 4, cancelled: Bool = false) -> Bool {
            CinemaQuickWatchScopePolicy.accepts(scope, titleID: title, titleType: type, episodeID: episode,
                profileID: profile, accountBoundaryGeneration: account, traktSessionID: trakt,
                routeGeneration: route, taskCancelled: cancelled)
        }
        expect(accepts(), "exact series episode/resume ownership remains admissible")
        expect(!accepts("tt456") && !accepts(type: "movie") && !accepts(episode: "tt123:1:3"), "title/type/episode replacement rejects stale watch")
        expect(!accepts(profile: "other") && !accepts(account: 8) && !accepts(trakt: "other"), "owner/credential/private session boundaries reject stale watch")
        expect(!accepts(route: 5) && !accepts(cancelled: true), "route ABA and canceled tasks reject stale watch")
        expect(TVQuickViewWatchTask.scope == nil, "ordinary resolver starts with no extra guard")
        let inherited = await TVQuickViewWatchTask.$scope.withValue(scope) {
            await scopedFallback()
        }
        expect(inherited == scope && TVQuickViewWatchTask.scope == nil, "structured resolver fallback inherits scope and leaves default callers unscoped")
        let item = try JSONDecoder().decode(CoreMeta.self, from: Data(#"{"id":"opaque:123","type":"anime","name":"Supplied title","background":"wide-art","poster":"portrait-art","runtime":"99 min","releaseInfo":"2026","imdbRating":"7.4","description":"Supplied overview"}"#.utf8))
        let presentation = TVCinemaCardPresentation.meta(item)
        expect(presentation.id == item.id && presentation.type == item.type && presentation.title == item.name,
               "opaque catalog route identity survives the actual projection")
        expect(presentation.facts == [.text("99 min"), .text("2026"), .rating("7.4"), .text("Anime")],
               "runtime/year/rating are supplied preview facts")
        let sparse = try JSONDecoder().decode(CoreMeta.self, from: Data(#"{"id":"sparse","type":"movie","name":"Sparse"}"#.utf8))
        expect(TVCinemaCardPresentation.meta(sparse).facts == [.text("Movie")], "missing preview facts stay absent")
        print("TVQuickViewDiscoverPolicyTests: \(checks) checks passed")
    }

    private static func scopedFallback() async -> CinemaQuickWatchScope? {
        await Task.yield()
        return TVQuickViewWatchTask.scope
    }
}
