import Foundation

/// Immutable ownership captured by an explicit Cinema Quick Watch request. Source resolution can outlive a
/// SwiftUI route, profile, or account boundary, so every presentation-capable await must revalidate this
/// scope before it mutates player state.
///
/// String identity fields intentionally carry only non-secret identifiers. The auth session is represented by
/// its local boundary token, never by an account credential.
struct CinemaQuickWatchScope: Equatable, Sendable {
    let titleID: String
    let titleType: String
    let episodeID: String?
    let profileID: String?
    let accountBoundaryGeneration: UInt64
    let traktSessionID: String?
    let routeGeneration: Int
}

/// Pure admission contract for async Quick Watch work. Keeping this value-only lets the focused contract test
/// cover title/type/profile/account/episode/route cancellation without SwiftUI, media, or network fixtures.
enum CinemaQuickWatchScopePolicy {
    static func accepts(
        _ scope: CinemaQuickWatchScope,
        titleID: String,
        titleType: String,
        episodeID: String?,
        profileID: String?,
        accountBoundaryGeneration: UInt64,
        traktSessionID: String?,
        routeGeneration: Int,
        taskCancelled: Bool
    ) -> Bool {
        guard !taskCancelled else { return false }
        return scope.titleID == titleID
            && normalized(scope.titleType) == normalized(titleType)
            && scope.episodeID == episodeID
            && scope.profileID == profileID
            && scope.accountBoundaryGeneration == accountBoundaryGeneration
            && scope.traktSessionID == traktSessionID
            && scope.routeGeneration == routeGeneration
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
