import Foundation

/// Pure routing and payload rules shared by Apple detail mutations. Keeping these rules independent
/// of the engine bridge makes the owner/overlay boundary and stale-detail fallbacks executable.
enum LibraryWatchedMutationPolicy {
    enum Route: Equatable {
        case engineAccount
        case profileOverlay
    }

    struct MetaPreview: Equatable {
        let id: String
        let type: String
        let name: String
        let poster: String?

        var dictionary: [String: Any] {
            var result: [String: Any] = ["id": id, "type": type, "name": name]
            if let poster { result["poster"] = poster }
            return result
        }
    }

    struct Video: Equatable {
        let id: String
        let season: Int?
        let episode: Int?
    }

    enum WatchedAction: Equatable {
        case video(Video, Bool)
        case title(Bool)
    }

    static func route(usesEngineHistory: Bool) -> Route {
        usesEngineHistory ? .engineAccount : .profileOverlay
    }

    /// Prefer only a ready meta for the open title. A ready response for a previous detail page
    /// must never be used to save the title currently on screen.
    static func detailPreview(targetID: String?, ready: [MetaPreview], catalog: MetaPreview?, decoded: MetaPreview?) -> MetaPreview? {
        if let targetID, let exact = ready.first(where: { $0.id == targetID }) { return exact }
        if targetID == nil, let first = ready.first { return first }
        if let targetID, catalog?.id == targetID { return catalog }
        if let targetID, decoded?.id == targetID { return decoded }
        return nil
    }

    /// Both watch directions must update the per-video bitfield before the title aggregate, so
    /// series ticks and movie-style library state remain consistent.
    static func wholeTitleActions(videos: [Video], isWatched: Bool) -> [WatchedAction] {
        videos.map { .video($0, isWatched) } + [.title(isWatched)]
    }

    static func watchedMembershipChanged(_ current: [String]?, _ next: [String]?) -> Bool {
        Set(current ?? []) != Set(next ?? [])
    }
}
