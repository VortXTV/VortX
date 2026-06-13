import SwiftUI

/// Touch detail page. Loads meta through the shared engine, shows the hero + synopsis, and plays
/// the ranked best source through the shared native player (PlayerScreen). Movies play via Watch
/// Now; series show a season/episode list that loads and plays each episode's ranked best source.
struct iOSDetailView: View {
    let id: String
    let type: String
    let title: String
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                AsyncImage(url: URL(string: meta?.background ?? meta?.poster ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(16/9, contentMode: .fill)
                    default: Theme.Palette.surface1.aspectRatio(16/9, contentMode: .fill)
                    }
                }
                .clipped()
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(meta?.name ?? title)
                        .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
                    if let info = meta?.releaseInfo { Text(info).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary) }
                    if type == "movie" { watchNow }
                    if let overview = meta?.description {
                        Text(overview).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    if type == "series" { episodeList }
                }
                .padding(.horizontal, Theme.Space.md)
            }
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

    // MARK: Movie

    @ViewBuilder private var watchNow: some View {
        Button {
            Task { await playMovie() }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                if preparing { ProgressView().tint(.white) } else { Image(systemName: "play.fill") }
                Text(movieLabel)
            }
            .font(Theme.Typography.cardTitle).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.md)
            .background(movieReady ? Theme.Palette.accent : Theme.Palette.surface2,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .disabled(!movieReady || preparing)
        .padding(.vertical, Theme.Space.sm)
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

    // MARK: Series

    @ViewBuilder private var episodeList: some View {
        if let videos = meta?.videos, !videos.isEmpty {
            let seasons = Array(Set(videos.compactMap { $0.season })).sorted()
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if seasons.count > 1 {
                    Picker("Season", selection: $season) {
                        ForEach(seasons, id: \.self) { Text("Season \($0)").tag($0) }
                    }
                    .pickerStyle(.menu).tint(Theme.Palette.accent)
                }
                ForEach(episodes(videos), id: \.id) { v in
                    Button {
                        Task { await playEpisode(v) }
                    } label: {
                        HStack(spacing: Theme.Space.sm) {
                            if preparingEpisodeID == v.id { ProgressView() }
                            else { Image(systemName: "play.circle").foregroundStyle(Theme.Palette.accent) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(v.episodeNumber). \(v.title ?? "Episode \(v.episodeNumber)")")
                                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
                                if let aired = v.released?.prefix(10) {
                                    Text(String(aired)).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                    .disabled(preparingEpisodeID != nil)
                    Divider().overlay(Theme.Palette.surface2)
                }
            }
            .padding(.top, Theme.Space.sm)
            .onAppear { if let first = seasons.first, !seasons.contains(season) { season = first } }
        }
    }

    private func episodes(_ videos: [CoreVideo]) -> [CoreVideo] {
        videos.filter { ($0.season ?? 1) == season }
            .sorted { $0.episodeNumber < $1.episodeNumber }
    }

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
