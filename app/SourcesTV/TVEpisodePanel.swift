#if os(tvOS)
import SwiftUI
import UIKit

/// The in-player episode list for the bare tvOS AVPlayer (#46). It is hosted inside
/// `AVPlayerViewController.customInfoViewControllers`, the Info-panel tab AVKit reveals when the viewer
/// swipes down on the Siri remote. AVKit owns the focus engine for that panel, so this focusable list never
/// competes with the remote the way a custom overlay would — which is exactly why the tvOS HLS / Dolby-Vision
/// path stays a bare `AVPlayerViewController` instead of routing through `TVPlayerView` (the focus invariant).
///
/// This delivers the "Prefer AVPlayer + in-player episode list" experience the redditors asked for: pick any
/// episode and `onSelect` resolves it through the engine and re-presents the player on the new episode.
struct TVPlayerEpisodePanel: View {
    let episodes: [CoreVideo]
    let currentVideoId: String
    let onSelect: (CoreVideo) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(episodes) { episode in
                        Button { onSelect(episode) } label: {
                            EpisodeRow(episode: episode, isCurrent: episode.id == currentVideoId)
                        }
                        .buttonStyle(.card)
                        .id(episode.id)
                    }
                }
                .padding(60)
            }
            // Land focus / scroll on the episode that's playing so the panel opens where the viewer is.
            .onAppear { proxy.scrollTo(currentVideoId, anchor: .center) }
        }
    }

    /// One episode: thumbnail, SxxExx label, title, and a "now playing" marker on the active episode.
    private struct EpisodeRow: View {
        let episode: CoreVideo
        let isCurrent: Bool

        var body: some View {
            HStack(spacing: 24) {
                AsyncImage(url: episode.thumbnail.flatMap(URL.init(string:))) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.white.opacity(0.08))
                }
                .frame(width: 214, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(label)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                        if isCurrent {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(episode.episodeTitle)
                        .font(.title3.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// "S2E5" / "E5" — numeric, not localized (episode numbering is universal).
        private var label: String {
            if let season = episode.season, season > 0 { return "S\(season)E\(episode.episodeNumber)" }
            return "E\(episode.episodeNumber)"
        }
    }
}

/// The in-player source / quality list for the bare tvOS AVPlayer (#46), the companion to the Episodes
/// panel and also hosted in `customInfoViewControllers`. It lists the ranked sources for the playing title,
/// marks the one playing (by ranking signature), and switches to any other without leaving the player. AVKit
/// owns the panel focus, same as the Episodes panel, so the Siri-remote focus invariant holds.
struct TVPlayerSourcesPanel: View {
    let groups: [CoreStreamSourceGroup]
    let currentSignature: String
    let onSelect: (CoreStream) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(groups, id: \.id) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        if !group.addon.isEmpty {
                            Text(group.addon)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(group.streams.enumerated()), id: \.offset) { _, stream in
                            if stream.playableURL != nil {
                                Button { onSelect(stream) } label: {
                                    SourceRow(stream: stream, isCurrent: StreamRanking.signature(stream) == currentSignature)
                                }
                                .buttonStyle(.card)
                            }
                        }
                    }
                }
            }
            .padding(60)
        }
    }

    /// One source: the add-on's stream label, with a "now playing" marker on the active source.
    private struct SourceRow: View {
        let stream: CoreStream
        let isCurrent: Bool

        var body: some View {
            HStack(spacing: 16) {
                if isCurrent {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(Color.accentColor)
                }
                Text(label)
                    .font(.title3.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Mirror of `TVPlayerView.sourceLabel`: the stream name's first line, else the description's, else
        /// a generic fallback.
        private var label: String {
            func firstLine(_ t: String?) -> String {
                (t ?? "").split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            }
            let name = firstLine(stream.name)
            if !name.isEmpty { return name }
            let desc = firstLine(stream.description)
            return desc.isEmpty ? String(localized: "Source") : desc
        }
    }
}

/// Resolve another episode of the playing series to a ready-to-present `PlaybackRequest`, the bare tvOS
/// AVPlayer's twin of `TVPlayerView.play(episode:)` and the iOS `iOSResolveEpisodeStream`. It loads the
/// episode's streams through the engine, waits on the same settle gate the launch path uses (so it lands on
/// the SAME quality the viewer was watching, not the first torrent that answers), ranks the best (honouring
/// the source pin), primes the torrent on the embedded server if the best is one, and hands back a request.
///
/// Re-presenting that request through `PlayerPresenter` re-runs the engine's routing decision: a non-torrent
/// best stays in this bare AVPlayer, a torrent best lands in `TVPlayerView`. @MainActor: touches `CoreBridge`.
@MainActor
func tvResolveEpisodeRequest(video v: CoreVideo, in episodes: [CoreVideo], seriesId: String,
                             seriesName: String, fallbackPoster: String?, continuity: String?,
                             binge: String?, core: CoreBridge, account: StremioAccount) async -> PlaybackRequest? {
    core.loadMeta(type: "series", id: seriesId, streamType: "series", streamId: v.id)
    var groups: [CoreStreamSourceGroup] = []
    var firstPlayableAt: Date?
    for _ in 0 ..< 80 {                                    // ~20s ceiling, matching the episode page
        groups = core.streamGroups(forStreamId: v.id)
        if groups.contains(where: { $0.streams.contains { $0.playableURL != nil } }), firstPlayableAt == nil {
            firstPlayableAt = Date()
        }
        let progress = core.streamLoadProgress(forStreamId: v.id)
        let elapsed = firstPlayableAt.map { Date().timeIntervalSince($0) } ?? 0
        if StreamRanking.resolveSettled(groups, loaded: progress.loaded, total: progress.total,
                                        secondsSinceFirstPlayable: elapsed, rememberedQuality: continuity) { break }
        try? await Task.sleep(for: .milliseconds(250))
    }
    let pin = SourcePinStore.shared.effectivePin(SourcePinContext(metaId: seriesId, isSeries: true))
    guard let best = StreamRanking.best(groups, continuity: continuity, binge: binge, pin: pin),
          let url = best.playableURL else { return nil }
    core.loadEnginePlayer(for: best)
    tvPrimeTorrentStream(best)   // no-op for direct / debrid URLs; the embedded server needs the create first
    let meta = PlaybackMeta(libraryId: seriesId, videoId: v.id, type: "series",
                            name: seriesName, poster: v.thumbnail ?? fallbackPoster,
                            season: v.season, episode: v.episode)
    let title = "\(seriesName)  ·  S\(v.season ?? 0)E\(v.episodeNumber)"
    return PlaybackRequest(url: url, title: title, meta: meta, episodes: episodes,
                           sourceHint: StreamRanking.signature(best), torrent: best.isTorrent,
                           bingeGroup: best.behaviorHints?.bingeGroup, headers: best.requestHeaders)
}

/// Tell the embedded server to create the torrent engine (POST /{hash}/create) before the player opens its
/// loopback URL — a self-contained copy of `TVPlayerView.prepareTorrent`, since the re-present path resolves
/// the episode/source outside any player view. Stateless and fire-and-forget; a no-op for direct / debrid
/// streams. File-internal (not private) so the Sources-panel switch in RootTabView can prime too.
func tvPrimeTorrentStream(_ stream: CoreStream) {
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
    URLSession.shared.dataTask(with: request).resume()
}
#endif
