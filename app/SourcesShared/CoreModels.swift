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
    /// Library bookkeeping: a removed entry stays in the bucket flagged `removed`,
    /// and watched-from-catalog markers are `temp`. "In the library" means neither.
    var removed: Bool? = nil
    var temp: Bool? = nil

    enum CodingKeys: String, CodingKey { case id = "_id", type, name, poster, state, removed, temp }

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
    var isLoading: Bool { if case .loading = self { return true } else { return false } }
}

struct CoreMeta: Decodable, Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let posterShape: String?
    /// The channel mark on live (tv/channel/events) catalog previews — channels publish a `logo`
    /// instead of box-art, so the Live surface's `ChannelTile` prefers it over `poster`. Optional;
    /// VOD previews omit it and decode fine.
    let logo: String?
    // Optional preview details most catalog add-ons include; they power the focused-hero
    // backdrop on the browse pages. All optional so older/sparser add-ons still decode.
    let background: String?
    let description: String?
    let releaseInfo: String?
    /// Rating + genres live in `links` in the engine's catalog-preview serialization (category "imdb"
    /// carries the rating in its name; category "Genres" carries each genre), NOT as top-level fields.
    /// The engine never emits a top-level `imdbRating`/`genres` for a preview, so the old stored
    /// properties decoded nil every time and the featured hero never showed a rating. Read them from
    /// `links` instead — the same place CoreMetaItem (the full detail meta) reads them.
    let links: [CoreLink]?

    var imdbRating: String? {
        (links ?? []).first { $0.category.caseInsensitiveCompare("imdb") == .orderedSame }?.name
    }
    var genres: [String]? {
        let g = (links ?? []).filter { ["genre", "genres"].contains($0.category.lowercased()) }.map(\.name)
        return g.isEmpty ? nil : g
    }
}

struct CoreLocalSearchState: Decodable {
    let searchResults: [CoreSearchSuggestion]
}

struct CoreSearchSuggestion: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String
    let poster: String?
    let releaseInfo: String?
}

// MARK: ctx (only what we need: addon manifests for catalog row titles)

struct CoreCtx: Decodable {
    let profile: CoreProfile
}

struct CoreProfile: Decodable {
    let addons: [CoreDescriptor]
}

struct CoreDescriptor: Decodable, Identifiable {
    let manifest: CoreManifest
    let transportUrl: String
    let flags: CoreDescriptorFlags?
    var id: String { transportUrl }
    /// Default addons (Cinemeta, the local addon) the engine refuses to uninstall.
    var isProtected: Bool { flags?.protected ?? false }

    var providesStreams: Bool { (manifest.resources ?? []).contains { $0.name == "stream" } }
    var providesMeta: Bool { (manifest.resources ?? []).contains { $0.name == "meta" } }
    var providesSubtitles: Bool { (manifest.resources ?? []).contains { $0.name == "subtitles" } }
    var hasCatalogs: Bool { !manifest.catalogs.isEmpty }
    /// Host only (the full transportUrl can embed a debrid config token).
    var host: String { URL(string: transportUrl)?.host ?? transportUrl }
    /// "Catalogs · Streams · Subtitles", the resource kinds the addon exposes.
    var capabilities: String {
        var caps: [String] = []
        if hasCatalogs { caps.append("Catalogs") }
        if providesStreams { caps.append("Streams") }
        if providesMeta { caps.append("Metadata") }
        if providesSubtitles { caps.append("Subtitles") }
        return caps.isEmpty ? "Add-on" : caps.joined(separator: " · ")
    }
}

struct CoreManifest: Decodable {
    let name: String
    let catalogs: [CoreManifestCatalog]
    let resources: [CoreManifestResource]?
}

/// `ManifestResource` is `#[serde(untagged)]`: either a bare string ("stream") or an object
/// ({ name: "stream", types: [...] }). Decode either into the resource name.
struct CoreManifestResource: Decodable {
    let name: String
    init(from decoder: Decoder) throws {
        if let short = try? decoder.singleValueContainer().decode(String.self) { name = short; return }
        name = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .name)
    }
    enum CodingKeys: String, CodingKey { case name }
}

struct CoreDescriptorFlags: Decodable {
    let official: Bool?
    let `protected`: Bool?
}

struct CoreManifestCatalog: Decodable {
    let id: String
    let type: String
    let name: String?
}

// MARK: assembled UI row

/// One Home board row: a titled, horizontally-scrolling catalog of meta previews. `type` is the
/// catalog's content type (the per-row `request.path.type`, e.g. "movie" / "series" / "tv"), so a
/// caller can pick out the Live rows (`LiveTypes`) without re-decoding the board state.
struct CoreBoardRow: Identifiable {
    let id: String
    let title: String
    let type: String
    let items: [CoreMeta]
}

/// The content types Stremio treats as Live TV (the same set tvOS uses for its live-tuned player
/// path): broadcast TV, individual channels, and live events. Shared so the Live surface, the live
/// detail branch, and the player all agree on what "live" means.
enum LiveTypes {
    /// Add-ons label live content inconsistently, so match CASE-INSENSITIVELY across the common variants
    /// instead of one exact set, which is why a "sport" / "Sports" / "live" / "linear" feed used to be
    /// misread as VOD (the player must open in live mode or an HLS feed plays a few seconds and quits).
    /// Builds on #94, which added "sport". Exact tokens only, never substrings, so "tv" can't swallow "tvshow".
    static let all: Set<String> = [
        "tv", "channel", "channels", "events", "event",
        "sport", "sports", "live", "linear", "iptv",
    ]
    static func contains(_ type: String) -> Bool { all.contains(type.lowercased()) }
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
    /// Trailer streams the meta add-on attached (camelCase `trailerStreams` in the engine JSON).
    /// Each is a full `Stream`, so a YouTube trailer flattens to a top-level `ytId` (see
    /// `meta_item.rs` / `serialize_meta_details.rs`). Optional so sparser add-ons still decode.
    let trailerStreams: [CoreStream]?
    /// Meta-level behaviorHints (camelCase `behaviorHints` in the engine JSON; the bridge decoder
    /// uses the default key strategy, same as `trailerStreams`). Distinct from the per-STREAM
    /// `CoreStreamBehaviorHints`. Live/EPG add-ons set `hasScheduledVideos` here to flag that
    /// `videos[]` is a now/next schedule rather than an episode list. Optional so sparse add-ons decode.
    let behaviorHints: CoreMetaBehaviorHints?

    var genres: [String] {
        // The engine emits the genres link category as "Genres" (PLURAL); the old "Genre" (singular)
        // filter matched nothing, so detail + episode headers always showed empty genres. Accept both.
        (links ?? []).filter { ["genre", "genres"].contains($0.category.lowercased()) }.map(\.name)
    }
    var imdbRating: String? {
        (links ?? []).first { $0.category.caseInsensitiveCompare("imdb") == .orderedSame }?.name
    }

    /// Credits, read from `links` where the engine serializes them as named link categories (each name
    /// is one person). Accept singular and plural spellings, since add-ons differ. Empty when absent.
    var cast: [String] { credits("cast", "actors", "actor") }
    var directors: [String] { credits("director", "directors") }
    var writers: [String] { credits("writer", "writers") }
    private func credits(_ categories: String...) -> [String] {
        (links ?? []).filter { categories.contains($0.category.lowercased()) }.map(\.name)
    }

    /// The first trailer's YouTube id, if the meta carries a playable YouTube trailer. Stremio metas
    /// expose trailers via `trailerStreams` whose source is a YouTube id; some older add-ons only
    /// fill `links` with a "Trailer" category pointing at a youtube.com URL, so fall back to that.
    var trailerYouTubeID: String? {
        if let yt = (trailerStreams ?? []).compactMap(\.ytId).first(where: { !$0.isEmpty }) {
            return yt
        }
        let trailerLink = (links ?? []).first {
            $0.category.caseInsensitiveCompare("Trailer") == .orderedSame
        }
        return trailerLink.flatMap { Self.youTubeID(from: $0.name) }
    }

    /// Extract a YouTube video id from a watch / share / embed URL (or a bare 11-char id).
    static func youTubeID(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            if host.contains("youtu.be") {
                let id = url.lastPathComponent
                return id.isEmpty ? nil : id
            }
            if host.contains("youtube.com") {
                if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
                    return v
                }
                // /embed/<id>, /shorts/<id>, /v/<id>
                let last = url.lastPathComponent
                return last.isEmpty ? nil : last
            }
        }
        // Bare 11-character YouTube id.
        let idChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        if trimmed.count == 11, trimmed.unicodeScalars.allSatisfy({ idChars.contains($0) }) {
            return trimmed
        }
        return nil
    }
}

/// Meta-level `behaviorHints` (NOT the per-stream `CoreStreamBehaviorHints`). All fields optional so
/// sparse add-ons decode. `hasScheduledVideos` marks a live channel whose `videos[]` is a now/next
/// EPG schedule; `featuredVideoId` (when present) names the currently-airing program directly.
struct CoreMetaBehaviorHints: Decodable {
    let hasScheduledVideos: Bool?
    let featuredVideoId: String?
    /// The canonical video id for a single-video title (a movie). For a title from a TMDB/Kitsu catalog
    /// the meta `id` is tmdb:/kitsu: but `defaultVideoId` carries the imdb id (tt...). Official Stremio
    /// uses this as the movie stream-path id, so imdb-keyed stream add-ons (idPrefixes ["tt"]) match;
    /// passing the raw tmdb id instead silently drops every imdb add-on from the plan.
    let defaultVideoId: String?
}

/// Pure, engine-free now/next selection over a live channel's scheduled `videos[]`. Mirrors the
/// reference serializer's now/next rule: NOW is the latest program that has already started
/// (`released <= reference`), NEXT is the earliest program still to come (`released > reference`).
/// Unit-testable in isolation: inject `reference` for deterministic results. Returns nil (so callers
/// fall back to the description / hide the strip) unless the meta is flagged scheduled AND at least
/// one dated program resolves to now or next.
struct EPGSchedule {
    let now: CoreVideo?
    let next: CoreVideo?

    init?(meta: CoreMetaItem, reference: Date = Date()) {
        guard meta.behaviorHints?.hasScheduledVideos == true, let videos = meta.videos else { return nil }
        let dated = videos.compactMap { v -> (CoreVideo, Date)? in v.releasedDate.map { (v, $0) } }
        guard !dated.isEmpty else { return nil }
        now  = dated.filter { $0.1 <= reference }.max { $0.1 < $1.1 }?.0
        next = dated.filter { $0.1 >  reference }.min { $0.1 < $1.1 }?.0
        guard now != nil || next != nil else { return nil }
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

    /// Display helpers used by the player's episode list and Prev/Next buttons.
    var episodeNumber: Int { episode ?? 0 }
    var episodeTitle: String {
        if let title, !title.isEmpty { return title }
        return "Episode \(episode ?? 0)"
    }

    /// The `released` string parsed as a `Date` (non-breaking — display still uses the raw string).
    /// Live/EPG schedules carry an ISO-8601 UTC timestamp here; try the plain form first, then the
    /// fractional-seconds variant some add-ons emit. Returns nil when absent or unparseable.
    var releasedDate: Date? {
        guard let released else { return nil }
        return ISO8601DateFormatter.epg.date(from: released)
            ?? ISO8601DateFormatter.epgFractional.date(from: released)
    }
}

extension ISO8601DateFormatter {
    /// Shared formatters for parsing `CoreVideo.released` — `static let` so the EPG now/next pass
    /// reuses one instance per form instead of allocating a formatter per video (they're costly).
    static let epg = ISO8601DateFormatter()
    static let epgFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
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
        guard !PlaybackSettings.torrentsDisabled else { return nil }
        guard let hash = infoHash?.lowercased() else { return nil }
        return URL(string: "\(StremioServer.base)/\(hash)/\(fileIdx ?? 0)")
    }

    /// HTTP request headers the add-on declares this stream NEEDS (behaviorHints.proxyHeaders):
    /// some add-ons front CDNs that reject requests without a specific Referer or browser
    /// User-Agent. Official clients apply these; the player must too or the stream 403s.
    var requestHeaders: [String: String]? {
        guard let headers = behaviorHints?.proxyHeaders?.request, !headers.isEmpty else { return nil }
        return headers
    }
}

struct CoreStreamBehaviorHints: Decodable {
    let notWebReady: Bool?
    let bingeGroup: String?
    let filename: String?
    let proxyHeaders: CoreProxyHeaders?
}

/// `behaviorHints.proxyHeaders`: per-stream HTTP headers, `request` applied on the way out.
struct CoreProxyHeaders: Decodable {
    let request: [String: String]?
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
    /// Present when the current catalog has another page (the engine's skip-based pagination); nil at
    /// the end. Drives Discover's infinite scroll via `CoreBridge.loadDiscoverNextPage()`.
    let nextPage: CoreSelectablePage?

    enum CodingKeys: String, CodingKey {
        case types, catalogs, extra
        case nextPage = "next_page"
    }
}

/// The engine's `SelectablePage` (catalog_with_filters): carries the request for the next page.
struct CoreSelectablePage: Decodable {
    let request: CoreRequest
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
