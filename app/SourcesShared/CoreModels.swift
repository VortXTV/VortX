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

    /// Whether this title is effectively FINISHED and should drop out of Continue Watching.
    ///
    /// The engine's `is_in_continue_watching()` is just `time_offset > 0` with no completion check, so a
    /// title watched to the end (or marked watched, or finished on another device and synced down) keeps a
    /// non-zero offset and lingers in the rail forever. The runtime rewind (`finishedWatching`) only fires
    /// from a local play-to-EOF, so nothing catches the marked-watched or watched-elsewhere cases. This is
    /// the data-layer backstop CoreBridge applies before publishing the rail.
    ///
    /// - Movie: finished when it is at/past the engine's own 0.9 credits threshold, OR when the engine
    ///   flagged it watched (`flaggedWatched`/`timesWatched > 0`) AND it is not currently being re-watched.
    ///   A movie the user finished once and is now re-watching has its offset reset to a low/mid value, so
    ///   it sits in the live-in-progress band (`resumeFloor`…0.9); that must KEEP it in the rail so the
    ///   rewatch shows and resumes, even though the watched counters are non-zero. A movie parked at the
    ///   credits, or freshly flagged-watched with no active offset, has no in-progress position and clears.
    /// - Series: `timesWatched` counts watched episodes, so it must NOT gate the rail. The only safe
    ///   finished signal is the current episode being at/past 0.9.
    ///   A finished episode with a next one rolls `time_offset` back to a low value for the new episode, so
    ///   its progress is low and it correctly stays.
    var isFinished: Bool {
        let watchedToEnd = progress >= 0.9
        if EpisodePlaybackIdentity.usesSeriesLifecycle(type: type) { return watchedToEnd }
        // A live, resumable position (progress above the resume floor but below the finished ceiling)
        // means an active watch/rewatch: keep it even if the watched counters are set.
        let resumeFloor = 0.0
        let inProgress = progress > resumeFloor && progress < 0.9
        if inProgress { return false }
        return watchedToEnd || state.flaggedWatched > 0 || state.timesWatched > 0
    }

    /// The engine's own "has been watched" predicate (upstream `LibraryItem::watched()`:
    /// `times_watched > 0`), driving the Library poster badge (DESIGN.md "PosterCard —
    /// Watched state"). `LibraryItemMarkAsWatched` and every finished play/episode bump
    /// `timesWatched`; unmark resets it to 0. `flaggedWatched` is deliberately NOT consulted:
    /// upstream documents it as a per-video "watched event sent" latch, not the indicator.
    /// Distinct from `isFinished`, which answers the Continue-Watching prune question.
    var isWatched: Bool { state.timesWatched > 0 }
}

struct CoreLibState: Decodable {
    let timeOffset: Double
    let duration: Double
    let videoId: String?
    /// Engine watched-bookkeeping. `flaggedWatched` (movies) flips to 1 when a movie is marked/played
    /// to the end; `timesWatched` counts finished plays (movies) or watched episodes (series). Both are
    /// camelCase in the engine's serialization and default to 0 for older/sparser entries that omit them.
    let flaggedWatched: Int
    let timesWatched: Int

    enum CodingKeys: String, CodingKey {
        case timeOffset, duration, videoId = "video_id", flaggedWatched, timesWatched
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeOffset = (try c.decodeIfPresent(Double.self, forKey: .timeOffset)) ?? 0
        duration = (try c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0
        videoId = try c.decodeIfPresent(String.self, forKey: .videoId)
        flaggedWatched = (try c.decodeIfPresent(Int.self, forKey: .flaggedWatched)) ?? 0
        timesWatched = (try c.decodeIfPresent(Int.self, forKey: .timesWatched)) ?? 0
    }

    /// Explicit memberwise init: declaring `init(from:)` above suppresses the synthesized one, and the
    /// overlay-profile builders in Profiles.swift construct states by hand. The two watched-count fields
    /// default to 0 (the overlay rail does its own finished-movie pruning), so those call sites are
    /// unchanged. `nil` videoId keeps the movie case working.
    init(timeOffset: Double, duration: Double, videoId: String?,
         flaggedWatched: Int = 0, timesWatched: Int = 0) {
        self.timeOffset = timeOffset
        self.duration = duration
        self.videoId = videoId
        self.flaggedWatched = flaggedWatched
        self.timesWatched = timesWatched
    }
}

// MARK: Continue-Watching exact-source resume

/// The URL a Continue-Watching resume should hand the player for the EXACT source this title last played,
/// PLUS whether that URL was freshly minted for that same source. Owner requirement: resume plays THAT
/// source (source #3 the user chose), not a re-run of source selection across all add-ons.
///
/// When the stored entry carries native-debrid provenance (`debridService` + `infoHash`, recorded on play
/// in `LastStreamStore.record`), we mint a FRESH direct link for that same file through the same provider
/// via `DebridCoordinator.reresolve` (a single `requestdl` on TorBox's stored torrentId/fileId, no full
/// add-on re-resolve, no auto-pick. Debrid links are time-limited and expire between sessions, so replaying
/// the stored `url` alone dead-ends on "this source didn't load" and the player then hops across every
/// source (the "Tried N sources" failure); reresolving the SAME source avoids that entirely.
///
/// Fail-soft and provenance-optional: an entry with no debrid ids (a plain-direct or torrent/loopback
/// resume) returns the stored `url` unchanged with `refreshed == false`, so those paths are byte-identical.
/// A debrid entry whose file is genuinely gone (reresolve throws `.notCached`/`.noKey`) also falls back to
/// the stored `url`; the caller's existing player failover is the last resort only when the SAME source is
/// truly unavailable.
@MainActor
enum CWResume {
    /// How recently the stored debrid link must have been minted for a resume to replay it INSTANTLY without
    /// a reresolve round-trip. Debrid direct links live for hours, so a link minted within this window is
    /// almost certainly still valid; a conservative 20 minutes keeps the "quick pause then resume" case
    /// instant while anything older takes the reliable reresolve path.
    private static let freshLinkWindow: TimeInterval = 20 * 60

    /// Resolve the exact stored source to a playable URL. `refreshed` is true when the URL is AUTHORITATIVE
    /// and should be played directly (a freshly minted debrid link, OR a stored link still inside the fresh
    /// window); false only when we fell back to a possibly-stale stored link because the source could not be
    /// reresolved, so the caller keeps its stale-link failover priming. Never throws.
    static func resolvedURL(for entry: LastStreamStore.Entry) async -> (url: URL, refreshed: Bool) {
        let stored = URL(string: entry.url)
        // No debrid provenance (plain-direct / torrent / usenet with no reresolve id): the stored link is
        // all we have. Return it unchanged so these paths behave exactly as before.
        guard let serviceRaw = entry.debridService, let service = DebridService(rawValue: serviceRaw),
              let infoHash = entry.infoHash, !infoHash.isEmpty else {
            return (stored ?? URL(fileURLWithPath: "/"), false)
        }
        // An episodic provider-array fallback needs a positive S/E hint. The original Stremio fileIdx is
        // source provenance only and cannot index a provider-local array. TorBox's stored torrentId+fileId
        // pair is an exact fast path, but a failure there must still close before an unscoped re-add.
        // The stored direct URL is already a concrete file, so return that exact URL unchanged and let the
        // platform decide whether it is safe to replay (raw loopback torrents still require fileIdx).
        let episodeHint = entry.season.flatMap { season in
            entry.episode.flatMap { episode in
                season >= 0 && episode > 0 ? DebridEpisode(season: season, episode: episode) : nil
            }
        }
        let isEpisode = EpisodePlaybackIdentity.isEpisodicContext(
            type: entry.type, season: entry.season, episode: entry.episode,
            videoID: entry.videoId
        )
        let hasExactProviderIDs = service == .torBox
            && entry.debridTorrentId != nil && entry.debridFileId != nil
        if isEpisode, episodeHint == nil, !hasExactProviderIDs {
            return (stored ?? URL(fileURLWithPath: "/"), false)
        }
        // INSTANT RESUME (Step 4): the previous behaviour reresolved a fresh link on EVERY resume, a blocking
        // network round-trip before the player appeared (the "CW resume is slow" regression). But a debrid
        // link minted moments ago is still valid, so when the stored link is inside the fresh window hand it
        // straight back with refreshed:true. The caller plays it immediately and attaches the debridRef, whose
        // ids let the player's own load-failure failover mint a fresh link ONLY if this fresh link somehow
        // dead-ends (strictly safer than today's fallback, which already plays a possibly-STALE stored link).
        if let stored, let savedAt = entry.linkSavedAt {
            let age = Date().timeIntervalSince(savedAt)
            if age >= 0, age < Self.freshLinkWindow { return (stored, true) }
        }
        // Older than the window (or no mint timestamp): mint a FRESH link for the SAME file through the SAME
        // provider. On TorBox this is a single requestdl off the stored torrentId+fileId (no re-add); other
        // providers may re-add only when a semantic episode selector proves the target file.
        if let fresh = try? await DebridCoordinator.shared.reresolve(
            service: service, infoHash: infoHash,
            torrentId: entry.debridTorrentId, fileId: entry.debridFileId, fileIdx: entry.fileIdx,
            episode: episodeHint, requiresSemanticSelection: isEpisode) {
            return (fresh, true)
        }
        // Same source is genuinely unavailable (evicted / no key): fall back to the stored link, letting the
        // player's existing load-failure failover take over only now.
        return (stored ?? URL(fileURLWithPath: "/"), false)
    }
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
        let tag = try container.decode(String.self, forKey: .type)
        switch tag {
        case "Ready": self = .ready(try container.decode(T.self, forKey: .content))
        case "Err": self = .err
        case "Loading": self = .loading
        // Any other tag (an engine "Err"-shape rename, or a genuinely errored group with an
        // unknown tag) is TERMINAL, not still-loading. Decoding it as .loading would leave
        // streamLoadProgress stuck at N-1/N and spin the source list forever. Treat it as
        // terminal (.err, which streamLoadProgress already counts as settled) and log the
        // surprise so an engine tag rename is visible instead of silent.
        default:
            NSLog("%@", "[core] CoreLoadable unknown tag '\(tag)' — treating as terminal (.err)")
            self = .err
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
    /// Base URL for resource requests: the transport URL minus the trailing `/manifest.json` (mirrors
    /// `AddonDescriptor.baseUrl`). The engine's installed add-ons became the source of truth once VortX went
    /// account-primary, so the subtitle fetch hits `\(baseUrl)/subtitles/…` off this.
    var baseUrl: String { transportUrl.replacingOccurrences(of: "/manifest.json", with: "") }
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
    /// Streams EMBEDDED in the meta itself (`MetaDetails.meta_streams`): the engine lifts the selected
    /// video's `video.streams` array into this parallel surface. Catalog add-ons that serve plain HTTP or
    /// HLS links usually inline them in the meta's videos instead of implementing a separate `stream`
    /// resource, so official clients list `metaStreams` alongside `streams`. Ignoring this field made every
    /// such add-on show zero sources (#122). Optional so an older payload without it still decodes.
    let metaStreams: [CoreStreamGroup]?
    /// The engine's library entry for this title (its state.timeOffset drives resume), if saved.
    let libraryItem: CoreCWItem?
    /// Watched episode ids, computed engine-side from the WatchedBitField (which isn't itself in JSON).
    let watchedVideoIds: [String]?

    /// Meta-embedded stream groups plus the stream-resource responses, in the engine's own
    /// `[meta_streams, streams]` concat order. The single source every stream surface should walk, so a
    /// meta-embedded HTTP/HLS source is never invisible to a path that only read `streams`.
    var allStreamGroups: [CoreStreamGroup] { (metaStreams ?? []) + streams }

    /// First fully-loaded meta, chosen by the user's ADD-ON PRIORITY order rather than the engine's raw
    /// `profile.addons` order. The catalog list, Home board and add-on list are display-sorted by the
    /// user's applied order (`VortXSyncManager.appliedAddonOrder`, set by the in-app Reorder screen or the
    /// dashboard drag); the engine's `meta_items` are NOT (a reorder never rewrites the engine's
    /// `profile.addons` Vec, which is what `AggrRequest::AllOfResource` walks). Without this a user whose
    /// #1 add-on is a localized meta provider (e.g. a French Cinemeta) sees French on the catalog but the
    /// DETAIL synopsis resolves from whichever add-on the engine lists first (the protected English
    /// Cinemeta, always seeded at index 0), i.e. English text under a French title (#144). Pick the ready
    /// meta whose add-on is earliest in the applied order so the detail honors the same priority the
    /// catalog does. With no applied order this is exactly the old `.first` (engine order) behavior, so
    /// English users and un-reordered accounts are unchanged.
    var meta: CoreMetaItem? {
        // (addon transport base, meta) for every add-on that returned a ready meta, in engine order.
        var ready: [(base: String, meta: CoreMetaItem)] = []
        for entry in metaItems {
            if let m = entry.content?.ready { ready.append((entry.request.base, m)) }
        }
        guard let first = ready.first else { return nil }
        let order = VortXSyncManager.appliedAddonOrder
        guard !order.isEmpty else { return first.meta }   // no user order -> engine order, unchanged
        var rank: [String: Int] = [:]
        for (i, url) in order.enumerated() { rank[url] = i }
        // Earliest applied-order add-on wins; add-ons not in the order sort AFTER the ordered ones and keep
        // engine order among themselves (a stable min: equal ranks fall back to the first ready seen).
        let best = ready.min { a, b in
            switch (rank[AddonTombstones.normalize(a.base)], rank[AddonTombstones.normalize(b.base)]) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return false
            }
        }
        return best?.meta ?? first.meta
    }
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
        // `runtime` is add-on-supplied, so everything below computes in Double and caps each field: a garbage
        // value like "3000000000000000:00:00" must yield nil, not trap on Int overflow or poison the community
        // trickplay duration bucket. A single field over 24h (86_400s) is dropped; the final total must be
        // finite and positive and is clamped to a 24h ceiling.
        let maxSeconds = 86_400.0
        func field(_ raw: Substring) -> Double? {
            guard let n = Double(raw.trimmingCharacters(in: .whitespaces)),
                  n.isFinite, n >= 0, n <= maxSeconds else { return nil }
            return n
        }
        func finalize(_ seconds: Double) -> Double? {
            guard seconds.isFinite, seconds > 0 else { return nil }
            return min(seconds, maxSeconds)
        }
        // "h:mm:ss" or "mm:ss" colon form first.
        if r.contains(":") {
            let parts = r.split(separator: ":").compactMap { field($0) }
            if parts.count == 3 { return finalize(parts[0] * 3600 + parts[1] * 60 + parts[2]) }
            if parts.count == 2 { return finalize(parts[0] * 60 + parts[1]) }
        }
        // "1h 32m" / "1 h 32 min" form: sum hours + minutes when an explicit hour marker is present.
        var totalMinutes = 0.0
        var matched = false
        let scanner = Scanner(string: r)
        scanner.charactersToBeSkipped = CharacterSet.alphanumerics.inverted
        while !scanner.isAtEnd {
            guard let n = scanner.scanInt(), n >= 0 else { break }
            let value = Double(n)
            guard value <= maxSeconds else { return nil }
            let unit = scanner.scanCharacters(from: CharacterSet.lowercaseLetters) ?? ""
            if unit.hasPrefix("h") { totalMinutes += value * 60; matched = true }
            else { totalMinutes += value; matched = true }   // bare number or "min" -> minutes
        }
        guard matched else { return nil }
        return finalize(totalMinutes * 60)
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
    ///
    /// DISPLAY ONLY. `episode ?? 0` collapses "not resolved yet" and "explicitly episode 0" (specials are
    /// legitimately numbered E0) into the same value, so this must never enter a fetch, cache, pool, or
    /// publication identity. Identity paths read the optional `episode` directly and treat absence as absence;
    /// see `SourceIndexIdentity.contentKey`, which rejects a PARTIAL coordinate pair rather than widening it.
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

/// Opaque identity for one logical media load. Equality is the only supported operation: callers use it
/// to prove that an engine callback came from the load whose state they are about to publish.
struct PlayerLoadToken: Hashable, Sendable {
    private let value = UUID()

    init() {}
}

/// A play-head sample with the exact logical load that produced it. URL equality is deliberately absent:
/// proxies, redirects, remux mounts, and repeated CDN URLs can all rewrite or reuse a URL.
struct PlayerTimePositionEvent: Sendable {
    let seconds: Double
    let loadToken: PlayerLoadToken
}

/// Pure callback-provenance state used by the libmpv bridge and its standalone regressions. The controller
/// serializes mutations with its own lock; this value only defines the fail-closed state transitions.
struct PlayerLoadProvenanceState {
    struct CommandResultField: Equatable {
        let key: String
        let int64Value: Int64?
    }

    private var requestedTokens: [Int64: PlayerLoadToken] = [:]
    private(set) var activeEntryID: Int64?
    private(set) var activeToken: PlayerLoadToken?
    private(set) var fileLoaded = false

    mutating func invalidate() {
        requestedTokens.removeAll(keepingCapacity: true)
        activeEntryID = nil
        activeToken = nil
        fileLoaded = false
    }

    mutating func registerRequest(entryID: Int64, token: PlayerLoadToken) {
        guard entryID > 0 else { return }
        requestedTokens[entryID] = token
        // `loadfile replace` succeeded and the exact playlist entry is now registered. Publish the
        // request token immediately so the caller can prove issuance synchronously. Property callbacks
        // still stay closed until `bindStart` because `callbackToken` requires an active entry below.
        activeEntryID = nil
        activeToken = token
        fileLoaded = false
    }

    /// Complete one synchronous `loadfile replace` attempt. A rejected command did not change mpv's
    /// playlist, so the previous request remains the only callback owner. An accepted command retires the
    /// previous provenance and publishes the new request atomically. If mpv accepted the command but did not
    /// expose a usable playlist-entry ID, invalidate instead of falsely restoring a token for media mpv has
    /// already replaced.
    @discardableResult
    mutating func completeReplacement(commandSucceeded: Bool, entryID: Int64,
                                      token: PlayerLoadToken) -> Bool {
        guard commandSucceeded else { return false }
        guard entryID > 0 else {
            invalidate()
            return false
        }
        invalidate()
        registerRequest(entryID: entryID, token: token)
        return true
    }

    /// Extract the one immutable playlist entry id returned by `loadfile`. Missing, mistyped, duplicate,
    /// or non-positive fields are unusable because associating the request with a guessed playlist entry
    /// would let a later callback publish the wrong media identity.
    static func playlistEntryID(from fields: [CommandResultField]) -> Int64? {
        let matches = fields.filter { $0.key == "playlist_entry_id" }
        guard matches.count == 1, let entryID = matches[0].int64Value, entryID > 0 else { return nil }
        return entryID
    }

    mutating func bindStart(entryID: Int64) {
        // `loadfile replace` can leave an old START_FILE already queued behind the controller lock. Accepted
        // replacement retired that entry's mapping, so ignore it instead of clearing the new request's
        // provisional active token. Callbacks remain closed until the registered new entry starts.
        guard let token = requestedTokens[entryID] else { return }
        activeEntryID = entryID
        activeToken = token
        fileLoaded = false
    }

    mutating func markFileLoaded() {
        fileLoaded = activeToken != nil
    }

    mutating func propagateRedirect(from entryID: Int64, firstInsertedID: Int64, count: Int) {
        guard let token = requestedTokens[entryID], firstInsertedID > 0, count > 0 else { return }
        for offset in 0..<count { requestedTokens[firstInsertedID + Int64(offset)] = token }
    }

    func callbackToken(requiresLoadedFile: Bool = false) -> PlayerLoadToken? {
        guard activeEntryID != nil else { return nil }
        guard !requiresLoadedFile || fileLoaded else { return nil }
        return activeToken
    }

    func token(forEntryID entryID: Int64) -> PlayerLoadToken? {
        requestedTokens[entryID]
    }

    static func accepts(callbackToken: PlayerLoadToken?, activeToken: PlayerLoadToken?) -> Bool {
        guard let callbackToken, let activeToken else { return false }
        return callbackToken == activeToken
    }

    /// AVPlayer callbacks must prove both halves of their provenance: the token belongs to the current
    /// logical request and the observer's captured item is still the item mounted by the player.
    static func acceptsAVCallback(callbackToken: PlayerLoadToken?, activeToken: PlayerLoadToken?,
                                  capturedItemIsCurrent: Bool) -> Bool {
        capturedItemIsCurrent && accepts(callbackToken: callbackToken, activeToken: activeToken)
    }

    static func canCommit(callbackToken: PlayerLoadToken?, activeToken: PlayerLoadToken?,
                          pendingToken: PlayerLoadToken?) -> Bool {
        accepts(callbackToken: callbackToken, activeToken: activeToken)
            && callbackToken == pendingToken
    }
}

/// Small, pure identity decisions shared by the engine bridge, episode play paths, and native-debrid
/// file selection. Keeping these decisions together prevents one surface from treating a torrent as
/// hash-only while another treats `(infoHash,fileIdx)` as the actual media identity.
enum EpisodePlaybackIdentity {
    enum TerminalEventRoute: Equatable {
        case committed
        case pending
        case superseded
        case outgoingCommittedWhileResolving
        case stale
    }

    enum TerminalEventKind: Equatable {
        case error
        case eof
    }

    enum TerminalEventAction: Equatable {
        case handleCommitted
        case handlePending
        case markSupersededTerminal
        case persistOutgoingCompletionOnly
        case ignoreOutgoingError
        case ignoreStale
    }

    enum EngineBindingSource: Equatable {
        case original
        case resolvedDirectURL(String)
    }

    struct FileCandidate: Equatable {
        let offset: Int
        let name: String
        let size: Int64
        let isVideo: Bool
    }

    struct EpisodeNumbers: Equatable {
        let season: Int
        let episode: Int
    }

    static func provenEpisodeNumbers(season: Int?, episode: Int?) -> EpisodeNumbers? {
        guard let season, season >= 0, let episode, episode > 0 else { return nil }
        return EpisodeNumbers(season: season, episode: episode)
    }

    /// Conservative beta fence for title lifecycle and state semantics. Only canonical `series` metadata
    /// may use episode-scoped resume, watched, navigation, terminal, scrobble, and download behavior. Broad
    /// physical-media safety remains in `isEpisodicContext`. INS-260720-03 dissolves this fence after catalog
    /// identities are normalized end to end.
    static func usesSeriesLifecycle(type: String?) -> Bool {
        type?.caseInsensitiveCompare("series") == .orderedSame
    }

    /// A provider-array fallback may use movie heuristics only for a known movie. Episode retries need an
    /// independent semantic selector because the raw torrent fileIdx is not a provider-array position.
    static func providerArrayFallbackAllowed(requiresSemanticSelection: Bool,
                                             season: Int?, episode: Int?,
                                             sourceFilename: String? = nil) -> Bool {
        guard requiresSemanticSelection else { return true }
        if provenEpisodeNumbers(season: season, episode: episode) != nil { return true }
        guard let sourceFilename else { return false }
        return !sourceFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Identify episode-like playback from durable media identity, not only the metadata type. Collection
    /// and franchise pages can retain their non-series type while carrying S/E fields. The canonical id:S:E
    /// suffix is independent evidence when those fields are unavailable. A different video id alone is not
    /// enough because some movies use a distinct default video id and retain hash-only movie compatibility.
    static func isEpisodicContext(type: String?, season: Int?, episode: Int?,
                                  videoID: String) -> Bool {
        if type?.caseInsensitiveCompare("series") == .orderedSame { return true }
        if let season, season >= 0, let episode, episode > 0 { return true }
        let parts = videoID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let season = Int(parts[parts.count - 2]), season >= 0,
              let episode = Int(parts[parts.count - 1]), episode > 0 else { return false }
        return true
    }

    /// A saved title-level resume belongs to the requested episode only when their exact video ids match.
    /// Movies retain title-level resume compatibility, even when their default video id differs from the
    /// library id.
    static func savedResumeTargetsDifferentEpisode(usesSeriesLifecycle: Bool, savedVideoID: String?,
                                                    requestedVideoID: String) -> Bool {
        usesSeriesLifecycle && savedVideoID.map { $0 != requestedVideoID } == true
    }

    /// Whole-title rewind is safe for a movie. Episodic playback requires a resident episode list and the
    /// current episode must be the proven final entry, so a missing list or mid-season close cannot erase the
    /// title resume position.
    static func canRewindWholeTitleAtTerminal(usesSeriesLifecycle: Bool,
                                              currentEpisodeIndex: Int?, episodeCount: Int) -> Bool {
        guard usesSeriesLifecycle else { return true }
        guard episodeCount > 0,
              let currentEpisodeIndex,
              episodesContains(index: currentEpisodeIndex, count: episodeCount) else { return false }
        return currentEpisodeIndex == episodeCount - 1
    }

    private static func episodesContains(index: Int, count: Int) -> Bool {
        index >= 0 && index < count
    }

    /// Accept an async media result only while both its request generation and target identity remain
    /// current. Cancellation is advisory, so callers also run this check after every awaited provider call.
    static func asyncMediaResultIsCurrent(capturedGeneration: Int, currentGeneration: Int,
                                          capturedVideoID: String?, currentVideoID: String?) -> Bool {
        capturedGeneration == currentGeneration && capturedVideoID == currentVideoID
    }

    /// Route a terminal callback by exact physical-load identity. A newer target can be resolving while an
    /// older issued target is still the active file, so `switchingEpisode` or `pending.issued` alone cannot
    /// distinguish the published outgoing file from that superseded physical load.
    static func terminalEventRoute(callbackToken: PlayerLoadToken?, activeToken: PlayerLoadToken?,
                                   committedToken: PlayerLoadToken?,
                                   pendingToken: PlayerLoadToken?, pendingIssued: Bool,
                                   supersededToken: PlayerLoadToken? = nil,
                                   supersededIssued: Bool = false,
                                   switchingEpisode: Bool) -> TerminalEventRoute {
        guard PlayerLoadProvenanceState.accepts(
            callbackToken: callbackToken, activeToken: activeToken
        ), let callbackToken else { return .stale }
        if pendingIssued, callbackToken == pendingToken { return .pending }
        if supersededIssued, callbackToken == supersededToken { return .superseded }
        if switchingEpisode, !pendingIssued {
            return callbackToken == committedToken ? .outgoingCommittedWhileResolving : .stale
        }
        if committedToken == nil || callbackToken == committedToken { return .committed }
        return .stale
    }

    /// Shared option-C policy used by both player surfaces. An outgoing committed EOF may persist that exact
    /// completion but cannot advance or exit while the requested target is resolving. Its error is ignored.
    static func terminalEventAction(route: TerminalEventRoute,
                                    kind: TerminalEventKind) -> TerminalEventAction {
        switch route {
        case .committed:
            return .handleCommitted
        case .pending:
            return .handlePending
        case .superseded:
            return .markSupersededTerminal
        case .outgoingCommittedWhileResolving:
            return kind == .eof ? .persistOutgoingCompletionOnly : .ignoreOutgoingError
        case .stale:
            return .ignoreStale
        }
    }

    /// A raw NZB URL is a descriptor, not playable media. Keep `CoreStream.playableURL` available for row
    /// eligibility, but episodic playback and download selection must require a resolved direct URL.
    static func resolvedEpisodeMediaURL(isUsenet: Bool, resolvedURL: URL?, fallbackURL: URL?) -> URL? {
        if isUsenet { return resolvedURL }
        return resolvedURL ?? fallbackURL
    }

    /// Torrent identity is the complete pair. A season pack can reuse one hash for every episode, so a
    /// hash-only match is never enough to recover the selected raw stream from engine state.
    static func torrentMatches(rawInfoHash: String?, rawFileIdx: Int?,
                               selectedInfoHash: String?, selectedFileIdx: Int?,
                               isEpisode: Bool = true) -> Bool {
        guard let rawInfoHash, let selectedInfoHash,
              rawInfoHash.caseInsensitiveCompare(selectedInfoHash) == .orderedSame else { return false }
        if !isEpisode, rawFileIdx == nil, selectedFileIdx == nil { return true }
        guard
              let rawFileIdx, rawFileIdx >= 0,
              let selectedFileIdx, selectedFileIdx >= 0 else { return false }
        return rawFileIdx == selectedFileIdx
    }

    /// Movies preserve the embedded server's legacy file-zero fallback. An episode must carry a selector:
    /// silently turning a hash-only season-pack row into `/hash/0` can play a different episode.
    static func playableTorrentFileIndex(fileIdx: Int?, isEpisode: Bool) -> Int? {
        if let fileIdx { return fileIdx >= 0 ? fileIdx : nil }
        return isEpisode ? nil : 0
    }

    /// Pick the stream shape for an explicit episode engine load. Direct streams remain unchanged even when
    /// they also carry provenance fields. A raw hash-only torrent can bind only through the concrete direct
    /// URL that native debrid actually resolved; no provider-local file offset is treated as a torrent index.
    static func engineBindingSource(isRawTorrent: Bool, fileIdx: Int?, resolvedURL: String?)
        -> EngineBindingSource? {
        if let resolvedURL, !resolvedURL.isEmpty { return .resolvedDirectURL(resolvedURL) }
        guard isRawTorrent else { return .original }
        return playableTorrentFileIndex(fileIdx: fileIdx, isEpisode: true).map { _ in .original }
    }

    /// A caller records an engine request identity only after CoreBridge confirms that it dispatched a valid
    /// binding. Failed bindings return nil, keeping every progress/watched gate closed.
    static func boundVideoID(requestedVideoID: String, bindingSucceeded: Bool) -> String? {
        bindingSucceeded ? requestedVideoID : nil
    }

    /// Engine progress/watched writes are safe only when the Player's successfully bound request names the
    /// same video as the media identity currently published by the native player.
    static func engineWritesAllowed(boundVideoID: String?, displayedVideoID: String?) -> Bool {
        guard let boundVideoID, let displayedVideoID else { return false }
        return boundVideoID == displayedVideoID
    }

    /// A different episode must issue different media. Treating the outgoing URL as a successful advance
    /// would publish and scrobble the target while the previous episode keeps rendering.
    static func canIssueEpisodeSwitch(currentVideoID: String?, targetVideoID: String,
                                      currentURL: URL?, targetURL: URL) -> Bool {
        guard currentVideoID != targetVideoID else { return false }
        return currentURL != targetURL
    }

    /// Choose a file from a provider-returned array. A raw torrent's `fileIdx` is deliberately absent here:
    /// provider order and ids are independent from torrent-metainfo order. Semantic identity wins, followed
    /// by an exact normalized source path/name when available, then a sole effective file; ambiguity closes.
    static func pickFileOffset(_ files: [FileCandidate], season: Int?, episode: Int?,
                               sourceFilename: String? = nil) -> Int? {
        let videos = files.filter(\.isVideo)
        let pool = videos.isEmpty ? files : videos
        if let numbers = provenEpisodeNumbers(season: season, episode: episode) {
            let scored = pool.map { candidate in
                (candidate, episodeMatchScore(
                    filename: candidate.name, season: numbers.season, episode: numbers.episode
                ))
            }
            let matches = scored.filter { $0.1 > 0 }
            if matches.count == 1 { return matches[0].0.offset }
        }
        let semanticFilename = sourceFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let semanticFilename, !semanticFilename.isEmpty {
            let source = normalizedFileIdentity(semanticFilename)
            let exactPath = pool.filter { normalizedFileIdentity($0.name).path == source.path }
            if exactPath.count == 1 { return exactPath[0].offset }
            let exactName = pool.filter { normalizedFileIdentity($0.name).name == source.name }
            if exactName.count == 1 { return exactName[0].offset }
        }
        let attemptedSemanticSelection = season != nil || episode != nil || semanticFilename?.isEmpty == false
        if !attemptedSemanticSelection {
            return pool.max(by: { $0.size < $1.size })?.offset
        }
        return pool.count == 1 ? pool[0].offset : nil
    }

    private static func normalizedFileIdentity(_ raw: String) -> (path: String, name: String) {
        let decoded = raw.removingPercentEncoding ?? raw
        let slashPath = decoded.replacingOccurrences(of: "\\", with: "/")
        let parts = slashPath.split(separator: "/").map(String.init).filter { $0 != "." }
        let path = parts.joined(separator: "/").lowercased()
        return (path, parts.last?.lowercased() ?? "")
    }

    private static func episodeMatchScore(filename: String, season: Int, episode: Int) -> Int {
        let lower = filename.lowercased()
        let sxe = "(?<![0-9])s0*\(season)e0*\(episode)(?![0-9])"
        if lower.range(of: sxe, options: .regularExpression) != nil { return 3 }
        let oneX = "(?<![0-9])\(season)x0*\(episode)(?![0-9])"
        if lower.range(of: oneX, options: .regularExpression) != nil { return 2 }
        let words = "(?<![0-9])season[ ._-]+0*\(season)[ ._-]+episode[ ._-]+0*\(episode)(?![0-9])"
        if lower.range(of: words, options: .regularExpression) != nil { return 1 }
        return 0
    }
}

/// A playable stream. `StreamSource` is `#[serde(untagged)]` + flattened, so the source fields
/// (url / ytId / infoHash / externalUrl) sit at the top level, decode them all optionally.
struct CoreStream: Decodable, Identifiable, Equatable {
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

    /// VortX provenance marker: the server UUID string on a synthetic MEDIA-SERVER stream (Plex/Jellyfin/Emby),
    /// nil on every engine-decoded stream. This is the STRUCTURAL, text-independent classification hook the
    /// ranker keys on (a media-server stream ranks in its own tier, is exempt from the instant-only filter, and
    /// gets the honest direct-play error). Optional, so the synthesized `Decodable` uses `decodeIfPresent` and
    /// engine JSON WITHOUT the key decodes byte-identically; set only by `MediaServerSource`'s synthetic mapping.
    let vortxProvider: String?

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
    var playableURL: URL? { playableURL(isEpisode: false) }

    /// Episode-aware playable URL. Direct, usenet, and YouTube sources keep their existing behavior. Raw
    /// episode torrents require an explicit file selector so a season-pack hash can never default to file 0.
    func playableURL(isEpisode: Bool) -> URL? {
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
        guard let selectedFileIndex = EpisodePlaybackIdentity.playableTorrentFileIndex(
            fileIdx: fileIdx, isEpisode: isEpisode
        ) else { return nil }
        return URL(string: "\(StremioServer.base)/\(hash)/\(selectedFileIndex)")
    }

    /// The bare YouTube id of an `isYouTubeTrailer` source-list stream (a trailer add-on's `{ "ytId": "…" }`
    /// row), or nil for any other stream. Lets the trailer-tap paths resolve such a row the SAME reliable
    /// way as the built-in Trailer chip (device-direct InnerTube first, worker `/yt` fallback) instead of
    /// only the plain worker URL in `playableURL`.
    var youTubeTrailerID: String? {
        guard isYouTubeTrailer, let ytId, !ytId.isEmpty else { return nil }
        return ytId
    }

    /// Language-aware worker fallback URL for an `isYouTubeTrailer` stream: `trailer.vortx.tv/yt/{id}` with a
    /// `?lang=` hint so the worker's own fallback chain (user-lang -> en -> original) returns the user's dub
    /// (e.g. Italian). This differs from `playableURL`, which appends no language. Used only after the
    /// device-direct resolver misses; nil for any non-trailer stream. Mirrors `TrailerRequest`'s worker shape.
    func youTubeTrailerWorkerURL(languageCode: String?) -> URL? {
        guard let yt = youTubeTrailerID else { return nil }
        var c = URLComponents(string: "\(StremioServer.trailerResolverBase)/yt/\(yt)")
        if let lang = languageCode, !lang.isEmpty { c?.queryItems = [URLQueryItem(name: "lang", value: lang)] }
        return c?.url
    }

    /// HTTP request headers the add-on declares this stream NEEDS (behaviorHints.proxyHeaders):
    /// some add-ons front CDNs that reject requests without a specific Referer or browser
    /// User-Agent. Official clients apply these; the player must too or the stream 403s.
    var requestHeaders: [String: String]? {
        guard let headers = behaviorHints?.proxyHeaders?.request, !headers.isEmpty else { return nil }
        return headers
    }
}

struct CoreStreamBehaviorHints: Decodable, Equatable {
    let notWebReady: Bool?
    let bingeGroup: String?
    let filename: String?
    let proxyHeaders: CoreProxyHeaders?
}

/// `behaviorHints.proxyHeaders`: per-stream HTTP headers, `request` applied on the way out.
struct CoreProxyHeaders: Decodable, Equatable {
    let request: [String: String]?
}

/// Streams grouped by source addon, for the per-addon filter + source labels.
struct CoreStreamSourceGroup: Identifiable, Equatable {
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
