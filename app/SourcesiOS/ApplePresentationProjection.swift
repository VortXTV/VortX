import Foundation

/// A publication cache, not a body-time collection signature. Equality and the expensive
/// transform run only when the owning source publishes or its profile identity changes.
struct ApplePresentationPublicationCache<Input: Equatable, Output> {
    private var input: Input?
    private var owner: UUID?
    private(set) var value: Output?

    func value(for owner: UUID?) -> Output? { self.owner == owner ? value : nil }

    @discardableResult
    mutating func accept(_ input: Input, owner: UUID? = nil, build: () -> Output) -> Bool {
        guard self.input != input || self.owner != owner || value == nil else { return false }
        self.input = input
        self.owner = owner
        value = build()
        return true
    }
}

/// Home observers inspect at most thirty resident entries. Include presentation and resume
/// fields so an interior progress/artwork replacement cannot hide behind first-ID/count keys.
enum AppleHomeHistoryProjection {
    static let observationLimit = 30
    struct Key: Equatable {
        let id: String
        let type: String
        let name: String
        let poster: String?
        let offset: UInt64
        let duration: UInt64
        let videoID: String?
        let activity: String?
        let flaggedWatched: Int
        let timesWatched: Int
        let removed: Bool?
        let temporary: Bool?
    }
    static func key(_ items: [CoreCWItem]) -> [Key] {
        items.prefix(observationLimit).map(entryKey)
    }
    /// Used only at a source publication, never by a body/observer. An identical accepted
    /// history re-emit must not repeat the selected-window sort or card conversion.
    static func inputKey(_ items: [CoreCWItem]) -> [Key] { items.map(entryKey) }
    private static func entryKey(_ item: CoreCWItem) -> Key {
        Key(id: item.id, type: item.type, name: item.name, poster: item.poster,
            offset: item.state.timeOffset.bitPattern, duration: item.state.duration.bitPattern,
            videoID: item.state.videoId, activity: item.state.lastWatched,
            flaggedWatched: item.state.flaggedWatched, timesWatched: item.state.timesWatched,
            removed: item.removed, temporary: item.temp)
    }
}

/// Accepted search publications are converted once, in source order. Dedicated Search and
/// merged Discover render these same arrays; neither filters or constructs cards in its body.
struct AppleSearchResultProjection {
    /// The bridge can re-announce an identical search snapshot on a library publication.
    /// Compare its card inputs at that source edge, including ordered interior metadata.
    /// Query changes already clear the accepted publisher; no query-only key is needed.
    struct Input: Equatable {
        let id: String
        let type: String
        let name: String
        let poster: String?
        let background: String?
        let description: String?
        let releaseInfo: String?
        let links: [CoreLink]?
    }
    static func inputKey(_ results: [CoreMeta]) -> [Input] {
        results.map { Input(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster,
            background: $0.background, description: $0.description, releaseInfo: $0.releaseInfo, links: $0.links) }
    }

    enum Group: String, CaseIterable {
        case movies, series, collections, other
        init(type: String) {
            switch type {
            case "movie": self = .movies
            case "series": self = .series
            case "collection", "collections": self = .collections
            default: self = .other
            }
        }
    }
    struct Section: Identifiable {
        let id: Group
        let items: [RailItem]
    }
    let sections: [Section]
    let count: Int
    var isEmpty: Bool { count == 0 }

    init(_ results: [CoreMeta]) {
        var grouped: [Group: [RailItem]] = [:]
        for item in results {
            grouped[Group(type: item.type), default: []].append(
                RailItem(id: item.id, type: item.type, name: item.name, poster: item.poster, progress: 0,
                         background: item.background, description: item.description,
                         releaseInfo: item.releaseInfo, imdbRating: item.imdbRating, genres: item.genres))
        }
        sections = Group.allCases.compactMap { group in
            grouped[group].map { Section(id: group, items: $0) }
        }
        count = results.count
    }
}
