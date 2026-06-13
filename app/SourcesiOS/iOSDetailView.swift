import SwiftUI

/// Touch detail page. Loads meta through the shared engine, shows the hero + synopsis, and plays
/// the ranked best source through the shared native player (PlayerScreen). Movies play here today;
/// the series episode picker is the next 0.3.0 iteration.
struct iOSDetailView: View {
    let id: String
    let type: String
    let title: String
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount

    @State private var player: PlayerLaunch?
    @State private var preparing = false

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
                    watchNow
                    if let overview = meta?.description {
                        Text(overview).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .padding(.horizontal, Theme.Space.md)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(meta?.name ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { core.loadMeta(type: type, id: id) }
        .onDisappear { core.unloadMeta() }
        .fullScreenCover(item: $player) { launch in
            PlayerScreen(
                url: launch.url, title: launch.title, resumeSeconds: launch.resume,
                onProgress: { pos, dur in Task { await account.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onSeek: { pos, dur in Task { await account.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onClose: { player = nil }
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var watchNow: some View {
        if type == "movie" {
            Button {
                Task { await prepareAndPlay() }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    if preparing { ProgressView().tint(.white) } else { Image(systemName: "play.fill") }
                    Text(watchLabel)
                }
                .font(Theme.Typography.cardTitle).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.md)
                .background(streamsReady ? Theme.Palette.accent : Theme.Palette.surface2,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .disabled(!streamsReady || preparing)
            .padding(.vertical, Theme.Space.sm)
        } else if type == "series" {
            Label("Series episode picker lands in the next 0.3.0 build", systemImage: "list.and.film")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                .padding(.top, Theme.Space.sm)
        }
    }

    /// Streams for THIS title are loaded and at least one is playable.
    private var streamsReady: Bool {
        meta != nil && bestStream != nil
    }

    private var bestStream: CoreStream? {
        guard meta != nil else { return nil }   // engine state matches this id (see meta guard)
        return StreamRanking.best(core.streamGroups())
    }

    private var watchLabel: String {
        if preparing { return "Finding the best source…" }
        guard streamsReady, let s = bestStream else { return "Loading sources…" }
        return "Watch  ·  \(StreamRanking.qualityLabel(s))"
    }

    private func prepareAndPlay() async {
        guard !preparing, let m = meta, let stream = bestStream, let url = stream.playableURL else { return }
        preparing = true
        defer { preparing = false }
        let pm = PlaybackMeta(libraryId: m.id, videoId: m.id, type: "movie",
                              name: m.name, poster: m.poster, season: nil, episode: nil)
        // Engine-history profiles resume from the engine; everyone else from the account/overlay.
        let resume: Double
        if let engine = core.engineResumeSeconds(for: pm) { resume = engine }
        else { resume = await account.resumeOffset(for: pm) }
        player = PlayerLaunch(url: url, title: m.name, resume: resume, meta: pm)
    }

    // metaDetails is a single shared @Published on the CoreBridge singleton. Guard on the id so a
    // previous page's still-resident meta (A -> back -> B) can't render A's hero/title under B.
    private var meta: CoreMetaItem? {
        let m = core.metaDetails?.meta
        return m?.id == id ? m : nil
    }
}
