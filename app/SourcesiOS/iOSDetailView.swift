import SwiftUI

/// Torrents: ask the embedded server to start fetching peers before playback. No-op for direct/debrid
/// URLs (those carry a `url`, so no `/create` is needed). Port of the tvOS `prepareTorrent`, reusing
/// the shared `TorrentTrackers.sources` so the create carries the TCP/TLS trackers that reach a swarm
/// from a sandboxed app. File-private free function so both the movie list and the per-episode list
/// share one implementation.
private func prepareTorrentStream(_ stream: CoreStream) {
    guard !PlaybackSettings.torrentsDisabled else { return }
    guard stream.url == nil, let hash = stream.infoHash?.lowercased(),
          let url = URL(string: "\(StremioServer.base)/\(hash)/create") else { return }
    let sources = TorrentTrackers.sources(forHash: hash, streamSources: stream.sources)
    let body: [String: Any] = ["torrent": ["infoHash": hash],
                               "peerSearch": ["sources": sources, "min": 40, "max": 150]]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    request.timeoutInterval = 5
    // Retry the prime a few times: the embedded server can still be cold-starting (notably the macOS
    // child `node` process), and a single fire-and-forget POST sent before it's listening is silently
    // dropped — leaving the torrent un-primed and the player hanging on a peerless swarm. A round-trip
    // that doesn't throw means the server received the create; connection-refused retries with backoff.
    Task {
        for attempt in 0..<5 {
            if (try? await URLSession.shared.data(for: request)) != nil { return }
            try? await Task.sleep(for: .seconds(Double(attempt + 1)))   // 1s,2s,3s,4s backoff over cold-start
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
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @EnvironmentObject private var profiles: ProfileStore   // per-profile watched set + episode progress

    // A SINGLE presentation slot drives every full-screen cover (player OR trailer). On macOS the
    // `platformFullScreenPlayerCover(item:)` calls become a `.sheet(item:)`, and two sheets attached to
    // the same view shadow each other — so tapping Watch could fail to present the player at all.
    // Driving both from one enum-typed item guarantees exactly one cover is ever attached, so Watch
    // always presents reliably. The player-cover variant sizes its content to fill the macOS window.
    @State private var presentation: Presentation?
    @State private var preparing = false                 // movie Watch Now is resolving
    @State private var season = 1

    /// The one thing presented full-screen at a time: a resolved player stream or the YouTube trailer.
    private enum Presentation: Identifiable {
        case player(PlayerLaunch)
        /// A trailer plays in the SAME native mpv player as a stream (resolved via the embedded
        /// server's `/yt` route), not a WKWebView IFrame — so no YouTube Error 153. recordMeta is
        /// nil for these so a trailer never lands in Continue Watching.
        case trailerPlayer(url: URL, title: String)
        var id: String {
            switch self {
            case .player(let l): "player-\(l.id)"
            case .trailerPlayer(_, let t): "trailer-\(t)"
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
        var isTorrent: Bool = false
    }

    /// The hero artwork height scales with the platform: phones get a shorter band, the Mac a taller one.
    private var backdropHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 320
        #endif
    }

    var body: some View {
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
                        hero { withAnimation { proxy.scrollTo(Self.sourcesAnchor, anchor: .top) } }
                        if type == "series" {
                            episodeList
                        } else {
                            sourceSection.id(Self.sourcesAnchor)
                        }
                    }
                }
                .padding(.bottom, Theme.Space.xl)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(meta?.name ?? title)
        .inlineNavigationTitle()
        .onAppear { core.loadMeta(type: type, id: id) }
        .onDisappear { core.unloadMeta() }
        .platformFullScreenPlayerCover(item: $presentation) { item in
            switch item {
            case .player(let launch):
                PlayerScreen(
                    url: launch.url, title: launch.title, headers: launch.headers, resumeSeconds: launch.resume,
                    recordMeta: launch.meta, recordQualityText: launch.qualityText, recordIsTorrent: launch.isTorrent,
                    onProgress: { pos, dur in Task { await account.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                    onSeek: { pos, dur in Task { await account.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                    onClose: { presentation = nil }
                )
                .ignoresSafeArea()
            case .trailerPlayer(let url, let title):
                PlayerScreen(url: url, title: title, headers: nil, resumeSeconds: 0,
                             recordMeta: nil, onClose: { presentation = nil })
                    .ignoresSafeArea()
            }
        }
    }

    /// Open the meta's trailer in the native mpv player via the embedded server's `/yt` route — the
    /// same path tvOS uses, so it plays a real video stream instead of a WKWebView IFrame (which
    /// YouTube rejected with Error 153). Falls back to the public YouTube link externally if no
    /// playable URL resolves (e.g. server still cold-starting, or a no-server build).
    private func playTrailer() {
        guard let m = meta, let req = TrailerRequest.from(meta: m) else { return }
        if let direct = req.directURL {
            // A real (non-YouTube) trailer stream plays natively in mpv.
            presentation = .trailerPlayer(url: direct, title: "\(m.name) — Trailer")
        } else if let watch = req.watchURL {
            // YouTube trailers open in the YouTube app / browser. The in-app `/yt` resolver (ytdl-core)
            // currently 403s — YouTube changed its player and broke extraction — so external open is the
            // reliable path; it never hits the old WKWebView "Error 153". In-app YouTube playback is
            // tracked for a follow-up (server-side resolver update).
            TrailerOpener.open(watch)
        }
    }

    /// A standalone Trailer chip, shown whenever the meta carries a trailer (direct stream or a YouTube
    /// link). Used in both the movie Watch row and the series hero.
    @ViewBuilder private var trailerButton: some View {
        if let m = meta, TrailerRequest.from(meta: m) != nil {
            Button { playTrailer() } label: {
                Label("Trailer", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    // MARK: Hero (full-bleed backdrop + scrim + meta), mirrors tvOS DetailView.hero

    /// Scroll-anchor id for the source section, so the hero's "Sources" action can jump to it.
    private static let sourcesAnchor = "iOSDetailSources"

    /// Hero: full-bleed backdrop + scrim + title / meta / action row / synopsis. `scrollToSources`
    /// is wired into the movie action row's "Sources" button (the tvOS 3-action twin).
    private func hero(scrollToSources: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                titleOrLogo
                metaRow
                if type == "movie" {
                    watchNow(scrollToSources: scrollToSources)
                } else {
                    seriesHeroActions
                }
                if let overview = meta?.description, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Full-bleed artwork with the same two scrims tvOS uses: a vertical canvas fade so the lower text
    /// block stays readable, and a leading canvas fade for the title column.
    private var backdrop: some View {
        AsyncImage(url: URL(string: meta?.background ?? meta?.poster ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.surface1
            }
        }
        .frame(height: backdropHeight)
        // The backdrop is the ZStack's WIDTH ANCHOR: it greedily takes the full viewport width and
        // pins to the leading edge, so the ZStack's leading edge is the screen's leading edge. Before
        // this, the oversized serif hero title made the ZStack wider than the screen and `.bottomLeading`
        // pushed the whole block to a negative x — clipping the title / Watch / synopsis off the left.
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

    /// The title block: the addon-provided logo when present (the editorial signature on the tvOS hero),
    /// otherwise the serif hero type.
    @ViewBuilder private var titleOrLogo: some View {
        if let logo = meta?.logo, let url = URL(string: logo), !logo.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 110, alignment: .leading)
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                default:
                    heroTitle
                }
            }
        } else {
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
        Text(meta?.name ?? title)
            .font(Theme.Typography.hero).tracking(-1)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(3).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    /// Rating · year · runtime · genres, same order and tokens as tvOS DetailView.metaRow.
    private var metaRow: some View {
        let m = meta
        return HStack(spacing: Theme.Space.md) {
            if let imdb = m?.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                    Text(imdb)
                }
            }
            if let r = m?.releaseInfo { Text(r) }
            if let rt = m?.runtime { Text(rt) }
            let genres = m?.genres ?? []
            if !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")).lineLimit(1) }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
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
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                if let m = meta, let primary {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        NavigationLink {
                            iOSEpisodeStreams(meta: m, video: primary.video, season: primary.video.season ?? 1)
                        } label: {
                            Label(primaryEpisodeLabel(primary.video, isResume: primary.isResume),
                                  systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryActionStyle())
                        if primary.isResume, primaryProgress > 0.01 {
                            iOSProgressStripe(value: primaryProgress)
                                .frame(width: 160)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                trailerButton
                iOSLibraryChip()
                Spacer(minLength: 0)
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

    private func primaryEpisodeLabel(_ video: CoreVideo, isResume: Bool) -> String {
        let prefix = isResume ? "Resume" : "Play"
        guard let season = video.season else { return "\(prefix) Episode \(video.episodeNumber)" }
        return "\(prefix) S\(season) E\(video.episodeNumber)"
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

    // MARK: Movie — Watch Now + sources

    /// The movie hero action row — the touch/Mac twin of the tvOS detail action set: a **Watch**
    /// button (best ranked source), a **Quality** picker (resolution tier → flavour variants), a
    /// **Sources** button (scrolls to the grouped per-add-on list below), and **Add to Library**,
    /// plus the trailer chip when one exists. Wraps onto a second line on a narrow phone.
    @ViewBuilder private func watchNow(scrollToSources: @escaping () -> Void) -> some View {
        let groups = StreamRanking.rankedGroups(displayGroups(core.streamGroups()))
        let sourceTotal = groups.reduce(0) { $0 + $1.streams.count }
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Button {
                    Task { await playMovie() }
                } label: {
                    HStack(spacing: Theme.Space.sm) {
                        if preparing { ProgressView().tint(Theme.Palette.onAccent) }
                        else { Image(systemName: "play.fill") }
                        Text(movieLabel)
                    }
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(!movieReady || preparing)
                .opacity(movieReady || preparing ? 1 : 0.55)

                qualityMenu(groups)
            }
            HStack(spacing: Theme.Space.sm) {
                Button { scrollToSources() } label: {
                    Label(sourceTotal > 0 ? "Sources · \(sourceTotal)" : "Sources",
                          systemImage: "list.bullet")
                }
                .buttonStyle(ChipButtonStyle())

                trailerButton
                iOSLibraryChip()
                Spacer(minLength: 0)
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
            groups: StreamRanking.rankedGroups(displayGroups(core.streamGroups())),
            progress: core.streamLoadProgress(),
            continuity: rememberedQuality,
            play: { stream, url in Task { await playStream(stream, url: url) } }
        )
        .padding(.horizontal, Theme.Space.md)
    }

    /// Apply the Direct-links-only filter (drop every torrent source) so a user with the setting on
    /// never sees or auto-plays a torrent — the exact `displayGroups` the tvOS `CoreStreamList` uses.
    private func displayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard PlaybackSettings.directLinksOnly else { return groups }
        return groups.compactMap { group in
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
        StreamRanking.best(displayGroups(core.streamGroups()), continuity: rememberedQuality)
    }

    private var movieReady: Bool { meta != nil && movieBest != nil }

    private var movieLabel: String {
        if preparing { return "Finding the best source…" }
        guard movieReady, let s = movieBest else { return "Loading sources…" }
        return "Watch  ·  \(StreamRanking.qualityLabel(s))"
    }

    private func playMovie() async {
        guard !preparing, let m = meta, let stream = movieBest,
              let url = stream.playableURL else { return }
        preparing = true; defer { preparing = false }
        primePlayback(stream)
        let pm = PlaybackMeta(libraryId: m.id, videoId: m.id, type: "movie",
                              name: m.name, poster: m.poster, season: nil, episode: nil)
        presentation = .player(PlayerLaunch(url: url, title: m.name, headers: stream.requestHeaders,
                                            resume: await resume(pm), meta: pm,
                                            qualityText: StreamRanking.signature(stream), isTorrent: stream.isTorrent))
    }

    /// Play an arbitrary chosen movie source (a tapped source-list row).
    private func playStream(_ stream: CoreStream, url: URL) async {
        guard !preparing, let m = meta else { return }
        preparing = true; defer { preparing = false }
        primePlayback(stream)
        let pm = PlaybackMeta(libraryId: m.id, videoId: m.id, type: "movie",
                              name: m.name, poster: m.poster, season: nil, episode: nil)
        presentation = .player(PlayerLaunch(url: url, title: m.name, headers: stream.requestHeaders,
                                            resume: await resume(pm), meta: pm,
                                            qualityText: StreamRanking.signature(stream), isTorrent: stream.isTorrent))
    }

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
            groups: StreamRanking.rankedGroups(displayGroups(core.streamGroups())),
            progress: core.streamLoadProgress(),
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
                                            qualityText: StreamRanking.signature(stream), isTorrent: stream.isTorrent))
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
                iOSEpisodeStreams(meta: m, video: v, season: v.season ?? season)
            } label: {
                episodeRowLabel(v, isWatched: isWatched, progress: progress)
            }
            .buttonStyle(RowFocusStyle())
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
        AsyncImage(url: URL(string: v.thumbnail ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default:
                Theme.Palette.surface2.overlay(
                    Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(Theme.Palette.textTertiary))
            }
        }
        .frame(width: 132, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(Theme.Palette.accent).padding(5).shadow(radius: 3)
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

    private func seasonLabel(_ s: Int) -> String { s == 0 ? "Specials" : "Season \(s)" }

    // MARK: Shared

    /// Prime a picked stream for playback BEFORE the player launches — exactly what the tvOS `play()`
    /// does. Wires the engine Player (so progress records against the right library item) and, for
    /// torrents, asks the embedded server to start fetching peers. Without this, iOS/Mac launched the
    /// player against a torrent the server had never been told to create, so the stream never played.
    private func primePlayback(_ stream: CoreStream) {
        core.loadEnginePlayer(for: stream)
        prepareTorrentStream(stream)
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
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager

    @State private var player: iOSDetailView.PlayerLaunch?
    @State private var preparing = false
    @State private var settleTimedOut = false      // resolution gave up → show "No sources found", not a spinner

    private var backdropHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 320
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                hero
                iOSSourceList(
                    groups: StreamRanking.rankedGroups(displayGroups(core.streamGroups(forStreamId: video.id))),
                    progress: core.streamLoadProgress(forStreamId: video.id),
                    settleTimedOut: settleTimedOut,
                    continuity: rememberedQuality,
                    play: { stream, url in Task { await play(stream, url: url) } }
                )
                .padding(.horizontal, Theme.Space.md)
            }
            .padding(.bottom, Theme.Space.xl)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(video.episodeTitle)
        .inlineNavigationTitle()
        // The engine loads per-episode streams on demand; trigger that load for THIS episode.
        .onAppear { core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: video.id) }
        .task {
            try? await Task.sleep(for: .seconds(12))
            settleTimedOut = true
        }
        .platformFullScreenPlayerCover(item: $player) { launch in
            PlayerScreen(
                url: launch.url, title: launch.title, headers: launch.headers, resumeSeconds: launch.resume,
                recordMeta: launch.meta, recordQualityText: launch.qualityText, recordIsTorrent: launch.isTorrent,
                onProgress: { pos, dur in Task { await account.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onSeek: { pos, dur in Task { await account.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onClose: { player = nil }
            )
            .ignoresSafeArea()
        }
    }

    /// Episode backdrop + show eyebrow + episode title + S·E / air date / facts + overview, mirroring
    /// the tvOS `CoreEpisodeStreams` header block.
    private var hero: some View {
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
                    // Same left-clip guard as iOSDetailView.heroTitle: clamp to the available width so
                    // the serif title wraps instead of forcing the ZStack wider than the viewport.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                metaRow
                if let overview = video.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        HStack(spacing: Theme.Space.md) {
            Text("S\(season) · E\(video.episode ?? 0)")
            if let released = video.released, released.count >= 10 { Text(String(released.prefix(10))) }
            if let rt = meta.runtime { Text(rt) }
            if let imdb = meta.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                    Text(imdb)
                }
            }
            let genres = meta.genres
            if !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")).lineLimit(1) }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    /// Play the tapped source: prime the engine + torrent (same path as the movie list), then present
    /// the native player carrying the stream's proxy headers.
    private func play(_ stream: CoreStream, url: URL) async {
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        core.loadEnginePlayer(for: stream)
        prepareTorrentStream(stream)
        let name = "\(meta.name)  ·  S\(video.season ?? season)E\(video.episodeNumber)"
        let pm = PlaybackMeta(libraryId: meta.id, videoId: video.id, type: "series",
                              name: meta.name, poster: video.thumbnail ?? meta.poster,
                              season: video.season, episode: video.episode)
        player = iOSDetailView.PlayerLaunch(url: url, title: name, headers: stream.requestHeaders,
                                            resume: await resume(pm), meta: pm,
                                            qualityText: StreamRanking.signature(stream), isTorrent: stream.isTorrent)
    }

    private func resume(_ pm: PlaybackMeta) async -> Double {
        if let engine = core.engineResumeSeconds(for: pm) { return engine }
        return await account.resumeOffset(for: pm)
    }

    /// Direct-links-only: drop every torrent source so a user with the setting on never sees or
    /// auto-plays one — the same `displayGroups` filter the tvOS `CoreStreamList` applies.
    private func displayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard PlaybackSettings.directLinksOnly else { return groups }
        return groups.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            guard !streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    /// The quality this series last played in (per profile), so the episode's Watch-in pick keeps the
    /// same quality across episodes — the tvOS `LastStreamStore` continuity hint, keyed on the series id.
    private var rememberedQuality: String? {
        LastStreamStore.entry(for: meta.id, profileID: ProfileStore.shared.activeID)?.qualityText
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
    var settleTimedOut = false                          // resolution gave up → show "No sources" not a spinner
    var continuity: String? = nil                       // remembered quality signature → same-quality Watch-in pick
    let play: (CoreStream, URL) -> Void

    @State private var sourceFilter: String? = nil      // nil = all add-ons
    @State private var showAllSources = false           // the full ranked list is revealed on demand
    @State private var collapsed: Set<String> = []      // per-add-on sections the user folded away
    @State private var qualityTier: String? = nil       // second-level quality sheet (a resolution tier)

    private var streamCount: Int { groups.reduce(0) { $0 + $1.streams.count } }
    // Still loading unless every add-on answered — OR the settle timeout fired, which flips a hung
    // resolution to the real "No sources found" state instead of an endless spinner.
    private var loading: Bool { !settleTimedOut && (progress.total == 0 || progress.loaded < progress.total) }
    private var visibleGroups: [CoreStreamSourceGroup] {
        groups.filter { sourceFilter == nil || $0.addon == sourceFilter }
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
                    iOSEmptyRow(text: "None of your add-ons returned a playable source for this title.")
                }
            } else {
                controlBar
                if loading && progress.total > 0 {
                    Text("Still finding more · \(progress.loaded)/\(progress.total) add-ons")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                }
                if showAllSources {
                    if groups.count > 1 { filterBar }
                    groupedList
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
            if let best = StreamRanking.best(groups, continuity: continuity), let url = best.playableURL {
                HStack(spacing: Theme.Space.sm) {
                    Button { play(best, url) } label: {
                        Label("Watch in \(StreamRanking.watchLabel(best))", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryActionStyle())

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

    // MARK: Grouped, collapsible streams

    /// One collapsible section per add-on. LazyVStack so only on-screen rows are built — a popular
    /// title can return thousands of sources, and instantiating them all at once OOM-crashed on tvOS.
    private var groupedList: some View {
        LazyVStack(spacing: Theme.Space.sm) {
            ForEach(visibleGroups) { group in
                Section {
                    if !collapsed.contains(group.addon) {
                        ForEach(Array(group.streams.enumerated()), id: \.offset) { _, stream in
                            streamRow(group.addon, stream)
                        }
                    }
                } header: {
                    sectionHeader(group)
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
    }

    @ViewBuilder private func streamRow(_ addon: String, _ stream: CoreStream) -> some View {
        if let url = stream.playableURL {
            Button { play(stream, url) } label: {
                iOSStreamLabel(addon: addon, stream: stream, enabled: true)
            }
            .buttonStyle(RowFocusStyle())
        } else {
            iOSStreamLabel(addon: addon, stream: stream, enabled: false)
                .background(Theme.Palette.surface1.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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

    var body: some View {
        let quality = StreamRanking.qualityLabel(stream)        // "4K" / "1080p" / "Best"
        let detail = StreamRanking.sourceDetail(stream)          // parsed (tags, size) — NOT the raw blurb
        return HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: enabled ? (stream.isTorrent ? "arrow.down.circle.fill" : "play.circle.fill") : "lock.circle")
                .font(.system(size: 26))
                .foregroundStyle(enabled ? Theme.Palette.accent : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    badge(quality, prominent: true)
                    badge(addon.uppercased())
                    if stream.isTorrent { badge("TORRENT") }
                }
                // Parsed flavour tags + size — the clean line tvOS shows, not the add-on's raw dump.
                HStack(spacing: 8) {
                    Text(detail.tags)
                        .font(Theme.Typography.label)
                        .foregroundStyle(enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                        .lineLimit(1)
                    if let size = detail.size {
                        Text(size)
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                // One trimmed human-readable line for context (the release title), collapsed to a
                // single line so a verbose multi-line add-on blurb can't bloat the row.
                if let title = cleanTitle {
                    Text(title)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .opacity(enabled ? 1 : 0.55)
    }

    /// A single trimmed context line: the add-on's stream `name` (its short release title) with
    /// newlines collapsed to spaces, or the first line of `description` as a fallback. Never the full
    /// multi-line blurb — that verbose dump is exactly what this row replaces.
    private var cleanTitle: String? {
        let raw = stream.name?.isEmpty == false ? stream.name : stream.description
        guard let raw, !raw.isEmpty else { return nil }
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func badge(_ text: String, prominent: Bool = false) -> some View {
        Text(text).font(Theme.Typography.eyebrow).tracking(1)
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
