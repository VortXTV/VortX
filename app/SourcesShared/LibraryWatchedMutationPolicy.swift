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

    /// Identity captured by a rendered detail action. The bridge must compare both fields before
    /// it dispatches, because an id alone is not a sufficient model identity across catalog types.
    struct DetailTarget: Equatable {
        let id: String
        let type: String
    }

    enum WatchedAction: Equatable {
        case video(Video, Bool)
        case title(Bool)
    }

    static func route(usesEngineHistory: Bool) -> Route {
        usesEngineHistory ? .engineAccount : .profileOverlay
    }

    static func residentMatches(_ expected: DetailTarget, residentID: String?, residentType: String?) -> Bool {
        expected.id == residentID && expected.type == residentType
    }

    static func renderedDetailTarget(routeID: String, routeType: String,
                                     residentID: String?, residentType: String?) -> DetailTarget {
        guard let residentID, !residentID.isEmpty,
              let residentType, !residentType.isEmpty else {
            return DetailTarget(id: routeID, type: routeType)
        }
        return DetailTarget(id: residentID, type: residentType)
    }

    static func canDispatchCatalogAdd(metaID: String, expectedType: String?, previewID: String?, previewType: String?) -> Bool {
        metaID == previewID && (expectedType == nil || expectedType == previewType)
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
