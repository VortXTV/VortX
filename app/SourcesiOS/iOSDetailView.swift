import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Torrents: ask the embedded server to start fetching peers before playback. No-op for direct/debrid
/// URLs (those carry a `url`, so no `/create` is needed). Port of the tvOS `prepareTorrent`, reusing
/// the shared `TorrentTrackers.sources` so the create carries the TCP/TLS trackers that reach a swarm
/// from a sandboxed app. Free function so the movie list, the per-episode list, and the batch-download
/// coordinator (#119) share one implementation. Returns the retry Task (or nil for a non-torrent /
/// disabled prime) so the caller can store and cancel it; the backoff loop outlives the view
/// otherwise, leaking on every pick. (The loop also self-terminates after ~15s of backoff, which is
/// what fire-and-forget callers rely on.)
@discardableResult
func prepareTorrentStream(_ stream: CoreStream) -> Task<Void, Never>? {
    guard !PlaybackSettings.torrentsDisabled else { return nil }
    guard stream.url == nil, let hash = stream.infoHash?.lowercased(),
          let url = URL(string: "\(StremioServer.base)/\(hash)/create") else { return nil }
    let sources = TorrentTrackers.sources(forHash: hash, streamSources: stream.sources)
    let body: [String: Any] = ["torrent": ["infoHash": hash],
                               "peerSearch": ["sources": sources, "min": 40, "max": 150]]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    request.timeoutInterval = 5
    // Retry the prime a few times: the embedded server can still be cold-starting (notably the macOS
    // child `node` process), and a single fire-and-forget POST sent before it's listening is silently
    // dropped — leaving the torrent un-primed and the player hanging on a peerless swarm. A round-trip
    // that doesn't throw means the server received the create; connection-refused retries with backoff.
    // The Task is returned so the owning view can cancel it on disappear / new selection.
    return Task {
        for attempt in 0..<5 {
            if Task.isCancelled { return }
            if (try? await URLSession.shared.data(for: request)) != nil { return }
            try? await Task.sleep(for: .seconds(Double(attempt + 1)))   // 1s,2s,3s,4s backoff over cold-start
        }
    }
}

/// One add-on's streams for a series episode, fetched straight over the Stremio add-on protocol so the
/// F6 warm-up never touches the engine's single meta slot (which would evict the playing episode). Mirrors
/// the tvOS preload's fetchStreams. nil on any failure or an empty answer, so a dead add-on is skipped.
private func warmFetchEpisodeStreams(base: String, addon: String, id: String) async -> CoreStreamSourceGroup? {
    let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    guard let url = URL(string: "\(base)/stream/series/\(escaped).json") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    struct Response: Decodable { let streams: [CoreStream]? }
    guard let (data, _) = try? await URLSession.shared.data(for: request),
          let response = try? JSONDecoder().decode(Response.self, from: data),
          let streams = response.streams, !streams.isEmpty else { return nil }
    return CoreStreamSourceGroup(id: base, addon: addon, streams: streams)
}

/// Direct-links-only filter (drop torrent sources) — the free twin of the per-view displayGroups,
/// shared by the Continue-Watching resume so it ranks the same set the detail page would.
func iOSDisplayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
    guard PlaybackSettings.directLinksOnly else { return groups }
    return groups.compactMap { group in
        let streams = group.streams.filter { !$0.isTorrent }
        guard !streams.isEmpty else { return nil }
        return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
    }
}

func iOSEngineAddonBase(for stream: CoreStream,
                        in groups: [CoreStreamSourceGroup]) -> String? {
    guard let id = groups.first(where: { $0.streams.contains(stream) })?.id,
          URL(string: id)?.scheme != nil else { return nil }
    return id
}

/// Resolve a series episode (by video id) to a ready-to-play stream: load its streams, filter
/// direct-links, rank (quality continuity), prime the torrent, and compute the resume offset. The
/// Continue-Watching resume hands this to PlayerScreen as its loadEpisode closure so a CW resume gets
/// the same in-player Next / Prev / episode-list switching the detail page has. @MainActor: touches CoreBridge.
@MainActor
func iOSResolveEpisodeStream(videoId: String, in videos: [CoreVideo], seriesId: String,
                             seriesName: String, defaultSeason: Int, fallbackPoster: String?,
                             continuity: String?, binge: String? = nil, cachedHashes: Set<String> = [],
                             core: CoreBridge,
                             account: StremioAccount) async -> PlayerEpisodeStream? {
    guard let v = videos.first(where: { $0.id == videoId }) else { return nil }
    core.loadMeta(type: "series", id: seriesId, streamType: "series", streamId: v.id)
    var groups: [CoreStreamSourceGroup] = []
    var firstPlayableAt: Date? = nil
    for _ in 0 ..< 80 {                                // ~20s ceiling, matching the episode page
        groups = iOSDisplayGroups(core.streamGroups(forStreamId: v.id))
        if !groups.isEmpty, firstPlayableAt == nil { firstPlayableAt = Date() }
        // Settle gate (see StreamRanking.resolveSettled): for a resume, hold out until the SAME quality the
        // user last played has loaded (and, unless they rank torrents on top, a non-torrent one), because
        // torrents answer in ~4s while the user's debrid of that quality lands ~10-12s later — a flat 4s
        // cutoff auto-picked the fast torrent, so the CW resume "tried a torrent first".
        let progress = core.streamLoadProgress(forStreamId: v.id)
        let elapsed = firstPlayableAt.map { Date().timeIntervalSince($0) } ?? 0
        if StreamRanking.resolveSettled(groups, loaded: progress.loaded, total: progress.total,
                                        secondsSinceFirstPlayable: elapsed, rememberedQuality: continuity) { break }
        try? await Task.sleep(for: .milliseconds(250))
    }
    let pin = SourcePinStore.shared.effectivePin(SourcePinContext(metaId: seriesId, isSeries: true))
    guard let best = StreamRanking.best(groups, continuity: continuity, binge: binge, pin: pin,
                                        debridCachedHashes: cachedHashes) else { return nil }
    let targetSeason = v.season ?? defaultSeason
    // PRESENCE, not truthiness: `episodeNumber` is the DISPLAY helper (`episode ?? 0`), so using it here
    // made an unresolved episode indistinguishable from an explicit E0 special, and the `> 0` test then
    // dropped both. Read the optional directly and accept episode ZERO.
    let targetEpisode = v.episode
    let episodeHint = targetSeason >= 0 && (targetEpisode ?? -1) >= 0
        ? DebridEpisode(season: targetSeason, episode: targetEpisode ?? 0) : nil
    let ref: DebridPlaybackRef?
    if best.url == nil, episodeHint == nil {
        ref = nil
    } else {
        ref = await DebridCoordinator.shared.resolvedPlaybackRef(
            for: best, episode: episodeHint,
            confirmedCachedHashes: cachedHashes.isEmpty ? nil : cachedHashes
        )
    }
    guard let url = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
        isUsenet: best.isUsenet, resolvedURL: ref?.url,
        fallbackURL: best.playableURL(isEpisode: true)
    ) else { return nil }
    if ref == nil { _ = prepareTorrentStream(best) }   // fire-and-forget prime; self-terminating backoff
    let pm = PlaybackMeta(libraryId: seriesId, videoId: v.id, type: "series",
                          name: seriesName, poster: v.thumbnail ?? fallbackPoster,
                          season: v.season, episode: v.episode)
    let title = "\(seriesName)  ·  S\(v.season ?? defaultSeason)E\(v.episodeNumber)"
    let resume: Double
    if let engine = core.engineResumeSeconds(for: pm) { resume = engine }
    else { resume = await account.resumeOffset(for: pm) }
    return PlayerEpisodeStream(
        stream: best, url: url, meta: pm, title: title, resume: resume,
        debridRef: ref, engineAddonBase: iOSEngineAddonBase(for: best, in: groups)
    )
}

/// A left-to-right layout that wraps onto a new line when a row runs out of width. The hero action rows
/// use it so a chip that doesn't fit the (now hard-width-capped) hero moves to the next line, instead of
/// being compressed into a vertical sliver ("Tr / ail / er"). Each child is measured and placed at its
/// natural size, so labels never wrap. iOS 16+ Layout protocol (the deployment target).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width - bounds.minX > maxWidth { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}

/// Touch / Mac detail page. Loads meta through the shared engine, then presents the same cinematic
/// composition the tvOS `DetailView` uses — a full-bleed backdrop from `meta.background` with a dark
/// gradient scrim, the hero (logo or title, year · runtime · genres · rating, synopsis) over it, a
/// Play / Watch action, and the source list styled as surface cards. Series show a season selector and
/// an episode list; tapping an episode pushes its own per-episode source-list screen (`iOSEpisodeStreams`)
/// with the full ranked sources + Quality picker, mirroring the tvOS `CoreEpisodeStreams` flow.
///
/// The PRESENTATION mirrors tvOS, and playback is now primed like tvOS too: before launching the
/// player, every play path wires the engine Player and (for torrents) creates the torrent on the
/// embedded server, and carries the stream's `requestHeaders` through to the player. tvOS-only
/// SwiftUI API is gated with `#if os(tvOS)`; this compiles on iOS 16 and
/// macOS.
struct iOSDetailView: View {
    let id: String
    let type: String
    let title: String
    /// Seed art carried from the hub card that pushed this detail, so the hero never blanks while
    /// (or if) Cinemeta meta is nil. A brand-new/unreleased title (`tt` at TMDB but not yet in Cinemeta)
    /// loads with meta=nil, which used to leave the hero empty; threading the card's already-resolved
    /// backdrop/logo (catalog background, else metahub-by-tt, else poster) keeps it populated. Defaults
    /// to nil so the existing non-hub call sites (search / live / similar) keep compiling unchanged.
    var seedBackdrop: String? = nil
    var seedLogo: String? = nil
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @EnvironmentObject private var profiles: ProfileStore   // per-profile watched set + episode progress
    @ObservedObject private var pinStore = SourcePinStore.shared   // pinned source floats to top + badges/menu (#15)
    @ObservedObject private var l10n = LocalizedMetadataStore.shared   // localized detail title/logo override
    /// Observed so the episode ticks repaint when an async Trakt shadow pull lands while this page is open.
    /// The Trakt episode mirror is read synchronously from a non-observable cache, so without this the page
    /// would show the pre-pull state until some unrelated event happened to re-evaluate it. WatchedIndex
    /// republishes nothing when the set is unchanged and never rebuilds during playback, so this costs
    /// nothing in the steady state.
    @ObservedObject private var watchedIndex = WatchedIndex.shared
    // #44: the in-hero auto-play trailer is skipped when the user prefers reduced motion (the hero then
    // stays a still backdrop). Read here so the hero composition can gate the clip overlay.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Circular in-hero back chevron dismisses this pushed detail (the cinematic-media chrome, in place of
    // the plain system nav-bar back on iOS). On Mac the existing .macBackAffordance() still supplies Esc / Cmd-[.
    @Environment(\.dismiss) private var dismiss

    /// The pin context for this title - a movie pin or a show pin, both keyed by the meta id. The
    /// resolved pin feeds `StreamRanking` (auto-pick + list order) and the per-row pin menu/badge.
    /// The AUTHORITATIVE type for the STREAM request + the series/movie render branch: the loaded meta's type
    /// once resident, else the incoming `type`. The Collections/Trending HUB passes a TMDB /movie-vs-/tv GUESS
    /// as `type` (TMDBClient), which for TV-movies / mini-series / anime disagrees with the type stream add-ons
    /// index the title under - so a type-scoped stream request matched no add-on ("No sources found" from the
    /// hub, while the same title worked from an add-on catalog whose card carries the engine's authoritative
    /// type). Keying off meta.type fixes both directions; the fallback to `type` keeps behavior unchanged until
    /// meta loads (verified cause: 3-agent settle 2026-07-01).
    private var effectiveType: String {
        if let t = meta?.type, !t.isEmpty { return t }
        return type
    }

    private var pinContext: SourcePinContext { SourcePinContext(metaId: id, isSeries: effectiveType == "series") }

    /// True for series AND for a COLLECTION/franchise meta: a non-series meta that carries MULTIPLE entries
    /// as videos[] (e.g. TVDB collections via AIOmetadata). >1 video distinguishes it from a normal movie
    /// (which has 0-1). Render those as an episodic list so the entries show, instead of trying to stream the
    /// collection id itself (which has no sources -> the "one entry, can't find sources" report, #102).
    /// Live/EPG schedules are excluded (they use videos[] as a now/next schedule, not a playable list).
    private var isEpisodic: Bool {
        if effectiveType == "series" { return true }
        if let vids = meta?.videos, vids.count > 1, meta?.behaviorHints?.hasScheduledVideos != true { return true }
        return false
    }
    private var sourcePin: ResolvedPin? { pinStore.effectivePin(pinContext) }
    @AppStorage("stremiox.autoplayTrailers") private var autoplayTrailers = true
    @AppStorage("vortx.spoilerBlur") private var spoilerBlur = true   // blur unwatched episode thumbnails to avoid spoilers
    // Spoiler-safe mode (SourcePreferences.spoilerSafeKey): veil an UNWATCHED episode's art + synopsis on the
    // episode list until the viewer reveals it. Observed via @AppStorage on the same flat key SourcePreferences
    // persists, so a later Settings toggle redraws this view. `revealedEpisodeIds` is a session-only reveal set
    // (read-only against the watch state, never a watch write), so revealing an episode never marks it watched.
    @AppStorage("vortx.detail.spoilerSafe") private var spoilerSafe = true
    @State private var revealedEpisodeIds: Set<String> = []

    // A SINGLE presentation slot drives every full-screen cover (player OR trailer). On macOS the
    // `platformFullScreenPlayerCover(item:)` calls become a `.sheet(item:)`, and two sheets attached to
    // the same view shadow each other — so tapping Watch could fail to present the player at all.
    // Driving both from one enum-typed item guarantees exactly one cover is ever attached, so Watch
    // always presents reliably. The player-cover variant sizes its content to fill the macOS window.
    @State private var presentation: Presentation?
    @State private var preparing = false                 // movie Watch Now is resolving
    @State private var downloadPicker: DownloadPickerRequest?   // pre-download quality picker payload (#30 follow-up)
    /// Owns the source-list assembly + ranking OFF the SwiftUI render path (snapshot -> merge -> rank
    /// off-main -> publish once, coalesced at ~250 ms). The body reads only its published output, so a
    /// CoreBridge revision storm during source search no longer rebuilds a 1000+ stream list per body
    /// eval (the Mac force-quit / dead-keyboard root cause). Serves BOTH the movie and the live page
    /// (a screen is one or the other; rankedGroups ignores continuity, so the group order is shared).
    @StateObject private var sourceList = SourceListModel()
    @State private var season = 1
    @State private var didApplySeason = false   // once the initial-season hint lands (or the user taps a season), stop re-applying it
    @State private var settleTimedOut = false            // movie/live resolution gave up → "No sources found", not a spinner
    @State private var sourceRefreshDebounce: Task<Void, Never>? = nil
    private static let sourceRefreshDebounceMs = 400     // trailing settle for the movie/live add-on load storm
    // Debrid cache AWARENESS for the movie/live source list: which raw torrents the user's debrid account
    // has cached, so they badge + rank up. Empty (zero badges, ranking unchanged) with no debrid key.
    @StateObject private var debridCache = DebridCacheAwareness()
    // TorBox search-as-a-source (gated on a TorBox key): extra usenet + torrent sources from the public
    // TorBox search index, merged into the list. Empty (list unchanged) with no TorBox key.
    @StateObject private var torboxSearch = TorBoxSearchSource()
    // Community source index ("Singularity"): the SERVE half. Merges corroborated pooled sources when the
    // per-profile Singularity toggle is ON and the user is signed in (empty otherwise). The HOARD half is a
    // fire-and-forget contribution keyed off the same assembled groups; both are gated + fail-soft inside
    // `SourceIndexClient`, so the source list is unchanged unless the user opted in.
    @StateObject private var sourceIndex = SourceIndexServeSource()
    // Media servers (Plex/Jellyfin/Emby): resolves this movie on the user's connected servers and merges the
    // direct-play hits as their own tier. Empty (list unchanged) with no server connected (dormant).
    @StateObject private var mediaServers = MediaServerSource()
    #if !os(tvOS)
    @ObservedObject private var downloads = DownloadStore.shared   // offline-download state for the hero "Download" affordance (#30)
    // Batch episode downloads (#119): the coordinator publishes the walk's status/summary; the two
    // selection vars drive the episode multi-select mode (chosen over a from/to range sheet because it
    // reuses the existing chip + row idiom, covers arbitrary picks AND ranges, and "whole season" is one
    // tap via Download Season / Select Season). Selection survives a season-chip switch on purpose, so a
    // pick can span seasons.
    @ObservedObject private var batch = BatchDownloadCoordinator.shared
    @State private var selectingEpisodes = false
    @State private var selectedEpisodeIds: Set<String> = []
    #endif
    @State private var torrentPrime: Task<Void, Never>?  // outstanding torrent /create retry loop, cancelled on disappear / new pick
    @State private var similarItems: [MetaPreview] = []
    /// Franchise/collection this movie belongs to (TMDB belongs_to_collection -> parts, in release order),
    /// rendered as the "Part of the … Collection" rail. Nil for a standalone film / series / any miss, which
    /// hides the row. `collectionKey` de-dupes the fetch per imdb id.
    @State private var collection: TMDBClient.CollectionResult?
    @State private var collectionKey: String?
    /// Cast & Crew disclosure: the full cast rail shows by default (#10, owner wants who-played-who with
    /// photos visible); the "Cast & Crew" button can still fold it away to declutter, animating
    /// transform/opacity only.
    @State private var castExpanded = true
    @State private var mdbRatings: MDBListRatings?
    /// Full cast with who-played-who + headshots (TMDB credits via the keyless edge), rendered as the
    /// horizontally scrollable cast rail. The meta's plain name list is the fallback so the rail never
    /// blanks without TMDB. `creditsKey` de-dupes the fetch per imdb id.
    @State private var castMembers: [TMDBClient.CastMember] = []
    @State private var creditsKey: String?
    /// TMDB's overview for this title, used when the engine meta carries no description (a hub-seeded
    /// tt id not yet in Cinemeta loads meta=nil, which used to leave the synopsis empty).
    @State private var fallbackOverview: String?
    @State private var watchAvail: TMDBClient.WatchAvailability?
    @State private var financials: TMDBClient.Financials?
    @State private var releaseDates: TMDBClient.ReleaseDates?   // theatrical + digital, TMDB-fetched (movies only)
    @AppStorage("vortx.detail.showFinancials") private var showFinancials = true   // budget + box office on movie detail (movies only, needs a TMDB key)
    /// #37: a trailer id fetched from Cinemeta when the engine's detail meta carries none. Some catalog
    /// add-ons (e.g. a TMDB catalog) return a meta WITHOUT trailerStreams, so the in-hero trailer never
    /// mounted on the detail page even though the Home hero (which enriches via Cinemeta) had one. This
    /// is the detail page's own fallback, used only when `meta.trailerYouTubeID` is nil.
    @State private var resolvedTrailerID: String?
    /// The user-language-PREFERRED YouTube trailer id from TMDB /videos, when one resolves. Used for the
    /// WITH-SOUND "watch trailer" action so a viewer whose preferred language is e.g. Portuguese gets the
    /// Portuguese trailer instead of the default (usually English) one. Resolved fail-soft and only when a
    /// TMDB key / edge is reachable; nil keeps today's default trailer, so there is never a regression.
    /// tvOS does not read this (no web view) but the seam is populated the same way there for a later VPS
    /// resolve; see `resolvePreferredTrailerIfNeeded`.
    @State private var resolvedPreferredTrailerID: String?
    /// A6: transient "trailer is preparing" notice for the rare both-paths-out case (no full YouTube trailer
    /// AND no /clip): a small auto-dismissing capsule over the hero, never the full source-error screen.
    @State private var trailerNotice = false
    @State private var trailerNoticeTask: Task<Void, Never>?
    /// Dynamic dominant-color backdrop: the page art's average color (PosterImageLoader.averageColor),
    /// washed into the page background BELOW the hero band so the whole detail page carries the title's
    /// palette instead of flat canvas. nil (no art / not computed) keeps today's canvas exactly.
    @State private var dominantTint: Color?
    /// yt-direct: the detail hero's ambient clip ATTEMPTED device-direct resolve, keyed by the YouTube id it
    /// resolved so a language-pick upgrade re-resolves. `url == nil` = attempted, no direct stream (mount the
    /// /yt worker URL). The clip waits for the attempt so it never remounts mid-loop on a late resolve.
    @State private var detailAmbientDirect: (ytID: String, url: URL?)?

    /// "Also available in" language chips (P1, community-subtitle system): the union of the languages
    /// PARSED from this title's loaded stream names and the crowd-sourced language index, so a user can
    /// tell at a glance whether e.g. a K-drama is available in English before opening a source. Codes only;
    /// gated on `features.languageIndex` and rendered only when non-empty. `langChipsKey` de-dupes the
    /// compute per title/episode set.
    @State private var langChips: [(code: String, label: String)] = []
    @State private var langChipsKey = ""
    @State private var langChipsDebounce: Task<Void, Never>? = nil
    private static let langChipsDebounceMs = 400   // settle window before the off-main name/regex parse, mirrors coalesceMs intent

    /// The one thing presented full-screen at a time: a resolved player stream or the trailer. Both play
    /// IN-APP through the native libmpv player; there is no longer a YouTube web-embed presentation.
    private enum Presentation: Identifiable {
        case player(PlayerLaunch)
        /// The trailer, played in the SAME native mpv player as a stream (`isTrailer: true`). The url is a
        /// direct (non-YouTube) trailer stream, a DEVICE-DIRECT yt stream (yt-direct; `audioSidecar` set
        /// when it is a video-only adaptive pick whose audio rides mpv's --audio-file sidecar), OR the
        /// server's `/yt/{id}` route. recordMeta is nil for these so a trailer never lands in Continue Watching.
        case trailerPlayer(url: URL, title: String, audioSidecar: URL?)
        /// A YouTube trailer played via the keyless IFrame embed (`TrailerEmbedCover`) - the reliable,
        /// official-Stremio-style path, and the one that needs no streaming server (works on Lite too).
        /// iOS/iPad/Mac only (WKWebView); tvOS keeps `/yt` via its own DetailView.
        case trailerEmbed(youTubeID: String, title: String)
        var id: String {
            switch self {
            case .player(let l): "player-\(l.id)"
            case .trailerPlayer(_, let t, _): "trailer-\(t)"
            case .trailerEmbed(let yt, _): "trailerEmbed-\(yt)"
            }
        }
    }

    /// A resolved stream ready to hand to PlayerScreen (Identifiable so the cover can drive it).
    struct PlayerLaunch: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let headers: [String: String]?       // behaviorHints.proxyHeaders, carried through to the player
        let resume: Double
        let meta: PlaybackMeta
        /// Quality signature + torrent flag of the launching stream, recorded into LastStreamStore on
        /// playback start (CW direct-resume + quality-continuity parity with tvOS).
        var qualityText: String? = nil
        /// The launching stream's release group (behaviorHints.bingeGroup), recorded so a CW resume's
        /// prev/next keeps the same release across episodes (binge continuity).
        var bingeGroup: String? = nil
        var isTorrent: Bool = false
        /// When this launch resolved a NATIVE debrid link, the provenance to reresolve a fresh link on a
        /// later Continue-Watching resume (recorded into LastStreamStore on play). nil for torrent/direct.
        var debridRef: DebridPlaybackRef? = nil
        var sourceStream: CoreStream? = nil
        /// Set only after the presenter synchronously dispatches an exact episode engine load.
        var enginePlayerVideoId: String? = nil
        /// True when the user explicitly chose this exact source (a tapped source-list row / quality pick),
        /// false for an auto-pick (Watch Now / Continue-Watching resume). The player honors an explicit
        /// pick on a start-timeout (retry in place) instead of silently hopping to a lower-quality source.
        var wasExplicitPick: Bool = false
    }

    /// A resolved TRAILER row ready to hand to PlayerScreen with `isTrailer: true` (Identifiable so the
    /// cover can drive it). Carries no PlaybackMeta so a trailer never lands in Continue Watching; the
    /// `audioSidecar` is set when a video-only adaptive yt pick rides mpv's --audio-file sidecar. Shared by
    /// the movie source list (via the `Presentation.trailerPlayer` case) and `iOSEpisodeStreams` (#95).
    struct TrailerLaunch: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        var audioSidecar: URL? = nil
    }

    /// #95: resolve a source-list TRAILER row (an `isYouTubeTrailer` `ytId` stream) into a `TrailerLaunch`
    /// the SAME reliable way the built-in Trailer button does: the YouTube id device-direct first (InnerTube
    /// on the user's own IP, adaptive 1080p+ with an audio sidecar), and only on a miss the worker `/yt/{id}`
    /// URL WITH a `?lang=` hint so the worker returns the user's dub. Shared by the movie source list and
    /// `iOSEpisodeStreams` so the resolve logic lives in ONE place; each caller assigns the result to its own
    /// trailer state. Returns nil only when there is no playable trailer URL at all.
    static func resolveTrailerLaunch(for stream: CoreStream, title: String) async -> TrailerLaunch? {
        if let yt = stream.youTubeTrailerID,
           let resolved = await YouTubeDirectResolver.resolve(videoID: yt, maxHeight: 1080) {
            NSLog("[yt-direct] trailer row: %@ h=%d", resolved.isMuxed ? "direct-muxed" : "direct-pair", resolved.height)
            return TrailerLaunch(url: resolved.videoURL, title: title, audioSidecar: resolved.audioURL)
        }
        // Device-direct missed: the worker URL WITH the language hint (the plain `playableURL` appends none).
        guard let url = stream.youTubeTrailerWorkerURL(languageCode: TMDBClient.trailerLanguageBaseCode)
                ?? stream.playableURL else { return nil }
        NSLog("[yt-direct] trailer row: fallback-worker")
        return TrailerLaunch(url: url, title: title, audioSidecar: nil)
    }

    /// The LIVE page's fixed artwork band (the VOD hero scales with the viewport via `heroBandHeight`).
    private var backdropHeight: CGFloat {
        #if os(macOS)
        return 560
        #else
        return 320
        #endif
    }

    /// The cinematic VOD hero band: ~60% of the viewport on iPhone/iPad (a fixed 320 band read as a
    /// ~20% strip on a modern phone) and ~58% of the Mac window, clamped so a short window still shows
    /// the action row without scrolling. Kept a fixed-per-layout (not aspect-ratio) band because the
    /// hero overlays a text block that an aspectRatio would fight on narrow windows.
    private func heroBandHeight(viewport: CGFloat) -> CGFloat {
        #if os(macOS)
        // The Mac detail hero reads near-fullscreen so the page stops looking empty (owner ask): on a TALL
        // window the cinematic banner takes ~72% of the height. But because `macDetailBody` PINS this band
        // (only the region beneath it scrolls, and it is the only way to reach the action row, synopsis,
        // credits and the episode / source list), the band must never eat the whole window. So we always
        // reserve a usable inner-scroll region: cap the band at `viewport - reservedForContent` so at least
        // ~320pt survives below it, even at the app's minimum 600pt window height (StremioXiOSApp.swift:176),
        // where the band shrinks to ~280pt instead of the old immovable 560pt banner that left a ~40pt slot.
        // For any window taller than ~1143pt the 0.72 fraction is the smaller term, so tall windows still
        // read near-fullscreen; the 1000 cap stops an enormous display pushing the banner past that point.
        guard viewport > 0 else { return 620 }
        let reservedForContent: CGFloat = 320
        let band = min(1000, min(viewport * 0.72, viewport - reservedForContent))
        return max(280, band)
        #else
        guard viewport > 0 else { return 420 }
        return max(360, viewport * 0.60)
        #endif
    }

    /// Hero primary-CTA width cap: iPhone stays edge-to-edge (minus margins), iPad caps at 760; the Mac
    /// caps near a comfortable button width so the primary Play doesn't span the whole window (#6).
    private var heroCtaMaxWidth: CGFloat {
        #if os(macOS)
        return 400
        #else
        return 760
        #endif
    }

    var body: some View {
        // A GeometryReader gives us the EXACT viewport width to HARD-cap the content column with
        // `.frame(width:)`. `maxWidth: .infinity` only sets an upper bound — it does not stop a child
        // whose intrinsic width exceeds the screen (the hero's single-line metaRow / action button row on
        // a narrow iPhone) from stretching the ZStack wider than the viewport, which then renders with a
        // negative leading origin and clipped every hero element off the left edge. A concrete width can't
        // be exceeded, so the column (and hero) stay pinned to the screen. macOS was wide enough to never
        // overflow, which is why this only bit iOS.
        GeometryReader { geo in
            ScrollViewReader { proxy in
                #if os(macOS)
                // macOS pinned-hero scroll model: for a VOD / series page, the cinematic banner is a FIXED
                // layer and only the content beneath (action row, synopsis, credits, and the episode / source
                // list) scrolls, as its own independent region. This is a fixed hero LAYER + an inner
                // ScrollView, NEVER a scroll section-header pin (that mechanism triggered the
                // NSToolbar/section-header crash class banned in architecture.md). Live keeps the single
                // scroll (its backdrop is a short fixed band, not a near-fullscreen hero).
                if LiveTypes.contains(type) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.lg) { livePage }
                            .padding(.bottom, Theme.Space.xl)
                            .frame(width: geo.size.width, alignment: .leading)
                    }
                } else {
                    macDetailBody(geo: geo, proxy: proxy)
                }
                #else
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        // Live (tv / channel / events) gets its own stripped-down page BEFORE the movie
                        // fallback: backdrop + name + LIVE badge + the channel's source list, with no VOD
                        // chrome (no trailer chip, no movie synopsis framing, no skip/chapter UI). It still
                        // builds the player launch with the meta `type` preserved so the player's live path
                        // engages (see PlayerScreen + MPVMetalViewController.configureLiveMode).
                        if LiveTypes.contains(type) {
                            livePage
                        } else {
                            // The Sources action in the hero row scrolls to this anchor.
                            hero(width: geo.size.width, height: geo.size.height) { withAnimation { proxy.scrollTo(Self.sourcesAnchor, anchor: .top) } }
                            // #9: on a wide iPad/Mac window keep the hero full-bleed but cap the
                            // source-heavy content to a readable column and center it (long lines hurt
                            // readability). iPhone (and any narrow width) stays full-width as before.
                            Group {
                                if isEpisodic {
                                    episodeList
                                } else {
                                    sourceSection.id(Self.sourcesAnchor)
                                }
                            }
                            .frame(maxWidth: geo.size.width > Theme.Space.wideLayoutMinWidth ? Theme.Space.contentColumn : .infinity)
                            .frame(maxWidth: .infinity)
                            whereToWatchSection
                            collectionSection
                            moreLikeThisSection
                        }
                    }
                    .padding(.bottom, Theme.Space.xl)
                    .frame(width: geo.size.width, alignment: .leading)
                }
                #endif
            }
        }
        // Dynamic dominant-color backdrop: canvas stays the base, with the art's average color washed in
        // BELOW the hero band. Extracted to helpers (dominantColorBackground / tintArtURL / recomputeTint)
        // so the addition costs this huge body's type-checker almost nothing (the b183 gate finding).
        .background(dominantColorBackground)
        // Compute the tint from the SAME art fallback chain the hero backdrop paints, so tint and art
        // always agree; recomputes when meta hydrates (background/poster can arrive after the seed art).
        .task(id: tintArtURL) { await recomputeTint() }
        // A6: the rare "no trailer available right now" notice (no full YouTube trailer AND no /clip). A small
        // capsule, auto-dismissed by `showTrailerNotice`, so the Trailer button never opens the source-error screen.
        .overlay(alignment: .top) {
            if trailerNotice {
                Text("Trailer is preparing, try again shortly")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    // The transient "trailer preparing" notice reads as a floating glass toast.
                    .vortxGlassToast(in: Capsule())
                    .padding(.top, Theme.Space.xl)
                    .transition(reduceMotion ? .identity : .opacity)
                    .allowsHitTesting(false)
            }
        }
        // navigationTitle on a PUSHED view bridges into the single shared window NSToolbar on macOS and
        // crashes in _insertNewItemWithItemIdentifier (the Beta 7 Mac crash). iOS-only; on macOS the title
        // already reads from the in-content hero.
        #if os(iOS)
        // Hide the system nav bar so the full-bleed hero runs edge-to-edge under the status bar; the
        // in-hero circular back chevron (heroChrome) is the back affordance. The swipe-from-edge
        // interactive pop still works with a hidden bar.
        .navigationTitle(meta?.name ?? title)
        .inlineNavigationTitle()
        .toolbar(.hidden, for: .navigationBar)
        // Hiding the bar also drops UIKit's edge-swipe back on this pushed page (the recognizer's
        // built-in delegate refuses to begin without a visible bar), so re-arm it explicitly. The
        // in-hero back disc is the visible affordance; the swipe is the muscle-memory one (#125).
        .background(RestoreSwipeBack().frame(width: 0, height: 0).allowsHitTesting(false))
        #endif
        // macOS has no toolbar back button (toolbar removed), so supply an in-content Back + Esc / Cmd-[.
        .macBackAffordance()
        // macOS cast/crew tap routing: the cast rail routes a PersonTarget VALUE (a destination-builder
        // NavigationLink does not fire from the lazy cast rail on Mac), so register the Person destination
        // here inside this tab's NavigationStack. iOS keeps the inline destination-builder link, so this is
        // macOS-only and leaves iOS / tvOS untouched.
        #if os(macOS)
        .navigationDestination(for: PersonTarget.self) { t in
            PersonView(personID: t.id, name: t.name, profileURL: t.profileURL)
        }
        #endif
        // Guard the meta load: the shared CoreBridge already holds this title's meta on an A -> back -> A
        // revisit, so re-loading it churns the engine and momentarily blanks the hero for no reason.
        .onAppear {
            // Wire the source-list model to this screen's sources (idempotent; nudges a refresh on
            // re-appear). The model owns assembly + ranking off-main from here on.
            sourceList.bind(core: core, torbox: torboxSearch, singularity: sourceIndex,
                            mediaServers: mediaServers, debridCache: debridCache)
            if effectiveType == "series" {
                torboxSearch.clearResults(); sourceIndex.clearResults(); mediaServers.clearResults()
                // A series detail loads meta only; streams load per-episode from iOSEpisodeStreams.
                if meta == nil { core.loadMeta(type: effectiveType, id: id) }
            } else if meta != nil {
                loadMovieStreamsIfNeeded()        // meta already resident → dispatch streams now
            } else {
                core.loadMeta(type: effectiveType, id: id) // load meta FIRST; onChange dispatches streams on arrival
                // For an imdb tt id whose Cinemeta meta may never arrive (new/unreleased title), don't wait
                // on the onChange(meta?.id) that would never fire: fire the tt-keyed streams now so the
                // sources list populates regardless of the meta race. No-op'd by hasStreams once they land.
                loadMovieStreamsIfNeeded()
            }
            if let m = meta { loadSimilar(m); loadRatings(); loadWatchProviders(); loadFinancials(); loadReleaseDates(); resolveTrailerIfNeeded(m); resolvePreferredTrailerIfNeeded(m) }
            // These resolve from the tt id alone, so a hub-seeded title whose Cinemeta meta never
            // arrives still gets its cast, synopsis fallback, and a More-Like-This rail (#7/#29).
            loadCredits()
            loadCollection()
            loadSimilarFallback()
            refreshLanguageChips()
        }
        // A movie/live title is a SINGLE video, but its stream request must carry the IMDB id, not the raw
        // catalog id: a TMDB/Kitsu catalog gives the meta a tmdb:/kitsu: id, and imdb-keyed stream add-ons
        // (idPrefixes ["tt"]) are silently dropped from the plan for a non-imdb id (so only AIOStreams-style
        // broad add-ons answer). The imdb id lives in the meta's behaviorHints.defaultVideoId, known only
        // AFTER the meta loads — so dispatch the streams here, once the meta arrives. (movieStreamId).
        // Re-dispatch streams under the AUTHORITATIVE meta.type once it arrives (Collections-hub fix): if the
        // hub's TMDB guess was wrong, meta.type now corrects it and the stream request re-fires under the type
        // the add-ons actually index the title under. The hasStreams guard keys on the effective streamId, so
        // this cannot loop.
        .onChange(of: meta?.type) { _ in
            if effectiveType != "series" { loadMovieStreamsIfNeeded() }
            else { torboxSearch.clearResults(); sourceIndex.clearResults(); mediaServers.clearResults() }
        }
        .onChange(of: meta?.id) { _ in
            if effectiveType != "series" { loadMovieStreamsIfNeeded() }
            else if let m = meta, let videos = m.videos {
                // F5: opening a series schedules its next-episode alert (asks permission in context the
                // first time; on by default). Keyed by series id, so revisiting refreshes rather than dupes.
                Task { await NewEpisodeNotifications.scheduleUpcomingAuthorized(seriesId: m.id, seriesName: m.name, videos: videos) }
            }
            resolvedTrailerID = nil   // new title: drop the previous fallback before re-resolving
            resolvedPreferredTrailerID = nil   // new title: drop the previous language-preferred pick too
            langChips = []; langChipsKey = ""   // new title: reset the language chips before recomputing
            if let m = meta { loadSimilar(m); loadRatings(); loadWatchProviders(); loadFinancials(); loadReleaseDates(); resolveTrailerIfNeeded(m); resolvePreferredTrailerIfNeeded(m) }
            loadCredits()   // meta may have surfaced the imdb defaultVideoId for a tmdb:/kitsu: catalog id
            loadCollection()   // ditto: the imdb id may only now be known for a tmdb:/kitsu: catalog id
            refreshLanguageChips()
        }
        // Do NOT unloadMeta here. On iOS, pushing the per-episode page (iOSEpisodeStreams) fires THIS
        // detail page's onDisappear AFTER the episode page has already loaded its streams — so calling
        // unloadMeta would wipe `metaDetails` out from under the episode page (~0.3s later), leaving its
        // source list empty ("No stream add-ons responded"). That race is why SERIES found no streams on
        // iOS while MOVIES (no child push) and macOS (different onDisappear timing) worked. The next
        // detail's loadMeta replaces the resident meta anyway, so leaving it loaded is harmless.
        .onDisappear { torrentPrime?.cancel(); sourceRefreshDebounce?.cancel(); langChipsDebounce?.cancel() }
        // Flip the spinner to "No sources found" if resolution hangs past 20s (mirrors iOSEpisodeStreams).
        .task {
            try? await Task.sleep(for: .seconds(20))
            settleTimedOut = true
        }
        // Debrid cache awareness: as add-ons answer (the load count climbs), check which raw torrents the
        // user's debrid account has cached. `refresh` de-dups by the hash set, so this only hits a provider
        // when the torrents actually change; with no debrid key it returns an empty set and nothing renders.
        // Series load streams per-episode (iOSEpisodeStreams owns its own awareness); movie + live read here.
        .onChange(of: core.streamLoadProgress().loaded) { _ in
            if effectiveType != "series" { scheduleSourceRefresh() }
            refreshLanguageChips()   // recompute the "Also available in" chips as more sources answer (own debounce)
        }
        // The Singularity pool answers asynchronously, so re-run the debrid cache check when its streams
        // arrive: each pooled torrent infohash is checked against the user's own debrid, so it resolves
        // per-user instead of merely rendering.
        .onChange(of: sourceIndex.streams.count) { _ in
            if effectiveType != "series" { scheduleSourceRefresh() }
        }
        // TorBox search-as-a-source: fetch the extra usenet/torrent sources once the meta's imdb id is
        // known (gated on a TorBox key inside `refresh`; de-duped by imdb id). Series episodes fetch in
        // their own episode view.
        .onChange(of: meta?.id) { _ in
            if effectiveType != "series" {
                mediaServers.refresh(imdb: titleIdentity.titleID, title: meta?.name,
                                     publicationTarget: mediaServerTargetID)
                refreshSourceIndex()
            }
        }
        .onAppear {
            if effectiveType != "series" {
                mediaServers.refresh(imdb: titleIdentity.titleID, title: meta?.name,
                                     publicationTarget: mediaServerTargetID)
                refreshSourceIndex()
            }
        }
        // Warm the Trakt playback shadow so the "Resume from <time>" chip can decide off a cache rather
        // than blocking the open on a network call. Internally throttled, opt-in gated, and a no-op when
        // Trakt is unconfigured or disconnected, so this costs nothing for everyone else.
        .onAppear { TraktPlaybackShadow.shared.refreshIfStale() }
        .platformFullScreenPlayerCover(item: $presentation) { item in
            switch item {
            case .player(let launch):
                PlayerScreen(
                    url: launch.url, title: launch.title, headers: launch.headers, resumeSeconds: launch.resume,
                    recordMeta: launch.meta, recordQualityText: launch.qualityText,
                    recordBingeGroup: launch.bingeGroup, recordIsTorrent: launch.isTorrent,
                    recordDebridRef: launch.debridRef,
                    initialSourceStream: launch.sourceStream,
                    initialEnginePlayerVideoId: launch.enginePlayerVideoId,
                    startedFromExplicitPick: launch.wasExplicitPick,
                    // reportProgress feeds the engine Player (TimeChanged) so Continue Watching updates live and
                    // watched time is tracked. The ACCOUNT write (account.saveProgress) moved INTO PlayerScreen
                    // (saveAccountProgress, keyed on curMeta): closing over launch.meta here pinned every account
                    // save to the LAUNCH episode across in-player binge advances (wrong-episode CW attribution).
                    onProgress: { pos, dur in core.reportProgress(timeSeconds: pos, durationSeconds: dur) },
                    onSeek: { pos, dur in core.reportProgress(timeSeconds: pos, durationSeconds: dur) },
                    onClose: {
                        core.unloadEnginePlayer()
                        presentation = nil
                    }
                )
                .ignoresSafeArea()
            case .trailerPlayer(let url, let title, let audioSidecar):
                PlayerScreen(url: url, title: title, headers: nil, resumeSeconds: 0,
                             recordMeta: nil, isTrailer: true, audioSidecarURL: audioSidecar,
                             onClose: { presentation = nil })
                    .ignoresSafeArea()
            case .trailerEmbed(let youTubeID, let title):
                TrailerEmbedCover(youTubeID: youTubeID, title: title, onClose: { presentation = nil })
                    .ignoresSafeArea()
            }
        }
    }

    /// Present the meta's FULL trailer IN-APP (A6 - the explicit Trailer button, NOT the ambient hero /clip).
    /// OWNER FINAL ARCHITECTURE (HARD): the FULL trailer plays ON DEMAND through the app's own server route
    /// (server.js `/yt/:id`, InnerTube ANDROID client -> a direct stream URL) NATIVELY in libmpv/AVPlayer - the
    /// SAME path our YouTube/Twitch URL playback already uses. There is NO trailer.vortx.tv full-trailer route
    /// and NO R2 full-trailer storage; the `/clip` mp4 is ONLY the 10s ambient hero snippet.
    ///
    /// Fallback order (A6 / D4 / D11):
    ///   1) /yt resolver -> native player (primary, every platform with an embedded server, tvOS-full included):
    ///      built from the language-preferred YouTube id (D11) when a genuine localized hit exists, else the
    ///      meta's own / Cinemeta-TMDB-fallback default id; a real DIRECT (non-YouTube) trailer stream is also a
    ///      full trailer and plays natively with no server;
    ///   2) iOS/Mac ONLY: the keyless WKWebView IFrame embed (`TrailerEmbedCover`) if the resolver path is
    ///      unavailable (Lite build / no server) but a YouTube id exists;
    ///   3) the ambient /clip mp4 (SHORT snippet) as a last resort so the button still plays something;
    ///   4) a transient "preparing" notice - never the full source-error screen.
    private func playTrailer() {
        guard let m = meta else { return }
        let title = "\(m.name) Trailer"
        let req = TrailerRequest.from(meta: m)
        // D11: resolve the language-preferred id first (async, fail-soft). preferredYouTubeID may already be
        // populated by resolvePreferredTrailerIfNeeded; if not, resolve inline so a manual tap still honors the
        // picker. The whole selection is fail-soft: any nil falls through to the default id / direct / clip.
        Task { @MainActor in
            let preferred = await resolvedOrFreshPreferredTrailerID(m)
            let defaultYT = (req?.youTubeID ?? resolvedTrailerID).flatMap { $0.isEmpty ? nil : $0 }
            let lang = TMDBClient.trailerLanguageBaseCode
            // 0) DEVICE-DIRECT FIRST (yt-direct): resolve the YouTube stream on the user's own IP (InnerTube
            //    from the app; a residential IP gets adaptive 1080p+, whose separate audio rides mpv's
            //    --audio-file sidecar). A direct (non-YouTube) trailer stream still wins below (it needs no
            //    resolver at all); any miss falls through to the /yt worker exactly as before.
            if req?.directURL == nil, let yt = preferred ?? defaultYT,
               let resolved = await YouTubeDirectResolver.resolve(videoID: yt, maxHeight: 1080) {
                NSLog("[yt-direct] detail trailer button: %@ h=%d", resolved.isMuxed ? "direct-muxed" : "direct-pair", resolved.height)
                presentation = .trailerPlayer(url: resolved.videoURL, title: title, audioSidecar: resolved.audioURL)
                return
            }
            // 1) NATIVE /yt (or a direct stream) is the PRIMARY full-trailer path on every server-capable build.
            if let native = req?.nativeFullTrailerURL(preferredYouTubeID: preferred ?? defaultYT, languageCode: lang)
                ?? TrailerRequest(title: m.name, youTubeID: preferred ?? defaultYT, directURL: nil)
                    .nativeFullTrailerURL(languageCode: lang) {
                NSLog("[yt-direct] detail trailer button: fallback-worker")
                presentation = .trailerPlayer(url: native, title: title, audioSidecar: nil)
                return
            }
            // 2) iOS/Mac only: no server (Lite) but a YouTube id exists -> the keyless IFrame embed cover.
            if let yt = preferred ?? defaultYT {
                presentation = .trailerEmbed(youTubeID: yt, title: title)
                return
            }
            // 3) No full trailer resolved: the short /clip mp4 so the button still plays something.
            if let clip = req?.playableURL {
                presentation = .trailerPlayer(url: clip, title: title, audioSidecar: nil)
                return
            }
            // 4) Nothing at all: a small transient notice, never the source-error screen.
            showTrailerNotice()
        }
    }

    /// The language-preferred trailer id (D11) for a manual Trailer tap: return the already-resolved id if
    /// `resolvePreferredTrailerIfNeeded` populated it, else resolve inline (a genuine preferred-language hit
    /// only, else nil so the default id plays). Fail-soft throughout: no TMDB key / no localized trailer -> nil.
    private func resolvedOrFreshPreferredTrailerID(_ m: CoreMetaItem) async -> String? {
        if let id = resolvedPreferredTrailerID, !id.isEmpty { return id }
        let languages = TMDBClient.preferredTrailerLanguages.filter { $0 != "en" }
        guard !languages.isEmpty else { return nil }
        let pick = await TMDBClient.preferredTrailerPick(metaID: m.id, type: m.type, preferredLanguages: languages)
        guard pick.matchedPreferred, let yt = pick.key, !yt.isEmpty else { return nil }
        return yt
    }

    /// A standalone Trailer chip, shown whenever the meta carries a trailer (direct stream or a YouTube
    /// link). Used in both the movie Watch row and the series hero.
    @ViewBuilder private var trailerButton: some View {
        // Show when ANY trailer source resolves: the engine meta's own trailer OR the Cinemeta/TMDB
        // fallback id (resolvedTrailerID), so a title whose engine meta carries no trailer still gets one.
        if let m = meta, TrailerRequest.from(meta: m) != nil || resolvedTrailerID?.isEmpty == false {
            Button { playTrailer() } label: {
                Label("Trailer", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    /// A6: surface the "no trailer right now" case (no full YouTube trailer AND no /clip) as a small
    /// self-dismissing notice over the hero band instead of the full source-error screen. Rare - it only
    /// fires when neither a YouTube id nor the /clip resolver produced a source.
    private func showTrailerNotice() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { trailerNotice = true }
        // The capsule is visual-only (allowsHitTesting false, no focus); speak it so a VoiceOver user who
        // tapped Trailer gets the same feedback instead of the tap appearing to do nothing.
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: "Trailer is preparing, try again shortly")
        #endif
        trailerNoticeTask?.cancel()
        trailerNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { trailerNotice = false }
        }
    }

    #if !os(tvOS)
    /// The offline-download state for one video id, derived from `DownloadStore.shared`. Drives the
    /// download chip's three affordances so a tap gives visible feedback: no record → offer a download,
    /// an active (queued/downloading/paused) record → an in-progress "Downloading" state, a completed
    /// record → a "Downloaded" check. Reuses the same store lookups that already prevent double-queueing.
    private enum DownloadChipState { case none, inProgress, done }

    private func downloadChipState(videoId: String) -> DownloadChipState {
        guard let record = downloads.records.first(where: { $0.videoId == videoId && $0.state != .failed }) else { return .none }
        return record.state == .completed ? .done : .inProgress
    }

    /// A Download chip with state feedback (#30), shared by the movie action row and the series hero. The
    /// idle state offers a download (enabled only when `ready`); while a record is active it shows a spinner
    /// + "Downloading" and is disabled; once complete it shows a "Downloaded" check and is disabled. The
    /// action runs only from the idle state, so a tap can't re-queue an in-flight or finished download.
    @ViewBuilder private func downloadChip(videoId: String, ready: Bool, action: @escaping () -> Void) -> some View {
        let state = downloadChipState(videoId: videoId)
        Button {
            if state == .none { action() }
        } label: {
            switch state {
            case .done:
                Label("Downloaded", systemImage: "checkmark.circle.fill")
            case .inProgress:
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Downloading")
                }
            case .none:
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        .buttonStyle(ChipButtonStyle())
        .disabled(state != .none || !ready)
    }
    #endif

    // MARK: Hero (full-bleed backdrop + scrim + meta), mirrors tvOS DetailView.hero

    /// Scroll-anchor id for the source section, so the hero's "Sources" action can jump to it.
    private static let sourcesAnchor = "iOSDetailSources"

    /// Hero: full-bleed backdrop + scrim + title / meta / action row / synopsis. `scrollToSources`
    /// is wired into the movie action row's "Sources" button (the tvOS 3-action twin).
    private func hero(width: CGFloat, height: CGFloat, scrollToSources: @escaping () -> Void) -> some View {
        // Two stacked blocks, NOT one bottom-aligned ZStack over the backdrop. The backdrop is a
        // fixed-height banner with the title + meta + a clamped synopsis overlaid at its bottom; the action
        // buttons and the (long) full synopsis flow BELOW it on the canvas. Putting the whole column inside
        // a bottom-aligned ZStack made a tall column (long synopsis + wrapped buttons) push the fixed-height
        // backdrop down until it sat behind the buttons with the title stranded on black above, the
        // "backdrop is so far down / layout is messy" report. A fixed banner keeps the art pinned to the top.
        //
        // Split into `heroBanner` (the cinematic art + title/meta overlay + chrome) and `heroBelow` (actions,
        // full synopsis, credits, language chips) so the macOS pinned-hero scroll model (`macDetailBody`) can
        // pin the banner while the below-content + episode/source list scroll independently beneath it. On
        // iOS/iPadOS the two are composed back into the exact single scrolling column as before.
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            heroBanner(width: width, height: height)
            heroBelow(width: width, scrollToSources: scrollToSources)
        }
        .frame(width: width, alignment: .leading)
    }

    #if os(macOS)
    /// macOS pinned-hero layout (item 4): the cinematic banner is a FIXED top layer and only the content
    /// below it (action row, full synopsis, credits, and the episode / source list) scrolls in its own
    /// independent inner ScrollView. Deliberately a fixed hero layer + inner ScrollView, NOT a scroll
    /// section-header pin, which is banned (it triggered the NSToolbar/section-header crash class). The
    /// hero "Sources" action still scrolls the inner region to the source anchor via the shared proxy.
    @ViewBuilder private func macDetailBody(geo: GeometryProxy, proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            heroBanner(width: geo.size.width, height: geo.size.height)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    heroBelow(width: geo.size.width) { withAnimation { proxy.scrollTo(Self.sourcesAnchor, anchor: .top) } }
                    // #9: cap the source-heavy content to a readable column and center it on a wide window.
                    Group {
                        if isEpisodic {
                            episodeList
                        } else {
                            sourceSection.id(Self.sourcesAnchor)
                        }
                    }
                    .frame(maxWidth: geo.size.width > Theme.Space.wideLayoutMinWidth ? Theme.Space.contentColumn : .infinity)
                    .frame(maxWidth: .infinity)
                    whereToWatchSection
                    collectionSection
                    moreLikeThisSection
                }
                .padding(.bottom, Theme.Space.xl)
                .frame(width: geo.size.width, alignment: .leading)
            }
        }
        // Near-full-bleed cinematic backdrop behind the ENTIRE detail page (owner ask). The pinned banner only
        // paints the top portion of the window (heroBandHeight reserves an inner-scroll region so the Watch /
        // Quality actions stay visible), which left the scroll region beneath it on flat black canvas: the
        // "dead black below" report. Painting the SAME art + multi-stop gradient scrim at the full window
        // height BEHIND the page makes the lower region read as continuous cinematic art with the copy still
        // legible, without growing the banner (which would push Watch below the fold). `.background` does not
        // affect the VStack's own layout; the opaque banner still owns the crisp focal art up top. macOS-only.
        .background(alignment: .top) {
            // Use the blurred-FILL wash, NOT a second crisp `backdrop`: painting `backdrop` again at full
            // height re-ran the banner's `.fit` fallback for a series (portrait poster), so the crisp banner
            // poster and this crisp background poster rendered as TWO offset centered images (the "two images"
            // report). `backdropWash` always fills + blurs + dims, so a movie reads as one continuous image
            // and a series reads as a crisp poster over soft blurred art (one image), never two.
            backdropWash(height: geo.size.height)
                .ignoresSafeArea()
        }
    }
    #endif

    /// The pinnable cinematic banner: full-bleed backdrop (with the ambient trailer clip) plus the
    /// title / meta / ratings / clamped-synopsis overlay and the circular back/overflow chrome. On macOS
    /// this is the FIXED layer of the pinned-hero scroll model; on iOS it is the top of the single column.
    private func heroBanner(width: CGFloat, height: CGFloat) -> some View {
        let band = heroBandHeight(viewport: height)
        return ZStack(alignment: .bottomLeading) {
            backdrop(height: band)
                // #44: cross-fade a muted, looping trailer clip over the still backdrop a beat after it
                // shows. Mounted ONLY for VOD with a resolved YouTube id and when motion is allowed; the
                // still backdrop underneath is the permanent fallback. Live channels never get a trailer.
                .overlay { heroTrailerClip(height: band) }
                // Edge-to-edge cinematic hero: the art bleeds UP under the status bar / notch so there is no
                // canvas-colored strip above it on a notched iPhone. Only the backdrop art (and its trailer
                // overlay) ignores the top safe area; heroChrome stays an overlay on the ZStack below, which
                // still respects the inset, so the back / overflow discs clear the notch.
                .ignoresSafeArea(edges: .top)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                titleOrLogo
                metaRow
                ratingsRow
                financialsRow
                releaseDatesRow
                // #9: a clamped synopsis reads WITH the ratings block on the hero art; the full
                // description still flows below the action row for anyone who wants all of it.
                if let synopsis = heroOverview {
                    Text(synopsis)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(3).truncationMode(.tail)
                        .frame(maxWidth: Theme.Space.readableColumn, alignment: .leading)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.lg)
            .frame(width: width, alignment: .leading)
        }
        // Circular translucent chrome: back chevron top-left, overflow top-right. Overlaid on the ZStack
        // (NOT the backdrop) so it keeps the safe-area inset the backdrop now ignores; its own top padding
        // then insets the discs below the status bar / notch, so the hero reads like a cinematic media app.
        .overlay(alignment: .topLeading) { heroChrome }
        .frame(width: width, alignment: .leading)
    }

    /// The scrollable remainder of the hero: the action row (Watch Now / series actions), the full
    /// synopsis, cast/crew, and language chips. On macOS this scrolls (with the episode/source list) under
    /// the pinned banner; on iOS it is the lower half of the single hero column.
    private func heroBelow(width: CGFloat, scrollToSources: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // Branch on the SAME authoritative signal the body uses (episodeList vs sourceSection), not the
            // raw hub-guess `type`: a hub tile the hub mis-typed as "movie" that resolves to a series/
            // collection meta would otherwise show movie Play actions contradicting an episodic body (#102).
            if !isEpisodic {
                watchNow(scrollToSources: scrollToSources)
            } else {
                seriesHeroActions
            }
            // H2: only show the full description below when it is meaningfully longer than the hero's
            // 3-line excerpt, so a short synopsis is not printed twice on the same screen.
            if showsFullDescriptionBelow, let overview = heroOverview {
                Text(overview)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.Space.readableColumn, alignment: .leading)
            }
            creditsRows
            languageChips
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(width: width, alignment: .leading)
        // Pre-download quality picker (#30 follow-up). Attached HERE, nested under the body's player cover,
        // NOT on the body itself: on macOS `platformFullScreenPlayerCover` becomes a `.sheet(item:)`, and a
        // second `.sheet(item:)` on the SAME view shadows it (see the `presentation` note). heroBelow is the
        // shared host for both the movie (`watchNow`) and series (`seriesHeroActions`) Download chips on iOS
        // AND macOS, so one attachment here covers both entry points on both platforms.
        .downloadQualityPicker($downloadPicker)
    }

    /// The synopsis to render: the engine meta's description, else TMDB's overview (a hub-seeded tt id
    /// not yet in Cinemeta loads meta=nil, which used to leave both synopsis blocks empty).
    private var heroOverview: String? {
        if let d = meta?.description, !d.isEmpty { return d }
        return fallbackOverview
    }

    /// H2: the hero band already shows a 3-line synopsis excerpt, so only repeat the FULL description in the
    /// section below the action row when it is MEANINGFULLY longer than that excerpt (~3 lines at the readable
    /// column width) - otherwise the two blocks are identical and the description reads as doubled. Chars,
    /// not rendered lines, is a good-enough proxy here.
    private static let heroSynopsisExcerptChars = 200
    private var showsFullDescriptionBelow: Bool {
        guard let o = heroOverview else { return false }
        return o.count > Self.heroSynopsisExcerptChars
    }

    /// Circular translucent chrome overlaid on the hero art: a back chevron (top-left) that pops this
    /// pushed detail, and an overflow control (top-right) with Share. Kept fail-soft: the overflow only
    /// carries actions that are always safe. Inset from the top so it clears the status bar / notch.
    @ViewBuilder private var heroChrome: some View {
        HStack {
            #if os(iOS)
            // macOS supplies its own in-content Back via .macBackAffordance() at the same topLeading anchor;
            // showing this disc too would stack two overlapping back affordances (T24), so gate it to iOS.
            CircleIconButton(systemName: "chevron.left", diameter: Theme.Control.circleChrome) { dismiss() }
                .accessibilityLabel("Back")
            #endif
            Spacer()
            Menu {
                if let m = meta {
                    if m.id.hasPrefix("tt"), let url = URL(string: "https://www.imdb.com/title/\(m.id)/") {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    } else {
                        ShareLink(item: m.name) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
            } label: {
                // Reuse the disc look for the menu label (Menu can't take a ButtonStyle directly), so
                // the overflow disc stays in lockstep with the back chevron's CircleIconButton.
                CircleIconDisc(systemName: "ellipsis", diameter: Theme.Control.circleChrome, tint: Theme.Palette.textPrimary)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
    }

    /// "Also available in" chips row (P1). Rendered only when the language merge produced something and the
    /// languageIndex feature is on. Full localized language NAMES (English · Français …, via the chip's
    /// Locale-resolved label, #8), in ONE horizontally scrollable row so a long list fits any width. No
    /// add-on wording: these are just the languages this title is available in.
    @ViewBuilder private var languageChips: some View {
        if !langChips.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Also available in")
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.Palette.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(langChips, id: \.code) { chip in
                            Text(chip.label)
                                .font(Theme.Typography.label.weight(.semibold))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                // Glass the static "Also available in" language pill: a non-selected
                                // glass chip so it reads as raised VortX chrome, not a flat surface fill.
                                .vortxGlassChip(selected: false)
                                .accessibilityLabel(chip.label)
                        }
                    }
                }
            }
            .padding(.top, Theme.Space.xs)
            .frame(maxWidth: Theme.Space.readableColumn, alignment: .leading)
        }
    }

    /// Full-bleed artwork at the LIVE page's fixed band height (the VOD hero passes its own scaled band).
    // MARK: Dynamic dominant-color backdrop (helpers, kept OUT of the body chain for type-check budget)

    /// The art the tint derives from: the SAME fallback chain `backdrop(height:)` paints, so tint and art
    /// always agree. Also the `.task(id:)` key, so a late meta hydrate recomputes.
    private var tintArtURL: String? {
        meta?.background ?? meta?.poster ?? seedBackdrop ?? FeaturedHeroItem.metahubBackground(forId: id)
    }

    /// Canvas with the dominant-color wash ramping in BELOW the hero band (clear at the top, so the hero's
    /// canvas-fade seam stays seamless) and easing off toward the bottom. nil tint = today's flat canvas.
    private var dominantColorBackground: some View {
        ZStack {
            Theme.Palette.canvas
            if let dominantTint {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.30),
                    .init(color: dominantTint.opacity(0.28), location: 0.60),
                    .init(color: dominantTint.opacity(0.10), location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    /// Off-main average-color compute (PosterImageLoader.averageColor, cached + downsampled); cross-fades
    /// the wash in. nil (no art / failure) keeps the plain canvas, the graceful fallback.
    private func recomputeTint() async {
        let tint = await PosterImageLoader.averageColor(tintArtURL)
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { dominantTint = tint }
    }

    private var backdrop: some View { backdrop(height: backdropHeight) }

    /// Full-bleed artwork with the same two scrims tvOS uses: a vertical canvas fade so the lower text
    /// block stays readable, and a leading canvas fade for the title column.
    private func backdrop(height: CGFloat) -> some View {
        // Fall back through: meta background -> meta poster -> the hub card's seed backdrop ->
        // metahub-by-tt (so a meta=nil unreleased title still paints art) -> the seed logo's poster.
        // Without this the hero blanked to surface1 whenever Cinemeta meta was nil (Cocktail 2,
        // Evil Dead Burn: tt exists at TMDB, not yet in Cinemeta).
        let bg = meta?.background ?? meta?.poster
            ?? seedBackdrop
            ?? FeaturedHeroItem.metahubBackground(forId: id)
        return AsyncImage(url: URL(string: bg ?? "")) { phase in
            switch phase {
            // Movies carry a 16:9 `background`, so .fill crops cleanly. A SERIES usually has no landscape
            // background and falls back to the PORTRAIT `poster`; .fill on that in the landscape band crops
            // it to black bars (the "shows all have cut off hero image" report), so series fit instead.
            case .success(let img): img.resizable().aspectRatio(contentMode: (effectiveType == "series" && (meta?.background?.isEmpty ?? true)) ? .fit : .fill)
            default: Theme.Palette.surface1
            }
        }
        .frame(height: height)
        // The backdrop is the ZStack's WIDTH ANCHOR: it greedily takes the full viewport width and
        // pins to the leading edge, so the ZStack's leading edge is the screen's leading edge. Before
        // this, the oversized serif hero title made the ZStack wider than the screen and `.bottomLeading`
        // pushed the whole block to a negative x — clipping the title / Watch / synopsis off the left.
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        // A smoother multi-stop vertical fade: the art stays crisp up top and dissolves cleanly into the
        // dark canvas so the title/meta block reads without a hard seam (the cinematic reference look).
        .overlay(
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.15), location: 0.45),
                .init(color: Theme.Palette.canvas.opacity(0.55), location: 0.72),
                .init(color: Theme.Palette.canvas.opacity(0.88), location: 0.90),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        )
        // A gentle top scrim so the translucent chrome buttons stay legible over bright artwork.
        .overlay(
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.45), .clear],
                           startPoint: .top, endPoint: .center)
        )
        // A soft leading fade anchors the title column.
        .overlay(
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.5), .clear],
                           startPoint: .leading, endPoint: .center)
        )
    }

    #if os(macOS)
    /// The full-window BACKGROUND wash behind the pinned macOS detail page (the pinned banner only paints the
    /// top band, so the scroll region beneath needs continuous atmosphere). Unlike the crisp `backdrop` banner,
    /// this ALWAYS uses `.fill` (never the series `.fit` fallback) plus a blur and a dim, so it reads as soft
    /// atmosphere rather than a SECOND crisp poster: a movie's crisp fill banner sits over a matching (softly
    /// blurred) fill wash (continuous, no seam), and a series' `.fit` poster banner sits over a soft blurred
    /// fill of the same art (poster-on-blur) instead of two competing centered posters. Decoupled from the
    /// banner's `.fit` switch at `backdrop(height:)` on purpose.
    private func backdropWash(height: CGFloat) -> some View {
        let bg = meta?.background ?? meta?.poster
            ?? seedBackdrop
            ?? FeaturedHeroItem.metahubBackground(forId: id)
        return AsyncImage(url: URL(string: bg ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)   // ALWAYS fill, never .fit
            default: Theme.Palette.canvas
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
        .blur(radius: 40)
        // Dim + fade to canvas so the copy scrolling below the banner stays legible over the soft art.
        .overlay(Theme.Palette.canvas.opacity(0.5))
        .overlay(
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.55), location: 0.6),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        )
        .accessibilityHidden(true)
    }
    #endif

    /// H3 / #44: the muted, looping in-hero trailer painted over the still backdrop. The owner wants the WHOLE
    /// trailer muted here (not a 10s snippet), through the SAME native /yt path as the explicit Trailer button
    /// (A6, owner FINAL architecture). Mounted only when ALL hold: motion is allowed, this is a VOD title (live
    /// channels carry no trailers and run a stripped page), and a trailer resolved. Priority mirrors A6:
    ///   1) the NATIVE full trailer (a direct stream, else the `/yt` resolver URL) muted + looping in libmpv -
    ///      the primary path on every server-capable build (the same route the Trailer button plays),
    ///   2) iOS/Mac ONLY: the keyless IFrame embed (`InHeroYouTubeTrailerView`) when no native URL is available
    ///      (Lite / no server) but a YouTube id exists,
    ///   3) a last-resort native `/yt` trailer built straight from the raw meta trailer (via `playableURL`),
    ///      muted + looping, for the rare case branch 1's language-preferred resolution has not populated yet.
    /// The clip fades in a beat after the backdrop shows; the still art underneath is the permanent fallback, so
    /// a missing / slow / blocked trailer never blanks the band, and no error is ever surfaced.
    @ViewBuilder private func heroTrailerClip(height: CGFloat) -> some View {
        if autoplayTrailers, !reduceMotion, !LiveTypes.contains(type) {
            if let native = detailNativeTrailerURL {
                // FULL trailer (direct stream OR the /yt resolver) muted + looping in libmpv (window nil = whole
                // trailer, looped). This is the owner's FINAL detail-hero path - same native route as the button.
                // yt-direct: try the DEVICE-DIRECT stream first (resolved on the user's own IP; the clip is
                // muted, so a video-only adaptive pick needs no audio sidecar). The clip mounts only after the
                // attempt lands so a late resolve never remounts it; a miss mounts the /yt worker URL. A meta
                // with a real direct (non-YouTube) trailer stream has no ambientYouTubeID and mounts at once.
                Group {
                    if let yt = detailAmbientYouTubeID {
                        if let attempt = detailAmbientDirect, attempt.ytID == yt {
                            InHeroTrailerView(url: attempt.url ?? native, height: height, window: nil)
                        }
                    } else {
                        InHeroTrailerView(url: native, height: height, window: nil)
                    }
                }
                .task(id: detailAmbientYouTubeID) { await resolveDetailAmbientDirect() }
            } else if let yt = detailTrailerYouTubeID {
                // Fallback (iOS/Mac only, no server): the FULL YouTube trailer muted + looping via the keyless
                // IFrame embed. The native /yt path above is preferred; this only fires on the Lite build.
                InHeroYouTubeTrailerView(youTubeID: yt, height: height)
            } else if let clip = detailTrailerClipURL {
                // Last resort: the meta's own trailer via the native /yt resolver (owner directive: the retired
                // R2 /clip snippet is gone), muted + looping the whole trailer, when branch 1 has not resolved.
                InHeroTrailerView(url: clip, height: height, window: nil)
            }
        }
    }

    /// The NATIVE full-trailer URL for the detail hero (owner FINAL architecture): a direct (non-YouTube)
    /// trailer stream from the meta, else the embedded/remote server's `/yt/{id}` resolver URL built from the
    /// language-preferred id (D11) when one resolved, else the meta's own / Cinemeta-TMDB-fallback default id.
    /// Server-gated: nil on the Lite build (no embedded server) for a YouTube-only trailer, so the IFrame-embed
    /// fallback (iOS/Mac) or the /clip ambient takes over. `?lang=` carries the resolved base language so the
    /// resolver's fallback chain matches the client pick.
    private var detailNativeTrailerURL: URL? {
        guard let m = meta else { return nil }
        let req = TrailerRequest.from(meta: m)
        if let direct = req?.directURL { return direct }
        let yt = (resolvedPreferredTrailerID?.isEmpty == false ? resolvedPreferredTrailerID : nil)
            ?? detailTrailerYouTubeID
        guard let yt, !yt.isEmpty else { return nil }
        return TrailerRequest(title: m.name, youTubeID: yt, directURL: nil)
            .nativeFullTrailerURL(languageCode: TMDBClient.trailerLanguageBaseCode)
    }

    /// The YouTube id the ambient detail-hero clip resolves (yt-direct): the same D11 language-preferred /
    /// default id `detailNativeTrailerURL` builds its `/yt` URL from, and nil when the meta carries a real
    /// direct (non-YouTube) trailer stream (that plays as-is, no resolver of any kind).
    private var detailAmbientYouTubeID: String? {
        guard let m = meta, TrailerRequest.from(meta: m)?.directURL == nil else { return nil }
        return (resolvedPreferredTrailerID?.isEmpty == false ? resolvedPreferredTrailerID : nil)
            ?? detailTrailerYouTubeID
    }

    /// yt-direct: one attempt per ambient YouTube id at resolving the detail-hero clip on the user's own IP.
    /// Fail-soft: any miss records `url = nil`, which mounts the existing /yt worker URL unchanged.
    private func resolveDetailAmbientDirect() async {
        guard let yt = detailAmbientYouTubeID, detailAmbientDirect?.ytID != yt else { return }
        let resolved = await YouTubeDirectResolver.resolve(videoID: yt, maxHeight: 1080)
        NSLog("[yt-direct] detail ambient: %@",
              resolved.map { $0.isMuxed ? "direct-muxed" : "direct-pair" } ?? "fallback-worker")
        detailAmbientDirect = (yt, resolved?.videoURL)
    }

    /// The detail hero's last-resort ambient trailer URL. `playableURL` now yields the meta's own trailer via
    /// the native `/yt` resolver (or a direct stream), NOT the retired R2 `/clip` snippet (owner directive), so
    /// this is a raw-meta `/yt` fallback used only when `detailNativeTrailerURL` (which layers the D11
    /// language-preferred id on top) has not resolved. Fail-soft: nil -> the still backdrop + Ken Burns stay.
    private var detailTrailerClipURL: URL? {
        guard let m = meta else { return nil }
        return TrailerRequest.from(meta: m)?.playableURL
    }

    /// The YouTube trailer id (engine meta's, else the Cinemeta/TMDB fallback) for the WKWebView IFrame clip
    /// fallback (iOS/Mac, no server).
    private var detailTrailerYouTubeID: String? {
        if let m = meta, let yt = TrailerRequest.from(meta: m)?.youTubeID, !yt.isEmpty { return yt }
        if let yt = resolvedTrailerID, !yt.isEmpty { return yt }
        return nil
    }

    /// #37 fallback: when the engine's detail meta has no trailer (`trailerYouTubeID == nil`), fetch the
    /// title's meta from Cinemeta and pull the first trailer's YouTube id, so the in-hero trailer mounts
    /// on the detail page just like the Home hero does. IMDB ids only (Cinemeta is keyed by `tt`); a
    /// non-`tt` catalog id simply gets no fallback. Applied only if the title is still on screen.
    private func resolveTrailerIfNeeded(_ m: CoreMetaItem) {
        guard m.trailerYouTubeID == nil, resolvedTrailerID == nil else { return }
        Task {
            // 1) Cinemeta (keyless) for IMDb ids covers most popular titles.
            if m.id.hasPrefix("tt"), let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(m.type)/\(m.id).json") {
                var req = URLRequest(url: url); req.timeoutInterval = 6; req.cachePolicy = .returnCacheDataElseLoad
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   let decoded = try? JSONDecoder().decode(AddonMetaResponse.self, from: data),
                   let yt = decoded.meta?.trailerYouTubeID, !yt.isEmpty {
                    await MainActor.run { if ResidentMeta.fenced(core.metaDetails?.meta, pageID: m.id, id: { $0.id }) != nil { resolvedTrailerID = yt } }
                    return
                }
            }
            // 2) TMDB /videos (when a TMDB key is set) fills Cinemeta's gaps and covers tmdb: catalog ids
            //    with no IMDb id (the same source Stremio trailer add-ons use).
            if let yt = await TMDBClient.trailerYouTubeID(metaID: m.id, type: m.type), !yt.isEmpty {
                await MainActor.run { if ResidentMeta.fenced(core.metaDetails?.meta, pageID: m.id, id: { $0.id }) != nil { resolvedTrailerID = yt } }
            }
        }
    }

    /// Resolve the user-LANGUAGE-preferred trailer id from TMDB /videos for the WITH-SOUND "watch trailer"
    /// action, independently of `resolveTrailerIfNeeded` (which only fires when the meta carries NO trailer).
    /// This runs even when the meta already has a default trailer, because the point is to prefer a trailer in
    /// the viewer's language over that (usually English) default. TMDB tags videos by `iso_639_1`, so the pick
    /// is language > original-language > English > first. Fail-soft: no TMDB data / no localized trailer leaves
    /// `resolvedPreferredTrailerID` nil and `playTrailer` uses today's default, so there is no regression.
    ///
    /// tvOS SEAM: this same id is what a future tvOS build would hand to a VPS resolve endpoint (tvOS has no
    /// web view to play a YouTube id, so it keeps playing the default warmed /clip today). The resolver lives
    /// in SourcesShared (`TMDBClient`), so tvOS can populate the same seam without new plumbing; the VPS side
    /// is intentionally NOT built here.
    private func resolvePreferredTrailerIfNeeded(_ m: CoreMetaItem) {
        guard resolvedPreferredTrailerID == nil else { return }
        // Only NON-English preferred languages are worth overriding the default (/clip) trailer for: the
        // default trailer is already the English one, so an English-preferred viewer keeps today's reliable
        // /clip path (no regression), while a viewer who prefers e.g. Portuguese gets the Portuguese trailer.
        let languages = TMDBClient.preferredTrailerLanguages.filter { $0 != "en" }
        guard !languages.isEmpty else { return }
        Task {
            // Require a GENUINE preferred-language hit (matchedPreferred): a fallback to original/English/first
            // is what the default path already plays, so overriding for that would needlessly swap the reliable
            // /clip mp4 for a YouTube embed. Fail-soft: no localized trailer leaves the id nil and the default plays.
            let pick = await TMDBClient.preferredTrailerPick(metaID: m.id, type: m.type, preferredLanguages: languages)
            guard pick.matchedPreferred, let yt = pick.key, !yt.isEmpty else { return }
            await MainActor.run { if ResidentMeta.fenced(core.metaDetails?.meta, pageID: m.id, id: { $0.id }) != nil { resolvedPreferredTrailerID = yt } }
        }
    }

    /// The title block: the addon-provided logo when present (the editorial signature on the tvOS hero),
    /// otherwise the serif hero type.
    @ViewBuilder private var titleOrLogo: some View {
        // fanart.tv clearlogo first (when enabled), else the ERDB-aware add-on/metahub logo, else serif text.
        // When meta is nil (unreleased/new title not yet in Cinemeta) fall through to the detail id and the
        // hub card's seed logo (metahub-by-tt), so the hero shows the show LOGO instead of blanking.
        ResolvedTitleLogo(id: meta?.behaviorHints?.defaultVideoId ?? meta?.id ?? id, type: meta?.type ?? type,
                          fallbackLogo: l10n.logo(for: id) ?? meta?.logo ?? seedLogo ?? FeaturedHeroItem.metahubLogo(forId: id),
                          maxWidth: 320, maxHeight: 110, accessibilityName: l10n.title(for: id) ?? meta?.name ?? title) {
            heroTitle
        }
    }

    private var heroTitle: some View {
        // No `.fixedSize` here: the serif `Theme.Typography.hero` type has a large intrinsic width,
        // and forcing the text to its intrinsic size made the ZStack (which sizes to its WIDEST child)
        // wider than the viewport, which `.bottomLeading` then pushed off the left edge. Clamping to
        // `maxWidth: .infinity, alignment: .leading` lets the title WRAP/scale within the available
        // width instead — so the title can never make the ZStack exceed the screen. Mirrors tvOS,
        // whose hero title wraps inside a width-bounded VStack with no horizontal fixedSize.
        Text(l10n.title(for: id) ?? meta?.name ?? title)
            .font(Theme.Typography.hero).tracking(-1)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(3).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    /// Rating · year · runtime · genres, same order and tokens as tvOS DetailView.metaRow.
    private var metaRow: some View {
        let m = meta
        var facts: [String] = []
        if let r = m?.releaseInfo { facts.append(r) }
        if let rt = m?.runtime { facts.append(rt) }
        let genres = m?.genres ?? []
        if !genres.isEmpty { facts.append(genres.prefix(3).joined(separator: " · ")) }
        return HStack(spacing: 6) {
            if let imdb = m?.imdbRating {
                Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                Text(imdb)
            }
            // Facts collapse into ONE truncating line. A row of separate non-truncating Texts had a
            // minimum width near the iPhone's portrait width, so it forced the hero wider than the screen
            // and the right edge clipped even with the GeometryReader cap. A single tail-truncating Text
            // keeps the row's minimum width tiny, so it always fits and the genres just truncate.
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  ")).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cast & Crew under the synopsis: a horizontally scrollable rail of EVERY cast member with photo +
    /// who-played-who (TMDB credits, keyless edge; the meta's plain name list is the no-TMDB fallback),
    /// then Director / Writer lines (#10). Visible by default; the header button folds it away.
    @ViewBuilder private var creditsRows: some View {
        let m = meta
        let directors = m?.directors ?? []
        let writers = m?.writers ?? []
        if !railCastMembers.isEmpty || !directors.isEmpty || !writers.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { castExpanded.toggle() }
                } label: {
                    // S9: same header component as Episodes / Sources / More Like This; the disclosure
                    // chevron rides at the trailing edge of the standardized header row (mirrors the way
                    // Episodes keeps its download menu in the header HStack).
                    HStack(spacing: Theme.Space.xs) {
                        iOSRailHeader(title: "Cast & Crew")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .rotationEffect(.degrees(castExpanded ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cast and crew")
                .accessibilityHint(castExpanded ? "Collapse" : "Expand")
                if castExpanded {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        castRail
                        VStack(alignment: .leading, spacing: 2) {
                            creditLine("Director", directors.prefix(3))
                            creditLine("Writer", writers.prefix(3))
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Space.xs)
        }
    }

    /// The rail's member list: TMDB credits (full cast, characters, headshots) when they resolved, else
    /// the meta's plain cast names (no photos/roles) so the rail never blanks without TMDB. Negative
    /// synthetic ids keep the fallback Identifiable without colliding with TMDB person ids.
    private var railCastMembers: [TMDBClient.CastMember] {
        if !castMembers.isEmpty { return castMembers }
        return (meta?.cast ?? []).enumerated().map {
            TMDBClient.CastMember(id: -1 - $0.offset, name: $0.element, character: nil, profileURL: nil)
        }
    }

    #if os(macOS)
    /// macOS-only value target for cast/crew navigation: a destination-builder NavigationLink inside the
    /// lazy cast rail does not fire on Mac, so the rail routes a `PersonTarget` value that `body` resolves
    /// via `.navigationDestination`. iOS keeps its inline destination-builder link, so this is macOS-only.
    struct PersonTarget: Hashable {
        let id: Int
        let name: String
        let profileURL: String?
    }
    #endif

    /// Horizontally scrollable full-cast rail: photo circle, actor name, character name beneath: ALL
    /// entries, not a 3-name line. LazyHStack so a 60-member ensemble builds on demand.
    @ViewBuilder private var castRail: some View {
        if !railCastMembers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.md) {
                    ForEach(railCastMembers) { member in
                        // A real TMDB person id (> 0) opens the Person page; the meta name-only fallback
                        // (railCastMembers' synthetic NEGATIVE id) has no TMDB person to look up, so it stays
                        // a plain non-tappable tile exactly as before.
                        if member.id > 0 {
                            #if os(macOS)
                            // macOS: a destination-builder NavigationLink inside this lazy horizontal stack
                            // does not reliably activate (the lazy container defers / loses the destination
                            // builder — the same #25 fragility documented at iOSRootView). Route by VALUE
                            // instead (registered via `.navigationDestination` in `body`), which fires
                            // reliably from a LazyHStack on Mac, and give the whole 92pt tile a hit shape so
                            // the gaps between headshots are clickable too, not just opaque photo pixels.
                            NavigationLink(value: PersonTarget(id: member.id, name: member.name, profileURL: member.profileURL)) {
                                castMemberTile(member).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            #else
                            NavigationLink {
                                PersonView(personID: member.id, name: member.name, profileURL: member.profileURL)
                            } label: { castMemberTile(member) }
                            .buttonStyle(.plain)
                            #endif
                        } else {
                            castMemberTile(member)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// One cast rail tile: headshot, actor name, character beneath. Extracted so a tappable (real person id)
    /// and the non-tappable fallback share identical layout.
    private func castMemberTile(_ member: TMDBClient.CastMember) -> some View {
        VStack(spacing: Theme.Space.xs) {
            castPhoto(member)
            Text(member.name)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let role = member.character, !role.isEmpty {
                Text(role)
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 92)
        .accessibilityElement(children: .combine)
    }

    /// One cast headshot: the TMDB profile photo in a circle, else an initials disc so the rail keeps
    /// its rhythm when a member has no photo (or TMDB never resolved).
    private func castPhoto(_ member: TMDBClient.CastMember) -> some View {
        AsyncImage(url: URL(string: member.profileURL ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Theme.Palette.surface2
                    Text(member.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined())
                        .font(Theme.Typography.label.weight(.semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.Palette.textPrimary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder private func creditLine(_ label: String, _ names: ArraySlice<String>) -> some View {
        if !names.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(label)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(width: 64, alignment: .leading)
                Text(names.joined(separator: ", "))
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Series — hero Resume/Play affordance (mirrors tvOS DetailView.seriesPrimaryEpisode)

    /// VortX's OWN watched episode-id set for the open series: the engine's computed set for
    /// engine-history profiles, the profile overlay's set otherwise — the exact same
    /// invariant tvOS uses for its ticks, dimming, and primary-episode pick.
    ///
    /// This is the AUTHORITATIVE set. Use it for any decision about the user's own place in the show
    /// (resume). `watchedSet` below adds the optional Trakt mirror on top for display.
    private var localWatchedSet: Set<String> {
        guard let m = meta else { return [] }
        return profiles.activeUsesEngineHistory
            ? (core.metaDetails?.watchedIds ?? [])
            : profiles.watchedVideoIds(forMeta: m.id)
    }

    /// `localWatchedSet` plus the episodes Trakt says are watched (opt-in import only, empty otherwise).
    /// Additive: the union can only ADD a tick to an episode VortX has no record of, never remove one, so
    /// the VortX account stays the authority on what you watched. Drives ticks, dimming, the first-unwatched
    /// season, and the show rollup. NOT the resume decision (see `seriesPrimaryEpisode`).
    private var watchedSet: Set<String> {
        guard let m = meta else { return [] }
        let local = localWatchedSet
        guard let videos = m.videos, !videos.isEmpty else { return local }
        return local.union(TraktEpisodeShadow.watchedVideoIDs(showIdentity: m.id, videos: videos))
    }

    /// Show-level watched rollup (issue #143): a series reads as watched once every AIRED, regular-season
    /// episode is watched, so unaired episodes and Season 0 specials never hold a finished show back, and a
    /// series whose episodes were MARKED (not played) still flips the poster badge even though the engine's
    /// library `times_watched` stays 0. Read-only: fed into WatchedIndex, never a write. Called on appear and
    /// whenever the watched set or the episode list changes.
    private func publishSeriesWatchRollup() {
        guard let m = meta, let videos = m.videos, !videos.isEmpty else { return }
        WatchedIndex.shared.noteSeriesWatched(m.id,
            isFullyWatched: SeriesWatched.isFullyWatched(videos: videos, watched: watchedSet))
    }

    /// Series hero: a primary "Resume S#E#" / "Play S#E#" button (with a progress stripe when the
    /// resume episode is partially watched), then the trailer + library chips — the touch/Mac twin
    /// of the tvOS series hero. Tapping it pushes that episode's source list (the same screen an
    /// episode-row tap opens), so the user still picks the source.
    @ViewBuilder private var seriesHeroActions: some View {
        let primary = meta?.videos.flatMap { seriesPrimaryEpisode($0) }
        let primaryProgress = primary.map { episodeProgress($0.video) } ?? 0
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // Full-width primary episode CTA on its own line (matches the movie Play button), with the
            // resume stripe just beneath it.
            if let m = meta, let primary {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    NavigationLink {
                        iOSEpisodeStreams(meta: m, video: primary.video, season: primary.video.season ?? 1,
                              seasonEpisodes: sortedEpisodes(m.videos ?? []))
                    } label: {
                        Label(primaryEpisodeLabel(primary.video, isResume: primary.isResume,
                                                  resumeSeconds: primary.isResume ? primaryEpisodeResumeSeconds : nil),
                              systemImage: "play.fill")
                    }
                    .buttonStyle(HeroPlayButtonStyle())
                    if primary.isResume, primaryProgress > 0.01 {
                        iOSProgressStripe(value: primaryProgress)
                            .frame(maxWidth: heroCtaMaxWidth)
                    }
                }
                // Same per-platform CTA cap as the movie Play button (#6): comfortable on Mac, wide on touch.
                .frame(maxWidth: heroCtaMaxWidth, alignment: .leading)
            }
            // Secondary actions wrap beneath. FlowLayout keeps each chip at its natural width and drops
            // overflow onto the next line under the hero's hard width cap (prevents "Tr / ail / er" slivers).
            FlowLayout(spacing: Theme.Space.sm) {
                #if !os(tvOS)
                // Offline (#30): open the pre-download quality picker for the primary episode — the series twin
                // of the movie Download chip. Gated on the primary episode resolving; the chip reflects state.
                if let primary {
                    downloadChip(videoId: primary.video.id, ready: true) {
                        Task { await presentSeriesDownloadPicker(primary.video) }
                    }
                }
                #endif
                trailerButton
                iOSLibraryChip()
                iOSWatchlistChip()
                ratingChip
                // "I'm watching this" on Trakt, for a cinema or someone else's TV. A series checks into an
                // EPISODE, so it passes the same episode the Play button above would start; the chip hides
                // itself when none has resolved, since a whole show cannot be checked into.
                TraktCheckinChip(season: primary?.video.season, episode: primary?.video.episode)
                shareChip
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    /// Resume position (the saved episode, if not yet watched) vs the first unwatched episode,
    /// vs the first episode — a straight port of the tvOS `seriesPrimaryEpisode`.
    /// The season of the episode the viewer was last on (from the resume videoId), decoupled from the
    /// watched-gate seriesPrimaryEpisode applies, so opening a series from Continue Watching lands on the season
    /// you were last in even after that episode is marked watched. nil when there is no resume position. Mirrors
    /// the tvOS DetailView helper; seriesPrimaryEpisode still drives the Resume/Play button unchanged.
    private func resumeSeasonHint(_ videos: [CoreVideo]) -> Int? {
        guard let m = meta else { return nil }
        let videoId: String? = profiles.activeUsesEngineHistory
            ? core.metaDetails?.libraryItem?.state.videoId
            : profiles.watch[m.id]?.videoId
        guard let videoId else { return nil }
        return sortedEpisodes(videos).first { $0.id == videoId }?.season
    }

    private func seriesPrimaryEpisode(_ videos: [CoreVideo]) -> (video: CoreVideo, isResume: Bool)? {
        guard let m = meta else { return nil }
        let sorted = sortedEpisodes(videos)
        let watched = watchedSet
        // Engine-history profiles read the engine library entry; overlay profiles their own entry,
        // exactly as resume / progress resolve everywhere else.
        let resume: (videoId: String?, timeOffsetMs: Double) = {
            guard profiles.activeUsesEngineHistory else {
                let entry = profiles.watch[m.id]
                return (entry?.videoId, Double(entry?.timeOffsetMs ?? 0))
            }
            let state = core.metaDetails?.libraryItem?.state
            return (state?.videoId, state?.timeOffset ?? 0)
        }()
        // RESUME is decided against VortX's OWN watched set, never the Trakt-unioned one. The resume
        // position and the local watched flag are two halves of one fact this device recorded: "you are
        // partway through this episode". A Trakt watched flag on that same episode is a staler claim from
        // an optional mirror (you finished it elsewhere, or on an account that scrobbles other devices),
        // and if it were allowed to answer here it would suppress the Resume button and jump the user to
        // the NEXT episode with their half-watched one silently abandoned. The VortX account is primary:
        // it alone decides where you are. Trakt only contributes below, to skip episodes VortX has no
        // record of at all.
        if resume.timeOffsetMs > 0,
           let videoId = resume.videoId,
           let video = sorted.first(where: { $0.id == videoId }),
           !localWatchedSet.contains(video.id) {
            return (video, true)
        }
        if let next = sorted.first(where: { !watched.contains($0.id) }) {
            return (next, false)
        }
        return sorted.first.map { ($0, false) }
    }

    private func primaryEpisodeLabel(_ video: CoreVideo, isResume: Bool, resumeSeconds: Double? = nil) -> String {
        let prefix = isResume ? String(localized: "Resume") : String(localized: "Play")
        let base: String = {
            guard let season = video.season else { return "\(prefix) \(String(localized: "Episode")) \(video.episodeNumber)" }
            return "\(prefix) S\(season) E\(video.episodeNumber)"
        }()
        // On a resume, append where playback picks up ("Resume S1 E3 · 1:03"); mirrors the movie button.
        if let timecode = resumeSeconds.flatMap(resumeTimecode) { return "\(base)  ·  \(timecode)" }
        return base
    }

    /// The saved resume position (seconds) for the series' primary episode, respecting the per-profile
    /// invariant: engine-history profiles read the engine library item's `timeOffset`; overlay profiles
    /// read their own entry. Read-only. Nil when the parked episode isn't the primary or there is none.
    private var primaryEpisodeResumeSeconds: Double? {
        guard let m = meta else { return nil }
        let saved: (videoId: String?, timeOffsetMs: Double) = {
            guard profiles.activeUsesEngineHistory else {
                let entry = profiles.watch[m.id]
                return (entry?.videoId, Double(entry?.timeOffsetMs ?? 0))
            }
            let state = core.metaDetails?.libraryItem?.state
            return (state?.videoId, state?.timeOffset ?? 0)
        }()
        guard saved.timeOffsetMs > 0 else { return nil }
        return saved.timeOffsetMs / 1000
    }

    private func sortedEpisodes(_ videos: [CoreVideo]) -> [CoreVideo] {
        videos.sorted {
            let leftSeason = $0.season ?? 0
            let rightSeason = $1.season ?? 0
            if leftSeason != rightSeason { return leftSeason < rightSeason }
            let leftEpisode = $0.episode ?? 0
            let rightEpisode = $1.episode ?? 0
            if leftEpisode != rightEpisode { return leftEpisode < rightEpisode }
            return $0.id < $1.id
        }
    }

    /// First-unwatched season in air order, used for the initial season selection.
    private var firstUnwatchedSeason: Int? {
        guard let videos = meta?.videos else { return nil }
        let watched = watchedSet
        return sortedEpisodes(videos).first { !watched.contains($0.id) }?.season
    }

    /// Apply the preferred episode-list season: the Continue-Watching resume-season hint, else first-unwatched,
    /// else the first non-special, else 1. Re-applies (guarded by didApplySeason so a manual tap wins) until it
    /// lands on a season present in `seasons`, so a large series whose episodes stream in after the list first
    /// appears still opens on the season you were last watching. Mirrors the tvOS CoreSeasonedEpisodes resolver.
    private func applyEpisodeSeason(_ seasons: [Int]) {
        guard let videos = meta?.videos else { return }
        if !didApplySeason {
            let preferred = resumeSeasonHint(videos) ?? firstUnwatchedSeason ?? seasons.first { $0 > 0 } ?? seasons.first ?? 1
            if seasons.contains(preferred) { season = preferred }   // triggers onChange(season) -> didApplySeason = true
        }
        if !seasons.contains(season) { season = seasons.first { $0 > 0 } ?? seasons.first ?? 1 }
    }

    /// 0…1 watch progress for one episode (overlay or engine source, matching the resume invariant).
    private func episodeProgress(_ v: CoreVideo) -> Double {
        guard let m = meta else { return 0 }
        guard profiles.activeUsesEngineHistory else {
            guard let entry = profiles.watch[m.id], entry.videoId == v.id else { return 0 }
            return entry.progress
        }
        guard let item = core.metaDetails?.libraryItem,
              item.state.videoId == v.id,
              item.state.duration > 0 else { return 0 }
        return min(max(item.state.timeOffset / item.state.duration, 0), 1)
    }

    /// Share chip: shares the title's IMDb page (or its name when there is no imdb id) via the native
    /// share sheet. Shown in the movie action row and the series hero.
    @ViewBuilder private var shareChip: some View {
        if let m = meta {
            if m.id.hasPrefix("tt"), let url = URL(string: "https://www.imdb.com/title/\(m.id)/") {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(ChipButtonStyle())
            } else {
                ShareLink(item: m.name) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(ChipButtonStyle())
            }
        }
    }

    /// Copy every playable (direct / debrid / HLS) stream link for this title to the clipboard, newline
    /// separated, for pasting into a debrid panel or another player. Torrent sources with no direct URL are
    /// skipped (they only resolve through the embedded server at play time).
    private func copyAllLinks(_ groups: [CoreStreamSourceGroup]) {
        let urls = groups.flatMap { $0.streams }.compactMap { $0.playableURL?.absoluteString }
        guard !urls.isEmpty else { return }
        let text = urls.joined(separator: "\n")
        #if os(macOS)
        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    // MARK: Movie — Watch Now + sources

    /// The movie hero action row — the touch/Mac twin of the tvOS detail action set: a **Watch**
    /// button (best ranked source), a **Quality** picker (resolution tier → flavour variants), a
    /// **Sources** button (scrolls to the grouped per-add-on list below), and **Add to Library**,
    /// plus the trailer chip when one exists. Wraps onto a second line on a narrow phone.
    @ViewBuilder private func watchNow(scrollToSources: @escaping () -> Void) -> some View {
        let groups = rankedMovie().groups
        let sourceTotal = groups.reduce(0) { $0 + $1.streams.count }
        // FlowLayout so the action chips wrap to a new line on a narrow phone instead of compressing into
        // vertical slivers ("Sou / rce") under the hero's hard width cap.
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // The primary CTA is a big, high-contrast rounded Play button on its own line, the
            // cinematic-media-app hero action, no longer one small chip lost in a wrapping row.
            // Width-capped per platform (heroCtaMaxWidth) so it doesn't span the whole Mac window (#6).
            Button {
                Task { await playMovie() }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    // Spin while resolving (preparing) AND while still waiting on add-ons, so the gated
                    // "Finding best… X/Y" state reads as busy, matching the source-list control bar.
                    if preparing || movieLoadingSources { ProgressView().tint(Theme.Palette.onAccent) }
                    else { Image(systemName: "play.fill") }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(movieLabel)
                        // #11: the selected source's spec line rides inside the CTA (resolution ·
                        // DV/HDR · flavor · size), so one glance says WHAT Play will play.
                        if movieReady, let s = movieBest, let detail = primarySourceDetail(s) {
                            Text(detail)
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.onAccent.opacity(0.82))
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            }
            .buttonStyle(HeroPlayButtonStyle())
            .disabled(!movieReady || preparing)
            .opacity(movieReady || preparing ? 1 : 0.55)
            .frame(maxWidth: heroCtaMaxWidth, alignment: .leading)

            // D10: a secondary "Play from start" beside the primary "Resume · 1:03", shown only when a saved
            // resume position exists. Plays the SAME best stream from 0:00 without clearing the stored resume
            // point (the primary Resume still seeks to the saved position). Hidden for a fresh title (nothing
            // to restart) and while sources are still resolving.
            if movieReady, movieResumeSeconds != nil {
                Button { Task { await playMovie(fromStart: true) } } label: {
                    Label("Play from start", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(preparing)
            }

            // "Resume from 41:23": a position Trakt holds from another device that is ahead of this one's.
            // A SUGGESTION, never an override: the primary CTA above still plays from THIS device's own
            // saved position, and tapping this only changes where this one playback begins (the same seam
            // "Play from start" uses). Nothing here writes engine state, the account, or Trakt. Hidden
            // unless the user opted in, and hidden while sources resolve so it can never be a dead press.
            if movieReady, let suggestion = movieTraktSuggestionSeconds,
               let stamp = resumeTimecode(suggestion) {
                Button { Task { await playMovie(startAt: suggestion) } } label: {
                    Label("Resume from \(stamp)", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(preparing)
            }

            // Secondary actions wrap beneath the CTA. FlowLayout keeps each chip at its natural width and
            // drops overflow onto the next line under the hero's hard width cap.
            FlowLayout(spacing: Theme.Space.sm) {
                qualityMenu(groups)

                #if !os(tvOS)
                // Offline (#30): open the pre-download quality picker, the offline twin of Watch Now. The chip
                // reflects state (idle / Downloading / Downloaded) so a tap gives visible feedback; `movieReady`
                // guarantees the sources are loaded when it fires (the source-list precondition).
                downloadChip(videoId: meta?.id ?? id, ready: movieReady) { presentMovieDownloadPicker() }
                #endif

                Button { scrollToSources() } label: {
                    Label(sourceTotal > 0 ? "Sources · \(sourceTotal)" : "Sources",
                          systemImage: "list.bullet")
                }
                .buttonStyle(ChipButtonStyle())

                trailerButton
                iOSLibraryChip()
                iOSWatchlistChip()
                ratingChip
                // "I'm watching this" on Trakt, for a cinema or someone else's TV. A movie checks in whole,
                // so there is no episode to pass.
                TraktCheckinChip()
                shareChip
            }
            // #16: why the recommended source was auto-picked - the rank decision the per-row tags don't show.
            if movieReady, let s = movieBest, let reason = StreamRanking.pickReason(s) {
                Text("Picked for \(reason)")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    /// Two-level Quality picker for the hero action row: resolution tier (4K / 1080p / 720p / Others),
    /// then the flavour variants inside it (Dolby Vision · Remux, HDR · Atmos, …). A native `Menu` with
    /// submenus is the touch/Mac idiom for the tvOS two-step quality `confirmationDialog`. Plays the
    /// chosen source straight through `playStream`. Hidden until at least one tier resolves.
    @ViewBuilder private func qualityMenu(_ groups: [CoreStreamSourceGroup]) -> some View {
        let tiers = sourceList.tiers
        if !tiers.isEmpty {
            Menu {
                ForEach(tiers, id: \.self) { tier in
                    Menu(tier) {
                        ForEach(StreamRanking.variantOptions(groups, tier: tier), id: \.label) { option in
                            if let url = option.stream.playableURL {
                                Button(option.label) { Task { await playStream(option.stream, url: url) } }
                            }
                        }
                    }
                }
                Divider()
                Button { copyAllLinks(groups) } label: { Label("Copy all links", systemImage: "doc.on.doc") }
            } label: {
                Label("Quality", systemImage: "chevron.up.chevron.down")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    /// The full source list for a movie. The presentation now mirrors tvOS: a quality picker, an
    /// "All sources" toggle, per-add-on filter chips, and the streams grouped under collapsible
    /// per-add-on headers (so a title returning thousands of sources doesn't bury one add-on). The
    /// component owns the filter / collapse state; it plays a chosen source through `playStream`.
    @ViewBuilder private var sourceSection: some View {
        // While the player/trailer cover is up, skip the expensive rankedGroups(displayGroups(...)) pass and
        // pass an empty list + isSuspended, so the mounted-but-hidden detail stops rebuilding the source list
        // behind the video. The list restores unchanged on player close (presentation flips back to nil).
        let suspended = presentation != nil
        iOSSourceList(
            groups: suspended ? [] : rankedMovie().groups,
            progress: core.streamLoadProgress(),
            states: core.streamAddonStates(),
            settleTimedOut: settleTimedOut,
            continuity: rememberedQuality,
            pinContext: pinContext,
            cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs,
            // Hero already shows Watch + Quality + the "Sources" scroll button, so suppress this list's
            // duplicate control bar; the grouped per-add-on list shows directly instead.
            showsPrimaryControls: false,
            play: { stream, url in Task { await playStream(stream, url: url) } },
            bestStream: sourceList.best,
            resolutionTiers: sourceList.tiers,
            download: movieDownloadHandler,
            isSuspended: suspended
        )
        // Equatable gate: unrelated detail re-renders (progress ticks, hero state) skip re-diffing the
        // 1000+ row list; the groups compare is a buffer-identity fast path until the model republishes.
        .equatable()
        .padding(.horizontal, Theme.Space.md)
    }

    /// The per-row offline-download handler passed to the movie source list — present on iPhone/iPad/Mac,
    /// nil on tvOS (downloads are deferred there), so the list renders no Download affordance on tvOS.
    private var movieDownloadHandler: ((CoreStream, URL) -> Void)? {
        #if os(tvOS)
        return nil
        #else
        return { stream, url in Task { await downloadStream(stream, url: url) } }
        #endif
    }

    /// The id to dispatch a movie/live stream request with: the meta's imdb `defaultVideoId` (tt...) when
    /// the catalog id is non-imdb (tmdb:/kitsu:), else the catalog id. Falls back to the catalog id before
    /// the meta is loaded. This is what makes imdb-keyed stream add-ons match (the engine's own guess_stream
    /// uses the same default_video_id; we lost it by moving movies to an explicit streamPath).
    /// ID-FENCED (REQ-260721-30): it reads the meta only when that meta's own id is this page's id. It used
    /// to read the shared singleton directly, AROUND the residency guard, so title B could dispatch title A's
    /// still-resident default video id.
    ///
    /// It is deliberately NOT the pool identity. The pool key is a canonical title head; a stream request must
    /// carry the add-on's OWN video id verbatim, coordinates included, or imdb-keyed add-ons stop matching.
    /// Same title, different required shape: do not "unify" these two by canonicalizing this one.
    private var movieStreamId: String {
        if let dv = meta?.behaviorHints?.defaultVideoId, !dv.isEmpty, dv != id { return dv }
        return id
    }

    /// Dispatch the movie/live stream request with the imdb-preferring stream id, unless those streams are
    /// already resident. No-op for series and until this title's meta has loaded (so movieStreamId can read
    /// the imdb defaultVideoId). The hasStreams guard keys on the EFFECTIVE id, so a re-dispatch loop can't
    /// form once the imdb-keyed streams arrive.
    private func loadMovieStreamsIfNeeded() {
        guard effectiveType != "series" else { return }
        // Relaxed guard (build 137): the old `meta?.id == id` gate blocked streams whenever Cinemeta meta
        // was nil (a brand-new/unreleased title: tt at TMDB, not yet in Cinemeta -> "No sources found"
        // even though imdb-keyed add-ons would answer the tt). Fire streams either when this title's meta
        // is resident (the normal imdb-defaultVideoId path) OR, when meta is still absent, directly on the
        // catalog id IF it is itself an imdb tt id (the hub-card case). Non-imdb ids without meta still wait
        // (their stream id only resolves from the meta's defaultVideoId). The hasStreams guard keys on the
        // effective id, so this can't form a re-dispatch loop once the streams arrive.
        let metaResident = meta != nil
        guard metaResident || id.hasPrefix("tt") else { return }
        let streamId = movieStreamId
        // Either surface counts as resident: meta-embedded streams (metaStreams, #122) are keyed by the
        // same stream path id, and their presence means the engine already selected this id.
        let hasStreams = core.metaDetails?.allStreamGroups.contains { $0.request.path.id == streamId } ?? false
        guard !hasStreams else { return }
        // Dispatch under the AUTHORITATIVE type (meta.type when resident), NOT the hub's TMDB movie/tv guess,
        // so a TV-movie / mini-series / anime the hub mis-typed still matches the add-on that indexes it. Log
        // a correction so a device/sim test can spot any residual (e.g. meta that never resolved under the guess).
        if effectiveType != type { NSLog("[detail] stream type corrected: hub-guess=%@ -> meta=%@ id=%@", type, effectiveType, id) }
        core.loadMeta(type: effectiveType, id: id, streamType: effectiveType, streamId: streamId)
    }

    /// The IMDb id to fetch MDBList ratings for: prefer the meta's imdb `defaultVideoId` (tt...) when the
    /// catalog id is non-imdb (tmdb:/kitsu:), else the catalog id when it is itself an imdb id.
    private var ratingsImdbID: String? {
        if let dv = meta?.behaviorHints?.defaultVideoId, dv.hasPrefix("tt") { return dv }
        return id.hasPrefix("tt") ? id : nil
    }

    /// The numeric TMDB id when this page was opened from a TMDB-keyed catalog ("tmdb:123",
    /// "tmdb:movie:123"). Carried alongside `ratingsImdbID` so a title whose tt id has not resolved (or
    /// does not exist) can still be rated, and so the rating stays findable once the tt id does arrive.
    /// Same extraction rule as `ScrobbleCoordinator.numericTMDB`, applied to the catalog id.
    /// The page's TWO resolved identities for the source paths, from the ONE shared resolver. Deliberately
    /// separate from `ratingsImdbID`: ratings, credits, and the subtitle fingerprint key on that value and are
    /// not part of this defect, while the pool and the IMDb-keyed TorBox index need a canonicalized title id
    /// (and the pool can additionally use a tmdb one). tvOS twin: DetailView.swift `CoreStreamList`.
    private var identityRoles: SourceIndexIdentity.Roles {
        SourceIndexIdentity.Roles(
            catalogID: id,
            defaultVideoID: meta?.behaviorHints?.defaultVideoId,
            currentVideoID: nil,
            kind: SourceIndexIdentity.ContentKind.from(type: effectiveType, liveTypes: LiveTypes.all)
        )
    }

    /// The page's resolved IMDb identity. ONE value: pool and TorBox take the same IMDb-only key.
    private var titleIdentity: SourceIndexIdentity.Resolved {
        SourceIndexIdentity.resolve(identityRoles)
    }

    private var ratingTMDBID: Int? {
        guard id.lowercased().hasPrefix("tmdb") else { return nil }
        return id.lowercased().split(separator: ":").compactMap { Int($0) }.first
    }

    /// "Your rating" chip. The SHARED control (SourcesShared/TraktRatingControl.swift), the same view the
    /// Apple TV detail page mounts, so the two surfaces cannot drift. It renders nothing unless Trakt is
    /// configured + connected and the ratings toggle is on, so this is a no-op on a credential-less build.
    /// Series rate at the SHOW level, matching the title-level watchlist writes.
    @ViewBuilder private var ratingChip: some View {
        TraktRatingChip(imdb: ratingsImdbID, tmdb: ratingTMDBID, isSeries: effectiveType == "series")
    }

    /// The pool `content_key` for this title (P1). Movies key on the imdb id; a series detail keys on the
    /// show id (no season/episode here, since the detail page lists all sources across episodes). nil when
    /// no imdb id is known — the whole language-chip feature then no-ops.
    private var languageContentKey: String? {
        SubtitleReleaseFingerprint.contentKey(imdbId: ratingsImdbID)
    }

    /// P1: compute the "Also available in" chips from (a) the languages PARSED from the loaded stream names
    /// and (b) the crowd-sourced language index, then fire-and-forget a name-provenance contribution. Gated
    /// on `features.languageIndex` inside the clients; de-duped per title + loaded-stream-count so it re-runs
    /// as sources arrive. Fail-soft: any miss leaves the row hidden.
    private func refreshLanguageChips() {
        // Gate the whole compute (incl. the TMDB spoken_languages verify fetch) on the master feature flag, so
        // it is a hard no-op when off rather than relying only on the per-client internal no-ops.
        guard LanguageIndexClient.isEnabled, let contentKey = languageContentKey else { return }
        // Cheap main-thread dedup: an integer stream count over the per-profile filtered snapshot, NO per-stream
        // string/regex work. The O(N) name flatten + the ~10^5-regex audioSubCodes parse both move off the main
        // thread below, so this gate can no longer stall the render even when it fires per loaded tick.
        let snapshot = displayGroups(core.streamGroups())      // per-profile filtered, value-type snapshot on main
        let streamCount = snapshot.reduce(0) { $0 + $1.streams.count }
        let key = "\(contentKey)#\(streamCount)"
        guard key != langChipsKey else { return }
        langChipsKey = key
        let imdb = ratingsImdbID
        let mediaType = type
        langChipsDebounce?.cancel()                            // supersede any in-flight settle
        langChipsDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.langChipsDebounceMs))
            guard !Task.isCancelled, languageContentKey == contentKey else { return }   // title switched during settle
            // AGGREGATE across EVERY loaded source for this title (all add-ons), scanning BOTH the stream `name`
            // AND its `description`, then split into AUDIO vs SUBTITLE claims. The heavy flatten + regex parse
            // runs OFF the main thread; audioSubCodes is pure/static so it is safe to call from the detached task.
            let observed = await Task.detached(priority: .utility) { () -> (audio: [String], sub: [String]) in
                let names = snapshot.flatMap { $0.streams }
                    .flatMap { [$0.name, $0.description] }
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                return LanguageIndexClient.audioSubCodes(fromNames: names)
            }.value
            guard languageContentKey == contentKey else { return }
            // Fetch the community index AND TMDB's real spoken_languages in PARALLEL: the two verification
            // sources for a name-parsed audio claim. Both fail soft to nil (no signal), never falsely contradict.
            async let availabilityTask = LanguageIndexClient.fetch(contentKey: contentKey)
            async let spokenTask = TMDBClient.spokenLanguages(imdbID: imdb, type: mediaType)
            let availability = await availabilityTask
            let tmdbSpoken = await spokenTask
            guard languageContentKey == contentKey else { return }   // title switched mid-fetch
            // VERIFY: drop a name-only AUDIO language that BOTH TMDB (not in spoken_languages) and the community
            // (no/low count) contradict -- the false-claim fix. Subtitle + community + TMDB codes are kept.
            // The chip row is horizontally scrollable now (#8), so a wider cap fits without clutter.
            langChips = LanguageIndexClient.verifiedAvailabilityChips(observedAudio: observed.audio,
                                                                      observedSub: observed.sub,
                                                                      availability: availability,
                                                                      tmdbSpoken: tmdbSpoken,
                                                                      limit: 24)
            // Fire-and-forget: contribute the name-parsed codes so the index learns from real users.
            Task.detached {
                await LanguageIndexClient.contribute(contentKey: contentKey,
                                                     audioLangs: observed.audio,
                                                     subLangs: observed.sub,
                                                     provenance: "name")
            }
        }
    }

    /// Community source index (movie/live): the SERVE + HOARD driver. SERVE refreshes the pooled community
    /// sources for the title (gated on the Singularity toggle + sign-in inside the client), and HOARD
    /// fire-and-forgets the assembled source descriptors so the pool learns from this resolve. Both are
    /// fully gated + fail-soft in `SourceIndexClient` (consent / fleet flag / toggle / login), so this is a
    /// hard no-op when the feature is off. De-duped per title; safe to call as sources stream in.
    ///
    /// SIGN-IN IDENTITY: the SERVE read is gated on the VORTX-SYNC account, not the Stremio account. The moat
    /// token that un-gates `sources.vortx.tv` is minted from the VortX session bearer (`VortXSyncManager`), so
    /// a Stremio-only sign-in mints no token and the worker returns an empty `login_required` list. Gate on the
    /// same identity that mints the token so a signed-in VortX user actually sees pooled sources.
    private var auxiliaryTarget: SourceIndexIdentity.TargetResolution {
        SourceIndexIdentity.publicationTarget(identityRoles)
    }

    private var sourceContentID: String? {
        auxiliaryTarget.target?.contentID
    }

    /// Media-server lookup also supports IMDb-less title matching. Its merge fence therefore uses an exact
    /// page token even when the indexed contributors have no canonical query id.
    private var mediaServerTargetID: String {
        sourceContentID ?? "meta:\(id)"
    }

    private func refreshSourceIndex(
        torboxMerged: [CoreStreamSourceGroup]? = nil,
        refreshContributors: Bool = true
    ) {
        let target = auxiliaryTarget
        let snapshot: AuxiliarySourcePipeline.Snapshot
        if refreshContributors {
            let receipt = AuxiliarySourcePipeline.refresh(
                target: target,
                torBox: torboxSearch,
                sourceIndex: sourceIndex,
                isSignedIn: VortXSyncManager.shared.isSignedIn
            )
            snapshot = AuxiliarySourcePipeline.snapshot(
                receipt: receipt,
                torBox: torboxSearch,
                sourceIndex: sourceIndex
            )
        } else {
            snapshot = AuxiliarySourcePipeline.snapshot(
                target: target,
                torBox: torboxSearch,
                sourceIndex: sourceIndex
            )
        }
        guard snapshot.target != nil else { return }
        // HOARD: report the anonymized descriptors from the UNFILTERED assembled groups (the pool should see
        // torrents even when the user hides them locally). Includes the TorBox search sources. No user data.
        // Pool-EXCLUDED: the caller's torbox-base when it already merged one, else self-merge. NEVER the
        // Singularity-pool-inclusive set: hoarding the pool's own results back into itself would be wrong.
        let groups = torboxMerged ?? AuxiliarySourcePipeline.torBoxMerged(
            into: core.streamGroups(),
            snapshot: snapshot
        )
        guard !groups.isEmpty else { return }
        Task.detached { await AuxiliarySourcePipeline.hoard(target: target, groups: groups) }
    }

    /// Trailing-debounced driver for the movie/live add-on load storm: the raw `.onChange` fired per add-on
    /// completion, each doing full O(N) merge walks on main. Coalesce to one pass ~400 ms after the burst
    /// settles, computing the torbox-base ONCE so the debrid (pool-inclusive) and hoard (pool-excluded) sets
    /// share it. Cache awareness reads the pool-INCLUDED set (raw torrents / usenet nzbs the Direct-links-only
    /// filter would drop are exactly what the native cache-check needs; orthogonal to the playback filter).
    private func scheduleSourceRefresh() {
        sourceRefreshDebounce?.cancel()
        sourceRefreshDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.sourceRefreshDebounceMs))
            guard !Task.isCancelled else { return }
            let target = auxiliaryTarget
            let snapshot = AuxiliarySourcePipeline.snapshot(
                target: target,
                torBox: torboxSearch,
                sourceIndex: sourceIndex
            )
            let torboxBase = AuxiliarySourcePipeline.torBoxMerged(
                into: core.streamGroups(),
                snapshot: snapshot
            )   // pool-EXCLUDED (hoard set)
            debridCache.refresh(from: AuxiliarySourcePipeline.sourceIndexMerged(
                into: torboxBase,
                snapshot: snapshot
            ))   // pool-INCLUDED (debrid set)
            refreshSourceIndex(torboxMerged: torboxBase, refreshContributors: false)
        }
    }

    /// Fetch cross-provider ratings for this title. Prefers the VortX ratings service (no user key
    /// needed: IMDb keyless, RT/Metacritic via VortX's server-side key), then fills any gap from the
    /// user's own MDBList key if they set one. Fail-soft: leaves the row hidden on any miss. Skipped for
    /// live channels, which carry no ratings.
    private func loadRatings() {
        guard !LiveTypes.contains(type), let imdb = ratingsImdbID, mdbRatings == nil else { return }
        Task {
            let vx = await VortXRatingsClient.ratings(imdbID: imdb, type: type)
            // Only reach for the user's MDBList key to fill what VortX did not return (e.g. RT / Metacritic
            // before the server key is set), so most users need no key at all.
            let needsMore = vx == nil || vx?.rottenTomatoes == nil || vx?.metacritic == nil
            let mdb = needsMore ? await MDBListClient.ratings(imdbID: imdb, type: type) : nil
            let merged = MDBListRatings(
                imdb: vx?.imdb ?? mdb?.imdb,
                rottenTomatoes: vx?.rottenTomatoes ?? mdb?.rottenTomatoes,
                metacritic: vx?.metacritic ?? mdb?.metacritic,
                tmdb: vx?.tmdb ?? mdb?.tmdb
            )
            await MainActor.run { mdbRatings = merged.hasAny ? merged : nil }
        }
    }

    /// Compact cross-provider ratings row ("IMDb 8.5  ·  RT 92%  ·  TMDB 78%"), fed by the VortX ratings
    /// service (no user key needed), with the user's MDBList key filling any gap. Shown only when ratings
    /// came back; renders nothing otherwise (no error UI). Same typography as metaRow.
    @ViewBuilder private var ratingsRow: some View {
        if let text = mdbRatings.flatMap(Self.mdbRatingsText), !text.isEmpty {
            Text(text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Build the joined ratings string from the decoded model, or nil when nothing is present.
    private static func mdbRatingsText(_ r: MDBListRatings) -> String? {
        var parts: [String] = []
        if let v = r.imdb { parts.append("IMDb \(mdbImdbFmt.string(from: NSNumber(value: v)) ?? String(v))") }
        if let v = r.rottenTomatoes { parts.append("RT \(v)%") }
        if let v = r.metacritic { parts.append("MC \(v)") }
        if let v = r.tmdb { parts.append("TMDB \(v)%") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// Fetch the movie budget + box office (no-op for series / no key / no imdb id). Fail-soft; the row hides on a miss.
    private func loadFinancials() {
        guard showFinancials, type != "series", let imdb = ratingsImdbID, financials == nil else { return }
        Task {
            let f = await TMDBClient.details(imdbID: imdb, type: type)
            await MainActor.run { financials = f }
        }
    }

    /// Fetch the full cast (who-played-who + headshots) and TMDB's overview fallback from the keyless
    /// credits edge path (#10). Keyed per imdb id so meta arriving after the tt-only first load doesn't
    /// refetch; works with meta=nil (hub-seeded tt not yet in Cinemeta). Fail-soft: a miss leaves the
    /// meta-cast fallback rail + empty overview.
    private func loadCredits() {
        guard !LiveTypes.contains(type), let imdb = ratingsImdbID, creditsKey != imdb else { return }
        creditsKey = imdb
        Task {
            guard let result = await TMDBClient.credits(imdbID: imdb, type: effectiveType) else { return }
            await MainActor.run {
                guard creditsKey == imdb else { return }   // title switched mid-fetch
                if !result.cast.isEmpty { castMembers = result.cast }
                if fallbackOverview == nil { fallbackOverview = result.overview }
            }
        }
    }

    /// Fetch this movie's franchise/collection (TMDB belongs_to_collection -> parts, release order) from the
    /// keyless edge. Movies only; keyed per imdb id so meta arriving after the tt-only first load doesn't
    /// refetch (works with meta=nil for a hub-seeded tt). Fail-soft: a standalone film / miss leaves the row hidden.
    private func loadCollection() {
        guard effectiveType != "series", let imdb = ratingsImdbID, collectionKey != imdb else { return }
        collectionKey = imdb
        Task {
            let result = await TMDBClient.movieCollection(imdbID: imdb, type: effectiveType)
            await MainActor.run {
                guard collectionKey == imdb else { return }   // title switched mid-fetch
                collection = result
            }
        }
    }

    /// Fetch theatrical + digital release dates (no-op for series / no key / no imdb id). Fail-soft; the row hides on a miss.
    private func loadReleaseDates() {
        guard type != "series", let imdb = ratingsImdbID, releaseDates == nil else { return }
        Task {
            let d = await TMDBClient.releaseDates(imdbID: imdb, type: type)
            await MainActor.run { releaseDates = d }
        }
    }

    /// Movie budget + box office (+ profit multiple), a fact line under the ratings. Opt-out via the
    /// "Show budget & box office" setting; movies-only, hidden when TMDB has no figures.
    @ViewBuilder private var financialsRow: some View {
        if showFinancials, type != "series", let f = financials {
            let text = Self.financialsText(f)
            if !text.isEmpty {
                Text(text)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// "Budget $200M  ·  Box Office $1.4B  ·  Profit 7.0x" - both values (Arvio shows budget only) plus a profit multiple.
    private static func financialsText(_ f: TMDBClient.Financials) -> String {
        var parts: [String] = []
        if let b = TMDBClient.shortMoney(f.budget) { parts.append("Budget \(b)") }
        if let r = TMDBClient.shortMoney(f.revenue) { parts.append("Box Office \(r)") }
        if f.budget > 0, f.revenue > 0 { parts.append(String(format: "Profit %.1fx", Double(f.revenue) / Double(f.budget))) }
        return parts.joined(separator: "  ·  ")
    }

    /// "In theaters Mar 1, 2024  ·  Digital May 21, 2024" - both dates, each shown only when TMDB has it. Movies only.
    @ViewBuilder private var releaseDatesRow: some View {
        if type != "series", let d = releaseDates {
            let text = Self.releaseDatesText(d)
            if !text.isEmpty {
                Text(text)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func releaseDatesText(_ d: TMDBClient.ReleaseDates) -> String {
        var parts: [String] = []
        if let t = d.theatrical { parts.append("In theaters \(t)") }
        if let g = d.digital { parts.append("Digital \(g)") }
        return parts.joined(separator: "  ·  ")
    }

    /// One-decimal IMDb formatter (8.5, not 8.50). `static let` to avoid per-row allocation.
    private static let mdbImdbFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    /// Apply the Direct-links-only filter (drop every torrent source) so a user with the setting on
    /// never sees or auto-plays a torrent — the exact `displayGroups` the tvOS `CoreStreamList` uses.
    private func displayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        // Merge the TorBox search sources FIRST (no-op with no TorBox key / no results), then the community
        // source-index sources (no-op unless the Singularity toggle is on + signed in), then apply the
        // Direct-links-only filter so a search/community torrent source is filtered on the same rule as an
        // add-on's — keeps the filter contract intact.
        let snapshot = AuxiliarySourcePipeline.snapshot(
            target: auxiliaryTarget,
            torBox: torboxSearch,
            sourceIndex: sourceIndex
        )
        let withSearch = AuxiliarySourcePipeline.merged(into: groups, snapshot: snapshot)
        guard PlaybackSettings.directLinksOnly else { return withSearch }
        return withSearch.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            guard !streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    /// The quality signature this title last played in (per profile), so reopening it auto-picks the
    /// remembered quality with same-release-group biasing — the tvOS `LastStreamStore` continuity hint.
    private var rememberedQuality: String? {
        guard let m = meta else { return nil }
        return LastStreamStore.entry(for: m.id, profileID: ProfileStore.shared.activeID)?.qualityText
    }

    /// The ranked groups + best for the MOVIE source set, read from `SourceListModel`'s published
    /// output. The old per-body-eval assembly (streamGroups rebuild + merges + an O(N) signature
    /// string over every stream) is gone: setContext is a handful of cheap reads behind an equality
    /// guard, and the heavy assemble + rank happens off-main inside the model, once per real change.
    private func rankedMovie() -> (groups: [CoreStreamSourceGroup], best: CoreStream?) {
        sourceList.setContext(
            metaId: id, streamId: nil, continuity: rememberedQuality, pin: sourcePin,
            auxiliaryTarget: auxiliaryTarget,
            mediaServerTargetID: mediaServerTargetID
        )
        return (sourceList.groups, sourceList.best)
    }

    /// The ranked groups for the LIVE source set. rankedGroups ignores continuity, so the group order
    /// is identical to the movie set's; live consumes only `groups` (never `best`), and a screen is
    /// either the live page or the movie page, so the one model serves both without a cache clash.
    private func rankedLive() -> [CoreStreamSourceGroup] {
        sourceList.setContext(
            metaId: id, streamId: nil, continuity: nil, pin: sourcePin,
            auxiliaryTarget: auxiliaryTarget,
            mediaServerTargetID: mediaServerTargetID
        )
        return sourceList.groups
    }

    /// The best source for the movie, honoring Direct-links-only and the remembered-quality continuity.
    private var movieBest: CoreStream? {
        rankedMovie().best
    }

    /// Whether stream add-ons are still answering for this movie. Mirrors the tvOS Watch-Now gate:
    /// total == 0 means no add-on has reported yet; loaded < total means some are still in flight. The
    /// settle timeout opens the gate even if one add-on hangs.
    private var movieLoadingSources: Bool {
        guard !settleTimedOut else { return false }
        let p = core.streamLoadProgress()
        return p.total == 0 || p.loaded < p.total
    }

    /// Watch-Now arms once a best stream has resolved and sources have settled. A4b: this is NO LONGER gated
    /// on `meta != nil` — a hub-opened title whose Cinemeta meta is nil/mismatched (a tt at TMDB not yet in
    /// Cinemeta) still assembles its `streamGroups` (the sources LIST renders from them unconditionally), so
    /// Play must arm off the SAME groups the list shows, not a meta-gated path, or the button would sit
    /// disabled forever while the sources below are fully playable. Playback identity falls back to the seed
    /// id/title (`moviePlaybackMeta`) when meta is nil.
    private var movieReady: Bool { movieBest != nil && !movieLoadingSources }

    /// The movie's playback identity, resolved from the loaded meta when present, else the seed id/title/type
    /// carried from the hub card (A4b: a hub-opened title with nil/mismatched Cinemeta meta still plays and
    /// records CW off its seed identity, mirroring `downloadStream`'s meta-or-seed fallback).
    private var moviePlaybackMeta: PlaybackMeta {
        let m = meta
        return PlaybackMeta(libraryId: m?.id ?? id, videoId: m?.id ?? id, type: "movie",
                            name: m?.name ?? title, poster: m?.poster ?? seedBackdrop, season: nil, episode: nil)
    }

    /// The movie's saved resume position in seconds, or nil when there is none. Reads the SAME
    /// per-profile source `playMovie`'s `resume(_:)` uses (the engine library item for engine-history
    /// profiles via `engineResumeSeconds`, the overlay's own entry otherwise via `ProfileStore.resumeOffset`),
    /// so the button label and the seek it triggers always agree. Read-only; writes nothing. A4b: keys off the
    /// meta-or-seed identity so a hub-opened title with nil meta still surfaces its resume point.
    private var movieResumeSeconds: Double? {
        let pm = moviePlaybackMeta
        let secs = core.engineResumeSeconds(for: pm) ?? profiles.resumeOffset(for: pm)
        return secs >= 1 ? secs : nil
    }

    /// The runtime used to turn Trakt's playback PERCENT into a timecode. Prefers the engine's real
    /// duration (mpv-measured, present once this title has played here) and falls back to the meta's
    /// PROVISIONAL `runtime` string. nil when neither is known, which suppresses the chip entirely: we
    /// never render a timecode we cannot actually compute. (`state.duration` is milliseconds, like
    /// `state.timeOffset`; see LibraryPortability's `durationMs: Int(state.duration)`.)
    private var movieDurationSeconds: Double? {
        if let d = core.metaDetails?.libraryItem?.state.duration, d > 0 { return d / 1000.0 }
        return meta?.runtimeSeconds
    }

    /// A position Trakt holds from ANOTHER device that is worth offering, or nil. Read-only and advisory:
    /// this is NOT consulted by `movieResumeSeconds` or by `playMovie`'s own `resume(_:)`, so the primary
    /// Resume button is byte-identical with or without Trakt. All of the policy (toggle, staleness band,
    /// clamps) lives in `TraktPlaybackShadow` so iOS and tvOS cannot drift apart on it.
    private var movieTraktSuggestionSeconds: Double? {
        TraktPlaybackShadow.shared.suggestionSeconds(for: moviePlaybackMeta,
                                                     localSeconds: movieResumeSeconds,
                                                     durationSeconds: movieDurationSeconds)
    }

    /// #11: the selected source's spec line for the primary CTA ("4K · DV · Remux · Atmos · 24.5 GB"),
    /// from the SAME parse the source rows use, so the button never promises what a row wouldn't show.
    private func primarySourceDetail(_ s: CoreStream) -> String? {
        let d = StreamRanking.sourceDetail(s)
        let joined = [d.tags, d.size].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    private var movieLabel: String {
        if preparing { return String(localized: "Finding the best source…") }
        if movieReady, movieBest != nil {
            // A saved resume position turns the primary into "Resume · 1:03" (playback already seeks there);
            // a fresh title keeps "Watch". The source spec now rides on the CTA's detail line (#11).
            return movieResumeSeconds.flatMap(resumeTimecode).map { "\(String(localized: "Resume"))  ·  \($0)" } ?? String(localized: "Watch")
        }
        if movieLoadingSources {
            let p = core.streamLoadProgress()
            return p.total > 0 ? String(localized: "Finding best…  \(p.loaded)/\(p.total)") : String(localized: "Loading sources…")
        }
        return String(localized: "No sources found")
    }

    /// D10: `fromStart` replays the SAME source the title was last played through, from 0:00, ignoring the
    /// saved resume position WITHOUT clearing it (the stored resume point is untouched; playback just starts
    /// at 0). Default false keeps the primary Play/Resume behaviour (same exact source, seek to the saved
    /// position). Play-from-start must NOT re-pick the source: it only changes WHERE playback begins, never
    /// WHICH source plays (owner: "it auto changed the source when I tried to play from start").
    ///
    /// `startAt` is the same idea generalized: begin at an explicit second instead of 0 or the saved
    /// position, still WITHOUT re-picking the source and still WITHOUT touching the stored resume point.
    /// It exists for the Trakt "Resume from <time>" chip, and it is deliberately the ONLY way that feature
    /// can influence playback: it chooses a start position for this one play, exactly as a manual scrub
    /// would, and the engine then records its own position through its normal path. Nothing reads Trakt
    /// inside this function. `startAt` wins over `fromStart` because a caller passes one or the other.
    ///
    /// The second to hand the player for this one play: an explicit `startAt` wins, then `fromStart` (0),
    /// otherwise the saved resume point. Deliberately a statement chain and NOT
    /// `startAt ?? (fromStart ? 0 : await resume(pm))`: `??`'s right operand is an `@autoclosure`, which
    /// cannot contain `await`, so that spelling does not compile. The short-circuit is preserved either
    /// way, so `resume(pm)` is still only awaited when neither caller-supplied value applies.
    private func resolvedResumeSeconds(_ pm: PlaybackMeta, fromStart: Bool, startAt: Double?) async -> Double {
        if let startAt { return startAt }
        if fromStart { return 0 }
        return await resume(pm)
    }

    private func playMovie(fromStart: Bool = false, startAt: Double? = nil) async {
        // A4b: no longer gated on `meta != nil` — a hub-opened title with nil/mismatched Cinemeta meta still
        // has a resolved best stream (off the same groups the list renders) and plays off its seed identity.
        guard !preparing, let stream = movieBest else { return }
        preparing = true; defer { preparing = false }
        // EXACT-SOURCE RESUME (owner requirement): if this title was last played through a specific debrid
        // source, play THAT source directly (reresolve a fresh link for the same file) instead of re-running
        // source selection across every add-on (the "Tried N sources / this source didn't load" failure). This
        // covers BOTH resume (seek to saved position) AND play-from-start (seek to 0): the source is the same,
        // only the start position differs, so fromStart must not fall through to the auto-pick race below and
        // swap the source. Only when the stored source is genuinely gone do we fall through to that race.
        // Movies only (a series episode resumes via its own path); skipped when it is a torrent while torrents
        // are off.
        if let entry = LastStreamStore.entry(for: moviePlaybackMeta.libraryId, profileID: ProfileStore.shared.activeID),
           let service = entry.debridService.flatMap(DebridService.init(rawValue:)),
           let hash = entry.infoHash, !hash.isEmpty,
           !(PlaybackSettings.torrentsDisabled && entry.torrent == true) {
            let (url, refreshed) = await CWResume.resolvedURL(for: entry)
            if refreshed {
                core.loadEnginePlayer(for: stream)
                let pm = moviePlaybackMeta
                let resumeSeconds = await resolvedResumeSeconds(pm, fromStart: fromStart, startAt: startAt)
                presentation = .player(PlayerLaunch(url: url, title: pm.name, headers: entry.headers,
                                                    resume: resumeSeconds, meta: pm,
                                                    qualityText: entry.qualityText, bingeGroup: entry.bingeGroup,
                                                    isTorrent: false,
                                                    debridRef: DebridPlaybackRef(url: url, service: service,
                                                        infoHash: hash, torrentId: entry.debridTorrentId,
                                                        fileId: entry.debridFileId, fileIdx: entry.fileIdx),
                                                    wasExplicitPick: true))
                return
            }
        }
        // CACHED DEBRID: a raw torrent the user's debrid serves plays as a direct link (fail-soft; no-key is
        // a zero-await nil → today's path). On a debrid hit we play a remote direct URL with isTorrent:false
        // and DON'T run primePlayback (no `/create`); otherwise `prime` stays true and the path is exactly
        // today's (primePlayback → engine + torrent prime), so the no-key path is byte-identical.
        //
        // AUTO-PICK PARALLELISM: this is the top-cached "Watch" path, so race the top few CACHED candidates
        // (StreamRanking order preserved) concurrently and play the FIRST that resolves — the user reaches a
        // genuinely-cached source in ~2-4s instead of committing to `movieBest` alone when it is a
        // false-cached row. Fail-soft: a nil race result falls straight through to the single-resolve on
        // `movieBest` below, so the no-key / no-cache path is byte-identical. (A manual source-row tap uses
        // `playStream`, which stays single-resolve on the exact chosen row.)
        // The model's published groups ARE StreamRanking.rankedGroups over the same inputs (and `stream`
        // above is the model's `best`, so candidates and best stay consistent); re-ranking 1000+ streams
        // synchronously on the main thread here was a press-time stall for no gain.
        let candidates = rankedMovie().groups.flatMap(\.streams)
        if let win = await DebridCoordinator.shared.resolveFirstPlayable(
            candidates: candidates, cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs, labeledBest: stream) {
            core.loadEnginePlayer(for: win.stream)
            let pm = moviePlaybackMeta
            let resumeSeconds = await resolvedResumeSeconds(pm, fromStart: fromStart, startAt: startAt)
            presentation = .player(PlayerLaunch(url: win.ref.url, title: pm.name, headers: win.stream.requestHeaders,
                                                resume: resumeSeconds, meta: pm,
                                                qualityText: StreamRanking.signature(win.stream),
                                                bingeGroup: win.stream.behaviorHints?.bingeGroup,
                                                isTorrent: false, debridRef: win.ref,
                                                sourceStream: win.stream))
            return
        }
        // INSTANT FIRST-PLAY: the parallel-cached race above already tried every confirmed-cached candidate, so
        // this single-resolve fallback on the ranked best cache-gates too: a not-confirmed best returns a nil
        // ref with zero network and primes+plays the embedded torrent instantly instead of blocking.
        let ref = await DebridCoordinator.shared.resolvedPlaybackRef(
            for: stream, confirmedCachedHashes: debridCache.cachedHashes,
            confirmedUsenetURLs: debridCache.cachedUsenetURLs)
        guard let url = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: stream.isUsenet, resolvedURL: ref?.url,
            fallbackURL: stream.playableURL
        ) else { return }
        let prime = ref == nil
        if prime { primePlayback(stream) } else { core.loadEnginePlayer(for: stream) }
        let pm = moviePlaybackMeta
        // fromStart: hand the player resume 0 so it starts at the beginning. The stored resume point is NOT
        // cleared here - it stays until normal playback progress overwrites it (D10: play-from-start, not reset).
        let resumeSeconds = await resolvedResumeSeconds(pm, fromStart: fromStart, startAt: startAt)
        presentation = .player(PlayerLaunch(url: url, title: pm.name, headers: stream.requestHeaders,
                                            resume: resumeSeconds, meta: pm,
                                            qualityText: StreamRanking.signature(stream),
                                            bingeGroup: stream.behaviorHints?.bingeGroup,
                                            isTorrent: prime && stream.isTorrent, debridRef: ref,
                                            sourceStream: stream))
    }

    /// #95: play a source-list TRAILER row (an `isYouTubeTrailer` `ytId` stream) the SAME reliable way the
    /// built-in Trailer button (`playTrailer`) does. The resolve logic is shared with `iOSEpisodeStreams` via
    /// `resolveTrailerLaunch`; here it is presented through `.trailerPlayer` (isTrailer:true, meta:nil) so a
    /// dead trailer shows "Trailer unavailable" and never hops to content.
    private func playTrailerStream(_ stream: CoreStream) async {
        let name = "\(moviePlaybackMeta.name) Trailer"
        guard let launch = await iOSDetailView.resolveTrailerLaunch(for: stream, title: name) else { return }
        presentation = .trailerPlayer(url: launch.url, title: launch.title, audioSidecar: launch.audioSidecar)
    }

    /// Play an arbitrary chosen movie source (a tapped source-list row). `url` is the source's
    /// `playableURL`; a cached-debrid raw torrent overrides it with the direct link (fail-soft, no-key
    /// byte-identical — see `DebridCoordinator.resolvedPlaybackURL`).
    private func playStream(_ stream: CoreStream, url: URL) async {
        // #95: a tapped TRAILER row (a Streailer/YouTube `ytId` source) is NOT a content stream. Route it to
        // the trailer player (isTrailer:true, no meta) so a dead trailer shows "Trailer unavailable" and STOPS
        // instead of failing over to content and playing the actual movie. Content streams fall through below.
        if stream.isYouTubeTrailer {
            await playTrailerStream(stream)
            return
        }
        // A4b: no longer gated on `meta != nil` — a hub-opened title with nil meta still plays a tapped source
        // row off its seed identity (the source list itself renders without meta, so its rows must be playable).
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        // INSTANT FIRST-PLAY: cache-gate the manual resolve on the account-confirmed sets, so only a genuinely
        // cached tap runs the blocking resolve; a not-confirmed tap returns a nil ref with zero network and
        // primes+plays the embedded torrent instantly, exactly the pre-511c973 tap-to-play snap.
        let ref = await DebridCoordinator.shared.resolvedPlaybackRef(
            for: stream, confirmedCachedHashes: debridCache.cachedHashes,
            confirmedUsenetURLs: debridCache.cachedUsenetURLs)
        let prime = ref == nil
        if prime { primePlayback(stream) } else { core.loadEnginePlayer(for: stream) }
        let pm = moviePlaybackMeta
        // A tapped source-list row / quality pick is an EXPLICIT choice: the player honors it on a
        // start-timeout (retries in place) rather than hopping to a different, lower-quality source.
        guard let playURL = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: stream.isUsenet, resolvedURL: ref?.url, fallbackURL: url
        ) else { return }
        presentation = .player(PlayerLaunch(url: playURL, title: pm.name, headers: stream.requestHeaders,
                                            resume: await resume(pm), meta: pm,
                                            qualityText: StreamRanking.signature(stream),
                                            bingeGroup: stream.behaviorHints?.bingeGroup,
                                            isTorrent: prime && stream.isTorrent, debridRef: ref,
                                            sourceStream: stream,
                                            wasExplicitPick: true))
    }

    #if !os(tvOS)
    // MARK: Offline download (#30)

    /// Queue an offline download of a chosen MOVIE source. Resolves the URL EXACTLY as `playStream` does
    /// (cached-debrid direct link preferred, else the source's `playableURL`), builds the same
    /// `PlaybackMeta`, and hands both to `DownloadManager`. Device-local only; writes nothing to the
    /// account / libraryItem docs.
    private func downloadStream(_ stream: CoreStream, url: URL) async {
        let resolved = await DebridCoordinator.shared.resolvedPlaybackURL(for: stream)
        // A raw torrent downloads through the loopback server, which must be told to /create the torrent
        // first. The play path primes it (primePlayback) but the download path never did, so a torrent
        // row's download hit a server with no such torrent and failed instantly (#21).
        if resolved == nil, stream.isTorrent {
            torrentPrime?.cancel()
            torrentPrime = prepareTorrentStream(stream)
        }
        // meta can be nil for a hub-seeded tt not yet in Cinemeta (its sources still list); the seed
        // id/title keep the download record usable instead of silently dropping the tap.
        let m = meta
        let pm = PlaybackMeta(libraryId: m?.id ?? id, videoId: m?.id ?? id, type: "movie",
                              name: m?.name ?? title, poster: m?.poster ?? seedBackdrop, season: nil, episode: nil)
        guard let mediaURL = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: stream.isUsenet, resolvedURL: resolved, fallbackURL: url
        ) else { return }
        DownloadManager.shared.download(stream: stream, meta: pm, resolvedURL: mediaURL,
                                        sourceName: stream.name, qualityText: StreamRanking.signature(stream))
    }

    /// Present the pre-download quality picker for the MOVIE (#30 follow-up): hands the picker the SAME
    /// display-filtered, ranked groups + remembered-quality continuity + source pin + confirmed cached-debrid
    /// hashes the source list and `StreamRanking.best` already use, so it lists exactly the sources "Download
    /// best" would have chosen from and the user picks the exact quality to save. Sync: the movie's sources are
    /// already loaded when the `movieReady`-gated chip fires. The picker's coordinator owns the transfer +
    /// automatic next-best fallback; nothing here writes to the account / libraryItem docs.
    private func presentMovieDownloadPicker() {
        downloadPicker = DownloadPickerRequest(
            meta: moviePlaybackMeta, episode: nil, groups: rankedMovie().groups,
            continuity: rememberedQuality, pin: sourcePin, cachedHashes: debridCache.cachedHashes)
    }

    /// Present the pre-download quality picker for a SERIES' primary episode (#30 follow-up) — the series twin
    /// of the movie Download chip. A series detail loads meta only, so this first loads + settles THAT
    /// episode's streams (mirroring the episode page's resolve gate), then hands the picker the SAME
    /// display-filtered groups + remembered-quality continuity + source pin + confirmed cached-debrid hashes
    /// the play path uses, tagged with the episode's `DebridEpisode(season:episode:)` so a season-pack link
    /// resolves to the right episode. No-op if meta is missing or nothing settles. The picker's coordinator
    /// owns the transfer + automatic next-best fallback; nothing here writes to the account / libraryItem docs.
    private func presentSeriesDownloadPicker(_ video: CoreVideo) async {
        guard let m = meta else { return }
        core.loadMeta(type: "series", id: m.id, streamType: "series", streamId: video.id)
        var groups: [CoreStreamSourceGroup] = []
        var firstPlayableAt: Date? = nil
        for _ in 0 ..< 80 {                                // ~20s ceiling, matching the episode page
            groups = iOSDisplayGroups(core.streamGroups(forStreamId: video.id))
            if !groups.isEmpty, firstPlayableAt == nil { firstPlayableAt = Date() }
            let progress = core.streamLoadProgress(forStreamId: video.id)
            let elapsed = firstPlayableAt.map { Date().timeIntervalSince($0) } ?? 0
            if StreamRanking.resolveSettled(groups, loaded: progress.loaded, total: progress.total,
                                            secondsSinceFirstPlayable: elapsed, rememberedQuality: rememberedQuality) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !groups.isEmpty else { return }
        let ep = video.season.flatMap { season in
            video.episode.flatMap { episode in
                season >= 0 && episode > 0 ? DebridEpisode(season: season, episode: episode) : nil
            }
        }
        let pm = PlaybackMeta(libraryId: m.id, videoId: video.id, type: "series",
                              name: m.name, poster: video.thumbnail ?? m.poster,
                              season: video.season, episode: video.episode)
        downloadPicker = DownloadPickerRequest(
            meta: pm, episode: ep, groups: groups,
            continuity: rememberedQuality, pin: sourcePin, cachedHashes: debridCache.cachedHashes,
            subtitle: video.season.flatMap { s in video.episode.map { "S\(s)E\($0)" } })
    }
    #endif

    // MARK: Live — backdrop + LIVE badge + source list (no VOD chrome)

    /// The Live channel page: the same cinematic backdrop + title block as a movie, but stripped of
    /// VOD chrome — no trailer chip, no movie-style synopsis paragraph, no skip/chapter UI. A "LIVE"
    /// badge sits beside the title, then a now/next EPG strip (when the channel carries a schedule),
    /// and the full channel source list lets the user pick a stream.
    @ViewBuilder private var livePage: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(alignment: .center, spacing: Theme.Space.sm) {
                    titleOrLogo
                    liveBadge
                }
                metaRow
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Cap the live hero ZStack's own width to the viewport (same fix as iOSDetailView.hero).
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same circular back / overflow chrome the VOD hero wears (#125): the nav bar is hidden on
        // this pushed page too (see body), so without the back disc a live channel / sport event had NO
        // back affordance at all, and the Live tab's only escape was relaunching the app.
        .overlay(alignment: .topLeading) { heroChrome }
        epgStrip
        liveSourceSection
    }

    /// Now/Next EPG strip for a live channel. The schedule already rides in the meta JSON
    /// (`behaviorHints.hasScheduledVideos` + dated `videos[]`) — no XMLTV/networking on the client.
    /// When `EPGSchedule` resolves, show a NOW row (program title + "until <next start>") and a NEXT
    /// row (title + start time). Otherwise, if the meta has a description, show it (lower-fidelity
    /// add-ons that only put Now/Next text in `description`). Times format with the device LOCALE
    /// (short time), turning the UTC `released` into a local clock reading. Display-only; reuses the
    /// existing eyebrow / label / body tokens.
    @ViewBuilder private var epgStrip: some View {
        if let m = meta {
            if let schedule = EPGSchedule(meta: m) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if let now = schedule.now {
                        epgRow(eyebrow: "NOW",
                               title: now.episodeTitle,
                               detail: schedule.next?.releasedDate.map { "until \(Self.epgTime.string(from: $0))" })
                    }
                    if let next = schedule.next {
                        epgRow(eyebrow: "NEXT",
                               title: next.episodeTitle,
                               detail: next.releasedDate.map { Self.epgTime.string(from: $0) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.md)
            } else if let d = m.description, !d.isEmpty {
                Text(d)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.md)
            }
        }
    }

    /// One EPG row: an eyebrow tag (NOW / NEXT), the program title, and an optional time detail.
    private func epgRow(eyebrow: String, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(eyebrow)
                .font(Theme.Typography.eyebrow).tracking(1.5)
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// Device-locale short-time formatter (UTC `released` → local clock reading). `static let` to
    /// avoid per-row allocation; locale/time-zone default to the device's current settings.
    private static let epgTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// The red "LIVE" pill that marks a live channel (the live counterpart to the VOD trailer/Watch
    /// affordances this page drops).
    private var liveBadge: some View {
        Text("LIVE")
            .font(Theme.Typography.eyebrow).tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.Palette.danger, in: Capsule())
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    /// The channel's source list, played through the live launch path (which preserves the live
    /// `type` so the player tunes for live). Same component as the movie list, minus the
    /// remembered-quality continuity hint (live streams don't carry meaningful quality memory).
    @ViewBuilder private var liveSourceSection: some View {
        // Suspend the list rebuild while the player cover is up (see sourceSection): skip rankedGroups and
        // pass an empty list, so the hidden live detail stops re-rendering behind the video.
        let suspended = presentation != nil
        iOSSourceList(
            groups: suspended ? [] : rankedLive(),
            progress: core.streamLoadProgress(),
            states: core.streamAddonStates(),
            settleTimedOut: settleTimedOut,
            pinContext: pinContext,
            cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs,
            play: { stream, url in Task { await playLiveStream(stream, url: url) } },
            bestStream: sourceList.best,
            resolutionTiers: sourceList.tiers,
            isSuspended: suspended
        )
        .equatable()   // see sourceSection: skip re-diffing the list on unrelated re-renders
        .padding(.horizontal, Theme.Space.md)
    }

    /// Play a chosen live channel source. Mirrors `playStream`, but the `PlaybackMeta.type` is the
    /// channel's own live type (tv / channel / events), which the player reads via `LiveTypes` to
    /// engage live tuning and to NO-OP resume/progress. No resume offset is requested or recorded —
    /// a live stream has no meaningful position to restore.
    private func playLiveStream(_ stream: CoreStream, url: URL) async {
        guard !preparing, let m = meta else { return }
        preparing = true; defer { preparing = false }
        primePlayback(stream)
        let pm = PlaybackMeta(libraryId: m.id, videoId: m.id, type: type,
                              name: m.name, poster: m.poster, season: nil, episode: nil)
        presentation = .player(PlayerLaunch(url: url, title: m.name, headers: stream.requestHeaders,
                                            resume: 0, meta: pm,
                                            qualityText: StreamRanking.signature(stream),
                                            bingeGroup: stream.behaviorHints?.bingeGroup,
                                            isTorrent: stream.isTorrent, sourceStream: stream))
    }

    // MARK: Series — season selector + episode cards

    @ViewBuilder private var episodeList: some View {
        if let videos = meta?.videos, !videos.isEmpty {
            let seasons = Array(Set(videos.compactMap { $0.season })).sorted()
            let watched = watchedSet
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .center, spacing: Theme.Space.sm) {
                    iOSRailHeader(eyebrow: "\(episodes(videos).count) episode\(episodes(videos).count == 1 ? "" : "s")",
                                  title: "Episodes")
                    #if !os(tvOS)
                    // Batch downloads (#119): whole current season, or a multi-select pass.
                    episodeDownloadMenu(videos)
                    #endif
                }

                // Always render the season chips (even single-season): they host the per-season /
                // whole-series Mark-Watched menu (long-press), the same as tvOS.
                if !seasons.isEmpty {
                    HStack(spacing: Theme.Space.sm) {
                        #if !os(tvOS)
                        // #119: persistent running count while multi-selecting, pinned OUTSIDE the
                        // scrolling chips (it must not scroll away on a long season row) so a pick
                        // made on another season stays visible after switching.
                        if selectingEpisodes, !selectedEpisodeIds.isEmpty {
                            Text(selectionCountLabel(videos))
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.accent)
                                .fixedSize()
                        }
                        #endif
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Space.sm) {
                                ForEach(seasons, id: \.self) { s in
                                    Button { season = s } label: { Text(seasonLabel(s)) }
                                        .buttonStyle(ChipButtonStyle(selected: season == s))
                                        .contextMenu {
                                            seasonWatchedMenu(s)
                                            #if !os(tvOS)
                                            // #119: download ANY season straight from its chip, without
                                            // first switching the visible season.
                                            Divider()
                                            Button { startBatchDownload(episodesInSeason(s)) } label: {
                                                Label("Download \(seasonLabel(s))", systemImage: "arrow.down.circle")
                                            }
                                            #endif
                                        }
                                }
                            }
                            .padding(.vertical, Theme.Space.xs)
                        }
                    }
                }

                #if !os(tvOS)
                // #119: live batch progress / end-of-batch summary for THIS series, and the
                // multi-select action bar while picking episodes.
                batchStatusLine
                if selectingEpisodes { episodeSelectionBar(videos) }
                #endif

                VStack(spacing: Theme.Space.sm) {
                    ForEach(episodes(videos), id: \.id) { v in
                        episodeRow(v, isWatched: watched.contains(v.id), progress: episodeProgress(v))
                    }
                }
            }
            .padding(.horizontal, Theme.Space.md)
            // Initial season = the season you were LAST watching (Continue Watching), else first-unwatched,
            // else the first non-special, else 1 — matching the tvOS rule. Re-applies when a large series'
            // episodes stream in after the list first appears (onChange videos.count), guarded so a manual tap
            // is never overridden.
            .onAppear { applyEpisodeSeason(seasons); publishSeriesWatchRollup() }
            // Single-param onChange: the zero-/two-param forms are iOS 17+, target here is iOS 16.
            .onChange(of: videos.count) { _ in
                applyEpisodeSeason(Array(Set(videos.compactMap { $0.season })).sorted())
                publishSeriesWatchRollup()
            }
            .onChange(of: watched) { _ in publishSeriesWatchRollup() }   // a mark flips the show-level badge (#143)
            .onChange(of: season) { _ in didApplySeason = true }
        }
    }

    /// Per-season + whole-series Mark Watched / Unwatched, wired to the same CoreBridge methods the
    /// tvOS season-chip context menu uses.
    @ViewBuilder private func seasonWatchedMenu(_ s: Int) -> some View {
        Button { core.markSeasonWatched(s, true) } label: {
            Label("Mark \(seasonLabel(s)) Watched", systemImage: "checkmark.circle")
        }
        Button { core.markSeasonWatched(s, false) } label: {
            Label("Mark \(seasonLabel(s)) Unwatched", systemImage: "arrow.uturn.backward")
        }
        Button { core.markWatched(true) } label: {
            Label("Mark Whole Series Watched", systemImage: "checkmark.circle.fill")
        }
        Button { core.markWatched(false) } label: {
            Label("Mark Whole Series Unwatched", systemImage: "circle")
        }
    }

    /// Tapping an episode now PUSHES its own source-list screen (the full ranked sources + Quality
    /// picker) instead of silently auto-playing the best source — mirroring the tvOS `CoreEpisodeStreams`
    /// flow. The user sees every source for that episode and picks one, which plays via the primed path.
    /// Spoiler-safe veil for one episode on the detail list: mode ON, the episode is NOT watched, and it has
    /// not yet been revealed this session. Read-only against `watchedSet` (never a write), so it honours the
    /// per-profile watch invariant. It gates the reveal-first tap and the withheld synopsis; the thumbnail blur
    /// additionally unions the legacy `SpoilerBlurSetting` (see `episodeThumbnail`).
    private func spoilerVeiled(_ v: CoreVideo, isWatched: Bool) -> Bool {
        spoilerSafe && !isWatched && !revealedEpisodeIds.contains(v.id)
    }

    @ViewBuilder private func episodeRow(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        #if !os(tvOS)
        // #119 multi-select mode: rows toggle membership instead of pushing the source page. An
        // already-downloaded episode is still selectable; the coordinator skips it and the summary says so.
        if selectingEpisodes {
            let isSelected = selectedEpisodeIds.contains(v.id)
            Button {
                if isSelected { selectedEpisodeIds.remove(v.id) } else { selectedEpisodeIds.insert(v.id) }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        .padding(.leading, Theme.Space.sm)
                        .accessibilityHidden(true)
                    episodeRowLabel(v, isWatched: isWatched, progress: progress)
                }
            }
            .buttonStyle(RowFocusStyle())
            .accessibilityValue(isSelected ? "Selected" : "")
        } else if spoilerVeiled(v, isWatched: isWatched) {
            // Spoiler-safe: a veiled row REVEALS on tap instead of pushing the source page, so the first tap can
            // never jump straight into a spoilery source list / backdrop. Once revealed it re-renders as the
            // normal navigation row, so a second tap opens the episode as usual.
            Button { revealedEpisodeIds.insert(v.id) } label: {
                episodeRowLabel(v, isWatched: isWatched, progress: progress)
            }
            .buttonStyle(RowFocusStyle())
            .accessibilityValue("Spoiler hidden")
            .accessibilityHint("Reveals this episode's artwork and description")
        } else {
            episodeRowNavigation(v, isWatched: isWatched, progress: progress)
        }
        #else
        episodeRowNavigation(v, isWatched: isWatched, progress: progress)
        #endif
    }

    /// The normal (non-selecting) episode row: a NavigationLink pushing the episode's source page.
    @ViewBuilder private func episodeRowNavigation(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        if let m = meta {
            NavigationLink {
                iOSEpisodeStreams(meta: m, video: v, season: v.season ?? season,
                                  seasonEpisodes: sortedEpisodes(m.videos ?? []))
            } label: {
                episodeRowLabel(v, isWatched: isWatched, progress: progress)
            }
            .buttonStyle(RowFocusStyle())
            .accessibilityValue(isWatched ? "Watched" : "")
            .contextMenu {
                Button(isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                    core.markVideoWatched(v, !isWatched)
                }
                #if !os(tvOS)
                // #119: one-episode auto-pick download from the list (best source via the same
                // ranked pipeline), without opening the episode's source page.
                if downloadChipState(videoId: v.id) == .none {
                    Button { startBatchDownload([v]) } label: {
                        Label("Download Episode", systemImage: "arrow.down.circle")
                    }
                }
                #endif
            }
        } else {
            episodeRowLabel(v, isWatched: isWatched, progress: progress)
        }
    }

    private func episodeRowLabel(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            episodeThumbnail(v, isWatched: isWatched, progress: progress)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(Theme.Palette.accent)
                            .accessibilityHidden(true)
                    }
                    Text("\(v.episodeNumber). \(v.episodeTitle)")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(isWatched ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                        .lineLimit(2)
                }
                if let aired = v.released, aired.count >= 10 {
                    Text(String(aired.prefix(10)))
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                }
                if spoilerVeiled(v, isWatched: isWatched) {
                    // Synopsis withheld until the viewer reveals this episode (spoiler-safe mode). The row itself
                    // is the reveal control (see episodeRow), so this is a static hint, not a nested button.
                    Label("Tap to reveal", systemImage: "eye.slash")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                        .accessibilityLabel("Description hidden")
                } else if let overview = v.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            #if !os(tvOS)
            // #119: per-episode offline state from the existing DownloadStore records, so a season
            // batch shows which rows are already saved / in flight at a glance.
            episodeDownloadStateBadge(v)
            #endif
        }
        .padding(Theme.Space.md)
        .opacity(isWatched ? 0.55 : 1)
    }

    #if !os(tvOS)
    // MARK: Batch episode downloads (#119)

    /// Trailing per-row offline indicator: a check for a completed download, a spinner while one is
    /// queued / downloading / paused, nothing otherwise. Derived from the same `DownloadStore` records
    /// the hero chip reads, so state is always consistent with DownloadsView.
    @ViewBuilder private func episodeDownloadStateBadge(_ v: CoreVideo) -> some View {
        switch downloadChipState(videoId: v.id) {
        case .done:
            Image(systemName: "arrow.down.circle.fill")
                .font(.callout)
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityLabel("Downloaded")
        case .inProgress:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Downloading")
        case .none:
            EmptyView()
        }
    }

    /// The Episodes-header Download menu: whole current season in one tap, or the multi-select mode for
    /// a range / arbitrary picks. Shows a stop action while a batch is walking this series.
    @ViewBuilder private func episodeDownloadMenu(_ videos: [CoreVideo]) -> some View {
        Menu {
            Button { startBatchDownload(episodes(videos)) } label: {
                Label("Download \(seasonLabel(season))", systemImage: "arrow.down.circle")
            }
            Button { selectingEpisodes = true; selectedEpisodeIds = [] } label: {
                Label("Select Episodes", systemImage: "checklist")
            }
            if batch.runningSeriesIds.contains(id) {
                Divider()
                Button(role: .destructive) { batch.cancel() } label: {
                    Label("Stop Batch Download", systemImage: "xmark.circle")
                }
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .buttonStyle(ChipButtonStyle())
    }

    /// Inline batch feedback for THIS series only. When this series' episode is the one resolving
    /// right now, the live "S1E5 · 3 of 8" line (per-series counters); when this series is queued
    /// behind another show's batch, a generic waiting line with ITS OWN count, never the other show's
    /// episode label; then the end-of-batch summary (queued / already downloaded / skipped) until
    /// dismissed.
    @ViewBuilder private var batchStatusLine: some View {
        if batch.runningSeriesIds.contains(id) {
            HStack(spacing: Theme.Space.sm) {
                ProgressView().controlSize(.small)
                if batch.currentSeriesId == id, let status = batch.statusText {
                    Text("Finding sources · \(status)")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    Text("Batch downloading · \(batch.remainingBySeries[id] ?? 0) waiting")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                Button("Stop") { batch.cancel() }
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.danger)
                    .buttonStyle(.plain)
            }
        } else if let s = batch.summary, s.seriesIds.contains(id) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Image(systemName: "arrow.down.circle")
                    .font(.callout)
                    .foregroundStyle(Theme.Palette.accent)
                    .accessibilityHidden(true)
                Text(s.text)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { batch.dismissSummary() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
    }

    /// How many distinct seasons the current selection spans (0 when nothing is selected). Selection
    /// deliberately survives a season switch, so the Download label + count indicator must say when a
    /// pick reaches beyond the visible season instead of silently including invisible episodes.
    private func selectedSeasonSpan(_ videos: [CoreVideo]) -> Int {
        Set(videos.filter { selectedEpisodeIds.contains($0.id) }.map { $0.season ?? 1 }).count
    }

    /// "N selected" (plus the season span when it crosses seasons), shown beside the season chips
    /// while selecting so the running pick stays visible even after switching seasons.
    private func selectionCountLabel(_ videos: [CoreVideo]) -> String {
        let count = selectedEpisodeIds.count
        let span = selectedSeasonSpan(videos)
        guard span > 1 else { return String(localized: "\(count) selected") }
        return String(localized: "\(count) selected · \(span) seasons")
    }

    /// The multi-select action bar: Select Season adds the visible season's episodes to the pick,
    /// Download hands the selection (in airing order, across seasons) to the coordinator, Cancel exits.
    /// The Download label calls out a cross-season pick ("Download 7 · 2 seasons") so episodes selected
    /// on a season no longer on screen are never queued silently.
    @ViewBuilder private func episodeSelectionBar(_ videos: [CoreVideo]) -> some View {
        let span = selectedSeasonSpan(videos)
        FlowLayout(spacing: Theme.Space.sm) {
            Button { selectedEpisodeIds.formUnion(episodes(videos).map(\.id)) } label: {
                Label("Select \(seasonLabel(season))", systemImage: "checklist")
            }
            .buttonStyle(ChipButtonStyle())
            Button {
                let chosen = sortedEpisodes(videos).filter { selectedEpisodeIds.contains($0.id) }
                startBatchDownload(chosen)
                selectingEpisodes = false
                selectedEpisodeIds = []
            } label: {
                Label(span > 1 ? "Download \(selectedEpisodeIds.count) · \(span) seasons"
                               : "Download \(selectedEpisodeIds.count)",
                      systemImage: "arrow.down.circle")
            }
            .buttonStyle(ChipButtonStyle(selected: true))
            .disabled(selectedEpisodeIds.isEmpty)
            Button { selectingEpisodes = false; selectedEpisodeIds = [] } label: {
                Text("Cancel")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    /// Hand an ordered episode list to the batch coordinator with the SAME ranking context a manual
    /// best-download captures right now (quality continuity, source pin, confirmed debrid cache, and
    /// the show's imdb id so the coordinator can refresh the TorBox-search / Singularity contributors
    /// exactly as the episode page would), so every episode's auto-pick matches a by-hand best-download.
    private func startBatchDownload(_ vids: [CoreVideo]) {
        guard let m = meta, !vids.isEmpty else { return }
        BatchDownloadCoordinator.shared.enqueue(
            seriesId: m.id, seriesName: m.name,
            // ROLES, not `ratingsImdbID`. That value is the show's tt-only ratings id: it is nil for a
            // TMDB/Kitsu-keyed show, and it is a default, not the selected episode. The coordinator applies
            // each episode's own current-video role as it walks.
            identityRoles: SourceIndexIdentity.Roles(
                catalogID: m.id,
                defaultVideoID: m.behaviorHints?.defaultVideoId,
                currentVideoID: nil,
                kind: .series
            ),
            fallbackPoster: m.poster,
            episodes: vids, continuity: rememberedQuality, pin: sourcePin,
            cachedHashes: debridCache.cachedHashes)
    }
    #endif

    private func episodeThumbnail(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        // Effective spoiler-blur: the user's explicit setting wins; else the RemoteConfig fleet default
        // (`features.spoilerBlur`); else baked true. `_ = spoilerBlur` keeps the view observing the
        // @AppStorage so a Settings toggle triggers a redraw.
        _ = spoilerBlur
        // Hide future-episode imagery until you have watched OR revealed it. The blur fires under the new
        // spoiler-safe mode OR the legacy thumbnail-blur setting; either way a per-episode reveal (a tap on the
        // row, tracked in revealedEpisodeIds) clears it, so revealing an episode always shows its art.
        let revealed = revealedEpisodeIds.contains(v.id)
        let blurArt = !isWatched && !revealed && (spoilerSafe || SpoilerBlurSetting.isEnabled)
        return AsyncImage(url: URL(string: v.thumbnail ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default:
                Theme.Palette.surface2.overlay(
                    Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(Theme.Palette.textTertiary))
            }
        }
        .frame(width: 132, height: 74)
        .blur(radius: blurArt ? 14 : 0)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay {
            if blurArt {
                Image(systemName: "eye.slash.fill").font(.footnote)
                    .foregroundStyle(.white.opacity(0.85)).shadow(radius: 2).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(Theme.Palette.accent).padding(5).shadow(radius: 3)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if !isWatched, progress > 0.01 {
                iOSProgressStripe(value: progress).padding(4)
            }
        }
    }

    private func episodes(_ videos: [CoreVideo]) -> [CoreVideo] {
        videos.filter { ($0.season ?? 1) == season }
            .sorted { $0.episodeNumber < $1.episodeNumber }
    }

    /// Ordered episodes of a SPECIFIC season (not the selected-season `episodes(_:)`), for the hero's
    /// primary play whose resume episode may live in a different season than the one on screen.
    private func episodesInSeason(_ s: Int) -> [CoreVideo] {
        (meta?.videos ?? []).filter { ($0.season ?? 1) == s }
            .sorted { $0.episodeNumber < $1.episodeNumber }
    }

    private func seasonLabel(_ s: Int) -> String { s == 0 ? "Specials" : "Season \(s)" }

    // MARK: Part of the Collection (franchise)

    /// The "Part of the … Collection" rail: every entry in this movie's TMDB collection in release order,
    /// each tappable to open its detail. Reuses the exact More-Like-This idiom (shared catalog card +
    /// NavigationLink to iOSDetailView), so it honors the same poster orientation / hide-labels settings.
    /// Rendered only when the collection has more than one entry (a one-item "collection" is not a franchise).
    @ViewBuilder private var collectionSection: some View {
        if let collection, collection.parts.count > 1 {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                iOSRailHeader(eyebrow: "Collection", title: TMDBClient.collectionRowTitle(collection.name))
                    .padding(.horizontal, Theme.Space.md)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(collection.parts) { item in
                            NavigationLink {
                                iOSDetailView(id: item.id, type: item.type, title: item.name)
                            } label: {
                                PosterCardiOS(id: item.id, type: item.type, name: item.name,
                                              poster: item.poster, progress: 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Space.md)
                }
            }
        }
    }

    // MARK: More Like This

    @ViewBuilder private var moreLikeThisSection: some View {
        if !similarItems.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                iOSRailHeader(eyebrow: type == "series" ? "Similar Series" : "Similar Movies",
                              title: "More Like This")
                    .padding(.horizontal, Theme.Space.md)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(similarItems.prefix(20)) { item in
                            NavigationLink {
                                iOSDetailView(id: item.id, type: item.type, title: item.name)
                            } label: {
                                // Reuse the shared catalog card so the related rail honors the same poster
                                // orientation (landscape/portrait) and hide-labels settings as every other
                                // rail, instead of a hardcoded portrait tile (Bug: related rail stayed portrait).
                                PosterCardiOS(id: item.id, type: item.type, name: item.name,
                                              poster: item.poster, progress: 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Space.md)
                }
            }
        }
    }

    private func loadSimilar(_ meta: CoreMetaItem) {
        guard !LiveTypes.contains(type), !meta.genres.isEmpty else { return }
        Task {
            let items = await AddonClient.similar(type: type, excludingId: id, genres: meta.genres, title: meta.name)
            var merged = items
            // Prepend TMDB recommendations (deduped) for richer "more like this". No key gate: the
            // recommendations call routes through the keyless catalogs edge when the user has no key.
            if id.hasPrefix("tt") {
                let existing = Set(items.map(\.id))
                let recs = await AddonClient.tmdbSimilar(type: type, imdbID: id).filter { $0.id != id && !existing.contains($0.id) }
                merged = recs + items
            }
            await MainActor.run { similarItems = merged }
        }
    }

    /// More-Like-This when Cinemeta meta is (still) nil: a hub-seeded tt not yet in Cinemeta has no
    /// genres for the add-on path, but TMDB recommendations resolve from the tt id alone (keyless edge),
    /// so the rail still populates (#29). The full `loadSimilar` overwrites this once meta arrives.
    private func loadSimilarFallback() {
        guard similarItems.isEmpty, meta == nil, id.hasPrefix("tt"), !LiveTypes.contains(type) else { return }
        Task {
            let recs = await AddonClient.tmdbSimilar(type: type, imdbID: id).filter { $0.id != id }
            await MainActor.run { if similarItems.isEmpty { similarItems = recs } }
        }
    }

    @ViewBuilder private var whereToWatchSection: some View {
        if let avail = watchAvail, !avail.providers.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // S9: standardized header component (title-only; no natural kicker here).
                iOSRailHeader(title: "Where to Watch")
                    .padding(.horizontal, Theme.Space.md)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.md) {
                        ForEach(avail.providers) { provider in
                            VStack(spacing: 6) {
                                // TMDB watch-provider marks are dark / brand-hued app icons that read as
                                // "very dark" drawn straight on the app's dark chrome (#95). Sit each mark on
                                // the shared warm near-white plate (the same treatment the Streaming Services
                                // tiles and RemoteLogo use) with a small inset, so a dark logo stays legible
                                // and whole instead of blending into the background.
                                AsyncImage(url: URL(string: provider.logoURL ?? "")) { img in
                                    img.resizable().scaledToFit().padding(48 * BundledLogo.plateInsetFraction)
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.Palette.surface1)
                                }
                                .frame(width: 48, height: 48)
                                .background(BundledLogo.plateFill)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(provider.name)
                                    .font(Theme.Typography.label)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                    .lineLimit(1).frame(width: 64)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.md)
                }
            }
        }
    }

    /// Legal streaming availability for the title in the viewer's region (TMDB watch/providers). Only
    /// runs with a TMDB key + an IMDb id; a nil result simply hides the section.
    private func loadWatchProviders() {
        guard !LiveTypes.contains(type), let imdb = ratingsImdbID else { return }
        Task {
            let avail = await TMDBClient.watchProviders(imdbID: imdb, type: effectiveType)
            await MainActor.run { watchAvail = avail }
        }
    }

    // MARK: Shared

    /// Prime a picked stream for playback BEFORE the player launches — exactly what the tvOS `play()`
    /// does. Wires the engine Player (so progress records against the right library item) and, for
    /// torrents, asks the embedded server to start fetching peers. Without this, iOS/Mac launched the
    /// player against a torrent the server had never been told to create, so the stream never played.
    private func primePlayback(_ stream: CoreStream) {
        core.loadEnginePlayer(for: stream)
        // Cancel any prior torrent prime before storing the new one, so a re-pick can't leave a stale
        // backoff loop running; the stored Task is also cancelled on view disappear.
        torrentPrime?.cancel()
        torrentPrime = prepareTorrentStream(stream)
    }

    /// Engine-history profiles resume from the engine; everyone else from the account/overlay.
    private func resume(_ pm: PlaybackMeta) async -> Double {
        if let engine = core.engineResumeSeconds(for: pm) { return engine }
        return await account.resumeOffset(for: pm)
    }

    // metaDetails is a single shared @Published on the CoreBridge singleton. Guard on the id so a
    // previous page's still-resident meta (A -> back -> B) can't render A's hero/title under B.
    private var meta: CoreMetaItem? {
        ResidentMeta.fenced(core.metaDetails?.meta, pageID: id) { $0.id }
    }
}

// MARK: - Per-episode source list (mirrors tvOS CoreEpisodeStreams)

/// The screen pushed when a series episode is tapped — the touch/Mac twin of the tvOS
/// `CoreEpisodeStreams`. It shows the episode's own backdrop, title, and overview, then the FULL
/// ranked source list (with the Quality picker) via the shared `iOSSourceList`, fed with that
/// episode's streamId. Picking a source primes playback (engine Player + torrent /create) and
/// presents the native player — exactly like the movie path. This replaces the old behaviour where
/// tapping an episode silently auto-played the best source and showed no sources / no quality picker.
struct iOSEpisodeStreams: View {
    let meta: CoreMetaItem
    let video: CoreVideo
    let season: Int
    let seasonEpisodes: [CoreVideo]   // ALL episodes across seasons, ordered (season, episode), for in-player Next/Prev/list + auto-advance ACROSS the season boundary (so the last episode of a season rolls into the next season's first)
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore   // engine-vs-overlay resume source for the binge re-anchor

    // Binge-advance re-anchor (binge-desync fix #4, the iOS twin of tvOS CoreEpisodeStreams.currentVideo):
    // this page stays mounted UNDER the full-screen player cover, so after continuous play advanced past
    // the launch episode it still showed - and its Watch button would REPLAY - the episode it was pushed
    // for (the stale Back target). `currentVideo` re-points to the engine's resume episode when the cover
    // dismisses AND on app foreground; every identity-bearing read below goes through `shownVideo` so the
    // hero, the source list scope, and the PlaybackMeta handed to the player all follow the CURRENT
    // episode. nil until a real move happens, so the pushed `video` drives the page exactly as before.
    @State private var currentVideo: CoreVideo? = nil
    @State private var episodeTargetGeneration = 0
    private var shownVideo: CoreVideo { currentVideo ?? video }
    /// The season the page shows: follows `shownVideo` so a cross-season binge advance re-labels correctly.
    private var shownSeason: Int { shownVideo.season ?? season }

    /// The episode's full-screen cover content: a resolved content stream (`player`) or a #95 trailer row
    /// (`trailer`, isTrailer:true / no meta). Driven from ONE `@State` so only one cover is ever attached
    /// (see the note on `presentation`); reuses the movie view's `PlayerLaunch` / `TrailerLaunch` payloads.
    enum Presentation: Identifiable {
        case player(iOSDetailView.PlayerLaunch)
        case trailer(iOSDetailView.TrailerLaunch)
        var id: String {
            switch self {
            case .player(let l): "player-\(l.id)"
            case .trailer(let t): "trailer-\(t.id)"
            }
        }
    }

    // A SINGLE presentation slot drives the episode's full-screen cover (player OR trailer), mirroring
    // iOSDetailView.presentation: on macOS `platformFullScreenPlayerCover(item:)` becomes `.sheet(item:)`,
    // and two sheets attached to the same view shadow each other, so a #95 trailer cover added ALONGSIDE the
    // player cover could stop Watch from presenting. One enum-typed slot guarantees exactly one cover.
    @State private var presentation: Presentation?
    @State private var preparing = false
    /// Smart Source Selection (Lane A) auto-pick: when `SourcePreferences.autoPickBest` is on, this page
    /// resolves + plays the best source on appear instead of making the viewer pick from the list. Guarded so
    /// it fires exactly once per appearance; backing out of the player reveals the full list (the escape hatch).
    @State private var didAutoPick = false
    /// Owns this episode's source-list assembly + ranking OFF the SwiftUI render path (see
    /// `SourceListModel`): the body reads only the published output, scoped to this episode's stream
    /// id, so CoreBridge bumps while the list is open no longer rebuild it per body eval.
    @StateObject private var sourceList = SourceListModel()
    @State private var lastBinge: String?   // release-group of the last pick; biases the next episode's source (#3 sticky autoplay)
    @State private var settleTimedOut = false      // resolution gave up → show "No sources found", not a spinner
    @State private var torrentPrime: Task<Void, Never>?  // outstanding torrent /create retry loop, cancelled on disappear / new pick
    @State private var sourceRefreshDebounce: Task<Void, Never>? = nil
    private static let sourceRefreshDebounceMs = 400     // trailing settle for this episode's add-on load storm
    @ObservedObject private var pinStore = SourcePinStore.shared   // pinned source for this show (#15)
    // Debrid cache awareness for THIS episode's source list. Empty (no badges, ranking unchanged) with no key.
    @StateObject private var debridCache = DebridCacheAwareness()
    // TorBox search-as-a-source for this episode: extra usenet + torrent sources for the SHOW (gated on a
    // TorBox key). Empty (list unchanged) with no key.
    @StateObject private var torboxSearch = TorBoxSearchSource()
    // Community source index ("Singularity") for this episode: SERVE (merges corroborated pooled sources
    // when the toggle is on + signed in) + HOARD (fire-and-forget descriptor contribution). Fully gated +
    // fail-soft inside `SourceIndexClient`; keyed on the episode content id (show:S:E).
    @StateObject private var sourceIndex = SourceIndexServeSource()
    // Media servers (Plex/Jellyfin/Emby) for THIS episode: direct-play hits resolved by SxEy. Dormant with no server.
    @StateObject private var mediaServers = MediaServerSource()

    /// A series pin is keyed by the show id, so every episode shares the pinned provider/quality.
    private var pinContext: SourcePinContext { SourcePinContext(metaId: meta.id, isSeries: true) }
    private var sourcePin: ResolvedPin? { pinStore.effectivePin(pinContext) }

    /// The show's identity roles, stated for the one shared resolver (tvOS twin: DetailView.swift
    /// `CoreStreamList.identityRoles`). Naming the roles makes conflicting valid IMDb heads an explicit
    /// mismatch instead of letting array position choose one.
    ///
    /// The FIELD CASE is preserved (REQ-260721-05): a TMDB/Kitsu-identified series with no defaultVideoId
    /// (meta.id "tmdb:94997") holds its IMDb identity only on the EPISODE video id ("tt0460649:3:6"), which
    /// the `.series` kind still admits as the last role, so the IMDb-keyed paths keep a usable key.
    private var showIdentityRoles: SourceIndexIdentity.Roles {
        SourceIndexIdentity.Roles(
            catalogID: meta.id,
            defaultVideoID: meta.behaviorHints?.defaultVideoId,
            currentVideoID: shownVideo.id,
            kind: .series
        )
    }

    /// The show's resolved IMDb identity. ONE value: pool and TorBox take the same IMDb-only key.
    private var showIdentity: SourceIndexIdentity.Resolved {
        SourceIndexIdentity.resolve(showIdentityRoles)
    }

    private var backdropHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 320
        #endif
    }

    var body: some View {
        // Hard-cap the column to the viewport width (see iOSDetailView.body) so the episode hero's wide
        // single-line metaRow can't stretch the ZStack past the screen and clip the title/synopsis off the left.
        GeometryReader { geo in
        #if os(macOS)
        // macOS pinned-episode model (mirrors `iOSDetailView.macDetailBody`, FINDING 3): the episode banner
        // is a FIXED near-fullscreen top layer and only the overview + source list scroll in an inner
        // ScrollView, over a continuous blurred backdrop wash. Replaces the old fixed 460 strip + large dead
        // canvas below (the "tiny hero, blank page" report), so the episode page matches the movie/show page.
        VStack(spacing: 0) {
            macEpisodeBanner(width: geo.size.width, height: episodeBandHeight(viewport: geo.size.height))
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    episodeOverviewText
                    sourceListView(width: geo.size.width)
                }
                .padding(.bottom, Theme.Space.xl)
                .frame(width: geo.size.width, alignment: .leading)
            }
        }
        // Continuous cinematic wash behind the whole page (blurred FILL, so it never becomes a second crisp
        // image); the pinned banner owns the crisp focal art up top.
        .background(alignment: .top) {
            backdropWash(height: geo.size.height)
                .ignoresSafeArea()
        }
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                hero(width: geo.size.width)
                sourceListView(width: geo.size.width)
            }
            .padding(.bottom, Theme.Space.xl)
            .frame(width: geo.size.width, alignment: .leading)
        }
        #endif
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        // iOS-only: a macOS navigationTitle on this pushed episode-streams view crashes the shared NSToolbar.
        #if os(iOS)
        .navigationTitle(shownVideo.episodeTitle)
        .inlineNavigationTitle()
        #endif
        .macBackAffordance()   // macOS in-content Back + Esc / Cmd-[ (no toolbar back exists)
        // The engine loads per-episode streams on demand; trigger that load for THIS episode — but only
        // when the resident streams aren't already this episode's, so a back/forward revisit doesn't churn.
        .onAppear {
            // Wire the source-list model to this episode's sources (idempotent; see SourceListModel).
            sourceList.bind(core: core, torbox: torboxSearch, singularity: sourceIndex,
                            mediaServers: mediaServers, debridCache: debridCache)
            // Load THIS episode's streams. The series meta is often ALREADY loaded (from the detail page)
            // WITHOUT this episode's stream path, so guarding on meta id alone skipped the stream request
            // entirely and the source list stayed empty ("no sources" / "no stream add-ons responded").
            // Also (re)load whenever the loaded streams aren't this episode's; the engine de-dups an
            // identical meta+stream load, so this is cheap when the right streams are already present.
            let hasThisEpisodeStreams = core.metaDetails?.allStreamGroups.contains { $0.request.path.id == shownVideo.id } ?? false
            if core.metaDetails?.meta?.id != meta.id || !hasThisEpisodeStreams {
                core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: shownVideo.id)
            }
            // Smart Source Selection (Lane A): auto-pick my best source. Fires once per appearance and only
            // when the viewer opted in; reuses `loadEpisodeStream` (the SAME settle + StreamRanking.best +
            // resume + torrent-prime resolve the in-player Next/Prev uses), then presents the player, so this
            // adds no new playback logic. A viewer who backs out of the player lands on the full source list.
            if SourcePreferences.shared.autoPickBest, !didAutoPick {
                didAutoPick = true
                Task { await autoPickAndPlayEpisode() }
            }
        }
        .onDisappear { torrentPrime?.cancel(); sourceRefreshDebounce?.cancel() }
        .task {
            try? await Task.sleep(for: .seconds(20))
            settleTimedOut = true
        }
        // Debrid cache awareness for this episode's torrents + usenet: re-check as add-ons answer (de-duped
        // by hash set in refresh). Includes the TorBox search sources so those rows badge too. No-op with
        // no debrid key.
        .onChange(of: core.streamLoadProgress(forStreamId: shownVideo.id).loaded) { _ in scheduleSourceRefresh() }
        // The Singularity pool answers asynchronously, so re-run the cache check when its streams arrive, so
        // pooled sources for this episode resolve per-user rather than only rendering.
        .onChange(of: sourceIndex.streams.count) { _ in scheduleSourceRefresh() }
        // Auxiliary sources are keyed to the exact episode. Each owner clears its prior publication
        // synchronously before starting the replacement request, and SourceListModel independently checks
        // the same content token before merging.
        .onAppear {
            mediaServers.refresh(imdb: showIdentity.titleID, season: auxiliarySeason, episode: auxiliaryEpisode,
                                 title: meta.name, publicationTarget: mediaServerEpisodeTargetID)
            refreshSourceIndex()
        }
        .onChange(of: shownVideo.id) { _ in
            mediaServers.refresh(imdb: showIdentity.titleID, season: auxiliarySeason, episode: auxiliaryEpisode,
                                 title: meta.name, publicationTarget: mediaServerEpisodeTargetID)
            refreshSourceIndex()
            scheduleSourceRefresh()
        }
        // Binge-desync fix #4 (Back target): when the player cover dismisses, continuous play may have
        // advanced past the episode this page was pushed for - follow the engine's resume episode so Back
        // lands on the CURRENT episode and Watch-Now plays it, not the launch episode.
        .onChange(of: presentation == nil) { _ in reanchorToEngineEpisode() }
        #if canImport(UIKit)
        // ...and ALSO on app foreground: across a background boundary no dismissal event fires (the cover
        // stays up / the page stays mounted), so this is the trigger that unfreezes the stale page.
        // Guarded inside on the cover being down, so a live player is never re-anchored from under.
        // macOS never suspends the process: not wired there (the dismissal trigger above covers it).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            reanchorToEngineEpisode()
        }
        #endif
        .platformFullScreenPlayerCover(item: $presentation) { item in
            switch item {
            case .player(let launch):
                PlayerScreen(
                    url: launch.url, title: launch.title, headers: launch.headers, resumeSeconds: launch.resume,
                    recordMeta: launch.meta, recordQualityText: launch.qualityText,
                    recordBingeGroup: launch.bingeGroup, recordIsTorrent: launch.isTorrent,
                    recordDebridRef: launch.debridRef,
                    initialSourceStream: launch.sourceStream,
                    initialEnginePlayerVideoId: launch.enginePlayerVideoId,
                    startedFromExplicitPick: launch.wasExplicitPick,
                    episodes: seasonEpisodes.map { PlayerEpisodeRef(id: $0.id, label: "S\($0.season ?? 1)E\($0.episodeNumber) · \($0.episodeTitle)") },
                    loadEpisode: { await loadEpisodeStream($0) },
                    warmNextEpisode: { await warmEpisodeStream($0) },
                    // Engine feed only: the ACCOUNT write lives in PlayerScreen.saveAccountProgress, keyed on
                    // curMeta, so a binge advance attributes progress to the CURRENT episode (capturing
                    // launch.meta here saved every advance's progress against the launch episode).
                    onProgress: { pos, dur in core.reportProgress(timeSeconds: pos, durationSeconds: dur) },
                    onSeek: { pos, dur in core.reportProgress(timeSeconds: pos, durationSeconds: dur) },
                    onClose: {
                        core.unloadEnginePlayer()
                        presentation = nil
                    }
                )
                .ignoresSafeArea()
            case .trailer(let launch):
                // #95: a tapped trailer row plays in the SAME native player as a stream but with isTrailer:true
                // and no recordMeta, so a dead trailer shows "Trailer unavailable" and never hops to content.
                PlayerScreen(url: launch.url, title: launch.title, headers: nil, resumeSeconds: 0,
                             recordMeta: nil, isTrailer: true, audioSidecarURL: launch.audioSidecar,
                             onClose: { presentation = nil })
                    .ignoresSafeArea()
            }
        }
    }

    /// Binge-advance re-anchor, shared by BOTH triggers (cover dismissal + app foreground): follow the
    /// engine's CURRENT resume episode (the per-profile overlay for overlay profiles, the same split every
    /// resume/progress read uses) so the page shows and plays the episode continuous play is actually on.
    /// Guarded on the cover being down (never re-point beneath a live player - its own dismissal re-fires
    /// this) and on a real move to an episode present in `seasonEpisodes`, so a no-op close (paused, same
    /// episode) leaves the page untouched. Re-points meta_details too, so the source list re-scopes.
    private func reanchorToEngineEpisode() {
        guard presentation == nil else { return }
        let id = profiles.activeUsesEngineHistory
            ? core.metaDetails?.libraryItem?.state.videoId
            : profiles.watch[meta.id]?.videoId
        guard let id, id != shownVideo.id, let moved = seasonEpisodes.first(where: { $0.id == id }) else { return }
        episodeTargetGeneration &+= 1
        currentVideo = moved
        core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: moved.id)
    }

    private func episodeTargetIsCurrent(_ target: CoreVideo, generation: Int) -> Bool {
        generation == episodeTargetGeneration && shownVideo.id == target.id
    }

    private func debridHint(for target: CoreVideo) -> DebridEpisode? {
        let targetSeason = target.season ?? season
        // PRESENCE, not truthiness (see the note on `auxiliaryEpisode`): `?? target.episodeNumber` was
        // `?? 0`, which laundered an unresolved episode into an explicit E0 and then discarded it anyway.
        guard targetSeason >= 0, let targetEpisode = target.episode, targetEpisode >= 0 else { return nil }
        return DebridEpisode(season: targetSeason, episode: targetEpisode)
    }

    /// Episode backdrop + show eyebrow + episode title + S·E / air date / facts + overview, mirroring
    /// the tvOS `CoreEpisodeStreams` header block.
    private func hero(width: CGFloat) -> some View {
        // Fixed backdrop banner (show eyebrow + episode title + meta overlaid) with the overview flowing
        // below on the canvas — same structure as iOSDetailView.hero, so a long episode synopsis can't push
        // the backdrop down behind the text.
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ZStack(alignment: .bottomLeading) {
                backdrop
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(meta.name.uppercased())
                        .font(Theme.Typography.eyebrow).tracking(1.5)
                        .foregroundStyle(Theme.Palette.accent)
                    Text(shownVideo.episodeTitle)
                        .font(Theme.Typography.hero).tracking(-1)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(3).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                    metaRow
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.bottom, Theme.Space.lg)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)

            if let overview = shownVideo.overview, !overview.isEmpty {
                Text(overview)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.Space.readableColumn, alignment: .leading)
                    .padding(.horizontal, Theme.Space.md)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The episode source list (extracted so the iOS single-scroll body and the macOS pinned body render the
    /// EXACT same list). While the episode's player / trailer cover is up, skip the rankedGroups pass (pass []
    /// + isSuspended) so this hidden episode list stops re-rendering behind the video; it restores on close.
    private func sourceListView(width: CGFloat) -> some View {
        iOSSourceList(
            groups: presentation != nil ? [] : rankedEpisode(),
            progress: core.streamLoadProgress(forStreamId: shownVideo.id),
            states: core.streamAddonStates(forStreamId: shownVideo.id),
            settleTimedOut: settleTimedOut,
            continuity: rememberedQuality,
            pinContext: pinContext,
            cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs,
            isEpisode: true,
            play: { stream, url in Task { await play(stream, url: url) } },
            playAuto: { stream, url in Task { await play(stream, url: url, explicit: false) } },
            playBest: { candidates, best in Task { await playBest(candidates, labeledBest: best) } },
            bestStream: sourceList.best,
            resolutionTiers: sourceList.tiers,
            download: episodeDownloadHandler,
            isSuspended: presentation != nil
        )
        // Equatable gate: unrelated episode re-renders skip re-diffing the ranked list (the
        // groups compare is a buffer-identity fast path until the model republishes).
        .equatable()
        .padding(.horizontal, Theme.Space.md)
        // #9: cap the source list to a readable column, centered, on wide iPad/Mac windows.
        .frame(maxWidth: width > Theme.Space.wideLayoutMinWidth ? Theme.Space.contentColumn : .infinity)
        .frame(maxWidth: .infinity)
    }

    #if os(macOS)
    /// The pinned episode banner for the macOS pinned model: the crisp backdrop art (bleeding under the top
    /// chrome) with the show eyebrow + episode title + meta overlaid at the bottom, sized to a near-fullscreen
    /// band. Mirrors `iOSDetailView.heroBanner`; the episode's own `.macBackAffordance()` supplies Back.
    private func macEpisodeBanner(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            backdrop(height: height)
                .ignoresSafeArea(edges: .top)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(meta.name.uppercased())
                    .font(Theme.Typography.eyebrow).tracking(1.5)
                    .foregroundStyle(Theme.Palette.accent)
                Text(shownVideo.episodeTitle)
                    .font(Theme.Typography.hero).tracking(-1)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(3).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                metaRow
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.lg)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
    }

    /// The episode overview, rendered in the macOS inner scroll region (the iOS path keeps it inside `hero`).
    @ViewBuilder private var episodeOverviewText: some View {
        if let overview = shownVideo.overview, !overview.isEmpty {
            Text(overview)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.Space.readableColumn, alignment: .leading)
                .padding(.horizontal, Theme.Space.md)
        }
    }

    /// Near-fullscreen episode band height (ports `iOSDetailView.heroBandHeight`'s macOS formula): ~72% of a
    /// tall window, always reserving ~320pt of inner-scroll room, floored at 280 and capped at 1000.
    private func episodeBandHeight(viewport: CGFloat) -> CGFloat {
        guard viewport > 0 else { return 620 }
        let reservedForContent: CGFloat = 320
        let band = min(1000, min(viewport * 0.72, viewport - reservedForContent))
        return max(280, band)
    }

    /// The full-window BACKGROUND wash behind the pinned episode page: ALWAYS blurred `.fill` + dim, so the
    /// new full-window paint reads as soft atmosphere and never becomes a second crisp image beside the banner.
    private func backdropWash(height: CGFloat) -> some View {
        AsyncImage(url: URL(string: shownVideo.thumbnail ?? meta.background ?? meta.poster ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.canvas
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
        .blur(radius: 40)
        .overlay(Theme.Palette.canvas.opacity(0.5))
        .overlay(
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.55), location: 0.6),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        )
        .accessibilityHidden(true)
    }
    #endif

    private var backdrop: some View { backdrop(height: backdropHeight) }

    private func backdrop(height: CGFloat) -> some View {
        AsyncImage(url: URL(string: shownVideo.thumbnail ?? meta.background ?? meta.poster ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.surface1
            }
        }
        .frame(height: height)
        // Width anchor for the episode hero ZStack — full viewport width, pinned leading (see iOSDetailView.backdrop).
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .overlay(
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.35), location: 0.55),
                .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.85),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                           startPoint: .leading, endPoint: .center)
        )
    }

    private var metaRow: some View {
        var facts: [String] = []
        if let released = shownVideo.released, released.count >= 10 { facts.append(String(released.prefix(10))) }
        if let rt = meta.runtime { facts.append(rt) }
        let genres = meta.genres
        if !genres.isEmpty { facts.append(genres.prefix(3).joined(separator: " · ")) }
        return HStack(spacing: 6) {
            Text("S\(shownSeason) · E\(shownVideo.episode ?? 0)")
            if let imdb = meta.imdbRating {
                Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                Text(imdb)
            }
            // One truncating tail line (see iOSDetailView.metaRow) so this row's minimum width stays tiny
            // and can't force the episode hero wider than the iPhone screen (right-edge clip).
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  ")).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// #95: play an episode source-list TRAILER row (an `isYouTubeTrailer` `ytId` stream) the SAME reliable
    /// way the movie source list and the Trailer button do. The resolve logic is shared via
    /// `iOSDetailView.resolveTrailerLaunch`; here it is presented via `.trailer` (isTrailer:true, meta:nil) so
    /// a dead trailer shows "Trailer unavailable" and never hops to the episode content. Presents nothing on a
    /// nil resolve (no playable trailer URL) rather than falling through to content.
    private func playTrailerStream(_ stream: CoreStream) async {
        let target = shownVideo
        let targetGeneration = episodeTargetGeneration
        let name = "\(meta.name) Trailer"
        guard let launch = await iOSDetailView.resolveTrailerLaunch(for: stream, title: name) else { return }
        guard presentation == nil,
              episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
        presentation = .trailer(launch)
    }

    /// Play the tapped source: prime the engine + torrent (same path as the movie list), then present
    /// the native player carrying the stream's proxy headers.
    ///
    /// CACHED DEBRID: a raw torrent the user's debrid can serve plays as a direct link, resolving the
    /// SxEy file in a season pack via the episode hint. Fail-soft (no-key is a zero-await nil → the
    /// passed-in `url`/torrent path, unchanged). A debrid URL is a remote direct stream: skip the torrent
    /// prime and mark isTorrent:false.
    /// `explicit`: true when the user tapped this exact source row / quality (honor it in the player, no
    /// silent hop on a start-timeout); false when it is an auto fallback (the ranked-best Watch path /
    /// the parallel-cached race's single-resolve fallback), which may hop normally.
    private func play(_ stream: CoreStream, url: URL, explicit: Bool = true) async {
        // #95: a tapped TRAILER row (a Streailer/YouTube `ytId` source) inside an episode source list is NOT a
        // content stream. Route it to the trailer player (isTrailer:true, no meta) so a dead trailer shows
        // "Trailer unavailable" and STOPS instead of failing over to and playing the actual episode. This is
        // the FIRST check, before any content resolution/prime; content streams fall through unchanged below.
        if stream.isYouTubeTrailer {
            await playTrailerStream(stream)
            return
        }
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        let target = shownVideo
        let targetGeneration = episodeTargetGeneration
        let ep = debridHint(for: target)
        let (ref, isTorrent) = await playbackRef(for: stream, episode: ep)
        guard presentation == nil,
              episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
        guard let playURL = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: stream.isUsenet, resolvedURL: ref?.url,
            fallbackURL: stream.playableURL(isEpisode: true)
        ) else { return }
        lastBinge = stream.behaviorHints?.bingeGroup   // seed the sticky release-group from the user's pick (#3)
        // Cancel any prior torrent prime before storing the new one, so a re-pick can't leave a stale
        // backoff loop running; the stored Task is also cancelled on view disappear. Debrid direct → no prime.
        torrentPrime?.cancel()
        torrentPrime = isTorrent ? prepareTorrentStream(stream) : nil
        let name = "\(meta.name)  ·  S\(target.season ?? season)E\(target.episodeNumber)"
        let pm = PlaybackMeta(libraryId: meta.id, videoId: target.id, type: "series",
                              name: meta.name, poster: target.thumbnail ?? meta.poster,
                              season: target.season, episode: target.episode)
        let resumeSeconds = await resume(pm)
        guard presentation == nil,
              episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
        let bindingSucceeded = core.loadEnginePlayer(
            for: stream, videoId: pm.videoId,
            base: iOSEngineAddonBase(for: stream, in: core.streamGroups(forStreamId: target.id)),
            resolvedURL: ref?.url
        )
        let engineVideoID = EpisodePlaybackIdentity.boundVideoID(
            requestedVideoID: pm.videoId, bindingSucceeded: bindingSucceeded
        )
        guard presentation == nil,
              episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
        presentation = .player(iOSDetailView.PlayerLaunch(url: playURL, title: name, headers: stream.requestHeaders,
                                            resume: resumeSeconds, meta: pm,
                                            qualityText: StreamRanking.signature(stream),
                                            bingeGroup: stream.behaviorHints?.bingeGroup,
                                            isTorrent: isTorrent, debridRef: ref,
                                            sourceStream: stream,
                                            enginePlayerVideoId: engineVideoID,
                                            wasExplicitPick: explicit))
    }

    /// AUTO-PICK play for the episode "Watch in <quality>" button: race the top few CACHED candidates
    /// (ranking order preserved) in parallel and play the FIRST that resolves, so the user reaches a
    /// genuinely-cached source fast instead of committing to the single ranked best when it is a
    /// false-cached row. FAIL-SOFT: a nil race result falls back to today's single-resolve on the ranked
    /// best (`play`), so the no-key / no-cache path is byte-identical. A MANUAL row tap / Quality pick still
    /// goes through `play(_:url:)` on the exact chosen row.
    private func playBest(_ candidates: [CoreStream], labeledBest: CoreStream) async {
        guard !preparing else { return }
        // Hold `preparing` for the whole race so a second Watch tap can't launch a duplicate resolve. It is
        // RELEASED before the single-resolve fallback below, which sets its own guard (`play` early-returns
        // while `preparing`), so the fallback path is unchanged.
        preparing = true
        let target = shownVideo
        let targetGeneration = episodeTargetGeneration
        let ep = debridHint(for: target)
        if let ep, let win = await DebridCoordinator.shared.resolveFirstPlayable(
            candidates: candidates, episode: ep, cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs, labeledBest: labeledBest) {
            defer { preparing = false }
            guard presentation == nil,
                  episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
            lastBinge = win.stream.behaviorHints?.bingeGroup
            torrentPrime?.cancel(); torrentPrime = nil   // debrid direct link: no torrent prime
            let name = "\(meta.name)  ·  S\(target.season ?? season)E\(target.episodeNumber)"
            let pm = PlaybackMeta(libraryId: meta.id, videoId: target.id, type: "series",
                                  name: meta.name, poster: target.thumbnail ?? meta.poster,
                                  season: target.season, episode: target.episode)
            let resumeSeconds = await resume(pm)
            guard presentation == nil,
                  episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
            let bindingSucceeded = core.loadEnginePlayer(
                for: win.stream, videoId: pm.videoId,
                base: iOSEngineAddonBase(for: win.stream, in: core.streamGroups(forStreamId: target.id)),
                resolvedURL: win.ref.url
            )
            let engineVideoID = EpisodePlaybackIdentity.boundVideoID(
                requestedVideoID: pm.videoId, bindingSucceeded: bindingSucceeded
            )
            guard presentation == nil,
                  episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
            presentation = .player(iOSDetailView.PlayerLaunch(url: win.ref.url, title: name, headers: win.stream.requestHeaders,
                                                resume: resumeSeconds, meta: pm,
                                                qualityText: StreamRanking.signature(win.stream),
                                                bingeGroup: win.stream.behaviorHints?.bingeGroup,
                                                isTorrent: false, debridRef: win.ref,
                                                sourceStream: win.stream,
                                                enginePlayerVideoId: engineVideoID))
            return
        }
        preparing = false   // release before the fallback, which re-guards on `preparing` inside `play`
        guard presentation == nil,
              episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
        // No acceptable parallel-cached winner (false-cached best, or every resolved leg a lower resolution
        // than a confirmed-cached label): single-resolve the LABELED best so the played quality matches the
        // button, instead of the first playable candidate (which could itself be a lower tier). Fall back to
        // the first playable only if the labeled best somehow has no URL.
        let fallback = !labeledBest.isUsenet && labeledBest.playableURL(isEpisode: true) != nil
            ? labeledBest
            : candidates.first(where: { !$0.isUsenet && $0.playableURL(isEpisode: true) != nil })
        guard let best = fallback, let url = best.playableURL(isEpisode: true) else { return }
        await play(best, url: url, explicit: false)   // auto Watch fallback: may hop normally
    }

    /// Smart Source Selection (Lane A): resolve this episode's best source and present the player, the
    /// auto-pick-my-best entry. Reuses `loadEpisodeStream` (full settle gate + `StreamRanking.best` + resume
    /// + engine/torrent prime), so it introduces no new resolve or playback logic; it only builds the same
    /// `PlayerLaunch` a manual Watch would and presents it. `wasExplicitPick` stays false (this is an
    /// auto-pick, so the player keeps its silent-hop-on-timeout behavior). No-op if a cover is already up.
    private func autoPickAndPlayEpisode() async {
        guard presentation == nil, !preparing else { return }
        preparing = true
        let target = shownVideo
        let targetGeneration = episodeTargetGeneration
        let resolved = await loadEpisodeStream(target.id)
        preparing = false
        guard presentation == nil, let e = resolved,
              e.meta.videoId == target.id,
              episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
        let bindingSucceeded = core.loadEnginePlayer(
            for: e.stream, videoId: e.meta.videoId, base: e.engineAddonBase,
            resolvedURL: e.debridRef?.url
        )
        let engineVideoID = EpisodePlaybackIdentity.boundVideoID(
            requestedVideoID: e.meta.videoId, bindingSucceeded: bindingSucceeded
        )
        guard presentation == nil,
              e.meta.videoId == target.id,
              episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
        presentation = .player(iOSDetailView.PlayerLaunch(
            url: e.url, title: e.title, headers: e.stream.requestHeaders,
            resume: e.resume, meta: e.meta,
            qualityText: StreamRanking.signature(e.stream),
            bingeGroup: e.stream.behaviorHints?.bingeGroup,
            isTorrent: e.debridRef == nil && e.stream.isTorrent,
            debridRef: e.debridRef, sourceStream: e.stream,
            enginePlayerVideoId: engineVideoID))
    }

    #if !os(tvOS)
    /// Per-row offline-download handler for the EPISODE source list (nil on tvOS). Resolves the URL the
    /// same way `play` does and queues a download for THIS episode, with the episode's `PlaybackMeta`.
    private var episodeDownloadHandler: ((CoreStream, URL) -> Void)? {
        { stream, url in Task { await downloadStream(stream, url: url) } }
    }

    /// Queue an offline download of a chosen episode source. Resolves the URL exactly as `play` does
    /// (cached-debrid direct preferred, else `stream.playableURL`) and builds the same series-typed
    /// `PlaybackMeta`, so play-from-local records progress against the right episode. Device-local only.
    private func downloadStream(_ stream: CoreStream, url: URL) async {
        let target = shownVideo
        let targetGeneration = episodeTargetGeneration
        let ep = debridHint(for: target)
        // A download is not a tap: keep the unconditional (non-cache-gated) resolve so it still resolves a
        // debrid direct link for an uncached-but-servable pick, exactly as before this play-path change.
        let (ref, isTorrent) = await playbackRef(for: stream, episode: ep, cacheGated: false)
        guard episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
        // A raw torrent downloads through the loopback server, which must be told to /create the torrent
        // first; the play path primes it, the download path didn't, so the row's download died (#21).
        if isTorrent {
            torrentPrime?.cancel()
            torrentPrime = prepareTorrentStream(stream)
        }
        let pm = PlaybackMeta(libraryId: meta.id, videoId: target.id, type: "series",
                              name: meta.name, poster: target.thumbnail ?? meta.poster,
                              season: target.season, episode: target.episode)
        guard let resolvedURL = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: stream.isUsenet, resolvedURL: ref?.url,
            fallbackURL: stream.playableURL(isEpisode: true)
        ) else { return }
        guard episodeTargetIsCurrent(target, generation: targetGeneration) else { return }
        DownloadManager.shared.download(stream: stream, meta: pm, resolvedURL: resolvedURL,
                                        sourceName: stream.name, qualityText: StreamRanking.signature(stream))
    }
    #else
    private var episodeDownloadHandler: ((CoreStream, URL) -> Void)? { nil }
    #endif

    /// Resolve the URL to play for `stream` on this episode view, preferring a cached-debrid DIRECT link
    /// for a raw torrent. Mirrors the movie view's helper; returns `(ref, false)` when debrid served it
    /// (the ref carries the URL + reresolve provenance), else `(nil, stream.isTorrent)` so the caller uses
    /// `stream.playableURL`. Fail-soft and no-key byte-identical.
    ///
    /// INSTANT FIRST-PLAY: by default (`cacheGated`) the resolve is cache-gated on the account-confirmed sets,
    /// so a manual tap / auto fallback only blocks on a genuinely cached pick and otherwise falls straight
    /// through to the embedded torrent path (pre-511c973 snap). The DOWNLOAD path passes `cacheGated: false`
    /// to keep its unconditional resolve (a download isn't a tap and can afford the add-then-poll).
    private func playbackRef(for stream: CoreStream, episode: DebridEpisode?,
                             cacheGated: Bool = true) async -> (ref: DebridPlaybackRef?, isTorrent: Bool) {
        // Never hand a raw episodic container to native debrid without a positive filename target. A valid
        // Stremio fileIdx may still play locally through playableURL(isEpisode:true); provider selection does
        // not get to fall back to largest-file behavior.
        if stream.url == nil, episode == nil { return (nil, stream.isTorrent) }
        let ref = await DebridCoordinator.shared.resolvedPlaybackRef(
            for: stream, episode: episode,
            confirmedCachedHashes: cacheGated ? debridCache.cachedHashes : nil,
            confirmedUsenetURLs: cacheGated ? debridCache.cachedUsenetURLs : nil)
        if let ref { return (ref, false) }
        return (nil, stream.isTorrent)
    }

    private func resume(_ pm: PlaybackMeta) async -> Double {
        if let engine = core.engineResumeSeconds(for: pm) { return engine }
        return await account.resumeOffset(for: pm)
    }

    /// Direct-links-only: drop every torrent source so a user with the setting on never sees or
    /// auto-plays one — the same `displayGroups` filter the tvOS `CoreStreamList` applies. Merges the
    /// TorBox search sources first (no-op with no TorBox key / no results).
    private func displayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        let snapshot = AuxiliarySourcePipeline.snapshot(
            target: episodeAuxiliaryTarget,
            torBox: torboxSearch,
            sourceIndex: sourceIndex
        )
        let withSearch = AuxiliarySourcePipeline.merged(into: groups, snapshot: snapshot)
        guard PlaybackSettings.directLinksOnly else { return withSearch }
        return withSearch.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            guard !streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    /// The ranked groups for the EPISODE source set, read from `SourceListModel`'s published output.
    /// The episode's stream id scopes the model's snapshot (streamGroups(forStreamId:)) so a struct
    /// instance reused for another episode can't serve a stale rank; setContext is cheap and
    /// equality-guarded, and the heavy assemble + rank runs off-main inside the model.
    private func rankedEpisode() -> [CoreStreamSourceGroup] {
        sourceList.setContext(
            metaId: meta.id, streamId: shownVideo.id, continuity: rememberedQuality, pin: sourcePin,
            auxiliaryTarget: episodeAuxiliaryTarget,
            mediaServerTargetID: mediaServerEpisodeTargetID
        )
        return sourceList.groups
    }

    /// The episode's pool `content_id` (show imdb id + `:S:E`), or nil when the show has no imdb id.
    private var auxiliarySeason: Int { shownVideo.season ?? season }

    /// The episode coordinate, PRESERVING nil.
    ///
    /// It used to read `shownVideo.episode ?? shownVideo.episodeNumber`, and `episodeNumber` is itself
    /// `episode ?? 0` (CoreModels.swift), so the whole expression was `episode ?? 0`: absence was laundered
    /// into the explicit value ZERO before any consumer saw it. Two things broke. The tuple-exact guard in
    /// `SourceIndexIdentity.contentKey` became UNREACHABLE from here, because a nil episode arrived as 0 and
    /// composed a complete-looking `tt...:S:0` key for an episode nobody had resolved yet. And an add-on that
    /// legitimately numbers a special E0 became indistinguishable from "not known yet".
    ///
    /// `episodeNumber` remains the DISPLAY helper it is named for (labels like "S1E4"); it must never enter a
    /// fetch, cache, pool, or publication identity, and nothing on this identity path reads it now.
    private var auxiliaryEpisode: Int? { shownVideo.episode }

    private var episodeDebridHint: DebridEpisode? {
        // Episode ZERO is a valid coordinate (specials), so this tests PRESENCE and non-negativity, never
        // truthiness. The old `> 0` silently dropped every E0 special from debrid episode matching.
        guard auxiliarySeason >= 0, let episode = auxiliaryEpisode, episode >= 0 else { return nil }
        return DebridEpisode(season: auxiliarySeason, episode: episode)
    }
    private var episodeAuxiliaryTarget: SourceIndexIdentity.TargetResolution {
        SourceIndexIdentity.publicationTarget(
            showIdentityRoles,
            season: auxiliarySeason,
            episode: auxiliaryEpisode
        )
    }
    private var episodeContentID: String? {
        episodeAuxiliaryTarget.target?.contentID
    }
    private var mediaServerEpisodeTargetID: String {
        episodeContentID ?? "meta:\(meta.id)|video:\(shownVideo.id)"
    }

    /// Community source index (episode): SERVE refresh + HOARD contribution for THIS episode. Fully gated +
    /// fail-soft inside `SourceIndexClient` (consent / fleet flag / Singularity toggle / login). De-duped per
    /// content id; safe to call as the episode's sources stream in.
    ///
    /// SIGN-IN IDENTITY: the SERVE read is gated on the VORTX-SYNC account, not the Stremio account. The moat
    /// token that un-gates `sources.vortx.tv` is minted from the VortX session bearer (`VortXSyncManager`), so
    /// a Stremio-only sign-in mints no token and the worker returns an empty `login_required` list. Gate on the
    /// same identity that mints the token so a signed-in VortX user actually sees pooled sources.
    private func refreshSourceIndex(
        torboxMerged: [CoreStreamSourceGroup]? = nil,
        refreshContributors: Bool = true
    ) {
        let target = episodeAuxiliaryTarget
        let snapshot: AuxiliarySourcePipeline.Snapshot
        if refreshContributors {
            let receipt = AuxiliarySourcePipeline.refresh(
                target: target,
                torBox: torboxSearch,
                sourceIndex: sourceIndex,
                isSignedIn: VortXSyncManager.shared.isSignedIn
            )
            snapshot = AuxiliarySourcePipeline.snapshot(
                receipt: receipt,
                torBox: torboxSearch,
                sourceIndex: sourceIndex
            )
        } else {
            snapshot = AuxiliarySourcePipeline.snapshot(
                target: target,
                torBox: torboxSearch,
                sourceIndex: sourceIndex
            )
        }
        guard snapshot.target != nil else { return }
        // Pool-EXCLUDED hoard set: the caller's episode-scoped torbox-base when it merged one, else self-merge.
        // NEVER the Singularity-pool-inclusive set: hoarding the pool's own results back into itself is wrong.
        let groups = torboxMerged ?? AuxiliarySourcePipeline.torBoxMerged(
            into: core.streamGroups(forStreamId: shownVideo.id),
            snapshot: snapshot
        )
        guard !groups.isEmpty else { return }
        Task.detached { await AuxiliarySourcePipeline.hoard(target: target, groups: groups) }
    }

    /// Trailing-debounced driver for THIS episode's add-on load storm: the raw `.onChange` fired per add-on
    /// completion, each doing full O(N) merge walks on main. Coalesce to one pass ~400 ms after the burst
    /// settles, computing the episode-scoped torbox-base ONCE so the debrid (pool-inclusive) and hoard
    /// (pool-excluded) sets share it. Cache awareness reads the pool-INCLUDED set (raw torrents the
    /// Direct-links-only filter would drop, plus the pool sources, so pooled sources resolve per-user).
    private func scheduleSourceRefresh() {
        sourceRefreshDebounce?.cancel()
        sourceRefreshDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.sourceRefreshDebounceMs))
            guard !Task.isCancelled else { return }
            let target = episodeAuxiliaryTarget
            let snapshot = AuxiliarySourcePipeline.snapshot(
                target: target,
                torBox: torboxSearch,
                sourceIndex: sourceIndex
            )
            let torboxBase = AuxiliarySourcePipeline.torBoxMerged(
                into: core.streamGroups(forStreamId: shownVideo.id),
                snapshot: snapshot
            )   // pool-EXCLUDED
            debridCache.refresh(from: AuxiliarySourcePipeline.sourceIndexMerged(
                into: torboxBase,
                snapshot: snapshot
            ))   // pool-INCLUDED (debrid set)
            refreshSourceIndex(torboxMerged: torboxBase, refreshContributors: false)
        }
    }

    /// The quality this series last played in (per profile), so the episode's Watch-in pick keeps the
    /// same quality across episodes — the tvOS `LastStreamStore` continuity hint, keyed on the series id.
    private var rememberedQuality: String? {
        LastStreamStore.entry(for: meta.id, profileID: ProfileStore.shared.activeID)?.qualityText
    }

    /// Resolve an episode to a ready-to-play stream for the player's in-place Next / Prev / list. Reuses
    /// the same load → rank → direct-links → torrent-prime → resume path as a manual source tap, so the
    /// player can switch episodes without owning any of that logic. Returns nil when nothing is playable.
    private func loadEpisodeStream(_ videoId: String) async -> PlayerEpisodeStream? {
        guard let v = seasonEpisodes.first(where: { $0.id == videoId }) else { return nil }
        core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: v.id)
        var groups: [CoreStreamSourceGroup] = []
        var firstPlayableAt: Date? = nil
        for _ in 0 ..< 80 {                                // ~20s ceiling, matching the page's settle timeout
            // Target-engine groups only. The page-owned auxiliary contributors are scoped to shownVideo and
            // must not leak into a different episode being resolved behind the player.
            groups = iOSDisplayGroups(core.streamGroups(forStreamId: v.id))
            if !groups.isEmpty, firstPlayableAt == nil { firstPlayableAt = Date() }
            // Settle gate (see StreamRanking.resolveSettled): hold out for the remembered quality (non-torrent
            // unless the user ranks torrents first) so a resume lands on the user's stream, not the first torrent.
            let progress = core.streamLoadProgress(forStreamId: v.id)
            let elapsed = firstPlayableAt.map { Date().timeIntervalSince($0) } ?? 0
            if StreamRanking.resolveSettled(groups, loaded: progress.loaded, total: progress.total,
                                            secondsSinceFirstPlayable: elapsed, rememberedQuality: rememberedQuality) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let best = StreamRanking.best(groups, continuity: rememberedQuality, binge: lastBinge, pin: sourcePin,
                                            debridCachedHashes: debridCache.cachedHashes) else { return nil }
        let targetSeason = v.season ?? season
        // PRESENCE, not truthiness: the display helper cannot tell absence from an explicit E0.
        let targetEpisode = v.episode
        let episodeHint = targetSeason >= 0 && (targetEpisode ?? -1) >= 0
            ? DebridEpisode(season: targetSeason, episode: targetEpisode ?? 0) : nil
        let ref: DebridPlaybackRef?
        if best.url == nil, episodeHint == nil {
            ref = nil
        } else {
            ref = await DebridCoordinator.shared.resolvedPlaybackRef(for: best, episode: episodeHint)
        }
        guard let url = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: best.isUsenet, resolvedURL: ref?.url,
            fallbackURL: best.playableURL(isEpisode: true)
        ) else { return nil }
        lastBinge = best.behaviorHints?.bingeGroup   // keep the next episode on this release group (#3)
        torrentPrime?.cancel(); torrentPrime = ref == nil ? prepareTorrentStream(best) : nil
        let pm = PlaybackMeta(libraryId: meta.id, videoId: v.id, type: "series",
                              name: meta.name, poster: v.thumbnail ?? meta.poster,
                              season: v.season, episode: v.episode)
        let title = "\(meta.name)  ·  S\(v.season ?? season)E\(v.episodeNumber)"
        return PlayerEpisodeStream(
            stream: best, url: url, meta: pm, title: title, resume: await resume(pm),
            debridRef: ref, engineAddonBase: iOSEngineAddonBase(for: best, in: groups)
        )
    }

    /// F6 preload: warm the next episode's likely source without disturbing the playing episode. Fetch
    /// its streams directly from every add-on (never `core.loadMeta`, which would evict the current
    /// episode's slot), rank with the same continuity hint, then start the chosen torrent's peer search
    /// or pull the first bytes of a direct file. Best-effort and silent; if nothing resolves, the later
    /// auto-advance simply pays the cold start it would have paid anyway.
    private func warmEpisodeStream(_ videoId: String) async {
        guard let v = seasonEpisodes.first(where: { $0.id == videoId }) else { return }
        let sources = account.streamSources
        var groups: [CoreStreamSourceGroup] = []
        await withTaskGroup(of: CoreStreamSourceGroup?.self) { tasks in
            for s in sources {
                tasks.addTask { await warmFetchEpisodeStreams(base: s.base, addon: s.name, id: v.id) }
            }
            for await g in tasks { if let g { groups.append(g) } }
        }
        guard let best = StreamRanking.best(iOSDisplayGroups(groups), continuity: rememberedQuality, binge: lastBinge, pin: sourcePin,
                                            debridCachedHashes: debridCache.cachedHashes) else { return }
        let targetSeason = v.season ?? season
        // PRESENCE, not truthiness: the display helper cannot tell absence from an explicit E0.
        let targetEpisode = v.episode
        let hint = targetSeason >= 0 && (targetEpisode ?? -1) >= 0
            ? DebridEpisode(season: targetSeason, episode: targetEpisode ?? 0) : nil
        let ref: DebridPlaybackRef?
        if best.url == nil, hint == nil {
            ref = nil
        } else {
            ref = await DebridCoordinator.shared.resolvedPlaybackRef(for: best, episode: hint)
        }
        if ref == nil { prepareTorrentStream(best) }
        guard let url = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: best.isUsenet, resolvedURL: ref?.url,
            fallbackURL: best.playableURL(isEpisode: true)
        ) else { return }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-8388607", forHTTPHeaderField: "Range")    // first 8 MB
        request.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: request)
    }
}

// MARK: - iOS / macOS presentation helpers
//
// `ProgressStripe`, `RailHeader`, and the tvOS stream-label live in SourcesTV (tvOS-only), so the
// touch/Mac detail page brings its own small copies built from the shared Theme tokens, keeping the
// same visual language without depending on the tvOS-only target.

/// Section header: a small ember eyebrow over the section title (mirrors tvOS RailHeader).
private struct iOSRailHeader: View {
    // Optional so every detail section can share this component (S9): sections with a natural kicker
    // (Episodes "N episodes", More Like This "Similar Series", Sources) pass one; sections without one
    // (Cast & Crew, Where to Watch) omit it and render title-only, rather than fabricating filler copy.
    var eyebrow: String? = nil
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(Theme.Typography.eyebrow).tracking(1.5)
                    .foregroundStyle(Theme.Palette.accent)
            }
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin resume-progress bar (twin of the tvOS `ProgressStripe`, which lives in the tvOS-only
/// SourcesTV target). Sits under an episode thumbnail or the series Resume button.
private struct iOSProgressStripe: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.55))
                Capsule().fill(Theme.Palette.accent)
                    .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

/// The grouped, filterable source list for the touch / Mac detail page — the twin of tvOS
/// `CoreStreamList`. Instead of a flat list of potentially thousands of streams, it offers:
///   • a **Watch in <quality>** primary button (best ranked source) + a **Quality** picker
///     (resolution tier → flavour variants, the same two-level model tvOS uses),
///   • an **All sources** toggle that reveals the full ranked list on demand,
///   • per-add-on **filter chips**, and
///   • the streams grouped under **collapsible per-add-on headers**, styled with Theme surface
///     cards, so reaching one add-on never means scrolling past every other add-on's sources.
///
/// It owns its own filter / collapse / picker UI state and plays a chosen source through the `play`
/// closure handed in by `iOSDetailView` (which resolves resume + presents the native player).
/// A stable-identity source row: a content id (`CoreStream.id`) plus an occurrence index disambiguates
/// duplicate streams that share the same id, so the ~4/sec republish keeps each row's identity stable (Lazy
/// diffing no longer reshuffles the list). Built bounded to the render window, so the per-row string work stays
/// capped no matter how many thousand sources a title returns.
private struct SourceRow: Identifiable { let id: String; let addon: String; let stream: CoreStream }

/// One add-on section in the windowed render plan: the group (for its header) plus only the rows that fit the
/// shared render budget. A collapsed group carries an empty `rows` (its header still shows the full count).
private struct WindowedGroup: Identifiable { let id: String; let group: CoreStreamSourceGroup; let rows: [SourceRow] }

struct iOSSourceList: View {
    let groups: [CoreStreamSourceGroup]
    let progress: (loaded: Int, total: Int)
    /// Per-add-on resolution state, used ONLY to explain an empty result: an add-on that errored
    /// (fetch/timeout/TLS) is surfaced distinctly from one that returned nothing. Empty by default.
    var states: [CoreBridge.StreamAddonState] = []
    var settleTimedOut = false                          // resolution gave up → show "No sources" not a spinner
    var continuity: String? = nil                       // remembered quality signature → same-quality Watch-in pick
    var pinContext: SourcePinContext? = nil             // title context for the per-row pin source menu/badge (#15)
    /// Raw-torrent infoHashes the user's debrid account has cached, lowercased, for the per-row "Cached"
    /// chip. Empty by default (no key / not yet checked) → no badges, identical to today.
    var cachedHashes: Set<String> = []
    /// nzb links whose TorBox usenet download is confirmed cached, for the per-row ⚡ on USENET rows. Empty
    /// by default (no TorBox key / not yet checked) → no usenet badges, identical to today.
    var cachedUsenetURLs: Set<String> = []
    /// Episode lists must never synthesize the legacy hash-only `/0` torrent URL.
    var isEpisode = false
    /// When false, the primary Watch / Quality / All-sources control bar is hidden and the grouped list is
    /// shown directly. The MOVIE detail page passes false because its hero already shows Watch + Quality +
    /// a "Sources" scroll button (rendering both looked like duplicate controls). The episode + live pages
    /// keep the default true — there the control bar is the only primary action.
    var showsPrimaryControls = true
    let play: (CoreStream, URL) -> Void
    /// AUTO single-resolve for the primary "Watch in <quality>" button's FALLBACK (used only when
    /// `playBest` is nil): the ranked-best source played as an AUTO pick, so the player may hop normally on
    /// a start-timeout. Distinct from `play` (a per-row / quality tap), which is an EXPLICIT choice the
    /// player honors in place. Defaults to `play` when the caller doesn't wire an auto variant.
    var playAuto: ((CoreStream, URL) -> Void)? = nil
    /// AUTO-PICK play for the primary "Watch in <quality>" button ONLY: hands the caller the ranked
    /// candidate list (best first) so it can race the top few CACHED sources in parallel and play the first
    /// that resolves, reaching a genuinely-cached link fast instead of committing to `best` alone. Optional:
    /// when nil, the Watch button falls back to the single-resolve `play(best, url)` (byte-identical to
    /// before). The per-row taps and the Quality picker NEVER use this — a user choosing a specific row still
    /// resolves exactly that row through `play`.
    var playBest: (([CoreStream], CoreStream) -> Void)? = nil
    /// Ranked best playable stream, computed once off-main by SourceListModel; the control bar's Watch pick.
    /// Defaults nil so a caller that omits it keeps the Watch button hidden rather than crashing.
    var bestStream: CoreStream? = nil
    /// Resolution tiers, computed once off-main by SourceListModel; the control bar's Quality picker first level.
    /// Defaults empty so an omitting caller renders no Quality menu rather than re-ranking on every body eval.
    var resolutionTiers: [String] = []
    /// Offline download of a chosen source row (`#30`). Optional so call sites that don't support
    /// downloads (e.g. tvOS, where the whole feature is `#if !os(tvOS)`-gated) pass nil and no Download
    /// affordance renders. `url` is resolved by the caller EXACTLY as the play path resolves it.
    var download: ((CoreStream, URL) -> Void)? = nil
    /// Set true by the detail page while a full-screen player (or trailer) cover is up. On macOS the detail
    /// tree stays MOUNTED behind the player (MacRootPlayerOverlay only sets opacity 0 + disabled, it does not
    /// unmount), and on tvOS the equivalent shell stays mounted too, so this hidden list keeps re-evaluating
    /// its body on every CoreBridge @Published bump. Rebuilding a 1000+ stream ranked list behind the video
    /// saturates the main thread and starves the mpv Metal surface of a layout pass (the "video stuck in a
    /// small rectangle / 30s stall" symptom). When suspended we render a same-size placeholder and skip the
    /// grouped list entirely; the view stays mounted so its filter / collapse / sort @State below survives, so
    /// closing the player restores the list exactly as it was. The caller ALSO passes `groups: []` when
    /// suspended, which skips the heavy `rankedGroups(displayGroups(...))` argument evaluation at the call site.
    var isSuspended: Bool = false

    @State private var sourceFilter: String? = nil      // nil = all add-ons
    @State private var showAllSources = false           // the full ranked list is revealed on demand
    // Render only the top N ranked rows across the expanded groups; a popular title returns 4000+ sources and
    // reassigning row identity ~4x/sec starved diffing. "Show more" grows the window by a step. Ranking +
    // auto-pick still run over the FULL list (see controlBar); this caps RENDERING only.
    @State private var renderLimit = Self.sourceWindowInitial
    private static let sourceWindowInitial = 100
    private static let sourceWindowStep = 100
    /// Rows whose per-row download was tapped this session (keyed by playable URL), so the icon flips to
    /// a check and disables; the tap used to give ZERO feedback, reading as "does nothing" (#21).
    @State private var queuedDownloads: Set<String> = []
    @State private var collapsed: Set<String> = []      // per-add-on sections the user folded away
    @State private var qualityTier: String? = nil       // second-level quality sheet (a resolution tier)
    @State private var sortMode: SourceSort = .best     // how the rows within each add-on are ordered
    @ObservedObject private var pinStore = SourcePinStore.shared   // re-render rows when a pin is added/removed (#15)

    /// How the streams inside each add-on section are ordered. Best is our ranking (resolution, source
    /// ladder, size, audio); Size and Seeders let a user override it when they want the biggest file or
    /// the healthiest torrent specifically. Kept per-add-on so the grouping the user filters by survives.
    enum SourceSort: String, CaseIterable, Identifiable {
        case best = "Best", size = "Size", seeders = "Seeders"
        var id: String { rawValue }
        /// Lowercase persistence key ("best" / "size" / "seeders"), so the chosen sort is remembered.
        var key: String { String(describing: self) }
        init(key: String) { self = SourceSort.allCases.first { $0.key == key } ?? .best }
    }

    /// The streams of `group`, reordered by the active sort. Best leaves the engine ranking intact;
    /// Size and Seeders sort descending with unknown values sinking to the bottom (sizeForSort 0,
    /// seedersForSort -1), so direct/debrid links don't outrank real torrents in a Seeders sort.
    private func sortedStreams(_ group: CoreStreamSourceGroup) -> [CoreStream] {
        switch sortMode {
        case .best:    return group.streams
        case .size:    return group.streams.sorted { StreamRanking.sizeForSort($0) > StreamRanking.sizeForSort($1) }
        case .seeders: return group.streams.sorted { StreamRanking.seedersForSort($0) > StreamRanking.seedersForSort($1) }
        }
    }

    private var streamCount: Int { groups.reduce(0) { $0 + $1.streams.count } }
    // Still loading unless every add-on answered — OR the settle timeout fired, which flips a hung
    // resolution to the real "No sources found" state instead of an endless spinner.
    private var loading: Bool { !settleTimedOut && (progress.total == 0 || progress.loaded < progress.total) }
    private var visibleGroups: [CoreStreamSourceGroup] {
        groups.filter { sourceFilter == nil || $0.addon == sourceFilter }
    }

    /// Windowed render plan for the grouped list: walk the visible groups, spending a shared row budget
    /// (`renderLimit`) only on EXPANDED groups. A collapsed group emits its header but no rows and spends
    /// nothing. Rows carry a stable content id (SourceRow), and the build is bounded to the budget, so the
    /// per-row string work stays capped. `expandable` is the count of rows that COULD still render (visible +
    /// not collapsed), so "Show more" is offered only when growing the window actually reveals more rows.
    private var windowedPlan: (groups: [WindowedGroup], shown: Int, expandable: Int) {
        var budget = renderLimit
        var shown = 0
        var expandable = 0
        var out: [WindowedGroup] = []
        for group in visibleGroups {
            if collapsed.contains(group.addon) {
                out.append(WindowedGroup(id: group.addon, group: group, rows: []))
                continue
            }
            let streams = sortedStreams(group)
            expandable += streams.count
            let take = min(budget, streams.count)   // budget is never negative: take <= budget each step
            var seen: [String: Int] = [:]
            let rows = streams.prefix(take).map { s -> SourceRow in
                let base = s.id
                let n = seen[base, default: 0]; seen[base] = n + 1
                return SourceRow(id: "\(base)#\(n)", addon: group.addon, stream: s)
            }
            out.append(WindowedGroup(id: group.addon, group: group, rows: Array(rows)))
            budget -= take
            shown += take
        }
        return (out, shown, expandable)
    }

    /// Empty result, told apart by CAUSE. If one or more add-ons actually ERRORED (fetch / timeout /
    /// TLS), name them and show the reason instead of the misleading generic "returned nothing" — this
    /// is what surfaces, on-device, WHY a title finds no links (e.g. an iOS-only stream-fetch failure).
    @ViewBuilder private var emptyState: some View {
        let errored = states.filter { $0.error != nil }
        // Stream add-ons that ANSWERED (not still loading) without an error: either genuinely had
        // nothing (ready == 0) or returned streams that the current filter (e.g. direct-links-only)
        // removed. Naming them tells the user the add-ons WERE queried and came back empty — which is
        // the actionable case (add-on offline / config expired) vs StremioX not asking at all.
        let answeredEmpty = states.filter { $0.error == nil && !$0.loading }
        if !errored.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                iOSEmptyRow(text: "\(errored.count) add-on\(errored.count == 1 ? "" : "s") couldn't be reached for this title:")
                ForEach(errored) { s in addonReasonRow(s.name, s.error ?? "error") }
            }
        } else if !answeredEmpty.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                iOSEmptyRow(text: "Your stream add-ons returned no sources for this title:")
                ForEach(answeredEmpty) { s in
                    addonReasonRow(s.name, s.ready > 0 ? "\(s.ready) found, hidden by your filters" : "no results")
                }
                Text("If this title should have sources, the add-on may be offline or its config expired. Try another stream add-on.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.md)
            }
        } else {
            // Reached "no sources" with NO add-on having produced any stream state — so no STREAM add-on
            // was even queried (only catalog/metadata add-ons are active). This is the real "no links"
            // cause: a stream add-on is missing, or the engine dropped it (e.g. lost after a force-quit).
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                iOSEmptyRow(text: "No stream add-ons responded for this title.")
                Text("Check Add-ons for one that lists \"Streams\" (not just Catalogs or Metadata). If you recently force-quit the app, reopen it so your add-ons reload, or re-add a stream add-on.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.md)
            }
        }
    }

    /// One "add-on name: reason" line in the empty state (errored or answered-empty).
    private func addonReasonRow(_ name: String, _ reason: String) -> some View {
        Text("\(name): \(reason)")
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.md)
    }

    /// Add-ons whose stream request FAILED (fetch/timeout/TLS/ATS) — the actionable transport failures.
    private var erroredAddons: [CoreBridge.StreamAddonState] { states.filter { $0.error != nil } }
    /// Add-ons that answered with no streams (queried, genuinely empty) — distinct from "not queried".
    private var emptyAddons: [CoreBridge.StreamAddonState] {
        states.filter { $0.error == nil && !$0.loading && $0.ready == 0 }
    }

    /// Below a NON-empty source list, account for the add-ons that produced nothing, so a title that
    /// shows only a couple of add-ons doesn't read as "StremioX didn't ask the rest". Errored add-ons
    /// are named with their reason (the actionable case, e.g. an iOS-only stream-fetch failure); the
    /// rest that came back empty are summarised. This is the on-device evidence for "movies only show
    /// a few add-ons": errored → transport/dispatch issue, empty → the add-on genuinely had nothing.
    @ViewBuilder private var unresolvedFooter: some View {
        if !loading, !erroredAddons.isEmpty || !emptyAddons.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if !erroredAddons.isEmpty {
                    iOSEmptyRow(text: "\(erroredAddons.count) add-on\(erroredAddons.count == 1 ? "" : "s") couldn't be reached:")
                    ForEach(erroredAddons) { addonReasonRow($0.name, $0.error ?? "couldn't be reached") }
                }
                if !emptyAddons.isEmpty {
                    Text("\(emptyAddons.count) other add-on\(emptyAddons.count == 1 ? "" : "s") returned no sources for this title.")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Space.md)
                }
            }
            .padding(.top, Theme.Space.xs)
        }
    }

    var body: some View {
        // While a player/trailer cover is up, the detail page stays mounted behind it (macOS overlay +
        // tvOS shell), so this body re-evaluates on every engine bump. Skip the whole grouped list and hold
        // a placeholder of a similar height so scroll position is roughly preserved. The view stays mounted,
        // so the @State (filter / collapse / sort / queuedDownloads) survives and the list restores on close.
        if isSuspended {
            return AnyView(Color.clear.frame(height: 1))
        }
        return AnyView(sourceListBody)
    }

    @ViewBuilder private var sourceListBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            iOSRailHeader(eyebrow: eyebrow, title: "Sources")

            if groups.isEmpty {
                if loading {
                    iOSLoadingRow(text: progress.total > 0
                                  ? "Finding sources…  \(progress.loaded)/\(progress.total)"
                                  : "Finding sources…")
                } else {
                    emptyState
                }
            } else {
                // Singularity renders INLINE ONLY: its merged group flows through the ranked list like
                // any add-on, sortable with the user's sort (owner decision; the old pinned duplicate
                // section above the list was removed on both platforms).
                if showsPrimaryControls { controlBar }
                if loading && progress.total > 0 {
                    Text("Still finding more · \(progress.loaded)/\(progress.total) add-ons")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                }
                // Reveal the grouped list on demand (All-sources toggle) OR always when the control bar is
                // hidden — otherwise the movie rail would be empty, since the toggle lives in that bar.
                if showAllSources || !showsPrimaryControls {
                    if groups.count > 1 { filterBar }
                    sortBar
                    groupedList
                    unresolvedFooter
                }
            }
        }
        // Reset the render window when the list collapses (re-expanding starts fresh at the top) or the title
        // changes (a new title must not inherit the previous one's grown window). pinContext carries the metaId,
        // so it flips on a title change even while this view stays mounted across a navigation.
        .onChange(of: showAllSources) { _ in if !showAllSources { renderLimit = Self.sourceWindowInitial } }
        .onChange(of: pinContext) { _ in renderLimit = Self.sourceWindowInitial }
    }

    // MARK: Controls (Watch-in-X · Quality picker · All sources)

    @ViewBuilder private var controlBar: some View {
        // The flow layout (HStack that wraps) is simulated with two rows so it stays tidy on a phone.
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // Watch-in pick honors the remembered-quality continuity hint, so reopening a title lands
            // on the same quality it last played (same-release-group biased) — matching tvOS.
            if let best = bestStream, let url = best.playableURL(isEpisode: isEpisode) {
                HStack(spacing: Theme.Space.sm) {
                    // Watch-Now waits until every add-on has answered (or the settle timeout fired), so one
                    // press plays the best of ALL sources, not the best of whoever replied first — the tvOS
                    // gate. The Quality picker stays live so a manual pick is always available immediately.
                    // AUTO-PICK: race the top cached candidates in parallel via `playBest` when the caller
                    // wired it (best first, ranking order preserved), else the single-resolve `play(best)`.
                    Button { if let playBest { playBest(groups.flatMap(\.streams), best) } else { (playAuto ?? play)(best, url) } } label: {
                        if loading {
                            HStack(spacing: Theme.Space.sm) {
                                ProgressView().tint(Theme.Palette.onAccent)
                                Text(progress.total > 0 ? "Finding best…  \(progress.loaded)/\(progress.total)" : "Finding best…")
                            }
                        } else {
                            Label("Watch in \(StreamRanking.watchLabel(best))", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(loading)
                    .opacity(loading ? 0.55 : 1)

                    qualityMenu
                }
            }
            HStack(spacing: Theme.Space.sm) {
                Button { withAnimation { showAllSources.toggle() } } label: {
                    Label(showAllSources ? "Hide sources" : "All sources · \(streamCount)",
                          systemImage: showAllSources ? "chevron.up" : "list.bullet")
                }
                .buttonStyle(ChipButtonStyle(selected: showAllSources))
                Spacer(minLength: 0)
            }
        }
    }

    /// The visible quality dropdown, two levels like tvOS: resolution tier first (4K / 1080p / 720p /
    /// Others), then the flavour variants inside it (Dolby Vision · Remux, HDR · Atmos, …). A native
    /// `Menu` with submenus is the touch / Mac idiom for the tvOS two-step `confirmationDialog`.
    @ViewBuilder private var qualityMenu: some View {
        let tiers = resolutionTiers
        if !tiers.isEmpty {
            Menu {
                ForEach(tiers, id: \.self) { tier in
                    Menu(tier) {
                        ForEach(StreamRanking.variantOptions(groups, tier: tier), id: \.label) { option in
                            if let url = option.stream.playableURL(isEpisode: isEpisode) {
                                Button(option.label) { play(option.stream, url) }
                            }
                        }
                    }
                }
            } label: {
                Label("Quality", systemImage: "chevron.up.chevron.down")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    // MARK: Per-add-on filter chips

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                Button { sourceFilter = nil } label: { Text("All (\(streamCount))") }
                    .buttonStyle(ChipButtonStyle(selected: sourceFilter == nil))
                ForEach(groups) { group in
                    Button { sourceFilter = group.addon } label: { Text("\(group.addon) (\(group.streams.count))") }
                        .buttonStyle(ChipButtonStyle(selected: sourceFilter == group.addon))
                }
            }
            .padding(.vertical, Theme.Space.xs)
        }
    }

    // MARK: Sort control (Best · Size · Seeders)

    /// A compact segmented control to reorder the rows inside every add-on section. Best is our ranking;
    /// Size and Seeders are the two objective overrides a user reaches for (biggest file, healthiest
    /// torrent). Only shown once at least two sources exist, since a single row has nothing to sort.
    @ViewBuilder private var sortBar: some View {
        if streamCount > 1 {
            HStack(spacing: Theme.Space.sm) {
                Text("Sort")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Picker("Sort sources", selection: $sortMode) {
                    ForEach(SourceSort.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Space.xs)
            // Open the list in the sort the user last chose, and remember any change (per the Settings default).
            .onAppear { sortMode = SourceSort(key: SourcePreferences.shared.defaultSourceSort) }
            .onChange(of: sortMode) { newValue in SourcePreferences.shared.defaultSourceSort = newValue.key }
        }
    }

    // MARK: Grouped, collapsible streams

    /// One collapsible section per add-on. LazyVStack so only on-screen rows are built — a popular
    /// title can return thousands of sources, and instantiating them all at once OOM-crashed on tvOS.
    private var groupedList: some View {
        let plan = windowedPlan
        return LazyVStack(spacing: Theme.Space.sm) {
            ForEach(plan.groups) { wg in
                // Header + rows as flat SIBLINGS, NOT wrapped in `Section {} header: {}`. On macOS the
                // LazyVStack + Section(header:) combo mis-measures section geometry during lazy realization -
                // a not-yet-built section reserves a near-viewport-height blank, which is the reported
                // "sources vanish / big blank gaps on scroll". Emitting them flat removes that reservation
                // while KEEPING the LazyVStack, so a title with thousands of sources still won't OOM on tvOS.
                sectionHeader(wg.group)
                if !collapsed.contains(wg.group.addon) {
                    ForEach(wg.rows) { row in streamRow(row.addon, row.stream) }
                }
            }
            if plan.shown < plan.expandable {
                Button { renderLimit += Self.sourceWindowStep } label: {
                    Label("Show more · \(plan.expandable - plan.shown) more", systemImage: "chevron.down")
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
    }

    /// Tappable add-on header: name + source count + a chevron that folds the section away. Styled as
    /// a Theme surface card so the grouping reads as a clean, deliberate section like tvOS.
    private func sectionHeader(_ group: CoreStreamSourceGroup) -> some View {
        let isCollapsed = collapsed.contains(group.addon)
        return Button {
            withAnimation(Theme.Motion.state) {
                if isCollapsed { collapsed.remove(group.addon) } else { collapsed.insert(group.addon) }
            }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Text(group.addon.uppercased())
                    .font(Theme.Typography.eyebrow).tracking(1.5)
                    .foregroundStyle(Theme.Palette.accent)
                Text("\(group.streams.count)")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                Spacer(minLength: 0)
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Glass the collapsible per-addon section header so the grouping reads as a deliberate
            // raised card, matching the settings-card language used across the app's chrome.
            .vortxSettingsCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.addon) sources")
        .accessibilityHint(isCollapsed ? "Double-tap to expand" : "Double-tap to collapse")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func streamRow(_ addon: String, _ stream: CoreStream) -> some View {
        if let url = stream.playableURL(isEpisode: isEpisode) {
            HStack(spacing: Theme.Space.sm) {
                Button { play(stream, url) } label: {
                    iOSStreamLabel(addon: addon, stream: stream, enabled: true, pinned: isPinned(addon, stream),
                                   debridCached: isDebridCached(stream))
                }
                .buttonStyle(RowFocusStyle())
                .contextMenu {
                    pinMenu(addon, stream)
                    if let download {
                        Button { download(stream, url) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    }
                }
                // A visible per-row Download affordance (the context menu carries the same action for
                // discoverability). `#if !os(tvOS)`-gated implicitly by the optional closure being nil there.
                if let download {
                    let key = url.absoluteString
                    Button {
                        download(stream, url)
                        queuedDownloads.insert(key)
                    } label: {
                        Image(systemName: queuedDownloads.contains(key) ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.Palette.accent)
                            // A full-size tap target: the bare 22pt glyph's hit area was near-untappable
                            // next to the big play row, which is why the icon read as dead (#21).
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(queuedDownloads.contains(key))
                    .accessibilityLabel(queuedDownloads.contains(key) ? "Download queued" : "Download this source")
                    .padding(.trailing, Theme.Space.xs)
                }
            }
        } else {
            iOSStreamLabel(addon: addon, stream: stream, enabled: false, pinned: false,
                           debridCached: isDebridCached(stream))
                // The disabled (no playable URL) source row sits on the shared card glass so it reads
                // as the same surface family as the loading / empty state cards, just non-interactive.
                .vortxGlassListRow(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    /// True when this row is confirmed cached in the user's debrid account (drives the row ⚡). A raw
    /// torrent matches by infoHash; a USENET row matches its nzb link against the usenet-cached set. False
    /// for every stream when both sets are empty (no key / not yet checked), so no chips render.
    private func isDebridCached(_ stream: CoreStream) -> Bool {
        if let nzb = stream.nzbUrl, !nzb.isEmpty {
            return !cachedUsenetURLs.isEmpty && cachedUsenetURLs.contains(nzb)
        }
        guard !cachedHashes.isEmpty, let h = stream.infoHash?.lowercased() else { return false }
        return cachedHashes.contains(h)
    }

    /// True when this stream is the one the effective pin floats to the top - drives the row's pin badge.
    private func isPinned(_ addon: String, _ stream: CoreStream) -> Bool {
        guard let ctx = pinContext, let pin = pinStore.effectivePin(ctx) else { return false }
        return SourcePinStore.matches(stream, addon: addon, pin: pin)
    }

    /// Long-press / right-click menu: pin this source for just this title, or for every title, or unpin.
    /// A pin is a strong preference (it tops the list + auto-pick), not a lock - failover still hops if dead.
    @ViewBuilder private func pinMenu(_ addon: String, _ stream: CoreStream) -> some View {
        if let ctx = pinContext {
            Button {
                pinStore.pin(stream, addon: addon, scope: .entry, context: ctx)
            } label: { Label("Pin for this \(ctx.entryNoun)", systemImage: "pin") }
            Button {
                pinStore.pin(stream, addon: addon, scope: .global, context: ctx)
            } label: { Label("Pin everywhere", systemImage: "pin.circle") }
            if pinStore.entryPin(ctx) != nil {
                Button(role: .destructive) {
                    pinStore.unpin(scope: .entry, context: ctx)
                } label: { Label("Unpin this \(ctx.entryNoun)", systemImage: "pin.slash") }
            }
            if pinStore.global != nil {
                Button(role: .destructive) {
                    pinStore.unpin(scope: .global, context: ctx)
                } label: { Label("Unpin everywhere", systemImage: "pin.slash") }
            }
        }
    }

    private var eyebrow: String {
        let count = streamCount
        if count == 0 { return loading ? "Searching" : "None found" }
        return loading ? "\(count) so far" : "\(count) source\(count == 1 ? "" : "s")"
    }
}

/// Equatable so `.equatable()` lets SwiftUI SKIP diffing the (potentially 1000+ row) list when an
/// unrelated detail re-render passes identical inputs. The closures (play / download / ...) are
/// deliberately excluded: they are recreated per parent eval but never change behavior. `groups`
/// comes from `SourceListModel`'s published array, which stays the SAME instance until the model
/// republishes, so the array compare is a buffer-identity fast path, not an element walk.
extension iOSSourceList: Equatable {
    static func == (lhs: iOSSourceList, rhs: iOSSourceList) -> Bool {
        lhs.isSuspended == rhs.isSuspended
            && lhs.isEpisode == rhs.isEpisode
            && lhs.settleTimedOut == rhs.settleTimedOut
            && lhs.showsPrimaryControls == rhs.showsPrimaryControls
            && lhs.progress == rhs.progress
            && lhs.continuity == rhs.continuity
            && lhs.pinContext == rhs.pinContext
            && lhs.cachedHashes == rhs.cachedHashes
            && lhs.cachedUsenetURLs == rhs.cachedUsenetURLs
            && lhs.states == rhs.states
            && lhs.bestStream == rhs.bestStream
            && lhs.resolutionTiers == rhs.resolutionTiers
            && lhs.groups == rhs.groups
    }
}

/// A CLEAN source row, mirroring the tvOS stream list's parsed labelling instead of dumping the
/// add-on's raw verbose blurb (e.g. "Stream Expression (308) / Included Reasons / Removal Reasons /
/// digitalRelease Bypass"). It shows: a leading play/torrent icon, a quality badge (4K / 1080p / …)
/// next to the add-on + TORRENT badges, the parsed flavour tags (Remux · HDR · Atmos · HEVC · Cached)
/// + file size, and a single trimmed title line for human context — built from `StreamRanking.sourceDetail`
/// and `StreamRanking.qualityLabel`, the same parse that powers the Watch / Quality affordances.
private struct iOSStreamLabel: View {
    let addon: String
    let stream: CoreStream
    let enabled: Bool
    var pinned: Bool = false
    /// This raw torrent is cached in the user's debrid account (coordinator-confirmed). The row ALSO lights
    /// the "⚡ CACHED" badge when the add-on's own text marks the source cached, so this only needs to be the
    /// native-hash signal; false by default so a coordinator with no key still defers to the text markers.
    var debridCached: Bool = false
    /// Compact rows (#117): keep only the parsed line (quality badge + flavour tags + size + add-on) and
    /// hide the raw release-name line beneath it. Device-local display preference; tvOS reads the SAME key.
    @AppStorage("vortx.streams.compactLabels") private var compactLabels = false

    var body: some View {
        let quality = StreamRanking.qualityLabel(stream)        // "4K" / "1080p" / "Best"
        // A row is cached when EITHER the native coordinator confirmed this raw torrent's hash
        // (`debridCached`) OR the add-on's own text carries a cache marker (⚡ / [RD+] / "cached" / …).
        // Owner's streams are pre-resolved debrid-ADDON links, so the native hash check collects nothing;
        // the text-marker path is what actually lights the badge for him. `signature` is the public
        // wrapper over the private `qualityText`, so it's the same text `isCached` parses internally.
        let cached = debridCached || StreamRanking.isCached(stream, StreamRanking.signature(stream))
        // Drop the plain "Cached" flavour chip when the row already shows the prominent "⚡ CACHED" badge,
        // so a cached row reads as one bolt badge, not a doubled bolt-plus-plain-"Cached".
        let flavors = StreamRanking.flavorTags(stream).filter { !($0 == "Cached" && cached) }
        let size = StreamRanking.sizeText(stream)
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: enabled ? (stream.isTorrent ? "arrow.down.circle.fill" : "play.circle.fill") : "lock.circle")
                .font(.system(size: 26))
                .foregroundStyle(enabled ? Theme.Palette.accent : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 6) {
                // On a narrow iPhone (below `Theme.Space.wideLayoutMinWidth`) the source column runs to
                // `.infinity` and the badge row's only width guard is each badge's `fixedSize`, so a long
                // add-on name plus the TORRENT / CACHED pills could run off-screen. A horizontal scroll keeps
                // every badge at its intrinsic width and lets the row scroll instead of overflowing; on wide
                // layouts they all fit, so nothing scrolls and the look is unchanged.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.Palette.accent)
                                .accessibilityLabel("Pinned source")
                        }
                        badge(quality, prominent: true)
                        // Skip the add-on badge when it only repeats the resolution: some add-on configs are
                        // literally named "1080p" / "4K", which rendered as a second quality pill next to the
                        // one above (the reported double tag). Real add-on names still show.
                        if addon.uppercased() != quality.uppercased() { badge(addon.uppercased()) }
                        if stream.isTorrent { badge("TORRENT") }
                        // Cache chip: instant from the user's debrid account (coordinator-confirmed raw torrent)
                        // OR the add-on already advertises the source as cached. Reuses the prominent (accent)
                        // badge style with a bolt glyph; only shows when cached.
                        if cached { badge("⚡ CACHED", prominent: true) }
                    }
                }
                // Parsed flavour tags + size — the clean line tvOS shows, minus the resolution (it is
                // the prominent badge above), so the row never reads as a doubled "4K · 4K · HDR".
                if !flavors.isEmpty || size != nil {
                    HStack(spacing: 8) {
                        if !flavors.isEmpty {
                            Text(flavors.joined(separator: " · "))
                                .font(Theme.Typography.label)
                                .foregroundStyle(enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                                .lineLimit(1)
                        }
                        if let size {
                            Text(size)
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                // The release title for human context. Allowed two lines so the fuller release name
                // shows (people want the detail) while a verbose multi-line add-on blurb still can't
                // run away — `cleanTitle` already keeps only the first line of the add-on's name.
                // Compact rows (#117) drop this line entirely: the parsed badges + tags + size above
                // are the whole row.
                if !compactLabels, let title = cleanTitle {
                    Text(title)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .opacity(enabled ? 1 : 0.55)
    }

    /// A single trimmed context line: the actual RELEASE NAME. Prefer behaviorHints.filename — it is the
    /// only field that distinguishes "...Deathly.Hallows.Part.1..." from "Part.2", which a short add-on
    /// label / quality blurb in `name` drops. Fall back to the stream `name`, then the first line of
    /// `description`. Newlines collapse to the first line and a trailing container extension is stripped;
    /// never the full multi-line blurb (the row is lineLimit(2), tail-truncated).
    private var cleanTitle: String? {
        let candidates = [stream.behaviorHints?.filename, stream.name, stream.description]
        guard let raw = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        var trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if let dot = trimmed.lastIndex(of: "."), trimmed.distance(from: dot, to: trimmed.endIndex) <= 6 {
            let ext = trimmed[trimmed.index(after: dot)...].lowercased()
            if ["mkv", "mp4", "avi", "ts", "m2ts", "webm", "mov", "wmv"].contains(ext) {
                trimmed = String(trimmed[..<dot]).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder private func badge(_ text: String, prominent: Bool = false) -> some View {
        let label = Text(text).font(Theme.Typography.eyebrow).tracking(1)
            // Keep the badge (including the add-on / debrid / source name) on a single horizontal line at
            // its intrinsic width. Without fixedSize a sibling badge could squeeze the name pill to a
            // near-zero width, wrapping the name to 2-3 characters per line (the reported vertical text).
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(prominent ? Theme.Palette.accent : Theme.Palette.textSecondary)
        if prominent {
            // The prominent (quality / CACHED) badge carries meaning through its ember accent tint, so it
            // stays a SOLID accent pill rather than glass.
            label.background(Theme.Palette.accent.opacity(0.22), in: Capsule())
        } else {
            // Neutral stream badges (add-on name, TORRENT) become badge-alpha glass pills so they read as
            // raised chrome; the flat shadow keeps them inline without floating.
            label.vortxGlass(in: Capsule(), fillAlpha: VortXGlass.badgeFillAlpha, shadow: .flat)
        }
    }
}

/// A focusable-looking loading card while sources stream in.
private struct iOSLoadingRow: View {
    let text: String
    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ProgressView().tint(Theme.Palette.accent)
            Text(text).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The "sources streaming in" card sits on the shared card glass (own padding kept, so the
        // settings-card composite's padding is not layered on top).
        .vortxGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
                    fillAlpha: VortXGlass.cardFillAlpha, shadow: .card)
    }
}

/// The "nothing playable" state card.
private struct iOSEmptyRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.Palette.textTertiary)
            Text(text).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The "nothing playable" state card sits on the shared card glass (own padding kept).
        .vortxGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
                    fillAlpha: VortXGlass.cardFillAlpha, shadow: .card)
    }
}

/// Add / remove the open title from the engine library — the touch/Mac twin of the tvOS LibraryChip.
private struct iOSLibraryChip: View {
    @EnvironmentObject private var core: CoreBridge

    var body: some View {
        let saved = core.detailInLibrary
        Button {
            if saved {
                core.removeDetailFromLibrary()   // removes from library + mirrors to external watchlists
            } else {
                core.addDetailToLibrary()
            }
        } label: {
            Label(saved ? "In Library" : "Add to Library",
                  systemImage: saved ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(ChipButtonStyle(selected: saved))
    }
}

/// Add / remove the open title from the local "want to watch" watchlist (`LibraryAutoAdd`) — a pure app-side
/// bookmark separate from the engine Library, engine-safe ids only (tt / tmdb). Reads the open title from the
/// engine detail meta exactly like `iOSLibraryChip` reads `core.detailInLibrary`, so it needs no call-site
/// plumbing; a synthetic magnet / paste-a-link title (no tt / tmdb id) hides the chip since it can't be
/// watchlisted. The touch/Mac twin of the tvOS `WatchlistChip`.
private struct iOSWatchlistChip: View {
    @EnvironmentObject private var core: CoreBridge
    @State private var isWatchlisted = false

    var body: some View {
        if let meta = core.metaDetails?.meta, meta.id.hasPrefix("tt") || meta.id.hasPrefix("tmdb") {
            Button {
                isWatchlisted = LibraryAutoAdd.toggleWatchlist(id: meta.id, type: meta.type,
                                                               name: meta.name, poster: meta.poster)
            } label: {
                Label(isWatchlisted ? "In Watchlist" : "Watchlist",
                      systemImage: isWatchlisted ? "star.fill" : "star")
            }
            .buttonStyle(ChipButtonStyle(selected: isWatchlisted))
            .onAppear { isWatchlisted = LibraryAutoAdd.isWatchlisted(meta.id) }
            .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in
                isWatchlisted = LibraryAutoAdd.isWatchlisted(meta.id)
            }
        }
    }
}

#if os(iOS)
/// Re-arms UINavigationController's interactive edge-swipe back on a pushed detail whose system nav
/// bar is hidden (`.toolbar(.hidden, for: .navigationBar)`, the cinematic full-bleed hero): with the
/// bar hidden UIKit's built-in gesture delegate refuses to begin the pop, which left the chrome-less
/// live/sport detail with no swipe escape (#125). A zero-size hosted probe reaches the enclosing
/// navigation controller once it joins the UIKit hierarchy and points the recognizer at a shared
/// delegate that allows the pop whenever a page is actually pushed.
private struct RestoreSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) {}

    final class Probe: UIViewController {
        // Re-arm at both attach points: didMove(toParent:) fires when SwiftUI hosts the probe (the
        // navigation controller may not be reachable yet on the first push), viewWillAppear when the
        // page is definitely on the stack. Both are idempotent assignments, so double-firing is free.
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            rearm()
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            rearm()
        }
        private func rearm() {
            guard let pop = navigationController?.interactivePopGestureRecognizer else { return }
            pop.isEnabled = true
            // Hand the recognizer a LONG-LIVED shared delegate, never this soon-to-pop controller:
            // the recognizer only holds its delegate weakly, so a per-page delegate would dangle
            // after the pop and leave an ungated recognizer swallowing edge drags at root.
            // Note: swapping the delegate also bypasses the system's hidesBackButton refusal. Fine
            // today (no .navigationBarBackButtonHidden exists in the app); a future intentionally
            // trapped flow must extend SwipeBackGate to keep refusing there.
            pop.delegate = SwipeBackGate.shared
        }
    }
}

/// The one delegate for every re-armed pop recognizer: allow the interactive pop only while its own
/// navigation controller (recovered from the recognizer's view, since each tab's NavigationStack has
/// its own) has a page pushed. At root the gesture stays inert; grabbing it there wedges the stack.
private final class SwipeBackGate: NSObject, UIGestureRecognizerDelegate {
    static let shared = SwipeBackGate()
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        var responder: UIResponder? = gestureRecognizer.view
        while let r = responder {
            // Refuse while a push/pop is already animating (transitionCoordinator non-nil): beginning an
            // interactive pop mid-transition is the classic pop-while-pushing stack corruption.
            if let nav = r as? UINavigationController {
                return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
            }
            responder = r.next
        }
        return false
    }
}
#endif
