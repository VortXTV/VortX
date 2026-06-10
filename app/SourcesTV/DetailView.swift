import SwiftUI

/// Meta detail, driven by the **stremio-core** engine (CoreBridge): a cinematic hero + overview, then
/// streams (movie) or a season selector with episode thumbnails (series). Streams come from the
/// engine's `meta_details`, the same complete, per-addon list the official app shows.
struct DetailView: View {
    let type: String
    let id: String
    var client: AddonClient = AddonClient()   // kept for call-site compatibility (Search)
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore

    var body: some View {
        Group {
            if let meta = core.metaDetails?.meta {
                if type == "series", let videos = meta.videos, !videos.isEmpty {
                    seriesPage(meta, videos: videos)
                } else {
                    moviePage(meta)
                }
            } else {
                // Focusable so Back pops this view instead of exiting the app while it loads.
                ScrollView {
                    BigSpinner().padding(120).focusable()
                }
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)            // let the backdrop bleed to the top edge
        .onAppear { core.loadMeta(type: type, id: id); captureHero() }
        .onChange(of: core.metaDetails?.meta?.id) { captureHero() }
    }

    /// Feed the browse pages' hero cache with what this page knows. The engine resolved this meta
    /// through the add-on system, so it works for every id scheme (tt, tmdb:, tvdb:, anything).
    private func captureHero() {
        guard let m = core.metaDetails?.meta, m.id == id else { return }
        FocusedItemModel.noteMeta(id: m.id, type: type, title: m.name,
                                  backdrop: m.background ?? m.poster,
                                  releaseInfo: m.releaseInfo, imdbRating: m.imdbRating,
                                  runtime: m.runtime, overview: m.description, genres: m.genres)
    }

    /// Series keep the hero + episode-list layout (the page below the hero is full of content).
    private func seriesPage(_ meta: CoreMetaItem, videos: [CoreVideo]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    hero(meta) { withAnimation { proxy.scrollTo("detailContent", anchor: .top) } }
                    CoreSeasonedEpisodes(meta: meta, videos: videos,
                                         watched: profiles.activeUsesEngineHistory
                                            ? (core.metaDetails?.watchedIds ?? [])
                                            : profiles.watchedVideoIds(forMeta: meta.id))
                        .id("detailContent")
                }
                .padding(.bottom, Theme.Space.xl)
            }
        }
    }

    /// Movies get the full-bleed cinematic page: the backdrop fills the whole viewport (no dead black
    /// band under the buttons), the title block sits on the lower band, and the source list scrolls
    /// over the scrimmed artwork.
    private func moviePage(_ m: CoreMetaItem) -> some View {
        ZStack {
            FullBleedBackdrop(url: m.background ?? m.poster)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Spacer().frame(height: 380)
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(m.name)
                            .font(Theme.Typography.hero).tracking(-1.5)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2).minimumScaleFactor(0.6)
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                        metaRow(m)
                        if let d = m.description, !d.isEmpty {
                            Text(d)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(4).lineSpacing(2)
                                .frame(maxWidth: 1000, alignment: .leading)
                        }
                    }
                    CoreStreamList(title: m.name,
                                   meta: PlaybackMeta(libraryId: m.id, videoId: m.id, type: type,
                                                      name: m.name, poster: m.poster,
                                                      season: nil, episode: nil))
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.bottom, Theme.Space.xl)
            }
        }
    }

    /// Full-bleed backdrop with a canvas-blended gradient and the title / metadata / synopsis on the
    /// lower band. The serif title is the editorial signature.
    private func hero(_ m: CoreMetaItem, scrollToContent: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: m.background ?? m.poster ?? "")) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: Theme.Palette.surface1
                }
            }
            .frame(height: 560)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(LinearGradient(colors: [.clear, Theme.Palette.canvas.opacity(0.55), Theme.Palette.canvas],
                                    startPoint: .top, endPoint: .bottom))
            .overlay(LinearGradient(colors: [Theme.Palette.canvas.opacity(0.75), .clear],
                                    startPoint: .leading, endPoint: .center))

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(m.name)
                    .font(Theme.Typography.hero).tracking(-1.5)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                metaRow(m)
                if let d = m.description, !d.isEmpty {
                    Text(d)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(3).lineSpacing(2)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                // On-screen focusable anchor: grabs initial focus on push (so Back pops instead of
                // exiting), and jumps to the episodes / sources below.
                Button(action: scrollToContent) {
                    Label(type == "series" ? "Episodes" : "Watch",
                          systemImage: type == "series" ? "list.bullet" : "play.fill")
                }
                .buttonStyle(PrimaryActionStyle())
                .padding(.top, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.bottom, Theme.Space.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaRow(_ m: CoreMetaItem) -> some View {
        HStack(spacing: Theme.Space.md) {
            if let imdb = m.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                    Text(imdb)
                }
            }
            if let r = m.releaseInfo { Text(r) }
            if let rt = m.runtime { Text(rt) }
            let genres = m.genres
            if !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")).lineLimit(1) }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
    }
}

/// Series episodes grouped by season: a season selector, then the chosen season's episodes with
/// thumbnails. Selecting an episode loads that episode's streams from the engine.
struct CoreSeasonedEpisodes: View {
    let meta: CoreMetaItem
    let videos: [CoreVideo]
    var watched: Set<String> = []
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe so accent ticks recolor on theme change

    @State private var season: Int = 1

    private var seasons: [Int] { Array(Set(videos.map { $0.season ?? 0 })).sorted() }
    private var episodes: [CoreVideo] {
        videos.filter { ($0.season ?? 0) == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: "\(episodes.count) episode\(episodes.count == 1 ? "" : "s")", title: "Episodes")

            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(seasons, id: \.self) { s in
                            Button { season = s } label: { Text(seasonLabel(s)) }
                                .buttonStyle(ChipButtonStyle(selected: season == s))
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs)
                }
            }

            // Mark watched/unwatched: selected season + whole series. (Per-episode: long-press a row.)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    Button { core.markSeasonWatched(season, true) } label: { Label("\(seasonLabel(season)) watched", systemImage: "checkmark.circle") }
                        .buttonStyle(ChipButtonStyle())
                    Button { core.markSeasonWatched(season, false) } label: { Label("\(seasonLabel(season)) unwatched", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(ChipButtonStyle())
                    Button { core.markWatched(true) } label: { Text("Whole series watched") }
                        .buttonStyle(ChipButtonStyle())
                    Button { core.markWatched(false) } label: { Text("Whole series unwatched") }
                        .buttonStyle(ChipButtonStyle())
                }
                .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs)
            }

            VStack(spacing: Theme.Space.sm) {
                ForEach(episodes) { v in episodeRow(v) }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
        }
        .onAppear {
            if !seasons.contains(season) { season = seasons.first { $0 > 0 } ?? seasons.first ?? 1 }
        }
    }

    private func episodeRow(_ v: CoreVideo) -> some View {
        let isWatched = watched.contains(v.id)
        let progress = episodeProgress(v)
        return NavigationLink {
            CoreEpisodeStreams(meta: meta, video: v, season: v.season ?? season, episodes: episodes)
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                thumbnail(v, isWatched: isWatched, progress: progress)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill").font(.callout).foregroundStyle(Theme.Palette.accent)
                        }
                        Text("\(v.episode ?? 0). \(episodeTitle(v))")
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(isWatched ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                            .lineLimit(2)
                    }
                    if let released = v.released, released.count >= 10 {
                        Text(String(released.prefix(10))).font(.system(size: 16)).foregroundStyle(Theme.Palette.textTertiary)
                    }
                    if let overview = v.overview, !overview.isEmpty {
                        Text(overview).font(.system(size: 18)).foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.md)
        }
        .buttonStyle(RowFocusStyle())
        .contextMenu {
            Button(isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                core.markVideoWatched(v, !isWatched)
            }
        }
    }

    private func thumbnail(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        AsyncImage(url: URL(string: v.thumbnail ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.surface2.overlay(
                Image(systemName: "play.rectangle.fill").font(.title).foregroundStyle(Theme.Palette.textTertiary))
            }
        }
        .frame(width: 300, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(Theme.Palette.accent).padding(8).shadow(radius: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if !isWatched, progress > 0.01 {
                ProgressStripe(value: progress).padding(Theme.Space.xs)
            }
        }
        .opacity(isWatched ? 0.55 : 1)
    }

    private func episodeProgress(_ v: CoreVideo) -> Double {
        guard let item = core.metaDetails?.libraryItem,
              item.state.videoId == v.id,
              item.state.duration > 0 else { return 0 }
        return min(max(item.state.timeOffset / item.state.duration, 0), 1)
    }

    private func episodeTitle(_ v: CoreVideo) -> String {
        let title = v.title ?? ""
        return title.isEmpty ? "Episode \(v.episode ?? 0)" : title
    }
    private func seasonLabel(_ s: Int) -> String { s == 0 ? "Specials" : "Season \(s)" }
}

/// Loads + shows the streams for one episode (engine `meta_details` with the episode as stream path).
struct CoreEpisodeStreams: View {
    let meta: CoreMetaItem
    let video: CoreVideo
    let season: Int
    var episodes: [CoreVideo] = []
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        ZStack {
            FullBleedBackdrop(url: video.thumbnail ?? meta.background ?? meta.poster)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Spacer().frame(height: 400)   // let the episode still own the top of the screen
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(meta.name.uppercased())
                            .font(Theme.Typography.eyebrow).tracking(1.5)
                            .foregroundStyle(Theme.Palette.accent)
                        Text(episodeTitle)
                            .font(Theme.Typography.screenTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2).minimumScaleFactor(0.7)
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                        episodeMetaRow
                        if let overview = video.overview, !overview.isEmpty {
                            Text(overview)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(4).lineSpacing(2)
                                .frame(maxWidth: 1000, alignment: .leading)
                        }
                    }
                    CoreStreamList(title: "\(meta.name) · S\(season)·E\(video.episode ?? 0)",
                                   meta: PlaybackMeta(libraryId: meta.id, videoId: video.id, type: "series",
                                                      name: meta.name, poster: meta.poster,
                                                      season: video.season, episode: video.episode),
                                   episodes: episodes)
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.bottom, Theme.Space.xl)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: video.id) }
    }

    /// Season/episode, air date, then the show-level facts (runtime, rating, genres) for context.
    private var episodeMetaRow: some View {
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

    private var episodeTitle: String {
        let t = video.title ?? ""
        return t.isEmpty ? "Episode \(video.episode ?? 0)" : t
    }
}

/// Full-screen backdrop for the cinematic pages: the artwork fills the entire viewport (no dead black
/// band anywhere), with canvas scrims that keep the lower text block and the leading edge readable
/// while the image stays vivid up top. Content scrolls over it.
struct FullBleedBackdrop: View {
    let url: String?
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        Color.clear
            .overlay {
                AsyncImage(url: URL(string: url ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: Theme.Palette.surface1
                    }
                }
            }
            .clipped()
            .overlay(
                // Light hand: the artwork stays vivid across most of the screen; just enough
                // canvas at the bottom for rows and at the leading edge for the text block.
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Theme.Palette.canvas.opacity(0.18), location: 0.50),
                    .init(color: Theme.Palette.canvas.opacity(0.55), location: 0.78),
                    .init(color: Theme.Palette.canvas.opacity(0.88), location: 1.0),
                ], startPoint: .top, endPoint: .bottom))
            .overlay(
                LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                               startPoint: .leading, endPoint: .center))
            .ignoresSafeArea()
    }
}

/// The per-addon stream list from the engine: source filter chips + each addon's streams shown
/// exactly as the addon labelled them (name + full description), with direct/debrid vs torrent.
struct CoreStreamList: View {
    let title: String
    var meta: PlaybackMeta? = nil
    var episodes: [CoreVideo] = []               // the season's episodes (series only), for the player's Prev/Next/Episodes
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @State private var sourceFilter: String? = nil
    @State private var showAllSources = false   // the full ranked list is revealed on demand (Watch-Now first)
    @State private var showQualityPicker = false   // level 1: pick a resolution tier
    @State private var qualityTier: String? = nil  // level 2: pick a flavor inside that tier
    @State private var settleTimedOut = false      // opens the Watch-Now gate even if an add-on hangs
    @EnvironmentObject private var presenter: PlayerPresenter   // root-replacement player presentation

    var body: some View {
        let groups = StreamRanking.rankedGroups(core.streamGroups())   // best source first within each add-on
        let streamCount = groups.reduce(0) { $0 + $1.streams.count }
        let visible = groups.filter { sourceFilter == nil || $0.addon == sourceFilter }
        let addons = core.streamLoadProgress()                       // (loaded, total) stream add-ons
        let loadingAddons = addons.total == 0 || addons.loaded < addons.total
        let best = StreamRanking.best(groups)

        // Watch-Now stays greyed until (nearly) every add-on has answered, so one press plays the
        // best of ALL sources, not the best of whoever answered first. A hung add-on can't hold the
        // button hostage: the timeout opens the gate anyway.
        let watchReady = !loadingAddons || settleTimedOut

        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let best {
                // Watch-Now first: one press plays the best source; long-press picks another resolution;
                // the full ranked list stays tucked behind "All sources".
                HStack(spacing: Theme.Space.md) {
                    // Stays FOCUSABLE while gated (a disabled button is unfocusable on tvOS, which
                    // dumped focus onto the Quality chip); the action is simply inert until the
                    // add-ons settle, then the same focused button springs alive in place.
                    Button { if watchReady { play(best) } } label: {
                        if watchReady {
                            Label("Watch in \(StreamRanking.qualityLabel(best))", systemImage: "play.fill")
                        } else {
                            HStack(spacing: Theme.Space.sm) {
                                ProgressView().tint(Theme.Palette.onAccent)
                                Text("Finding best…  \(addons.loaded)/\(addons.total)")
                            }
                        }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .opacity(watchReady ? 1 : 0.55)
                    .contextMenu { resolutionMenu(groups) }

                    // The visible quality dropdown, two levels: resolution tier first (4K / 1080p /
                    // 720p / Others), then the flavors inside it (Dolby Vision · Remux, HDR · Atmos, …).
                    Button { showQualityPicker = true } label: {
                        Label("Quality", systemImage: "chevron.up.chevron.down")
                    }
                    .buttonStyle(ChipButtonStyle())
                    .confirmationDialog("Pick a quality", isPresented: $showQualityPicker, titleVisibility: .visible) {
                        ForEach(StreamRanking.tiers(groups), id: \.self) { tier in
                            Button(tier) {
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 250_000_000)   // let level 1 dismiss first
                                    qualityTier = tier
                                }
                            }
                        }
                    }
                    .background {
                        Color.clear.confirmationDialog(qualityTier ?? "",
                                                       isPresented: Binding(get: { qualityTier != nil },
                                                                            set: { if !$0 { qualityTier = nil } }),
                                                       titleVisibility: .visible) {
                            if let tier = qualityTier {
                                ForEach(StreamRanking.variantOptions(groups, tier: tier), id: \.label) { option in
                                    Button(option.label) { play(option.stream) }
                                }
                            }
                        }
                    }

                    Button { withAnimation { showAllSources.toggle() } } label: {
                        Label(showAllSources ? "Hide sources" : "All sources · \(streamCount)",
                              systemImage: showAllSources ? "chevron.up" : "list.bullet")
                    }
                    .buttonStyle(ChipButtonStyle(selected: showAllSources))
                }
                if loadingAddons && addons.total > 0 {
                    Text("Still finding more · \(addons.loaded)/\(addons.total) add-ons")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                }
                if showAllSources {
                    if groups.count > 1 { filterBar(groups, total: streamCount) }
                    // LazyVStack so only on-screen rows are built: a popular title can return 2000+ sources,
                    // and a plain VStack instantiated them all at once, OOM-crashing the Apple TV mid-load.
                    LazyVStack(spacing: Theme.Space.sm) {
                        ForEach(visible) { group in
                            ForEach(Array(group.streams.enumerated()), id: \.offset) { _, stream in
                                streamRow(group.addon, stream)
                            }
                        }
                    }
                }
            } else if loadingAddons {
                // Searching: a focusable, primary-styled loading button (focus can't escape to the tab bar
                // while sources arrive). It flips to "Watch in …" the moment the first source lands.
                Button {} label: {
                    HStack(spacing: Theme.Space.sm) {
                        ProgressView().tint(Theme.Palette.onAccent)
                        Text(addons.total > 0 ? "Finding sources…  \(addons.loaded)/\(addons.total)" : "Finding sources…")
                    }
                }
                .buttonStyle(PrimaryActionStyle())
            } else {
                // Done, nothing playable: a greyed (disabled-looking) button + an explanation. Focusable so Back works.
                Button {} label: { Label("No sources found", systemImage: "exclamationmark.triangle") }
                    .buttonStyle(PrimaryActionStyle())
                    .opacity(0.55)
                Text("None of your \(addons.total) add-on\(addons.total == 1 ? "" : "s") returned a playable source for this title.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        // Greedy width so the column never shrinks to its widest child. Without this, the Watch-Now state
        // (just two buttons + a status line, no full-width row yet) collapsed to button-width and an
        // enclosing ScrollView centered it — the "black bar with two buttons in the middle" bug.
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            try? await Task.sleep(for: .seconds(12))
            settleTimedOut = true
        }
    }

    /// Resolution dropdown for the Watch button (long-press): the best source at each available quality.
    @ViewBuilder private func resolutionMenu(_ groups: [CoreStreamSourceGroup]) -> some View {
        ForEach(StreamRanking.resolutionOptions(groups), id: \.label) { opt in
            Button { play(opt.stream) } label: { Label("Watch in \(opt.label)", systemImage: "play.fill") }
        }
    }

    /// Play a stream by handing a request to the root, which swaps the whole shell out for the player
    /// (the only reliable tvOS focus isolation — see RootView). Wires the engine + prepares torrents first.
    private func play(_ stream: CoreStream) {
        guard let url = stream.playableURL else { return }
        core.loadEnginePlayer(for: stream)
        prepareTorrent(stream)
        presenter.request = PlaybackRequest(url: url, title: title, meta: meta, episodes: episodes)
    }

    private func filterBar(_ groups: [CoreStreamSourceGroup], total: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                Button { sourceFilter = nil } label: { Text("All (\(total))") }
                    .buttonStyle(ChipButtonStyle(selected: sourceFilter == nil))
                ForEach(groups) { group in
                    Button { sourceFilter = group.addon } label: { Text("\(group.addon) (\(group.streams.count))") }
                        .buttonStyle(ChipButtonStyle(selected: sourceFilter == group.addon))
                }
            }
            .padding(.vertical, Theme.Space.xs)
        }
    }

    @ViewBuilder private func streamRow(_ addon: String, _ stream: CoreStream) -> some View {
        if stream.playableURL != nil {
            Button { play(stream) } label: { streamLabel(addon, stream, enabled: true) }
                .buttonStyle(RowFocusStyle())
        } else {
            streamLabel(addon, stream, enabled: false)   // external/youtube, not playable in-app
                .background(Theme.Palette.surface1.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private func streamLabel(_ addon: String, _ stream: CoreStream, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: enabled ? (stream.isTorrent ? "arrow.down.circle.fill" : "play.circle.fill") : "lock.circle")
                .font(.system(size: 30))
                .foregroundStyle(enabled ? Theme.Palette.accent : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    badge(addon.uppercased())
                    if stream.isTorrent { badge("TORRENT") }
                }
                if let name = stream.name, !name.isEmpty {
                    Text(name).font(Theme.Typography.cardTitle)
                        .foregroundStyle(enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let desc = stream.description, !desc.isEmpty {
                    Text(desc).font(.system(size: 18)).foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .opacity(enabled ? 1 : 0.55)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(Theme.Typography.eyebrow).tracking(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.Palette.surface3, in: Capsule())
            .foregroundStyle(Theme.Palette.textSecondary)
    }

    /// Torrents: ask the embedded server to start fetching peers before playback. No-op for url/debrid.
    private func prepareTorrent(_ stream: CoreStream) {
        guard stream.url == nil, let hash = stream.infoHash?.lowercased(),
              let url = URL(string: "\(StremioServer.base)/\(hash)/create") else { return }
        var sources = stream.sources ?? []
        sources.append("dht:\(hash)")
        let body: [String: Any] = ["torrent": ["infoHash": hash],
                                   "peerSearch": ["sources": sources, "min": 40, "max": 150]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()
    }
}
