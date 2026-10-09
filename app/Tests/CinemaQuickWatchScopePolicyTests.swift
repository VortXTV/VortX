import Foundation

@main
enum CinemaQuickWatchScopePolicyTests {
    private static let scope = CinemaQuickWatchScope(
        titleID: "tt100",
        titleType: " Series ",
        episodeID: "tt100:1:2",
        profileID: "profile-a",
        accountBoundaryGeneration: 7,
        traktSessionID: "trakt-a",
        routeGeneration: 3
    )

    static func main() {
        expect(accepts(), "exact title/profile/account/episode scope is admitted")
        expect(accepts(titleType: "series"), "type comparison is normalized")
        expect(!accepts(titleID: "tt200"), "stale title is rejected")
        expect(!accepts(titleType: "movie"), "late title-type replacement is rejected")
        expect(!accepts(episodeID: "tt100:1:3"), "binge-advanced episode is rejected")
        expect(!accepts(profileID: "profile-b"), "profile switch is rejected")
        expect(!accepts(accountBoundaryGeneration: 8), "account credential boundary is rejected")
        expect(!accepts(traktSessionID: "trakt-b"), "Trakt account boundary is rejected")
        expect(!accepts(routeGeneration: 4), "route departure generation is rejected")
        expect(!accepts(taskCancelled: true), "cancelled task is rejected")

        let movie = CinemaQuickWatchScope(
            titleID: "tt200", titleType: "movie", episodeID: nil, profileID: nil,
            accountBoundaryGeneration: 0, traktSessionID: nil, routeGeneration: 1
        )
        expect(CinemaQuickWatchScopePolicy.accepts(
            movie, titleID: "tt200", titleType: "movie", episodeID: nil,
            profileID: nil, accountBoundaryGeneration: 0, traktSessionID: nil,
            routeGeneration: 1, taskCancelled: false
        ), "movie seed scope admits without episode identity")
        print("ALL PASS")
    }

    private static func accepts(
        titleID: String = "tt100",
        titleType: String = "series",
        episodeID: String? = "tt100:1:2",
        profileID: String? = "profile-a",
        accountBoundaryGeneration: UInt64 = 7,
        traktSessionID: String? = "trakt-a",
        routeGeneration: Int = 3,
        taskCancelled: Bool = false
    ) -> Bool {
        CinemaQuickWatchScopePolicy.accepts(
            scope,
            titleID: titleID,
            titleType: titleType,
            episodeID: episodeID,
            profileID: profileID,
            accountBoundaryGeneration: accountBoundaryGeneration,
            traktSessionID: traktSessionID,
            routeGeneration: routeGeneration,
            taskCancelled: taskCancelled
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        print("PASS: \(message)")
    }
}
