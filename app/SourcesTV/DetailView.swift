import SwiftUI

/// Meta detail, driven by the **stremio-core** engine (CoreBridge): a cinematic hero + overview, then
/// streams (movie) or a season selector with episode thumbnails (series). Streams come from the
/// engine's `meta_details`, the same complete, per-addon list the official app shows.
struct DetailView: View {
    let type: String
    let id: String
    var client: AddonClient = AddonClient()   // kept for call-site compatibility (Search)
    @EnvironmentObject private var core: CoreBridge

    var body: some View {
        ScrollView {
            if let meta = core.metaDetails?.meta {
                VStack(alignment: .leading, spacing: 40) {
                    hero(meta)
                    if type == "series", let videos = meta.videos, !videos.isEmpty {
                        CoreSeasonedEpisodes(meta: meta, videos: videos,
                                             watched: core.metaDetails?.watchedIds ?? [])
                    } else {
                        CoreStreamList(title: meta.name,
                                       meta: PlaybackMeta(libraryId: meta.id, videoId: meta.id, type: type,
                                                          name: meta.name, poster: meta.poster,
                                                          season: nil, episode: nil))
                            .padding(.horizontal, 60)
                    }
                }
                .padding(.bottom, 60)
            } else {
                ProgressView().padding(120)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)            // let the backdrop bleed to the top edge
        .onAppear { core.loadMeta(type: type, id: id) }
    }

    /// Full-bleed backdrop + gradient with title/metadata/overview overlaid on the lower band.
    private func hero(_ m: CoreMetaItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: m.background ?? m.poster ?? "")) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: Color.gray.opacity(0.15)
                }
            }
            .frame(height: 520)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(
                LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(m.name).font(.system(size: 56, weight: .heavy)).lineLimit(1)
                HStack(spacing: 16) {
                    if let r = m.releaseInfo { Label(r, systemImage: "calendar") }
                    if let rt = m.runtime { Label(rt, systemImage: "clock") }
                    if let imdb = m.imdbRating { Label(imdb, systemImage: "star.fill").foregroundStyle(.yellow) }
                }
                .font(.title3).foregroundStyle(.white.opacity(0.9))
                let genres = m.genres
                if !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · ")).font(.callout).foregroundStyle(.white.opacity(0.7))
                }
                if let d = m.description, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2).frame(maxWidth: 1300, alignment: .leading)
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Series episodes grouped by season: a season selector, then the chosen season's episodes with
/// thumbnails. Selecting an episode loads that episode's streams from the engine.
struct CoreSeasonedEpisodes: View {
    let meta: CoreMetaItem
    let videos: [CoreVideo]
    var watched: Set<String> = []
    @EnvironmentObject private var core: CoreBridge

    @State private var season: Int = 1

    private var seasons: [Int] { Array(Set(videos.map { $0.season ?? 0 })).sorted() }
    private var episodes: [CoreVideo] {
        videos.filter { ($0.season ?? 0) == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Episodes").font(.title2.weight(.semibold)).padding(.horizontal, 60)

            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(seasons, id: \.self) { s in
                            Button { season = s } label: { Text(seasonLabel(s)) }
                                .buttonStyle(ChipButtonStyle(selected: season == s))
                        }
                    }
                    .padding(.horizontal, 60).padding(.vertical, 4)
                }
            }

            // Mark watched/unwatched, selected season + whole series. (Per-episode: long-press a row.)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    Button { core.markSeasonWatched(season, true) } label: { Text("Mark \(seasonLabel(season)) watched") }
                        .buttonStyle(ChipButtonStyle())
                    Button { core.markSeasonWatched(season, false) } label: { Text("Mark \(seasonLabel(season)) unwatched") }
                        .buttonStyle(ChipButtonStyle())
                    Button { core.markWatched(true) } label: { Text("Whole series watched") }
                        .buttonStyle(ChipButtonStyle())
                    Button { core.markWatched(false) } label: { Text("Whole series unwatched") }
                        .buttonStyle(ChipButtonStyle())
                }
                .padding(.horizontal, 60).padding(.vertical, 4)
            }

            VStack(spacing: 18) {
                ForEach(episodes) { v in episodeRow(v) }
            }
            .padding(.horizontal, 60)
        }
        .onAppear {
            if !seasons.contains(season) { season = seasons.first { $0 > 0 } ?? seasons.first ?? 1 }
        }
    }

    private func episodeRow(_ v: CoreVideo) -> some View {
        let isWatched = watched.contains(v.id)
        return NavigationLink {
            CoreEpisodeStreams(meta: meta, video: v, season: v.season ?? season)
        } label: {
            HStack(alignment: .top, spacing: 22) {
                AsyncImage(url: URL(string: v.thumbnail ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: ZStack { Color.gray.opacity(0.2)
                        Image(systemName: "play.rectangle.fill").font(.title).foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 300, height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2).foregroundStyle(.green).padding(8).shadow(radius: 3)
                    }
                }
                .opacity(isWatched ? 0.6 : 1)   // watched episodes are dimmed; unwatched stand out

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                        }
                        Text("\(v.episode ?? 0). \(episodeTitle(v))")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(isWatched ? Color.secondary : Color.white).lineLimit(2)
                    }
                    if let released = v.released, released.count >= 10 {
                        Text(String(released.prefix(10))).font(.callout).foregroundStyle(.secondary)
                    }
                    if let overview = v.overview, !overview.isEmpty {
                        Text(overview).font(.callout).foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .buttonStyle(.card)
        .contextMenu {
            Button(isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                core.markVideoWatched(v, !isWatched)
            }
        }
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
    @EnvironmentObject private var core: CoreBridge

    var body: some View {
        ScrollView {
            CoreStreamList(title: "\(meta.name) · S\(season)·E\(video.episode ?? 0)",
                           meta: PlaybackMeta(libraryId: meta.id, videoId: video.id, type: "series",
                                              name: meta.name, poster: meta.poster,
                                              season: video.season, episode: video.episode))
                .padding(.horizontal, 60).padding(.vertical, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: video.id) }
    }
}

/// The per-addon stream list from the engine: source filter chips + each addon's streams shown
/// exactly as the addon labelled them (name + full description), with direct/debrid vs torrent.
struct CoreStreamList: View {
    let title: String
    var meta: PlaybackMeta? = nil
    @EnvironmentObject private var core: CoreBridge
    @State private var sourceFilter: String? = nil

    var body: some View {
        let groups = core.streamGroups()
        let total = groups.reduce(0) { $0 + $1.streams.count }
        let visible = groups.filter { sourceFilter == nil || $0.addon == sourceFilter }

        return VStack(alignment: .leading, spacing: 16) {
            if total > 0 {
                Text("\(visible.reduce(0) { $0 + $1.streams.count }) of \(total) source\(total == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                if groups.count > 1 { filterBar(groups, total: total) }
                ForEach(visible) { group in
                    ForEach(group.streams) { stream in streamRow(group.addon, stream) }
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Finding streams…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
            }
        }
    }

    private func filterBar(_ groups: [CoreStreamSourceGroup], total: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button { sourceFilter = nil } label: { Text("All (\(total))") }
                    .buttonStyle(ChipButtonStyle(selected: sourceFilter == nil))
                ForEach(groups) { group in
                    Button { sourceFilter = group.addon } label: { Text("\(group.addon) (\(group.streams.count))") }
                        .buttonStyle(ChipButtonStyle(selected: sourceFilter == group.addon))
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func streamRow(_ addon: String, _ stream: CoreStream) -> some View {
        if let url = stream.playableURL {
            NavigationLink {
                TVPlayerView(url: url, title: title, meta: meta)
                    .task { prepareTorrent(stream) }
            } label: { streamLabel(addon, stream, enabled: true) }
            .buttonStyle(.plain)
        } else {
            streamLabel(addon, stream, enabled: false)   // external/youtube, not playable in-app
        }
    }

    private func streamLabel(_ addon: String, _ stream: CoreStream, enabled: Bool) -> some View {
        let icon = enabled ? (stream.isTorrent ? "arrow.down.circle.fill" : "play.circle.fill") : "lock.circle"
        return HStack(alignment: .top, spacing: 18) {
            Image(systemName: icon).font(.title2).foregroundStyle(enabled ? .cyan : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(addon.uppercased()).font(.caption2.weight(.bold)).tracking(1)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color.cyan.opacity(0.18), in: Capsule()).foregroundStyle(.cyan)
                    if stream.isTorrent {
                        Text("TORRENT").font(.caption2.weight(.bold)).tracking(1)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Color.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                    }
                }
                if let name = stream.name, !name.isEmpty {
                    Text(name).font(.headline).foregroundStyle(enabled ? .white : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let desc = stream.description, !desc.isEmpty {
                    Text(desc).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).opacity(enabled ? 1 : 0.5)
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
