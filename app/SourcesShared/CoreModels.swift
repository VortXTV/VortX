import Foundation

/// Codable mirrors of the `stremio-core` JSON shapes we read via `CoreBridge`. Field names match the
/// engine's serde output (camelCase, with a few explicit renames). `Core`-prefixed to avoid clashing
/// with the legacy hand-rolled models (MetaPreview, Descriptor, …) during the screen-by-screen migration.

/// A whole-seconds count to a compact timecode: "M:SS" under an hour, "H:MM:SS" past it. The shared
/// "resume 1:03" / "45:12" / "1:12:30" affordance used on Continue Watching cards and the detail
/// primary button (mirrors the webapp's `formatTime`). Returns nil for non-positive input so callers
/// can cleanly omit the badge / suffix when there is nothing to resume.
func resumeTimecode(_ seconds: Double) -> String? {
    guard seconds.isFinite, seconds >= 1 else { return nil }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

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

    /// The saved resume position in whole seconds (`timeOffset` is ms), so a card can show where
    /// playback will pick up ("Resume 1:03"). 0 when nothing has been played into this title.
    var resumeSeconds: Double { max(0, state.timeOffset / 1000) }
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
    /// A Stremio default/official add-on (Cinemeta, the local add-on, WatchHub, Public Domain, …). A
    /// logout resets the profile to ONLY these, so "every add-on is official" means the user's installed
    /// add-ons were wiped.
    var isOfficial: Bool { flags?.official ?? false }

    var providesStreams: Bool { (manifest.resources ?? []).contains { $0.name == "stream" } }
    var providesMeta: Bool { (manifest.resources ?? []).contains { $0.name == "meta" } }
    var providesSubtitles: Bool { (manifest.resources ?? []).contains { $0.name == "subtitles" } }
    var hasCatalogs: Bool { !manifest.catalogs.isEmpty }
    /// Host only (the full transportUrl can embed a debrid config token).
    var host: String { URL(string: transportUrl)?.host ?? transportUrl }
    /// True when the add-on declares a web configuration page (manifest behaviorHints.configurable).
    var isConfigurable: Bool { manifest.behaviorHints?.configurable == true }
    /// The add-on's configuration page: the manifest URL with the trailing `manifest.json` swapped for
    /// `configure` (the Stremio convention). Opens in a browser on iPhone/iPad/Mac; on Apple TV the
    /// Configure sheet shows it as a QR to finish on a phone (or via the web dashboard).
    var configureURL: URL? {
        guard isConfigurable else { return nil }
        if transportUrl.hasSuffix("/manifest.json") {
            return URL(string: String(transportUrl.dropLast("manifest.json".count)) + "configure")
        }
        return URL(string: transportUrl)
    }
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
    /// Manifest-level behaviorHints; `configurable` means the add-on exposes a web configuration page.
    let behaviorHints: CoreManifestBehaviorHints?
    /// The add-on's logo URL (Stremio `manifest.logo`). AIOManager bakes a user's custom logo here, so
    /// VortX renders it on the add-on row for parity. Optional; older/sparser manifests omit it.
    let logo: String?
}

/// Manifest-level `behaviorHints` (distinct from the meta-level + per-stream ones). `configurable` flags
/// that the add-on has a config page (Stremio convention: its manifest URL with `manifest.json` -> `configure`).
struct CoreManifestBehaviorHints: Decodable {
    let configurable: Bool?
    let configurationRequired: Bool?
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
    /// Index of this catalog in the engine's `board.catalogs`, so a Home row can ask the engine to
    /// `LoadNextPage(engineIndex)` for its own horizontal infinite scroll (#95). Stable across page
    /// loads and board widening; `buildBoardRows` captures it before the display filter/sort.
    let engineIndex: Int
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

    /// A PROVISIONAL playback duration in seconds parsed from the human `runtime` string ("60 min",
    /// "1h 32m", "92 min", "2:05:00"). Used by community trickplay to key + start capture at the first
    /// positive timePos, BEFORE mpv emits its `duration` event (which a debrid MKV may never deliver). The
    /// real mpv duration later refines the bucket. Returns nil when no number can be read.
    var runtimeSeconds: Double? {
        guard let r = runtime?.lowercased() else { return nil }
        // "h:mm:ss" or "mm:ss" colon form first.
        if r.contains(":") {
            let parts = r.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3 { return Double(parts[0] * 3600 + parts[1] * 60 + parts[2]) }
            if parts.count == 2 { return Double(parts[0] * 60 + parts[1]) }
        }
        // "1h 32m" / "1 h 32 min" form: sum hours + minutes when an explicit hour marker is present.
        var totalMinutes = 0
        var matched = false
        let scanner = Scanner(string: r)
        scanner.charactersToBeSkipped = CharacterSet.alphanumerics.inverted
        while !scanner.isAtEnd {
            guard let n = scanner.scanInt() else { break }
            let unit = scanner.scanCharacters(from: CharacterSet.lowercaseLetters) ?? ""
            if unit.hasPrefix("h") { totalMinutes += n * 60; matched = true }
            else { totalMinutes += n; matched = true }   // bare number or "min" -> minutes
        }
        guard matched, totalMinutes > 0 else { return nil }
        return Double(totalMinutes * 60)
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

    /// All episodes ordered (season, then episode, then id) across EVERY season — the list handed to the
    /// player so in-player Next / auto-advance rolls past the season boundary into the next season's first
    /// episode (was per-season, so it dead-ended at the last episode of a season).
    var orderedEpisodes: [CoreVideo] { (videos ?? []).orderedBySeasonEpisode }

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

    /// A minimal placeholder meta for a title whose Cinemeta meta is nil (a brand-new/unreleased title:
    /// the `tt` exists at TMDB but is not yet in Cinemeta). The detail page is driven entirely by this
    /// meta, so meta=nil used to leave an empty hero AND blocked the sources list. This synthesizes just
    /// enough (id, type, name, and Stremio's standard metahub-by-tt backdrop/logo) so the hero paints and
    /// the stream request can still fire on the `tt`. Built via JSON decode so it tracks the struct's own
    /// field set with no manual memberwise init. Returns nil only if the decoder itself fails (never, here).
    static func placeholder(id: String, type: String, name: String) -> CoreMetaItem? {
        let bg = id.hasPrefix("tt") ? "https://images.metahub.space/background/big/\(id)/img" : ""
        let logo = id.hasPrefix("tt") ? "https://images.metahub.space/logo/medium/\(id)/img" : ""
        let json: [String: Any] = [
            "id": id, "type": type, "name": name,
            "background": bg, "logo": logo,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(CoreMetaItem.self, from: data)
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

extension Array where Element == CoreVideo {
    /// Episodes ordered by (season, episode, id) across all seasons. The cross-season player list, so
    /// auto-advance rolls from a season's last episode into the next season's first (shared by the iOS/Mac
    /// and tvOS detail screens). Specials (season 0) sort first and don't interrupt end-of-season advance.
    var orderedBySeasonEpisode: [CoreVideo] {
        sorted {
            let ls = $0.season ?? 0, rs = $1.season ?? 0
            if ls != rs { return ls < rs }
            let le = $0.episode ?? 0, re = $1.episode ?? 0
            if le != re { return le < re }
            return $0.id < $1.id
        }
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
    /// Native Stremio USENET source fields (part of the stream spec, alongside url / ytId / infoHash):
    /// `nzbUrl` is an http(s) link to an `.nzb`, and `fileMustInclude` is an optional regex that picks the
    /// video inside the (potentially multi-file) usenet download. A stream with a non-nil `nzbUrl` is a
    /// USENET stream — it resolves through the user's own usenet-capable debrid account (TorBox), never a
    /// torrent swarm. All optional so a stream without them (every torrent/direct/YouTube source) still
    /// decodes byte-identically to before.
    let nzbUrl: String?
    let fileMustInclude: String?

    var id: String { (url ?? externalUrl ?? infoHash ?? nzbUrl ?? "?") + "#" + (name ?? "") + (description ?? "") }
    var isTorrent: Bool { url == nil && infoHash != nil && nzbUrl == nil }

    /// A USENET stream: no direct `url` yet, but an `.nzb` link to resolve through a usenet-capable debrid
    /// account. Like a raw torrent, it needs resolution before it is playable — the usenet analogue of
    /// `isTorrent`. Kept mutually exclusive from `isTorrent` (which now also checks `nzbUrl == nil`) so a
    /// stream is classified as exactly one of torrent / usenet / direct.
    var isUsenet: Bool { url == nil && (nzbUrl.map { !$0.isEmpty } ?? false) }

    /// A bare YouTube source (`ytId`, no direct `url`): a trailer/clip from a trailer add-on like
    /// Streailer, not a full feature stream. Playable (via the `/yt` route in `playableURL`) so the
    /// user can tap it, but excluded from quality RANKING and the one-press auto-pick — otherwise an
    /// unscored "🎬 Trailer" row could become `StreamRanking.best` and play the trailer in place of
    /// the movie (and a trailer must never be recorded as Continue Watching).
    var isYouTubeTrailer: Bool { url == nil && infoHash == nil && (ytId.map { !$0.isEmpty } ?? false) }

    /// Direct/debrid URLs play as-is; torrents go through the embedded streaming server.
    ///
    /// A `ytId`-only stream is a YouTube source (e.g. a trailer add-on like Streailer returns
    /// `{ "ytId": "…" }` streams, no `url`/`infoHash`): play it through the remote resolver's
    /// `/yt/{id}` route — the same path the Trailer button uses (`TrailerRequest`). The remote
    /// resolver needs no embedded server, so this is playable on every scheme including Lite.
    /// Without this, every Streailer stream rendered as an inert lock-icon row.
    var playableURL: URL? {
        if let url, let parsed = URL(string: url) { return parsed }
        // USENET: playable only when a TorBox key can resolve it. The play path
        // (`DebridCoordinator.resolvedPlaybackRef`) turns the nzb into a direct https link BEFORE the
        // player sees any URL; the nzb link here only makes the row tappable / identifies it. Without
        // this, every usenet row rendered as a dead disabled label (every row gate keys on this
        // property). No TorBox key -> nil, the pre-usenet behavior. Deliberately NOT behind the
        // torrents gate: usenet resolves to a remote link, no embedded server needed (Lite plays it).
        if isUsenet, DebridKeys.shared.isConfigured(.torBox), let nzb = nzbUrl, let parsed = URL(string: nzb) {
            return parsed
        }
        if let ytId, !ytId.isEmpty {
            return URL(string: "\(StremioServer.trailerResolverBase)/yt/\(ytId)")
        }
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
    /// True while any catalog page is still loading (e.g. a just-dispatched next-page request). Lets the
    /// bridge tell a mid-load emit (same item count, more coming) apart from a settled end-of-catalog
    /// (load finished with no new items), so cursorless-pagination end-detection never latches early.
    var isLoadingPage: Bool { catalog.contains { $0.content?.isLoading == true } }
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

// MARK: - VortX account-owned add-on (sync doc)

/// A full add-on descriptor the VortX account OWNS, stored plaintext in `doc.vortx.addons` so the
/// engine can be re-hydrated network-free when a Stremio session is absent/degraded (the "0 sources /
/// 0 add-ons" fix). The shape mirrors the engine's `InstallAddon` descriptor (`{transportUrl, manifest,
/// flags}`) so a re-dispatch is byte-shape-exact, plus `name` for the dashboard. `manifest`/`flags`
/// are kept as opaque JSON passthrough so the descriptor round-trips into the engine unchanged without
/// this layer needing to model the whole Stremio manifest schema. Only descriptors enter the doc (the
/// Stremio token stays Keychain-only); these already ride `doc.addons` + `apiKeys` E2E today.
struct VortXOwnedAddon {
    let transportUrl: String
    let name: String
    let manifest: [String: Any]   // opaque passthrough, re-dispatched verbatim to the engine
    let flags: [String: Any]?

    /// Build from one `doc.vortx.addons` (or `doc.addons`) entry. Tolerates the legacy
    /// `{transportUrl,name}`-only shape (manifest absent) by skipping it: without a manifest the engine
    /// cannot InstallAddon, so it is not hydratable and is dropped rather than dispatched as a no-op.
    init?(json: [String: Any]) {
        guard let url = json["transportUrl"] as? String, !url.isEmpty,
              let manifest = json["manifest"] as? [String: Any] else { return nil }
        self.transportUrl = url
        self.manifest = manifest
        self.flags = json["flags"] as? [String: Any]
        self.name = (json["name"] as? String) ?? (manifest["name"] as? String) ?? url
    }

    /// The exact `InstallAddon` descriptor the engine expects (`installAddon` sends the same shape).
    /// Keys are camelCase to match the engine's serde contract; a lowercase-key mismatch silently
    /// no-ops in the engine, so this MUST stay aligned with CoreBridge.installAddon.
    var installDescriptor: [String: Any] {
        var d: [String: Any] = ["transportUrl": transportUrl, "manifest": manifest]
        d["flags"] = flags ?? ["official": false, "protected": false]
        return d
    }
}

// MARK: - Stremio mirror settings (owner-requested per-category control)

/// Per-category control of whether VortX mirrors a live Stremio account.
///
/// DEFAULT OFF for every category = the FLOOR: VortX owns the category. Snapshot-on-import seeds it
/// once, hydrate-from-doc keeps it alive, and a Stremio removal NEVER removes it from VortX.
///
/// ON = EXACT MIRROR for that category: on a SUCCESSFUL Stremio reconcile the VortX-owned set for the
/// category is replaced to match the live Stremio set (adds AND removes tracked).
///
/// The never-zero guard is independent of these toggles: a failed/absent/empty Stremio pull is ignored
/// and never zeroes a category. Hydrate-from-doc is also NOT gated by the toggles. The toggles only
/// control the snapshot/mirror DIRECTION (Stremio -> VortX) and whether Stremio removals propagate.
///
/// Stored in UserDefaults so the flags ride the SettingsBackup blob (doc.settings) and sync across
/// devices.
enum MirrorSettings {
    static let addonsKey = "stremiox.sync.mirror.addons"
    static let libraryKey = "stremiox.sync.mirror.library"
    static let continueWatchingKey = "stremiox.sync.mirror.cw"

    /// Mirror add-ons from Stremio (default OFF = VortX keeps its own add-on set).
    static var mirrorAddons: Bool { UserDefaults.standard.bool(forKey: addonsKey) }
    /// Mirror library from Stremio (default OFF = VortX keeps its own library).
    static var mirrorLibrary: Bool { UserDefaults.standard.bool(forKey: libraryKey) }
    /// Mirror Continue Watching from Stremio (default OFF = VortX keeps its own CW).
    static var mirrorContinueWatching: Bool { UserDefaults.standard.bool(forKey: continueWatchingKey) }
}
