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
    @EnvironmentObject private var presenter: PlayerPresenter   // root-replacement player presentation (Trailer)

    @State private var similarItems: [MetaPreview] = []
    @State private var mdbRatings: MDBListRatings?

    var body: some View {
        Group {
            if let meta = core.metaDetails?.meta {
                // Live (tv / channel / events) gets its own stripped-down page BEFORE the movie
                // fallback (today live falls through to moviePage): backdrop + name + a red LIVE
                // badge + the channel source list, with NO VOD chrome — no trailer chip, no movie
                // synopsis framing, no skip/chapter UI. The source list keeps PlaybackMeta(type: type)
                // so the player's live-tuned path engages (see TVPlayerView.initialLiveMode).
                if LiveTypes.contains(type) {
                    livePage(meta)
                } else if type == "series", let videos = meta.videos, !videos.isEmpty {
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
        // NO ignoresSafeArea on the content: tvOS's safe-area insets exist to keep UI out of
        // TV overscan, and pushing the whole page into them clipped the top of the detail page
        // on TVs that crop (field report). The backdrops self-bleed (FullBleedBackdrop ignores
        // the safe area itself), so only text and controls moved back inside the safe zone.
        .onAppear {
            // Movies / live are a single video. Their stream request must carry the IMDB id, not the raw
            // catalog id: a TMDB/Kitsu catalog gives a tmdb:/kitsu: meta id, and imdb-keyed add-ons
            // (idPrefixes ["tt"]) are dropped from the plan for a non-imdb id (only AIOStreams-style broad
            // add-ons answer). The imdb id is in the meta's behaviorHints.defaultVideoId, known only after
            // the meta loads, so load meta FIRST then dispatch streams on meta-ready (loadMovieStreamsIfNeeded).
            // Series load streams per-episode (CoreEpisodeStreams), so a series detail loads meta only.
            if type == "series" {
                core.loadMeta(type: type, id: id)
            } else if core.metaDetails?.meta?.id == id {
                loadMovieStreamsIfNeeded()
            } else {
                core.loadMeta(type: type, id: id)
            }
            captureHero()
            if let m = core.metaDetails?.meta, m.id == id { loadSimilar(m); loadRatings() }
        }
        .onDisappear {
            // Scrolling the series episode list auto-hides the tab bar at the UIKit level. When the
            // user presses Back the NavigationStack pops but the bar can stay hidden at its scroll-
            // suppressed position. Heal it the same way the player-close path does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { TabBarHealer.heal("detail-popped") }
        }
        .onChange(of: core.metaDetails?.meta?.id) {
            captureHero()
            if type != "series" { loadMovieStreamsIfNeeded() }
            if let m = core.metaDetails?.meta, m.id == id { loadSimilar(m); loadRatings() }
        }
    }

    /// The IMDb id to fetch MDBList ratings for: prefer the meta's imdb `defaultVideoId` (tt...) when the
    /// catalog id is non-imdb (tmdb:/kitsu:), else the catalog id when it is itself an imdb id.
    private var ratingsImdbID: String? {
        if let dv = core.metaDetails?.meta?.behaviorHints?.defaultVideoId, dv.hasPrefix("tt") { return dv }
        return id.hasPrefix("tt") ? id : nil
    }

    /// Fetch MDBList ratings for this title (no-op without a key / imdb id). Fail-soft: leaves the row
    /// hidden on any miss. Skipped for live channels, which carry no ratings.
    private func loadRatings() {
        guard !LiveTypes.contains(type), let imdb = ratingsImdbID, mdbRatings == nil else { return }
        Task {
            let r = await MDBListClient.ratings(imdbID: imdb, type: type)
            await MainActor.run { mdbRatings = r }
        }
    }

    /// The id to dispatch a movie/live stream request with: the meta's imdb `defaultVideoId` (tt...) when
    /// the catalog id is non-imdb (tmdb:/kitsu:), else the catalog id. Falls back to the catalog id before
    /// the meta loads. Matches official Stremio (and the engine's guess_stream), which key movie streams on
    /// default_video_id so imdb add-ons match.
    private var movieStreamId: String {
        if let dv = core.metaDetails?.meta?.behaviorHints?.defaultVideoId, !dv.isEmpty, dv != id { return dv }
        return id
    }

    /// Dispatch the movie/live stream request with the imdb-preferring id, unless those streams are already
    /// resident. No-op for series and until this title's meta loaded. The hasStreams guard keys on the
    /// EFFECTIVE id so no re-dispatch loop forms once the imdb-keyed streams arrive.
    private func loadMovieStreamsIfNeeded() {
        guard type != "series", core.metaDetails?.meta?.id == id else { return }
        let streamId = movieStreamId
        let hasStreams = core.metaDetails?.streams.contains { $0.request.path.id == streamId } ?? false
        guard !hasStreams else { return }
        core.loadMeta(type: type, id: id, streamType: type, streamId: streamId)
    }

    @ViewBuilder private var moreLikeThisSection: some View {
        if !similarItems.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                RailHeader(title: "More Like This")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                        ForEach(similarItems.prefix(20)) { item in
                            PosterCard(title: item.name, poster: item.poster,
                                       type: item.type, id: item.id)
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge)
                    .padding(.vertical, Theme.Space.lg)
                }
            }
        }
    }

    private func loadSimilar(_ meta: CoreMetaItem) {
        guard !LiveTypes.contains(type), !meta.genres.isEmpty else { return }
        Task {
            let items = await AddonClient.similar(type: type, excludingId: id, genres: meta.genres, title: meta.name)
            var merged = items
            // When a TMDB key is set, prepend TMDB recommendations (deduped) for richer "more like this".
            if ApiKeys.tmdbKey() != nil, id.hasPrefix("tt") {
                let existing = Set(items.map(\.id))
                let recs = await AddonClient.tmdbSimilar(type: type, imdbID: id).filter { $0.id != id && !existing.contains($0.id) }
                merged = recs + items
            }
            await MainActor.run { similarItems = merged }
        }
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
        let watched = profiles.activeUsesEngineHistory
            ? (core.metaDetails?.watchedIds ?? [])
            : profiles.watchedVideoIds(forMeta: meta.id)
        let primary = seriesPrimaryEpisode(videos, watched: watched, metaID: meta.id)
        let primaryProgress = primary.map { episodeProgress($0.video, metaID: meta.id) } ?? 0
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    hero(meta, primaryEpisode: primary?.video, primaryIsResume: primary?.isResume == true,
                         primaryProgress: primaryProgress,
                         scrollToContent: { withAnimation { proxy.scrollTo("detailContent", anchor: .top) } })
                    CoreSeasonedEpisodes(meta: meta, videos: videos,
                                         watched: watched,
                                         initialSeason: primary?.video.season)
                        .id("detailContent")
                    moreLikeThisSection
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
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        Spacer().frame(height: 380)
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Text(m.name)
                                .font(Theme.Typography.hero).tracking(-1.5)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(2).minimumScaleFactor(0.6)
                                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                            metaRow(m)
                            ratingsRow()
                            if let d = m.description, !d.isEmpty {
                                Text(d)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .lineLimit(4).lineSpacing(2)
                                    .frame(maxWidth: 1000, alignment: .leading)
                            }
                            HStack(spacing: Theme.Space.sm) { trailerChip(m) }
                                .padding(.top, Theme.Space.xs)
                        }
                        CoreStreamList(title: m.name,
                                       meta: PlaybackMeta(libraryId: m.id, videoId: m.id, type: type,
                                                          name: m.name, poster: m.poster,
                                                          season: nil, episode: nil))
                    }
                    .padding(.horizontal, Theme.Space.screenEdge)
                    moreLikeThisSection
                }
                .padding(.bottom, Theme.Space.xl)
            }
        }
    }

    /// Live channel page: the same full-bleed cinematic backdrop as a movie, but stripped of VOD chrome —
    /// no trailer chip, no movie-style synopsis paragraph, no skip/chapter UI. A red "LIVE" badge sits
    /// beside the title, then a now/next EPG strip (when the channel carries a schedule), and the
    /// channel's full source list lets the user pick a stream. The stream list carries the channel's
    /// live `type` in its `PlaybackMeta`, which the player reads via `LiveTypes` to engage live tuning
    /// and NO-OP resume/progress.
    private func livePage(_ m: CoreMetaItem) -> some View {
        ZStack {
            FullBleedBackdrop(url: m.background ?? m.poster)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Spacer().frame(height: 380)
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                            Text(m.name)
                                .font(Theme.Typography.hero).tracking(-1.5)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(2).minimumScaleFactor(0.6)
                                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                            liveBadge
                        }
                        metaRow(m)
                    }
                    epgStrip(m)
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

    /// Now/Next EPG strip for a live channel (tvOS twin of the iOS one; reuses the SAME `EPGSchedule`
    /// type, no duplicated selection logic). The schedule already rides in the meta JSON
    /// (`behaviorHints.hasScheduledVideos` + dated `videos[]`) — no XMLTV/networking on the client.
    /// When `EPGSchedule` resolves, show a NOW row (title + "until <next start>") and a NEXT row
    /// (title + start time); otherwise fall back to the channel description. Display-only and
    /// non-focusable, so the focus order (title → source list) is unchanged. Times use the device
    /// LOCALE (short time), turning the UTC `released` into a local clock reading.
    @ViewBuilder private func epgStrip(_ m: CoreMetaItem) -> some View {
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
            .frame(maxWidth: 1000, alignment: .leading)
        } else if let d = m.description, !d.isEmpty {
            Text(d)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: 1000, alignment: .leading)
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

    /// The red "LIVE" pill that marks a live channel (the live counterpart to the VOD trailer / Watch
    /// affordances this page drops).
    private var liveBadge: some View {
        Text("LIVE")
            .font(Theme.Typography.eyebrow).tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.Palette.danger, in: Capsule())
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    /// Full-bleed backdrop with a canvas-blended gradient and the title / metadata / synopsis on the
    /// lower band. The serif title is the editorial signature.
    private func hero(_ m: CoreMetaItem, primaryEpisode: CoreVideo? = nil, primaryIsResume: Bool = false,
                      primaryProgress: Double = 0,
                      scrollToContent: @escaping () -> Void) -> some View {
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
                ratingsRow()
                if let d = m.description, !d.isEmpty {
                    Text(d)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(3).lineSpacing(2)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                // On-screen focusable anchor: grabs initial focus on push (so Back pops instead of
                // exiting), and jumps to the episodes / sources below.
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.sm) {
                        if let primaryEpisode {
                            VStack(spacing: Theme.Space.xs) {
                                NavigationLink {
                                    CoreEpisodeStreams(meta: m, video: primaryEpisode,
                                                       season: primaryEpisode.season ?? 0,
                                                       episodes: seasonEpisodes(videos: m.videos ?? [], season: primaryEpisode.season ?? 0))
                                } label: {
                                    Label(primaryEpisodeLabel(primaryEpisode, isResume: primaryIsResume),
                                          systemImage: "play.fill")
                                }
                                .buttonStyle(PrimaryActionStyle())
                                if primaryIsResume, primaryProgress > 0.01 {
                                    ProgressStripe(value: primaryProgress)
                                        .padding(.horizontal, Theme.Space.sm)
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        if primaryEpisode == nil {
                            Button(action: scrollToContent) {
                                Label(type == "series" ? "Episodes" : "Watch",
                                      systemImage: type == "series" ? "list.bullet" : "play.fill")
                            }
                            .buttonStyle(PrimaryActionStyle())
                        } else {
                            Button(action: scrollToContent) {
                                Label("Episodes", systemImage: "list.bullet")
                            }
                            .buttonStyle(ChipButtonStyle())
                        }
                        LibraryChip()
                        trailerChip(m)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.bottom, Theme.Space.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Trailer chip. Plays the meta's trailer as a one-off clip through the player (no torrent, no
    /// meta, no progress / auto-next). Shown only when a playable trailer URL exists — for a
    /// YouTube-only trailer that needs the embedded server's `/yt` route, this is false on the Lite
    /// build (StremioServer.canProxy == false), so the chip auto-hides there.
    @ViewBuilder private func trailerChip(_ m: CoreMetaItem) -> some View {
        if let req = TrailerRequest.from(meta: m), let url = req.playableURL {
            Button {
                presenter.request = PlaybackRequest(url: url, title: "\(m.name) — Trailer")
            } label: {
                Label("Trailer", systemImage: "film")
            }
            .buttonStyle(ChipButtonStyle())
        }
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

    /// Compact MDBList ratings row ("IMDb 8.5  ·  RT 92%  ·  TMDB 78%"), shown only when the user has set
    /// an MDBList key AND ratings came back. Renders nothing otherwise (no error UI). Same typography as
    /// metaRow so it reads as a second fact line under the title.
    @ViewBuilder private func ratingsRow() -> some View {
        if let text = mdbRatings.flatMap(Self.ratingsText), !text.isEmpty {
            Text(text)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Build the joined ratings string from the decoded model, or nil when nothing is present.
    private static func ratingsText(_ r: MDBListRatings) -> String? {
        var parts: [String] = []
        if let v = r.imdb { parts.append("IMDb \(imdbFmt.string(from: NSNumber(value: v)) ?? String(v))") }
        if let v = r.rottenTomatoes { parts.append("RT \(v)%") }
        if let v = r.tmdb { parts.append("TMDB \(v)%") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// One-decimal IMDb formatter (8.5, not 8.50). `static let` to avoid per-row allocation.
    private static let imdbFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    private func seriesPrimaryEpisode(_ videos: [CoreVideo], watched: Set<String>, metaID: String) -> (video: CoreVideo, isResume: Bool)? {
        let sorted = sortedEpisodes(videos)
        // Resume position: the engine's library entry is account level, so overlay
        // profiles resolve theirs from the profile overlay instead (the same
        // invariant as the ticks and the progress stripes).
        let resume: (videoId: String?, timeOffset: Double) = {
            guard profiles.activeUsesEngineHistory else {
                let entry = profiles.watch[metaID]
                return (entry?.videoId, Double(entry?.timeOffsetMs ?? 0))
            }
            let state = core.metaDetails?.libraryItem?.state
            return (state?.videoId, state?.timeOffset ?? 0)
        }()
        if resume.timeOffset > 0,
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

    private func seasonEpisodes(videos: [CoreVideo], season: Int) -> [CoreVideo] {
        sortedEpisodes(videos).filter { ($0.season ?? 0) == season }
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

    private func episodeProgress(_ video: CoreVideo, metaID: String) -> Double {
        guard profiles.activeUsesEngineHistory else {
            guard let entry = profiles.watch[metaID], entry.videoId == video.id else { return 0 }
            return entry.progress
        }
        guard let item = core.metaDetails?.libraryItem,
              item.state.videoId == video.id,
              item.state.duration > 0 else { return 0 }
        return min(max(item.state.timeOffset / item.state.duration, 0), 1)
    }
}

/// Series episodes grouped by season: a season selector, then the chosen season's episodes with
/// thumbnails. Selecting an episode loads that episode's streams from the engine.
struct CoreSeasonedEpisodes: View {
    let meta: CoreMetaItem
    let videos: [CoreVideo]
    var watched: Set<String> = []
    var initialSeason: Int?
    @State private var showBulkMenu = false
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe so accent ticks recolor on theme change
    @EnvironmentObject private var profiles: ProfileStore   // per-profile progress + live updates

    @State private var season: Int = 1
    // Cached so a re-render (watch-state updates arrive often) does not re-filter and
    // re-sort the episode list every time. seasons depends only on the immutable
    // `videos`; episodes additionally on `season`.
    @State private var seasons: [Int] = []
    @State private var episodes: [CoreVideo] = []

    private func recomputeSeasons() { seasons = Array(Set(videos.map { $0.season ?? 0 })).sorted() }
    private func recomputeEpisodes() {
        episodes = videos.filter { ($0.season ?? 0) == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: "\(episodes.count) episode\(episodes.count == 1 ? "" : "s")", title: "Episodes")

            // Always render the season chips, even for a single season: they are the
            // only home of the bulk watched menu (long press), so hiding them left
            // single-season shows with no season or series level mark-watched at all.
            if !seasons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(seasons, id: \.self) { s in
                            Button { season = s } label: { Text(seasonLabel(s)) }
                                .buttonStyle(ChipButtonStyle(selected: season == s))
                                .contextMenu {
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
                        }
                        // The discoverable face of the bulk menu (long-pressing a season
                        // chip is the shortcut for the same actions).
                        Button { showBulkMenu = true } label: {
                            Image(systemName: "ellipsis")
                        }
                        .buttonStyle(ChipButtonStyle())
                        .confirmationDialog("Mark watched", isPresented: $showBulkMenu, titleVisibility: .visible) {
                            Button("\(seasonLabel(season)) watched") { core.markSeasonWatched(season, true) }
                            Button("\(seasonLabel(season)) unwatched") { core.markSeasonWatched(season, false) }
                            Button("Whole series watched") { core.markWatched(true) }
                            Button("Whole series unwatched") { core.markWatched(false) }
                            Button("Cancel", role: .cancel) {}
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs)
                }
            }

            VStack(spacing: Theme.Space.sm) {
                ForEach(episodes) { v in episodeRow(v) }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
        }
        .onAppear {
            recomputeSeasons()
            let preferred = initialSeason ?? firstUnwatchedSeason ?? seasons.first { $0 > 0 } ?? seasons.first ?? 1
            if seasons.contains(preferred) { season = preferred }
            else if !seasons.contains(season) { season = seasons.first { $0 > 0 } ?? seasons.first ?? 1 }
            recomputeEpisodes()
        }
        .onChange(of: season) { recomputeEpisodes() }
    }

    private var firstUnwatchedSeason: Int? {
        videos
            .sorted {
                let leftSeason = $0.season ?? 0
                let rightSeason = $1.season ?? 0
                if leftSeason != rightSeason { return leftSeason < rightSeason }
                let leftEpisode = $0.episode ?? 0
                let rightEpisode = $1.episode ?? 0
                if leftEpisode != rightEpisode { return leftEpisode < rightEpisode }
                return $0.id < $1.id
            }
            .first { !watched.contains($0.id) }?
            .season
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
        // Overlay profiles read their own history; the engine's library entry is
        // account level and would show the main profile's position (same invariant
        // as the watched ticks).
        guard profiles.activeUsesEngineHistory else {
            guard let entry = profiles.watch[meta.id], entry.videoId == v.id else { return 0 }
            return entry.progress
        }
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
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false

    var body: some View {
        let groups = StreamRanking.rankedGroups(displayGroups(core.streamGroups()))   // best source first within each add-on
        let streamCount = groups.reduce(0) { $0 + $1.streams.count }
        let visible = groups.filter { sourceFilter == nil || $0.addon == sourceFilter }
        let addons = core.streamLoadProgress()                       // (loaded, total) stream add-ons
        let loadingAddons = addons.total == 0 || addons.loaded < addons.total
        // Per-series quality memory: bias Watch Now toward the quality signature of
        // whatever this title played last (per profile), so a series you watch in a
        // specific quality keeps opening in it. Cached/instant still outranks it.
        let remembered = meta.flatMap { LastStreamStore.entry(for: $0.libraryId, profileID: ProfileStore.shared.activeID)?.qualityText }
        let best = StreamRanking.best(groups, continuity: remembered)

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
                            // watchLabel derives from the EXACT stream this button plays, so it
                            // can never promise a quality it doesn't deliver.
                            Label("Watch in \(StreamRanking.watchLabel(best))", systemImage: "play.fill")
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

                    LibraryChip()
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

    private func displayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard directLinksOnly else { return groups }
        return groups.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            guard !streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    /// Play a stream by handing a request to the root, which swaps the whole shell out for the player
    /// (the only reliable tvOS focus isolation — see RootView). Wires the engine + prepares torrents first.
    private func play(_ stream: CoreStream) {
        guard let url = stream.playableURL else { return }
        core.loadEnginePlayer(for: stream)
        prepareTorrent(stream)
        presenter.request = PlaybackRequest(url: url, title: title, meta: meta, episodes: episodes,
                                            sourceHint: StreamRanking.signature(stream), torrent: stream.isTorrent,
                                            bingeGroup: stream.behaviorHints?.bingeGroup,
                                            headers: stream.requestHeaders)
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
            // Non-playable (Ratings/RPDB, external/youtube): keep it FOCUSABLE via an inert Button so
            // the tvOS focus engine can land here and keep scrolling DOWN past it. A bare non-focusable
            // first row blocked the whole "All sources" list from scrolling (issue #77). The enabled:false
            // label still dims and shows the lock icon, so it reads as non-playable.
            Button {} label: { streamLabel(addon, stream, enabled: false) }
                .buttonStyle(RowFocusStyle())
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
        guard !PlaybackSettings.torrentsDisabled else { return }
        guard stream.url == nil, let hash = stream.infoHash?.lowercased(),
              let url = URL(string: "\(StremioServer.base)/\(hash)/create") else { return }
        // The server's first-create-wins contract means the FIRST /create's source list sticks for
        // the engine's life, and this is the PRIMARY play path — so it must carry the TCP/TLS
        // trackers (UDP/DHT alone is unreliable in the tvOS sandbox), exactly like every other
        // create path. The old `dht:` + addon-udp-only list left a sandboxed swarm unable to form.
        let sources = TorrentTrackers.sources(forHash: hash, streamSources: stream.sources)
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


/// The watch-later button: saves the open title to the library (the same library
/// the Library tab and the engine's sync use), or removes it again. State comes
/// from the engine's own library entry for this title, so it stays truthful
/// across Continue Watching, catalog, and Library entrances.
struct LibraryChip: View {
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
