import Foundation

/// Codable mirrors of the `stremio-core` JSON shapes we read via `CoreBridge`. Field names match the
/// engine's serde output (camelCase, with a few explicit renames). `Core`-prefixed to avoid clashing
/// with the legacy hand-rolled models (MetaPreview, Descriptor, …) during the screen-by-screen migration.

// MARK: continue_watching_preview

struct CoreCWPreview: Decodable {
    let items: [CoreCWItem]
}

struct CoreCWItem: Decodable, Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let state: CoreLibState

    enum CodingKeys: String, CodingKey { case id = "_id", type, name, poster, state }

    /// 0…1 watch progress (timeOffset/duration; both in ms).
    var progress: Double {
        guard state.duration > 0 else { return 0 }
        return min(max(state.timeOffset / state.duration, 0), 1)
    }
}

struct CoreLibState: Decodable {
    let timeOffset: Double
    let duration: Double
    let videoId: String?

    enum CodingKeys: String, CodingKey { case timeOffset, duration, videoId = "video_id" }
}

// MARK: board (catalogs_with_extra)

struct CoreBoardState: Decodable {
    let catalogs: [[CoreCatalogPage]]
}

struct CoreCatalogPage: Decodable {
    let request: CoreResourceRequest
    let content: CoreLoadable<[CoreMeta]>?
}

struct CoreResourceRequest: Decodable {
    let base: String
    let path: CoreResourcePath
}

struct CoreResourcePath: Decodable {
    let resource: String
    let type: String
    let id: String
}

/// Mirrors `Loadable<R, E>` = `#[serde(tag = "type", content = "content")]`:
/// `{"type":"Loading"}` | `{"type":"Ready","content":R}` | `{"type":"Err","content":E}`.
enum CoreLoadable<T: Decodable>: Decodable {
    case loading
    case ready(T)
    case err

    private enum CodingKeys: String, CodingKey { case type, content }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "Ready": self = .ready(try container.decode(T.self, forKey: .content))
        case "Err": self = .err
        default: self = .loading
        }
    }

    var ready: T? { if case let .ready(value) = self { return value } else { return nil } }
}

struct CoreMeta: Decodable, Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let posterShape: String?
}

// MARK: ctx (only what we need: addon manifests for catalog row titles)

struct CoreCtx: Decodable {
    let profile: CoreProfile
}

struct CoreProfile: Decodable {
    let addons: [CoreDescriptor]
}

struct CoreDescriptor: Decodable {
    let manifest: CoreManifest
    let transportUrl: String
}

struct CoreManifest: Decodable {
    let name: String
    let catalogs: [CoreManifestCatalog]
}

struct CoreManifestCatalog: Decodable {
    let id: String
    let type: String
    let name: String?
}

// MARK: assembled UI row

/// One Home board row: a titled, horizontally-scrolling catalog of meta previews.
struct CoreBoardRow: Identifiable {
    let id: String
    let title: String
    let items: [CoreMeta]
}

// MARK: meta_details

struct CoreMetaDetails: Decodable {
    let metaItems: [CoreMetaEntry]
    let streams: [CoreStreamGroup]
    /// The engine's library entry for this title (its state.timeOffset drives resume), if saved.
    let libraryItem: CoreCWItem?
    /// Watched episode ids, computed engine-side from the WatchedBitField (which isn't itself in JSON).
    let watchedVideoIds: [String]?

    /// First fully-loaded meta (addons are queried in order; take the first that resolved).
    var meta: CoreMetaItem? { metaItems.compactMap { $0.content?.ready }.first }
    var watchedIds: Set<String> { Set(watchedVideoIds ?? []) }
}

/// `ResourceLoadable<MetaItem>`, one addon's meta response ({request, content}).
struct CoreMetaEntry: Decodable {
    let request: CoreResourceRequest
    let content: CoreLoadable<CoreMetaItem>?
}

struct CoreMetaItem: Decodable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let runtime: String?
    let links: [CoreLink]?
    let videos: [CoreVideo]?

    var genres: [String] {
        (links ?? []).filter { $0.category.caseInsensitiveCompare("Genre") == .orderedSame }.map(\.name)
    }
    var imdbRating: String? {
        (links ?? []).first { $0.category.caseInsensitiveCompare("imdb") == .orderedSame }?.name
    }
}

struct CoreLink: Decodable {
    let name: String
    let category: String
}

struct CoreVideo: Decodable, Identifiable {
    let id: String
    let title: String?
    let released: String?
    let overview: String?
    let thumbnail: String?
    let season: Int?
    let episode: Int?
}

/// One addon's stream response for the selected meta/episode (`ResourceLoadable<Vec<Stream>>`).
struct CoreStreamGroup: Decodable {
    let request: CoreResourceRequest
    let content: CoreLoadable<[CoreStream]>?
}

/// A playable stream. `StreamSource` is `#[serde(untagged)]` + flattened, so the source fields
/// (url / ytId / infoHash / externalUrl) sit at the top level, decode them all optionally.
struct CoreStream: Decodable, Identifiable {
    let url: String?
    let ytId: String?
    let infoHash: String?
    let fileIdx: Int?
    let sources: [String]?
    let externalUrl: String?
    let name: String?
    let description: String?
    let behaviorHints: CoreStreamBehaviorHints?

    var id: String { (url ?? externalUrl ?? infoHash ?? "?") + "#" + (name ?? "") + (description ?? "") }
    var isTorrent: Bool { url == nil && infoHash != nil }

    /// Direct/debrid URLs play as-is; torrents go through the embedded streaming server.
    var playableURL: URL? {
        if let url, let parsed = URL(string: url) { return parsed }
        guard let hash = infoHash?.lowercased() else { return nil }
        return URL(string: "\(StremioServer.base)/\(hash)/\(fileIdx ?? 0)")
    }
}

struct CoreStreamBehaviorHints: Decodable {
    let notWebReady: Bool?
    let bingeGroup: String?
    let filename: String?
}

/// Streams grouped by source addon, for the per-addon filter + source labels.
struct CoreStreamSourceGroup: Identifiable {
    let id: String
    let addon: String
    let streams: [CoreStream]
}

// MARK: discover (catalog_with_filters)

struct CoreDiscover: Decodable {
    let selectable: CoreDiscoverSelectable
    let catalog: [CoreCatalogPage]          // Vec<ResourceLoadable<Vec<MetaItemPreview>>> (pages)
    var items: [CoreMeta] { catalog.compactMap { $0.content?.ready }.flatMap { $0 } }
}

struct CoreDiscoverSelectable: Decodable {
    let types: [CoreSelectableType]
    let catalogs: [CoreSelectableCatalog]
    let extra: [CoreSelectableExtra]
}

struct CoreSelectableType: Decodable, Identifiable {
    let type: String
    let selected: Bool
    let request: CoreRequest
    var id: String { type }
}

struct CoreSelectableCatalog: Decodable, Identifiable {
    let catalog: String
    let selected: Bool
    let request: CoreRequest
    var id: String { "\(catalog)|\(request.path.id)|\(request.path.type)" }
}

struct CoreSelectableExtra: Decodable {
    let name: String
    let options: [CoreSelectableExtraOption]
}

struct CoreSelectableExtraOption: Decodable, Identifiable {
    let value: String?
    let selected: Bool
    let request: CoreRequest
    var id: String { value ?? "·all·" }
    var label: String { value ?? "All" }
}

// MARK: library (library_with_filters)

struct CoreLibrary: Decodable {
    let selectable: CoreLibrarySelectable
    let catalog: [CoreCWItem]               // Vec<LibraryItem> (already sorted/filtered/paginated)
}

struct CoreLibrarySelectable: Decodable {
    let types: [CoreLibType]
    let sorts: [CoreLibSort]
}

struct CoreLibType: Decodable, Identifiable {
    let type: String?
    let selected: Bool
    let request: CoreLibraryRequest
    var id: String { type ?? "·all·" }
    var label: String { type?.capitalized ?? "All" }
}

struct CoreLibSort: Decodable, Identifiable {
    let sort: String
    let selected: Bool
    let request: CoreLibraryRequest
    var id: String { sort }
    var label: String {
        switch sort {
        case "lastwatched": return "Recent"
        case "name": return "Name A–Z"
        case "namereverse": return "Name Z–A"
        case "timeswatched": return "Most watched"
        case "watched": return "Watched"
        case "notwatched": return "Unwatched"
        default: return sort.capitalized
        }
    }
}

// MARK: round-trippable requests, decoded from `selectable`, re-encoded to dispatch a selection

struct CoreRequest: Codable, Hashable {
    let base: String
    let path: CoreRequestPath
}

struct CoreRequestPath: Codable, Hashable {
    let resource: String
    let type: String
    let id: String
    let extra: [[String]]   // [["genre","Action"], …], array of pairs, not objects
}

struct CoreLibraryRequest: Codable, Hashable {
    let type: String?
    let sort: String
    let page: Int
}
