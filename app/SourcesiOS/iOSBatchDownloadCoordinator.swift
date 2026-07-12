import Foundation

/// Batch offline downloads for series episodes (#119): "download season 2" / "download episodes 5-10"
/// without starting each one by hand.
///
/// The coordinator walks the requested episodes STRICTLY SEQUENTIALLY - one in-flight resolution at a
/// time - so a whole-season request never stampedes the engine's stream loaders or a debrid API with
/// 20 parallel resolves. Each episode goes through the SAME pipeline a manual "download best" uses
/// (`iOSDetailView.downloadBestSeries`):
///
///  1. `CoreBridge.loadMeta` with the episode's stream path, then the settle loop
///     (`StreamRanking.resolveSettled`) so ranking sees the user's real source set, not whoever
///     answered first.
///  2. `StreamRanking.best` with the SAME continuity / pin / user-filter inputs the manual path passes,
///     so the chosen quality preference, the source pin, and the AUDIO-LANGUAGE RANKING
///     (`StreamRanking.languageScore` over `TrackPreferences.audioLanguages`) all apply per episode.
///     There is no per-download language chooser - a download fetches the picked source's file - so
///     language preference is honored exactly the way a manual best-download honors it: via ranking.
///  3. Cached-debrid resolve (`DebridCoordinator.resolvedPlaybackURL`, season-pack episode aware) and
///     the loopback torrent prime for raw torrents, then `DownloadManager.download(...)`, whose
///     existing byte-queue (cap 2) takes over. Records appear in DownloadsView immediately as
///     `.queued` because `download()` upserts before any transfer starts.
///
/// FAIL-SOFT PER EPISODE: an episode whose sources never settle or rank to nothing is recorded as
/// skipped and the walk CONTINUES; the summary surfaces the skip count + labels at the end. This pass
/// deliberately does NOT retry alternate sources for a failed episode (follow-up work): the byte
/// transfer itself can still fail later, and the record then shows `.failed` in DownloadsView as usual.
///
/// ENGINE-SLOT HONESTY: `loadMeta` targets the engine's single meta_details slot, the same slot the
/// open detail page reads. The sequential walk keeps contention minimal, and detail pages already
/// guard their display on `meta.id`, but resolving a batch while browsing a DIFFERENT title can make
/// that page re-request its meta. Accepted for v1 (identical to what a manual episode resolve does).
///
/// Device-local only, like every download: nothing here writes account / libraryItem documents.
@MainActor
final class BatchDownloadCoordinator: ObservableObject {
    static let shared = BatchDownloadCoordinator()

    // MARK: Model

    /// One episode to resolve, carrying the ranking context captured at enqueue time (the same values
    /// the detail page would hand a manual download at that moment).
    struct Job {
        let seriesId: String
        let seriesName: String
        let fallbackPoster: String?
        let video: CoreVideo
        let continuity: String?
        let pin: ResolvedPin?
        let cachedHashes: Set<String>
    }

    /// End-of-batch result, shown inline on the series detail page until dismissed (or replaced by the
    /// next batch). `skipped` lists the episode labels that found no downloadable source.
    struct BatchSummary: Equatable {
        var seriesIds: Set<String> = []
        var queued = 0
        var alreadyDownloaded = 0
        var skipped: [String] = []
        var wasCancelled = false

        var text: String {
            var parts: [String] = [String(localized: "Queued \(queued)")]
            if alreadyDownloaded > 0 { parts.append(String(localized: "\(alreadyDownloaded) already downloaded")) }
            if !skipped.isEmpty {
                parts.append(String(localized: "skipped \(skipped.count) (no source): \(skipped.joined(separator: ", "))"))
            }
            if wasCancelled { parts.append(String(localized: "stopped early")) }
            return parts.joined(separator: "  ·  ")
        }
    }

    private enum Outcome { case queued, noSource, cancelled }

    // MARK: Published state (drives the inline status line on the detail page)

    /// Series ids with episodes still pending / resolving, so a detail page shows the status line only
    /// for its own title.
    @Published private(set) var runningSeriesIds: Set<String> = []
    /// "S1E5 · 3 of 8" while the walk runs; nil when idle.
    @Published private(set) var statusText: String?
    /// The finished batch's result; sticks until dismissed or a new batch starts.
    @Published private(set) var summary: BatchSummary?

    private var pending: [Job] = []
    private var worker: Task<Void, Never>?
    private var currentVideoId: String?
    private var tally: BatchSummary?
    private var totalPlanned = 0
    private var startedCount = 0

    var isRunning: Bool { worker != nil }

    // MARK: Public API

    /// Queue a batch of episodes (a season, or a hand-picked selection) for offline download.
    /// Episodes that already have a non-failed download record are counted as `alreadyDownloaded` and
    /// skipped with a note; episodes already pending in this batch are deduplicated silently. Calling
    /// again while a batch runs APPENDS to the walk (the status total grows), so "download season 1"
    /// then "download season 2" behaves as one longer queue.
    func enqueue(seriesId: String, seriesName: String, fallbackPoster: String?, episodes: [CoreVideo],
                 continuity: String?, pin: ResolvedPin?, cachedHashes: Set<String>) {
        guard !episodes.isEmpty else { return }
        // A fresh batch (nothing running) starts a clean tally and clears the previous summary.
        if worker == nil {
            tally = BatchSummary()
            summary = nil
        }
        tally?.seriesIds.insert(seriesId)

        let pendingIds = Set(pending.map { $0.video.id })
        var jobs: [Job] = []
        for video in episodes {
            if DownloadStore.shared.hasDownload(videoId: video.id) {
                tally?.alreadyDownloaded += 1
                continue
            }
            guard !pendingIds.contains(video.id), video.id != currentVideoId else { continue }
            jobs.append(Job(seriesId: seriesId, seriesName: seriesName, fallbackPoster: fallbackPoster,
                            video: video, continuity: continuity, pin: pin, cachedHashes: cachedHashes))
        }

        pending.append(contentsOf: jobs)
        totalPlanned += jobs.count
        runningSeriesIds.insert(seriesId)

        if worker == nil {
            if jobs.isEmpty {
                // Everything requested was already downloaded: no walk to run, surface that immediately.
                finish(cancelled: false)
            } else {
                worker = Task { [weak self] in await self?.drain() }
            }
        }
    }

    /// Stop the batch: pending episodes are dropped and the current resolution unwinds at its next
    /// cancellation check. Downloads ALREADY handed to `DownloadManager` keep going (they are ordinary
    /// queue entries by then; cancel those individually from DownloadsView).
    func cancel() {
        pending = []
        worker?.cancel()
    }

    func dismissSummary() { summary = nil }

    // MARK: Walk

    private func drain() async {
        while !Task.isCancelled, !pending.isEmpty {
            let job = pending.removeFirst()
            currentVideoId = job.video.id
            startedCount += 1
            statusText = "\(episodeLabel(job.video)) · \(startedCount) of \(totalPlanned)"
            // Re-check at resolve time: an episode enqueued twice in quick succession, or downloaded
            // manually while earlier episodes resolved, must not double-queue.
            if DownloadStore.shared.hasDownload(videoId: job.video.id) {
                tally?.alreadyDownloaded += 1
                continue
            }
            switch await resolveAndQueue(job) {
            case .queued: tally?.queued += 1
            case .noSource: tally?.skipped.append(episodeLabel(job.video))
            case .cancelled: break
            }
        }
        finish(cancelled: Task.isCancelled)
    }

    /// The per-episode pipeline, mirroring `iOSDetailView.downloadBestSeries` step for step (load +
    /// settle, rank with the user's continuity/pin/filters, cached-debrid resolve, torrent prime,
    /// enqueue). Returns `.noSource` instead of throwing so the walk continues past a dead episode.
    private func resolveAndQueue(_ job: Job) async -> Outcome {
        let core = CoreBridge.shared
        // Skip the dispatch when this episode's streams are ALREADY resident (the user just had its
        // source page open): less churn on the shared meta slot, identical result.
        if core.streamGroups(forStreamId: job.video.id).isEmpty {
            core.loadMeta(type: "series", id: job.seriesId, streamType: "series", streamId: job.video.id)
        }
        var groups: [CoreStreamSourceGroup] = []
        var firstPlayableAt: Date? = nil
        for _ in 0 ..< 80 {                                // ~20s ceiling, matching the episode page
            if Task.isCancelled { return .cancelled }
            groups = iOSDisplayGroups(core.streamGroups(forStreamId: job.video.id))
            if !groups.isEmpty, firstPlayableAt == nil { firstPlayableAt = Date() }
            let progress = core.streamLoadProgress(forStreamId: job.video.id)
            let elapsed = firstPlayableAt.map { Date().timeIntervalSince($0) } ?? 0
            if StreamRanking.resolveSettled(groups, loaded: progress.loaded, total: progress.total,
                                            secondsSinceFirstPlayable: elapsed,
                                            rememberedQuality: job.continuity) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let best = StreamRanking.best(groups, continuity: job.continuity, pin: job.pin,
                                            debridCachedHashes: job.cachedHashes),
              let url = best.playableURL else { return .noSource }
        let ep = job.video.season.flatMap { s in job.video.episode.map { DebridEpisode(season: s, episode: $0) } }
        let resolved = await DebridCoordinator.shared.resolvedPlaybackURL(for: best, episode: ep)
        if Task.isCancelled { return .cancelled }
        // Raw torrent: the loopback server must be told to /create it first (#21). Fire-and-forget:
        // the prime's retry loop is self-terminating (~15s max), same as the CW-resume prime.
        if resolved == nil, best.isTorrent { _ = prepareTorrentStream(best) }
        let pm = PlaybackMeta(libraryId: job.seriesId, videoId: job.video.id, type: "series",
                              name: job.seriesName, poster: job.video.thumbnail ?? job.fallbackPoster,
                              season: job.video.season, episode: job.video.episode)
        let record = DownloadManager.shared.download(stream: best, meta: pm, resolvedURL: resolved ?? url,
                                                     sourceName: best.name,
                                                     qualityText: StreamRanking.signature(best))
        // download() can refuse synchronously (an HLS source on a device that can't save HLS, a storage
        // shortfall): that episode was NOT queued, so report it as skipped, not as a success.
        return DownloadStore.shared.record(id: record.id)?.state == .failed ? .noSource : .queued
    }

    private func finish(cancelled: Bool) {
        worker = nil
        currentVideoId = nil
        pending = []
        totalPlanned = 0
        startedCount = 0
        statusText = nil
        runningSeriesIds = []
        if var result = tally {
            result.wasCancelled = cancelled
            summary = result
        }
        tally = nil
    }

    private func episodeLabel(_ video: CoreVideo) -> String {
        guard let season = video.season else { return "E\(video.episodeNumber)" }
        return "S\(season)E\(video.episodeNumber)"
    }
}
