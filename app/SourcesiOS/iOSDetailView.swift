import SwiftUI

/// Touch / Mac detail page. Loads meta through the shared engine, then presents the same cinematic
/// composition the tvOS `DetailView` uses — a full-bleed backdrop from `meta.background` with a dark
/// gradient scrim, the hero (logo or title, year · runtime · genres · rating, synopsis) over it, a
/// Play / Watch action, and the source list styled as surface cards. Series show a season selector and
/// an episode list; each episode loads and plays its own ranked best source.
///
/// Only the PRESENTATION mirrors tvOS. The engine wiring is unchanged: `loadMeta` / `meta_details` /
/// `streamGroups`, `StreamRanking.best`, resume, and the native `PlayerScreen` launch all behave
/// exactly as before. tvOS-only SwiftUI API is gated with `#if os(tvOS)`; this compiles on iOS 16 and
/// macOS.
struct iOSDetailView: View {
    let id: String
    let type: String
    let title: String
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live

    @State private var player: PlayerLaunch?
    @State private var preparing = false                 // movie Watch Now is resolving
    @State private var preparingEpisodeID: String?       // which episode row is resolving
    @State private var season = 1

    /// A resolved stream ready to hand to PlayerScreen (Identifiable so fullScreenCover(item:) drives it).
    private struct PlayerLaunch: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let resume: Double
        let meta: PlaybackMeta
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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                hero
                if type == "series" {
                    episodeList
                } else {
                    sourceSection
                }
            }
            .padding(.bottom, Theme.Space.xl)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(meta?.name ?? title)
        .inlineNavigationTitle()
        .onAppear { core.loadMeta(type: type, id: id) }
        .onDisappear { core.unloadMeta() }
        .platformFullScreenCover(item: $player) { launch in
            PlayerScreen(
                url: launch.url, title: launch.title, resumeSeconds: launch.resume,
                onProgress: { pos, dur in Task { await account.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onSeek: { pos, dur in Task { await account.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onClose: { player = nil }
            )
            .ignoresSafeArea()
        }
    }

    // MARK: Hero (full-bleed backdrop + scrim + meta), mirrors tvOS DetailView.hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                titleOrLogo
                metaRow
                if type == "movie" { watchNow }
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
        .frame(maxWidth: .infinity)
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
        Text(meta?.name ?? title)
            .font(Theme.Typography.hero).tracking(-1)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(3).minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Movie — Watch Now + sources

    @ViewBuilder private var watchNow: some View {
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

            iOSLibraryChip()
        }
        .padding(.top, Theme.Space.xs)
    }

    /// The full source list for a movie, styled like the tvOS stream list (surface cards, source labels).
    @ViewBuilder private var sourceSection: some View {
        let groups = StreamRanking.rankedGroups(core.streamGroups())
        let progress = core.streamLoadProgress()
        let loading = progress.total == 0 || progress.loaded < progress.total
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            iOSRailHeader(eyebrow: sourceEyebrow(count: streamCount(groups), loading: loading), title: "Sources")
            if groups.isEmpty {
                if loading {
                    iOSLoadingRow(text: progress.total > 0 ? "Finding sources…  \(progress.loaded)/\(progress.total)" : "Finding sources…")
                } else {
                    iOSEmptyRow(text: "None of your add-ons returned a playable source for this title.")
                }
            } else {
                LazyVStack(spacing: Theme.Space.sm) {
                    ForEach(groups) { group in
                        ForEach(Array(group.streams.enumerated()), id: \.offset) { _, stream in
                            movieStreamRow(group.addon, stream)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
    }

    @ViewBuilder private func movieStreamRow(_ addon: String, _ stream: CoreStream) -> some View {
        if let url = stream.playableURL {
            Button {
                Task { await playStream(stream, url: url) }
            } label: {
                iOSStreamLabel(addon: addon, stream: stream, enabled: true)
            }
            .buttonStyle(RowFocusStyle())
        } else {
            iOSStreamLabel(addon: addon, stream: stream, enabled: false)
                .background(Theme.Palette.surface1.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private var movieReady: Bool { meta != nil && StreamRanking.best(core.streamGroups()) != nil }

    private var movieLabel: String {
        if preparing { return "Finding the best source…" }
        guard movieReady, let s = StreamRanking.best(core.streamGroups()) else { return "Loading sources…" }
        return "Watch  ·  \(StreamRanking.qualityLabel(s))"
    }

    private func playMovie() async {
        guard !preparing, let m = meta, let stream = StreamRanking.best(core.streamGroups()),
              let url = stream.playableURL else { return }
        preparing = true; defer { preparing = false }
        let pm = PlaybackMeta(libraryId: m.id, videoId: m.id, type: "movie",
                              name: m.name, poster: m.poster, season: nil, episode: nil)
        player = PlayerLaunch(url: url, title: m.name, resume: await resume(pm), meta: pm)
    }

    /// Play an arbitrary chosen movie source (a tapped source-list row).
    private func playStream(_ stream: CoreStream, url: URL) async {
        guard !preparing, let m = meta else { return }
        preparing = true; defer { preparing = false }
        let pm = PlaybackMeta(libraryId: m.id, videoId: m.id, type: "movie",
                              name: m.name, poster: m.poster, season: nil, episode: nil)
        player = PlayerLaunch(url: url, title: m.name, resume: await resume(pm), meta: pm)
    }

    // MARK: Series — season selector + episode cards

    @ViewBuilder private var episodeList: some View {
        if let videos = meta?.videos, !videos.isEmpty {
            let seasons = Array(Set(videos.compactMap { $0.season })).sorted()
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                iOSRailHeader(eyebrow: "\(episodes(videos).count) episode\(episodes(videos).count == 1 ? "" : "s")",
                              title: "Episodes")

                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.sm) {
                            ForEach(seasons, id: \.self) { s in
                                Button { season = s } label: { Text(seasonLabel(s)) }
                                    .buttonStyle(ChipButtonStyle(selected: season == s))
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }

                VStack(spacing: Theme.Space.sm) {
                    ForEach(episodes(videos), id: \.id) { v in episodeRow(v) }
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .onAppear { if let first = seasons.first, !seasons.contains(season) { season = first } }
        }
    }

    private func episodeRow(_ v: CoreVideo) -> some View {
        let isPreparing = preparingEpisodeID == v.id
        return Button {
            Task { await playEpisode(v) }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                episodeThumbnail(v, preparing: isPreparing)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(v.episodeNumber). \(v.episodeTitle)")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
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
        }
        .buttonStyle(RowFocusStyle())
        .disabled(preparingEpisodeID != nil)
    }

    private func episodeThumbnail(_ v: CoreVideo, preparing: Bool) -> some View {
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
        .overlay {
            if preparing {
                ZStack {
                    Color.black.opacity(0.45)
                    ProgressView().tint(Theme.Palette.textPrimary)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            }
        }
    }

    private func episodes(_ videos: [CoreVideo]) -> [CoreVideo] {
        videos.filter { ($0.season ?? 1) == season }
            .sorted { $0.episodeNumber < $1.episodeNumber }
    }

    private func seasonLabel(_ s: Int) -> String { s == 0 ? "Specials" : "Season \(s)" }

    /// Load the episode's streams (the engine loads per-episode streams on demand), wait for a
    /// playable source to land, rank the best, and present the player. Mirrors the tvOS flow.
    private func playEpisode(_ v: CoreVideo) async {
        guard preparingEpisodeID == nil, let m = meta else { return }
        preparingEpisodeID = v.id
        defer { preparingEpisodeID = nil }
        core.loadMeta(type: "series", id: id, streamType: "series", streamId: v.id)
        // Poll for this episode's streams (matched by id) for up to ~12s.
        for _ in 0..<48 {
            let groups = core.streamGroups(forStreamId: v.id)
            if let best = StreamRanking.best(groups), let url = best.playableURL {
                let name = "\(m.name)  ·  S\(v.season ?? season)E\(v.episodeNumber)"
                let pm = PlaybackMeta(libraryId: m.id, videoId: v.id, type: "series",
                                      name: m.name, poster: v.thumbnail ?? m.poster,
                                      season: v.season, episode: v.episode)
                player = PlayerLaunch(url: url, title: name, resume: await resume(pm), meta: pm)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Shared

    private func streamCount(_ groups: [CoreStreamSourceGroup]) -> Int {
        groups.reduce(0) { $0 + $1.streams.count }
    }

    private func sourceEyebrow(count: Int, loading: Bool) -> String {
        if count == 0 { return loading ? "Searching" : "None found" }
        return loading ? "\(count) so far" : "\(count) source\(count == 1 ? "" : "s")"
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

/// A source row styled like the tvOS stream list: an icon, the addon + torrent badges, the addon's
/// own name, and its full description.
private struct iOSStreamLabel: View {
    let addon: String
    let stream: CoreStream
    let enabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: enabled ? (stream.isTorrent ? "arrow.down.circle.fill" : "play.circle.fill") : "lock.circle")
                .font(.system(size: 26))
                .foregroundStyle(enabled ? Theme.Palette.accent : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 6) {
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
                    Text(desc).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
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
