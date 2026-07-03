import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Torrents: ask the embedded server to start fetching peers before playback. No-op for direct/debrid
/// URLs (those carry a `url`, so no `/create` is needed). Port of the tvOS `prepareTorrent`, reusing
/// the shared `TorrentTrackers.sources` so the create carries the TCP/TLS trackers that reach a swarm
/// from a sandboxed app. File-private free function so both the movie list and the per-episode list
/// share one implementation. Returns the retry Task (or nil for a non-torrent / disabled prime) so the
/// caller can store and cancel it — the backoff loop outlives the view otherwise, leaking on every pick.
@discardableResult
private func prepareTorrentStream(_ stream: CoreStream) -> Task<Void, Never>? {
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
                                        debridCachedHashes: cachedHashes),
          let url = best.playableURL else { return nil }
    core.loadEnginePlayer(for: best)
    _ = prepareTorrentStream(best)   // fire-and-forget prime; self-terminating backoff
    let pm = PlaybackMeta(libraryId: seriesId, videoId: v.id, type: "series",
                          name: seriesName, poster: v.thumbnail ?? fallbackPoster,
                          season: v.season, episode: v.episode)
    let title = "\(seriesName)  ·  S\(v.season ?? defaultSeason)E\(v.episodeNumber)"
    let resume: Double
    if let engine = core.engineResumeSeconds(for: pm) { resume = engine }
    else { resume = await account.resumeOffset(for: pm) }
    return PlayerEpisodeStream(stream: best, url: url, meta: pm, title: title, resume: resume)
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
        if core.metaDetails?.meta?.id == id, let t = core.metaDetails?.meta?.type, !t.isEmpty { return t }
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

    // A SINGLE presentation slot drives every full-screen cover (player OR trailer). On macOS the
    // `platformFullScreenPlayerCover(item:)` calls become a `.sheet(item:)`, and two sheets attached to
    // the same view shadow each other — so tapping Watch could fail to present the player at all.
    // Driving both from one enum-typed item guarantees exactly one cover is ever attached, so Watch
    // always presents reliably. The player-cover variant sizes its content to fill the macOS window.
    @State private var presentation: Presentation?
    @State private var preparing = false                 // movie Watch Now is resolving
    @State private var season = 1
    @State private var settleTimedOut = false            // movie/live resolution gave up → "No sources found", not a spinner
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
    #if !os(tvOS)
    @ObservedObject private var downloads = DownloadStore.shared   // offline-download state for the hero "Download" affordance (#30)
    #endif
    @State private var torrentPrime: Task<Void, Never>?  // outstanding torrent /create retry loop, cancelled on disappear / new pick
    @State private var similarItems: [MetaPreview] = []
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
        guard viewport > 0 else { return 560 }
        return min(760, max(560, viewport * 0.58))
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
                            moreLikeThisSection
                        }
                    }
                    .padding(.bottom, Theme.Space.xl)
                    .frame(width: geo.size.width, alignment: .leading)
                }
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        // A6: the rare "no trailer available right now" notice (no full YouTube trailer AND no /clip). A small
        // capsule, auto-dismissed by `showTrailerNotice`, so the Trailer button never opens the source-error screen.
        .overlay(alignment: .top) {
            if trailerNotice {
                Text("Trailer is preparing, try again shortly")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    .background(.black.opacity(0.72), in: Capsule())
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
        #endif
        // macOS has no toolbar back button (toolbar removed), so supply an in-content Back + Esc / Cmd-[.
        .macBackAffordance()
        // Guard the meta load: the shared CoreBridge already holds this title's meta on an A -> back -> A
        // revisit, so re-loading it churns the engine and momentarily blanks the hero for no reason.
        .onAppear {
            if effectiveType == "series" {
                // A series detail loads meta only; streams load per-episode from iOSEpisodeStreams.
                if core.metaDetails?.meta?.id != id { core.loadMeta(type: effectiveType, id: id) }
            } else if core.metaDetails?.meta?.id == id {
                loadMovieStreamsIfNeeded()        // meta already resident → dispatch streams now
            } else {
                core.loadMeta(type: effectiveType, id: id) // load meta FIRST; onChange dispatches streams on arrival
                // For an imdb tt id whose Cinemeta meta may never arrive (new/unreleased title), don't wait
                // on the onChange(meta?.id) that would never fire: fire the tt-keyed streams now so the
                // sources list populates regardless of the meta race. No-op'd by hasStreams once they land.
                loadMovieStreamsIfNeeded()
            }
            if let m = core.metaDetails?.meta, m.id == id { loadSimilar(m); loadRatings(); loadWatchProviders(); loadFinancials(); loadReleaseDates(); resolveTrailerIfNeeded(m); resolvePreferredTrailerIfNeeded(m) }
            // These resolve from the tt id alone, so a hub-seeded title whose Cinemeta meta never
            // arrives still gets its cast, synopsis fallback, and a More-Like-This rail (#7/#29).
            loadCredits()
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
        .onChange(of: core.metaDetails?.meta?.type) { _ in
            if effectiveType != "series" { loadMovieStreamsIfNeeded() }
        }
        .onChange(of: core.metaDetails?.meta?.id) { _ in
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
            refreshLanguageChips()
        }
        // Do NOT unloadMeta here. On iOS, pushing the per-episode page (iOSEpisodeStreams) fires THIS
        // detail page's onDisappear AFTER the episode page has already loaded its streams — so calling
        // unloadMeta would wipe `metaDetails` out from under the episode page (~0.3s later), leaving its
        // source list empty ("No stream add-ons responded"). That race is why SERIES found no streams on
        // iOS while MOVIES (no child push) and macOS (different onDisappear timing) worked. The next
        // detail's loadMeta replaces the resident meta anyway, so leaving it loaded is harmless.
        .onDisappear { torrentPrime?.cancel() }
        // Flip the spinner to "No sources found" if resolution hangs past 12s (mirrors iOSEpisodeStreams).
        .task {
            try? await Task.sleep(for: .seconds(20))
            settleTimedOut = true
        }
        // Debrid cache awareness: as add-ons answer (the load count climbs), check which raw torrents the
        // user's debrid account has cached. `refresh` de-dups by the hash set, so this only hits a provider
        // when the torrents actually change; with no debrid key it returns an empty set and nothing renders.
        // Series load streams per-episode (iOSEpisodeStreams owns its own awareness); movie + live read here.
        .onChange(of: core.streamLoadProgress().loaded) { _ in
            // Cache awareness reads the UNFILTERED groups PLUS the TorBox search sources (usenet + torrent):
            // the Direct-links-only filter drops raw torrents, but a raw torrent / usenet nzb is exactly what
            // the native cache-check needs, so filtering here would starve the check. Cache awareness is
            // orthogonal to the playback filter.
            if effectiveType != "series" {
                debridCache.refresh(from: torboxSearch.merged(into: core.streamGroups()))
                refreshSourceIndex()   // SERVE + HOARD the community source index as more sources answer
            }
            refreshLanguageChips()   // recompute the "Also available in" chips as more sources answer
        }
        // TorBox search-as-a-source: fetch the extra usenet/torrent sources once the meta's imdb id is
        // known (gated on a TorBox key inside `refresh`; de-duped by imdb id). Series episodes fetch in
        // their own episode view.
        .onChange(of: core.metaDetails?.meta?.id) { _ in
            if effectiveType != "series" { torboxSearch.refresh(imdbId: ratingsImdbID); refreshSourceIndex() }
        }
        .onAppear { if effectiveType != "series" { torboxSearch.refresh(imdbId: ratingsImdbID); refreshSourceIndex() } }
        .platformFullScreenPlayerCover(item: $presentation) { item in
            switch item {
            case .player(let launch):
                PlayerScreen(
                    url: launch.url, title: launch.title, headers: launch.headers, resumeSeconds: launch.resume,
                    recordMeta: launch.meta, recordQualityText: launch.qualityText,
                    recordBingeGroup: launch.bingeGroup, recordIsTorrent: launch.isTorrent,
                    recordDebridRef: launch.debridRef,
                    // reportProgress feeds the engine Player (TimeChanged) so Continue Watching updates live and
                    // watched time is tracked; saveProgress keeps the signed-in remote/overlay sync. iOS was only
                    // doing the latter, so nothing reached the engine and CW never updated (tvOS does both).
                    onProgress: { pos, dur in core.reportProgress(timeSeconds: pos, durationSeconds: dur); Task { [weak account] in await account?.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                    onSeek: { pos, dur in core.reportProgress(timeSeconds: pos, durationSeconds: dur); Task { [weak account] in await account?.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                    onClose: { presentation = nil }
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
        let band = heroBandHeight(viewport: height)
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            ZStack(alignment: .bottomLeading) {
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
        }
        .frame(width: width, alignment: .leading)
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
            CircleIconButton(systemName: "chevron.left", diameter: Theme.Control.circleChrome) { dismiss() }
                .accessibilityLabel("Back")
            Spacer()
            Menu {
                if let m = core.metaDetails?.meta {
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
                                .background(Theme.Palette.surface2, in: Capsule())
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
            case .success(let img): img.resizable().aspectRatio(contentMode: (type == "series" && (meta?.background?.isEmpty ?? true)) ? .fit : .fill)
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
                    await MainActor.run { if core.metaDetails?.meta?.id == m.id { resolvedTrailerID = yt } }
                    return
                }
            }
            // 2) TMDB /videos (when a TMDB key is set) fills Cinemeta's gaps and covers tmdb: catalog ids
            //    with no IMDb id (the same source Stremio trailer add-ons use).
            if let yt = await TMDBClient.trailerYouTubeID(metaID: m.id, type: m.type), !yt.isEmpty {
                await MainActor.run { if core.metaDetails?.meta?.id == m.id { resolvedTrailerID = yt } }
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
            await MainActor.run { if core.metaDetails?.meta?.id == m.id { resolvedPreferredTrailerID = yt } }
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
                    HStack(spacing: Theme.Space.xs) {
                        Text("Cast & Crew")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textPrimary)
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

    /// Horizontally scrollable full-cast rail: photo circle, actor name, character name beneath: ALL
    /// entries, not a 3-name line. LazyHStack so a 60-member ensemble builds on demand.
    @ViewBuilder private var castRail: some View {
        if !railCastMembers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.md) {
                    ForEach(railCastMembers) { member in
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
                }
                .padding(.vertical, 2)
            }
        }
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

    /// The watched episode-id set for the open series: the engine's computed set for
    /// engine-history profiles, the profile overlay's set otherwise — the exact same
    /// invariant tvOS uses for its ticks, dimming, and primary-episode pick.
    private var watchedSet: Set<String> {
        guard let m = meta else { return [] }
        return profiles.activeUsesEngineHistory
            ? (core.metaDetails?.watchedIds ?? [])
            : profiles.watchedVideoIds(forMeta: m.id)
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
                // Offline (#30): download the primary episode's auto-picked source — the series twin of the
                // movie Download chip. Gated on the primary episode resolving; the chip reflects state.
                if let primary {
                    downloadChip(videoId: primary.video.id, ready: true) {
                        Task { await downloadBestSeries(primary.video) }
                    }
                }
                #endif
                trailerButton
                iOSLibraryChip()
                shareChip
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    /// Resume position (the saved episode, if not yet watched) vs the first unwatched episode,
    /// vs the first episode — a straight port of the tvOS `seriesPrimaryEpisode`.
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
        if resume.timeOffsetMs > 0,
           let videoId = resume.videoId,
           let video = sorted.first(where: { $0.id == videoId }),
           !watched.contains(video.id) {
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
        if let m = core.metaDetails?.meta {
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
        let groups = StreamRanking.rankedGroups(displayGroups(core.streamGroups()), pin: sourcePin,
                                                debridCachedHashes: debridCache.cachedHashes)
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

            // Secondary actions wrap beneath the CTA. FlowLayout keeps each chip at its natural width and
            // drops overflow onto the next line under the hero's hard width cap.
            FlowLayout(spacing: Theme.Space.sm) {
                qualityMenu(groups)

                #if !os(tvOS)
                // Offline (#30): download the best source, the offline twin of Watch Now. The chip reflects
                // state (idle / Downloading / Downloaded) so a tap gives visible feedback.
                downloadChip(videoId: meta?.id ?? id, ready: movieReady) { Task { await downloadBest() } }
                #endif

                Button { scrollToSources() } label: {
                    Label(sourceTotal > 0 ? "Sources · \(sourceTotal)" : "Sources",
                          systemImage: "list.bullet")
                }
                .buttonStyle(ChipButtonStyle())

                trailerButton
                iOSLibraryChip()
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
        let tiers = StreamRanking.tiers(groups)
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
        iOSSourceList(
            groups: StreamRanking.rankedGroups(displayGroups(core.streamGroups()), pin: sourcePin,
                                               debridCachedHashes: debridCache.cachedHashes),
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
            download: movieDownloadHandler
        )
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
    private var movieStreamId: String {
        if let dv = core.metaDetails?.meta?.behaviorHints?.defaultVideoId, !dv.isEmpty, dv != id { return dv }
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
        let metaResident = core.metaDetails?.meta?.id == id
        guard metaResident || id.hasPrefix("tt") else { return }
        let streamId = movieStreamId
        let hasStreams = core.metaDetails?.streams.contains { $0.request.path.id == streamId } ?? false
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
        if let dv = core.metaDetails?.meta?.behaviorHints?.defaultVideoId, dv.hasPrefix("tt") { return dv }
        return id.hasPrefix("tt") ? id : nil
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
        // AGGREGATE across EVERY loaded source for this title (all add-ons), scanning BOTH the stream `name`
        // AND its `description`: add-ons commonly split the release name into `name` and the audio/sub language
        // tags into `description` (or vice-versa), so `name ?? description` under-labelled a lazy add-on. Taking
        // both widens the union of language tokens (MULTI, DUAL, KOR+ENG, audio/sub tags) we can see.
        let names: [String] = displayGroups(core.streamGroups())
            .flatMap { $0.streams }
            .flatMap { [$0.name, $0.description] }
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        // Re-run only when the title or the set of observed names changes (sources stream in over time).
        let key = "\(contentKey)#\(names.count)"
        guard key != langChipsKey else { return }
        langChipsKey = key

        // Split into AUDIO vs SUBTITLE claims per stream context: a bare release-name language word is an audio
        // claim (verified below); a code from a subtitle-marked string (vostfr, "ESubs", ...) is a subtitle
        // claim (kept). This split is what lets the verify drop a FALSE audio claim without dropping real subs.
        let observed = LanguageIndexClient.audioSubCodes(fromNames: names)
        let imdb = ratingsImdbID
        Task { @MainActor in
            // Fetch the community index AND TMDB's real spoken_languages in PARALLEL: the two verification
            // sources for a name-parsed audio claim. Both fail soft to nil (no signal), never falsely contradict.
            async let availabilityTask = LanguageIndexClient.fetch(contentKey: contentKey)
            async let spokenTask = TMDBClient.spokenLanguages(imdbID: imdb, type: type)
            let availability = await availabilityTask
            let tmdbSpoken = await spokenTask
            // Guard against a title switch mid-fetch.
            guard languageContentKey == contentKey else { return }
            // VERIFY: drop a name-only AUDIO language that BOTH TMDB (not in spoken_languages) and the community
            // (no/low count) contradict -- the false-claim fix. Subtitle + community + TMDB codes are kept.
            // The chip row is horizontally scrollable now (#8), so a wider cap fits without clutter.
            langChips = LanguageIndexClient.verifiedAvailabilityChips(observedAudio: observed.audio,
                                                                      observedSub: observed.sub,
                                                                      availability: availability,
                                                                      tmdbSpoken: tmdbSpoken,
                                                                      limit: 24)
        }
        // Fire-and-forget: contribute the name-parsed codes so the index learns from real users.
        Task.detached {
            await LanguageIndexClient.contribute(contentKey: contentKey,
                                                 audioLangs: observed.audio,
                                                 subLangs: observed.sub,
                                                 provenance: "name")
        }
    }

    /// Community source index (movie/live): the SERVE + HOARD driver. SERVE refreshes the pooled community
    /// sources for the title (gated on the Singularity toggle + sign-in inside the client), and HOARD
    /// fire-and-forgets the assembled source descriptors so the pool learns from this resolve. Both are
    /// fully gated + fail-soft in `SourceIndexClient` (consent / fleet flag / toggle / login), so this is a
    /// hard no-op when the feature is off. De-duped per title; safe to call as sources stream in.
    private func refreshSourceIndex() {
        guard let contentID = SourceIndexClient.contentID(imdbId: ratingsImdbID) else { return }
        sourceIndex.refresh(contentID: contentID, isSignedIn: account.isSignedIn)
        // HOARD: report the anonymized descriptors from the UNFILTERED assembled groups (the pool should see
        // torrents even when the user hides them locally). Includes the TorBox search sources. No user data.
        let groups = torboxSearch.merged(into: core.streamGroups())
        guard !groups.isEmpty else { return }
        Task.detached { await SourceIndexClient.hoard(contentID: contentID, groups: groups) }
    }

    /// Fetch cross-provider ratings for this title. Prefers the VortX ratings service (no user key
    /// needed: IMDb keyless, RT/Metacritic via VortX's server-side key), then fills any gap from the
    /// user's own MDBList key if they set one. Fail-soft: leaves the row hidden on any miss. Skipped for
    /// live channels, which carry no ratings.
    private func loadRatings() {
        guard !LiveTypes.contains(type), let imdb = ratingsImdbID, mdbRatings == nil else { return }
        Task {
            let vx = await VortXRatingsClient.ratings(imdbID: imdb, type: type)
            // Only reach for the user's MDBList key to fill what VortX did not return (e.g. RT before the
            // server key is set), so most users need no key at all.
            let needsMore = vx == nil || vx?.rottenTomatoes == nil
            let mdb = needsMore ? await MDBListClient.ratings(imdbID: imdb, type: type) : nil
            let merged = MDBListRatings(
                imdb: vx?.imdb ?? mdb?.imdb,
                rottenTomatoes: vx?.rottenTomatoes ?? mdb?.rottenTomatoes,
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
        let withSearch = sourceIndex.merged(into: torboxSearch.merged(into: groups))
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

    /// The best source for the movie, honoring Direct-links-only and the remembered-quality continuity.
    private var movieBest: CoreStream? {
        StreamRanking.best(displayGroups(core.streamGroups()), continuity: rememberedQuality, pin: sourcePin,
                           debridCachedHashes: debridCache.cachedHashes)
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

    /// D10: `fromStart` plays the SAME best stream from 0:00, ignoring the saved resume position WITHOUT
    /// clearing it (the stored resume point is untouched; playback just starts at 0). Default false keeps the
    /// primary Play/Resume behaviour (seek to the saved position).
    private func playMovie(fromStart: Bool = false) async {
        // A4b: no longer gated on `meta != nil` — a hub-opened title with nil/mismatched Cinemeta meta still
        // has a resolved best stream (off the same groups the list renders) and plays off its seed identity.
        guard !preparing, let stream = movieBest else { return }
        preparing = true; defer { preparing = false }
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
        let candidates = StreamRanking.rankedGroups(displayGroups(core.streamGroups()), pin: sourcePin,
                                                    debridCachedHashes: debridCache.cachedHashes).flatMap(\.streams)
        if let win = await DebridCoordinator.shared.resolveFirstPlayable(
            candidates: candidates, cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs) {
            core.loadEnginePlayer(for: win.stream)
            let pm = moviePlaybackMeta
            let resumeSeconds = fromStart ? 0 : await resume(pm)
            presentation = .player(PlayerLaunch(url: win.ref.url, title: pm.name, headers: win.stream.requestHeaders,
                                                resume: resumeSeconds, meta: pm,
                                                qualityText: StreamRanking.signature(win.stream),
                                                bingeGroup: win.stream.behaviorHints?.bingeGroup,
                                                isTorrent: false, debridRef: win.ref))
            return
        }
        let ref = await DebridCoordinator.shared.resolvedPlaybackRef(for: stream)
        guard let url = ref?.url ?? stream.playableURL else { return }
        let prime = ref == nil
        if prime { primePlayback(stream) } else { core.loadEnginePlayer(for: stream) }
        let pm = moviePlaybackMeta
        // fromStart: hand the player resume 0 so it starts at the beginning. The stored resume point is NOT
        // cleared here - it stays until normal playback progress overwrites it (D10: play-from-start, not reset).
        let resumeSeconds = fromStart ? 0 : await resume(pm)
        presentation = .player(PlayerLaunch(url: url, title: pm.name, headers: stream.requestHeaders,
                                            resume: resumeSeconds, meta: pm,
                                            qualityText: StreamRanking.signature(stream),
                                            bingeGroup: stream.behaviorHints?.bingeGroup,
                                            isTorrent: !prime && stream.isTorrent, debridRef: ref))
    }

    /// Play an arbitrary chosen movie source (a tapped source-list row). `url` is the source's
    /// `playableURL`; a cached-debrid raw torrent overrides it with the direct link (fail-soft, no-key
    /// byte-identical — see `DebridCoordinator.resolvedPlaybackURL`).
    private func playStream(_ stream: CoreStream, url: URL) async {
        // A4b: no longer gated on `meta != nil` — a hub-opened title with nil meta still plays a tapped source
        // row off its seed identity (the source list itself renders without meta, so its rows must be playable).
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        let ref = await DebridCoordinator.shared.resolvedPlaybackRef(for: stream)
        let prime = ref == nil
        if prime { primePlayback(stream) } else { core.loadEnginePlayer(for: stream) }
        let pm = moviePlaybackMeta
        presentation = .player(PlayerLaunch(url: ref?.url ?? url, title: pm.name, headers: stream.requestHeaders,
                                            resume: await resume(pm), meta: pm,
                                            qualityText: StreamRanking.signature(stream),
                                            bingeGroup: stream.behaviorHints?.bingeGroup,
                                            isTorrent: !prime && stream.isTorrent, debridRef: ref))
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
        DownloadManager.shared.download(stream: stream, meta: pm, resolvedURL: resolved ?? url,
                                        sourceName: stream.name, qualityText: StreamRanking.signature(stream))
    }

    /// "Download best" — the offline twin of Watch Now: download the auto-picked best source.
    private func downloadBest() async {
        guard let stream = movieBest, let url = stream.playableURL else { return }
        await downloadStream(stream, url: url)
    }

    /// Download-best for a SERIES: queue the primary episode's auto-picked source — the offline twin of the
    /// series hero's Resume/Play, which targets the SAME episode (`seriesPrimaryEpisode`) and the SAME
    /// `StreamRanking.best` path. A series detail loads meta only, so this loads + settles that episode's
    /// streams (mirroring `iOSResolveEpisodeStream`), ranks them, resolves a cached-debrid direct link when
    /// possible, then hands the episode's series-typed `PlaybackMeta` to `DownloadManager`. No-op if nothing
    /// resolves. Device-local only; writes nothing to the account / libraryItem docs.
    private func downloadBestSeries(_ video: CoreVideo) async {
        guard let m = meta else { return }
        core.loadMeta(type: "series", id: m.id, streamType: "series", streamId: video.id)
        var groups: [CoreStreamSourceGroup] = []
        var firstPlayableAt: Date? = nil
        for _ in 0 ..< 80 {                                // ~20s ceiling, matching the episode page
            groups = displayGroups(core.streamGroups(forStreamId: video.id))
            if !groups.isEmpty, firstPlayableAt == nil { firstPlayableAt = Date() }
            let progress = core.streamLoadProgress(forStreamId: video.id)
            let elapsed = firstPlayableAt.map { Date().timeIntervalSince($0) } ?? 0
            if StreamRanking.resolveSettled(groups, loaded: progress.loaded, total: progress.total,
                                            secondsSinceFirstPlayable: elapsed, rememberedQuality: rememberedQuality) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let best = StreamRanking.best(groups, continuity: rememberedQuality, pin: sourcePin,
                                            debridCachedHashes: debridCache.cachedHashes),
              let url = best.playableURL else { return }
        let ep = video.season.flatMap { s in video.episode.map { DebridEpisode(season: s, episode: $0) } }
        let resolved = await DebridCoordinator.shared.resolvedPlaybackURL(for: best, episode: ep)
        // Same loopback-torrent prime as the per-row download (#21): the server must /create it first.
        if resolved == nil, best.isTorrent {
            torrentPrime?.cancel()
            torrentPrime = prepareTorrentStream(best)
        }
        let pm = PlaybackMeta(libraryId: m.id, videoId: video.id, type: "series",
                              name: m.name, poster: video.thumbnail ?? m.poster,
                              season: video.season, episode: video.episode)
        DownloadManager.shared.download(stream: best, meta: pm, resolvedURL: resolved ?? url,
                                        sourceName: best.name, qualityText: StreamRanking.signature(best))
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
        iOSSourceList(
            groups: StreamRanking.rankedGroups(displayGroups(core.streamGroups()), pin: sourcePin,
                                               debridCachedHashes: debridCache.cachedHashes),
            progress: core.streamLoadProgress(),
            states: core.streamAddonStates(),
            settleTimedOut: settleTimedOut,
            pinContext: pinContext,
            cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs,
            play: { stream, url in Task { await playLiveStream(stream, url: url) } }
        )
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
                                            bingeGroup: stream.behaviorHints?.bingeGroup, isTorrent: stream.isTorrent))
    }

    // MARK: Series — season selector + episode cards

    @ViewBuilder private var episodeList: some View {
        if let videos = meta?.videos, !videos.isEmpty {
            let seasons = Array(Set(videos.compactMap { $0.season })).sorted()
            let watched = watchedSet
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                iOSRailHeader(eyebrow: "\(episodes(videos).count) episode\(episodes(videos).count == 1 ? "" : "s")",
                              title: "Episodes")

                // Always render the season chips (even single-season): they host the per-season /
                // whole-series Mark-Watched menu (long-press), the same as tvOS.
                if !seasons.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.sm) {
                            ForEach(seasons, id: \.self) { s in
                                Button { season = s } label: { Text(seasonLabel(s)) }
                                    .buttonStyle(ChipButtonStyle(selected: season == s))
                                    .contextMenu { seasonWatchedMenu(s) }
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }

                VStack(spacing: Theme.Space.sm) {
                    ForEach(episodes(videos), id: \.id) { v in
                        episodeRow(v, isWatched: watched.contains(v.id), progress: episodeProgress(v))
                    }
                }
            }
            .padding(.horizontal, Theme.Space.md)
            // Initial season = first-unwatched season, else the first non-special, else season 1 —
            // the tvOS `initialSeason ?? firstUnwatchedSeason ?? first non-special` rule.
            .onAppear {
                let preferred = firstUnwatchedSeason ?? seasons.first { $0 > 0 } ?? seasons.first ?? 1
                if seasons.contains(preferred) { season = preferred }
                else if !seasons.contains(season) { season = seasons.first { $0 > 0 } ?? seasons.first ?? 1 }
            }
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
    @ViewBuilder private func episodeRow(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
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
                if let overview = v.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .opacity(isWatched ? 0.55 : 1)
    }

    private func episodeThumbnail(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        // Effective spoiler-blur: the user's explicit setting wins; else the RemoteConfig fleet default
        // (`features.spoilerBlur`); else baked true. `_ = spoilerBlur` keeps the view observing the
        // @AppStorage so a Settings toggle triggers a redraw.
        _ = spoilerBlur
        let blurArt = SpoilerBlurSetting.isEnabled && !isWatched   // hide future-episode imagery until you have watched it
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
                Text("Where to Watch")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Space.md)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.md) {
                        ForEach(avail.providers) { provider in
                            VStack(spacing: 6) {
                                AsyncImage(url: URL(string: provider.logoURL ?? "")) { img in
                                    img.resizable().scaledToFit()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.Palette.surface1)
                                }
                                .frame(width: 48, height: 48)
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
        guard !LiveTypes.contains(type), id.hasPrefix("tt") else { return }
        Task {
            let avail = await TMDBClient.watchProviders(imdbID: id, type: type)
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
        let m = core.metaDetails?.meta
        return m?.id == id ? m : nil
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

    @State private var player: iOSDetailView.PlayerLaunch?
    @State private var preparing = false
    @State private var lastBinge: String?   // release-group of the last pick; biases the next episode's source (#3 sticky autoplay)
    @State private var settleTimedOut = false      // resolution gave up → show "No sources found", not a spinner
    @State private var torrentPrime: Task<Void, Never>?  // outstanding torrent /create retry loop, cancelled on disappear / new pick
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

    /// A series pin is keyed by the show id, so every episode shares the pinned provider/quality.
    private var pinContext: SourcePinContext { SourcePinContext(metaId: meta.id, isSeries: true) }
    private var sourcePin: ResolvedPin? { pinStore.effectivePin(pinContext) }

    /// The show's imdb id for the TorBox search index (defaultVideoId when the meta id is tmdb:/kitsu:).
    private var showImdbID: String? {
        if let dv = meta.behaviorHints?.defaultVideoId, dv.hasPrefix("tt") { return dv }
        return meta.id.hasPrefix("tt") ? meta.id : nil
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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                hero(width: geo.size.width)
                iOSSourceList(
                    groups: StreamRanking.rankedGroups(displayGroups(core.streamGroups(forStreamId: video.id)), pin: sourcePin,
                                                       debridCachedHashes: debridCache.cachedHashes),
                    progress: core.streamLoadProgress(forStreamId: video.id),
                    states: core.streamAddonStates(forStreamId: video.id),
                    settleTimedOut: settleTimedOut,
                    continuity: rememberedQuality,
                    pinContext: pinContext,
                    cachedHashes: debridCache.cachedHashes,
                    cachedUsenetURLs: debridCache.cachedUsenetURLs,
                    play: { stream, url in Task { await play(stream, url: url) } },
                    playBest: { candidates in Task { await playBest(candidates) } },
                    download: episodeDownloadHandler
                )
                .padding(.horizontal, Theme.Space.md)
                // #9: cap the source list to a readable column, centered, on wide iPad/Mac windows.
                .frame(maxWidth: geo.size.width > Theme.Space.wideLayoutMinWidth ? Theme.Space.contentColumn : .infinity)
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, Theme.Space.xl)
            .frame(width: geo.size.width, alignment: .leading)
        }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        // iOS-only: a macOS navigationTitle on this pushed episode-streams view crashes the shared NSToolbar.
        #if os(iOS)
        .navigationTitle(video.episodeTitle)
        .inlineNavigationTitle()
        #endif
        .macBackAffordance()   // macOS in-content Back + Esc / Cmd-[ (no toolbar back exists)
        // The engine loads per-episode streams on demand; trigger that load for THIS episode — but only
        // when the resident streams aren't already this episode's, so a back/forward revisit doesn't churn.
        .onAppear {
            // Load THIS episode's streams. The series meta is often ALREADY loaded (from the detail page)
            // WITHOUT this episode's stream path, so guarding on meta id alone skipped the stream request
            // entirely and the source list stayed empty ("no sources" / "no stream add-ons responded").
            // Also (re)load whenever the loaded streams aren't this episode's; the engine de-dups an
            // identical meta+stream load, so this is cheap when the right streams are already present.
            let hasThisEpisodeStreams = core.metaDetails?.streams.contains { $0.request.path.id == video.id } ?? false
            if core.metaDetails?.meta?.id != meta.id || !hasThisEpisodeStreams {
                core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: video.id)
            }
        }
        .onDisappear { torrentPrime?.cancel() }
        .task {
            try? await Task.sleep(for: .seconds(20))
            settleTimedOut = true
        }
        // Debrid cache awareness for this episode's torrents + usenet: re-check as add-ons answer (de-duped
        // by hash set in refresh). Includes the TorBox search sources so those rows badge too. No-op with
        // no debrid key.
        .onChange(of: core.streamLoadProgress(forStreamId: video.id).loaded) { _ in
            // Unfiltered: cache awareness needs the raw torrents the Direct-links-only filter would drop.
            debridCache.refresh(from: torboxSearch.merged(into: core.streamGroups(forStreamId: video.id)))
            refreshSourceIndex()   // SERVE + HOARD the community source index as this episode's sources answer
        }
        // TorBox search-as-a-source for the show (gated on a TorBox key; de-duped by imdb id inside refresh).
        .onAppear { torboxSearch.refresh(imdbId: showImdbID); refreshSourceIndex() }
        .platformFullScreenPlayerCover(item: $player) { launch in
            PlayerScreen(
                url: launch.url, title: launch.title, headers: launch.headers, resumeSeconds: launch.resume,
                recordMeta: launch.meta, recordQualityText: launch.qualityText, recordIsTorrent: launch.isTorrent,
                episodes: seasonEpisodes.map { PlayerEpisodeRef(id: $0.id, label: "S\($0.season ?? 1)E\($0.episodeNumber) · \($0.episodeTitle)") },
                loadEpisode: { await loadEpisodeStream($0) },
                warmNextEpisode: { await warmEpisodeStream($0) },
                onProgress: { pos, dur in core.reportProgress(timeSeconds: pos, durationSeconds: dur); Task { [weak account] in await account?.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onSeek: { pos, dur in core.reportProgress(timeSeconds: pos, durationSeconds: dur); Task { [weak account] in await account?.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onClose: { player = nil }
            )
            .ignoresSafeArea()
        }
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
                    Text(video.episodeTitle)
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

            if let overview = video.overview, !overview.isEmpty {
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

    private var backdrop: some View {
        AsyncImage(url: URL(string: video.thumbnail ?? meta.background ?? meta.poster ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.surface1
            }
        }
        .frame(height: backdropHeight)
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
        if let released = video.released, released.count >= 10 { facts.append(String(released.prefix(10))) }
        if let rt = meta.runtime { facts.append(rt) }
        let genres = meta.genres
        if !genres.isEmpty { facts.append(genres.prefix(3).joined(separator: " · ")) }
        return HStack(spacing: 6) {
            Text("S\(season) · E\(video.episode ?? 0)")
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

    /// Play the tapped source: prime the engine + torrent (same path as the movie list), then present
    /// the native player carrying the stream's proxy headers.
    ///
    /// CACHED DEBRID: a raw torrent the user's debrid can serve plays as a direct link, resolving the
    /// SxEy file in a season pack via the episode hint. Fail-soft (no-key is a zero-await nil → the
    /// passed-in `url`/torrent path, unchanged). A debrid URL is a remote direct stream: skip the torrent
    /// prime and mark isTorrent:false.
    private func play(_ stream: CoreStream, url: URL) async {
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        let ep = video.season.flatMap { s in video.episode.map { DebridEpisode(season: s, episode: $0) } }
        let (ref, isTorrent) = await playbackRef(for: stream, episode: ep)
        let playURL = ref?.url ?? url
        core.loadEnginePlayer(for: stream)
        lastBinge = stream.behaviorHints?.bingeGroup   // seed the sticky release-group from the user's pick (#3)
        // Cancel any prior torrent prime before storing the new one, so a re-pick can't leave a stale
        // backoff loop running; the stored Task is also cancelled on view disappear. Debrid direct → no prime.
        torrentPrime?.cancel()
        torrentPrime = isTorrent ? prepareTorrentStream(stream) : nil
        let name = "\(meta.name)  ·  S\(video.season ?? season)E\(video.episodeNumber)"
        let pm = PlaybackMeta(libraryId: meta.id, videoId: video.id, type: "series",
                              name: meta.name, poster: video.thumbnail ?? meta.poster,
                              season: video.season, episode: video.episode)
        player = iOSDetailView.PlayerLaunch(url: playURL, title: name, headers: stream.requestHeaders,
                                            resume: await resume(pm), meta: pm,
                                            qualityText: StreamRanking.signature(stream),
                                            isTorrent: isTorrent, debridRef: ref)
    }

    /// AUTO-PICK play for the episode "Watch in <quality>" button: race the top few CACHED candidates
    /// (ranking order preserved) in parallel and play the FIRST that resolves, so the user reaches a
    /// genuinely-cached source fast instead of committing to the single ranked best when it is a
    /// false-cached row. FAIL-SOFT: a nil race result falls back to today's single-resolve on the ranked
    /// best (`play`), so the no-key / no-cache path is byte-identical. A MANUAL row tap / Quality pick still
    /// goes through `play(_:url:)` on the exact chosen row.
    private func playBest(_ candidates: [CoreStream]) async {
        guard !preparing else { return }
        // Hold `preparing` for the whole race so a second Watch tap can't launch a duplicate resolve. It is
        // RELEASED before the single-resolve fallback below, which sets its own guard (`play` early-returns
        // while `preparing`), so the fallback path is unchanged.
        preparing = true
        let ep = video.season.flatMap { s in video.episode.map { DebridEpisode(season: s, episode: $0) } }
        if let win = await DebridCoordinator.shared.resolveFirstPlayable(
            candidates: candidates, episode: ep, cachedHashes: debridCache.cachedHashes,
            cachedUsenetURLs: debridCache.cachedUsenetURLs) {
            defer { preparing = false }
            core.loadEnginePlayer(for: win.stream)
            lastBinge = win.stream.behaviorHints?.bingeGroup
            torrentPrime?.cancel(); torrentPrime = nil   // debrid direct link: no torrent prime
            let name = "\(meta.name)  ·  S\(video.season ?? season)E\(video.episodeNumber)"
            let pm = PlaybackMeta(libraryId: meta.id, videoId: video.id, type: "series",
                                  name: meta.name, poster: video.thumbnail ?? meta.poster,
                                  season: video.season, episode: video.episode)
            player = iOSDetailView.PlayerLaunch(url: win.ref.url, title: name, headers: win.stream.requestHeaders,
                                                resume: await resume(pm), meta: pm,
                                                qualityText: StreamRanking.signature(win.stream),
                                                isTorrent: false, debridRef: win.ref)
            return
        }
        preparing = false   // release before the fallback, which re-guards on `preparing` inside `play`
        // No parallel-cached winner: today's single-resolve on the ranked best (first playable candidate).
        guard let best = candidates.first(where: { $0.playableURL != nil }), let url = best.playableURL else { return }
        await play(best, url: url)
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
        let ep = video.season.flatMap { s in video.episode.map { DebridEpisode(season: s, episode: $0) } }
        let (ref, isTorrent) = await playbackRef(for: stream, episode: ep)
        // A raw torrent downloads through the loopback server, which must be told to /create the torrent
        // first; the play path primes it, the download path didn't, so the row's download died (#21).
        if isTorrent {
            torrentPrime?.cancel()
            torrentPrime = prepareTorrentStream(stream)
        }
        let pm = PlaybackMeta(libraryId: meta.id, videoId: video.id, type: "series",
                              name: meta.name, poster: video.thumbnail ?? meta.poster,
                              season: video.season, episode: video.episode)
        DownloadManager.shared.download(stream: stream, meta: pm, resolvedURL: ref?.url ?? url,
                                        sourceName: stream.name, qualityText: StreamRanking.signature(stream))
    }
    #else
    private var episodeDownloadHandler: ((CoreStream, URL) -> Void)? { nil }
    #endif

    /// Resolve the URL to play for `stream` on this episode view, preferring a cached-debrid DIRECT link
    /// for a raw torrent. Mirrors the movie view's helper; returns `(ref, false)` when debrid served it
    /// (the ref carries the URL + reresolve provenance), else `(nil, stream.isTorrent)` so the caller uses
    /// `stream.playableURL`. Fail-soft and no-key byte-identical.
    private func playbackRef(for stream: CoreStream, episode: DebridEpisode?) async -> (ref: DebridPlaybackRef?, isTorrent: Bool) {
        if let ref = await DebridCoordinator.shared.resolvedPlaybackRef(for: stream, episode: episode) {
            return (ref, false)
        }
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
        let withSearch = sourceIndex.merged(into: torboxSearch.merged(into: groups))
        guard PlaybackSettings.directLinksOnly else { return withSearch }
        return withSearch.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            guard !streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    /// The episode's pool `content_id` (show imdb id + `:S:E`), or nil when the show has no imdb id.
    private var episodeContentID: String? {
        SourceIndexClient.contentID(imdbId: showImdbID, season: video.season ?? season, episode: video.episodeNumber)
    }

    /// Community source index (episode): SERVE refresh + HOARD contribution for THIS episode. Fully gated +
    /// fail-soft inside `SourceIndexClient` (consent / fleet flag / Singularity toggle / login). De-duped per
    /// content id; safe to call as the episode's sources stream in.
    private func refreshSourceIndex() {
        guard let contentID = episodeContentID else { return }
        sourceIndex.refresh(contentID: contentID, isSignedIn: account.isSignedIn)
        let groups = torboxSearch.merged(into: core.streamGroups(forStreamId: video.id))
        guard !groups.isEmpty else { return }
        Task.detached { await SourceIndexClient.hoard(contentID: contentID, groups: groups) }
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
            groups = displayGroups(core.streamGroups(forStreamId: v.id))
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
                                            debridCachedHashes: debridCache.cachedHashes),
              let url = best.playableURL else { return nil }
        lastBinge = best.behaviorHints?.bingeGroup   // keep the next episode on this release group (#3)
        core.loadEnginePlayer(for: best)
        torrentPrime?.cancel(); torrentPrime = prepareTorrentStream(best)
        let pm = PlaybackMeta(libraryId: meta.id, videoId: v.id, type: "series",
                              name: meta.name, poster: v.thumbnail ?? meta.poster,
                              season: v.season, episode: v.episode)
        let title = "\(meta.name)  ·  S\(v.season ?? season)E\(v.episodeNumber)"
        return PlayerEpisodeStream(stream: best, url: url, meta: pm, title: title, resume: await resume(pm))
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
        guard let best = StreamRanking.best(displayGroups(groups), continuity: rememberedQuality, binge: lastBinge, pin: sourcePin,
                                            debridCachedHashes: debridCache.cachedHashes) else { return }
        prepareTorrentStream(best)                       // start peer discovery now (no-op for direct / debrid)
        guard best.url != nil, let url = best.playableURL else { return }   // direct / debrid → pull first bytes to warm the CDN
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
    let eyebrow: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow.uppercased())
                .font(Theme.Typography.eyebrow).tracking(1.5)
                .foregroundStyle(Theme.Palette.accent)
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
    /// When false, the primary Watch / Quality / All-sources control bar is hidden and the grouped list is
    /// shown directly. The MOVIE detail page passes false because its hero already shows Watch + Quality +
    /// a "Sources" scroll button (rendering both looked like duplicate controls). The episode + live pages
    /// keep the default true — there the control bar is the only primary action.
    var showsPrimaryControls = true
    let play: (CoreStream, URL) -> Void
    /// AUTO-PICK play for the primary "Watch in <quality>" button ONLY: hands the caller the ranked
    /// candidate list (best first) so it can race the top few CACHED sources in parallel and play the first
    /// that resolves, reaching a genuinely-cached link fast instead of committing to `best` alone. Optional:
    /// when nil, the Watch button falls back to the single-resolve `play(best, url)` (byte-identical to
    /// before). The per-row taps and the Quality picker NEVER use this — a user choosing a specific row still
    /// resolves exactly that row through `play`.
    var playBest: (([CoreStream]) -> Void)? = nil
    /// Offline download of a chosen source row (`#30`). Optional so call sites that don't support
    /// downloads (e.g. tvOS, where the whole feature is `#if !os(tvOS)`-gated) pass nil and no Download
    /// affordance renders. `url` is resolved by the caller EXACTLY as the play path resolves it.
    var download: ((CoreStream, URL) -> Void)? = nil

    @State private var sourceFilter: String? = nil      // nil = all add-ons
    @State private var showAllSources = false           // the full ranked list is revealed on demand
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
    }

    // MARK: Controls (Watch-in-X · Quality picker · All sources)

    @ViewBuilder private var controlBar: some View {
        // The flow layout (HStack that wraps) is simulated with two rows so it stays tidy on a phone.
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // Watch-in pick honors the remembered-quality continuity hint, so reopening a title lands
            // on the same quality it last played (same-release-group biased) — matching tvOS.
            if let best = StreamRanking.best(groups, continuity: continuity, debridCachedHashes: cachedHashes), let url = best.playableURL {
                HStack(spacing: Theme.Space.sm) {
                    // Watch-Now waits until every add-on has answered (or the settle timeout fired), so one
                    // press plays the best of ALL sources, not the best of whoever replied first — the tvOS
                    // gate. The Quality picker stays live so a manual pick is always available immediately.
                    // AUTO-PICK: race the top cached candidates in parallel via `playBest` when the caller
                    // wired it (best first, ranking order preserved), else the single-resolve `play(best)`.
                    Button { if let playBest { playBest(groups.flatMap(\.streams)) } else { play(best, url) } } label: {
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
        let tiers = StreamRanking.tiers(groups)
        if !tiers.isEmpty {
            Menu {
                ForEach(tiers, id: \.self) { tier in
                    Menu(tier) {
                        ForEach(StreamRanking.variantOptions(groups, tier: tier), id: \.label) { option in
                            if let url = option.stream.playableURL {
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
        LazyVStack(spacing: Theme.Space.sm) {
            ForEach(visibleGroups) { group in
                // Header + rows as flat SIBLINGS, NOT wrapped in `Section {} header: {}`. On macOS the
                // LazyVStack + Section(header:) combo mis-measures section geometry during lazy realization -
                // a not-yet-built section reserves a near-viewport-height blank, which is the reported
                // "sources vanish / big blank gaps on scroll". Emitting them flat removes that reservation
                // while KEEPING the LazyVStack, so a title with thousands of sources still won't OOM on tvOS.
                sectionHeader(group)
                if !collapsed.contains(group.addon) {
                    ForEach(Array(sortedStreams(group).enumerated()), id: \.offset) { _, stream in
                        streamRow(group.addon, stream)
                    }
                }
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
            .background(Theme.Palette.surface2.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.addon) sources")
        .accessibilityHint(isCollapsed ? "Double-tap to expand" : "Double-tap to collapse")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func streamRow(_ addon: String, _ stream: CoreStream) -> some View {
        if let url = stream.playableURL {
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
                .background(Theme.Palette.surface1.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
                if let title = cleanTitle {
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

    private func badge(_ text: String, prominent: Bool = false) -> some View {
        Text(text).font(Theme.Typography.eyebrow).tracking(1)
            // Keep the badge (including the add-on / debrid / source name) on a single horizontal line at
            // its intrinsic width. Without fixedSize a sibling badge could squeeze the name pill to a
            // near-zero width, wrapping the name to 2-3 characters per line (the reported vertical text).
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(prominent ? Theme.Palette.accent.opacity(0.22) : Theme.Palette.surface3, in: Capsule())
            .foregroundStyle(prominent ? Theme.Palette.accent : Theme.Palette.textSecondary)
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
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// Add / remove the open title from the engine library — the touch/Mac twin of the tvOS LibraryChip.
private struct iOSLibraryChip: View {
    @EnvironmentObject private var core: CoreBridge

    var body: some View {
        let saved = core.detailInLibrary
        Button {
            if saved {
                if let id = core.metaDetails?.meta?.id { core.removeFromLibrary(id: id) }
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
