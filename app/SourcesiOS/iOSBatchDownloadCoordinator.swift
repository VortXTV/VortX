import Foundation

/// Batch offline downloads for series episodes (#119): "download season 2" / "download episodes 5-10"
/// without starting each one by hand.
///
/// The coordinator walks the requested episodes STRICTLY SEQUENTIALLY - one in-flight resolution at a
/// time - so a whole-season request never stampedes the engine's stream loaders or a debrid API with
/// 20 parallel resolves. Each episode goes through the SAME pipeline a manual per-episode download
/// uses (the `iOSEpisodeStreams` page):
///
///  1. `CoreBridge.loadMeta` with the episode's stream path, then the settle loop
///     (`StreamRanking.resolveSettled`) so ranking sees the user's real source set, not whoever
///     answered first.
///  2. The SAME client-side contributors the manual page merges before ranking: the TorBox search
///     index (`TorBoxSearchSource`) and the Singularity community pool (`SourceIndexServeSource`),
///     refreshed ONCE PER SERIES (matching the episode page's show-level refresh) and merged into the
///     engine groups in the same order (`sourceIndex.merged(into: torboxSearch.merged(into: groups))`)
///     BEFORE the Direct-links-only filter. Without this merge, a TorBox-primary user's batch would
///     skip every episode a manual tap finds. SERVE only: the HOARD contribution stays on the
///     interactive surfaces.
///  3. `StreamRanking.best` with the SAME continuity / pin / user-filter inputs the manual path passes,
///     so the chosen quality preference, the source pin, and the AUDIO-LANGUAGE RANKING
///     (`StreamRanking.languageScore` over `TrackPreferences.audioLanguages`) all apply per episode.
///     There is no per-download language chooser - a download fetches the picked source's file - so
///     language preference is honored exactly the way a manual best-download honors it: via ranking.
///  4. Cached-debrid resolve (`DebridCoordinator.resolvedPlaybackURL`, season-pack episode aware) and
///     the loopback torrent prime for raw torrents, then `DownloadManager.download(...)`, whose
///     existing byte-queue (cap 2) takes over. Records appear in DownloadsView immediately as
///     `.queued` because `download()` upserts before any transfer starts.
///
/// FAIL-SOFT PER EPISODE: an episode whose sources never settle or rank to nothing is recorded as
/// skipped and the walk CONTINUES; the summary surfaces the skip count + labels at the end. This pass
/// deliberately does NOT retry alternate sources for a failed episode (follow-up work): the byte
/// transfer itself can still fail later, and the record then shows `.failed` in DownloadsView as usual.
///
/// INTERRUPTION HONESTY: the pending walk lives in memory only (no background-task assertion), so an
/// app quit / kill mid-batch silently drops the not-yet-queued episodes. A tiny snapshot (series ids +
/// remaining episode labels + the running tally) is persisted to UserDefaults on every job transition;
/// the next launch surfaces it as a one-shot "interrupted, N not queued" summary and clears it. No
/// auto-resume in this pass: a re-run is cheap and idempotent (already-downloaded episodes skip).
///
/// ENGINE-SLOT HONESTY: `loadMeta` targets the engine's single meta_details slot, the same slot the
/// open detail page reads. Browsing to a DIFFERENT title while a batch runs can clobber that slot out
/// from under the episode resolving at that moment: its stream groups then read empty and it is
/// recorded as a FALSE "no source" skip. There is no wrong-file risk (groups are matched on the
/// episode's own stream id, so ranking never sees another title's streams); the cost is only the
/// visible skip, and re-running the batch re-attempts it. Same slot contention a manual resolve has.
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
        /// The show's imdb tt id (the meta `defaultVideoId` fallback chain), the key both contributor
        /// fetchers need. nil when unknown; both fetchers then no-op, same as the manual page.
        let seriesImdbId: String?
        let fallbackPoster: String?
        let video: CoreVideo
        let continuity: String?
        let pin: ResolvedPin?
        let cachedHashes: Set<String>
    }

    /// End-of-batch result, shown inline on the series detail page until dismissed (or replaced by the
    /// next batch). `skipped` lists the episode labels that found no downloadable source;
    /// `interrupted` counts episodes a previous process never got to (restored from the snapshot).
    struct BatchSummary: Equatable {
        var seriesIds: Set<String> = []
        var queued = 0
        var alreadyDownloaded = 0
        var skipped: [String] = []
        var wasCancelled = false
        var interrupted = 0

        var text: String {
            var parts: [String] = []
            if interrupted > 0 {
                parts.append(String(localized: "Batch interrupted: \(interrupted) not queued"))
            }
            parts.append(String(localized: "Queued \(queued)"))
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

    /// Series ids with episodes waiting or resolving, so a detail page shows a status line only for
    /// its own title.
    @Published private(set) var runningSeriesIds: Set<String> = []
    /// The series whose episode is resolving RIGHT NOW. `statusText` describes only this series; a
    /// page for any other running series shows its own generic waiting line (`remainingBySeries`),
    /// never another show's episode label.
    @Published private(set) var currentSeriesId: String?
    /// "S1E5 · 3 of 8" for `currentSeriesId`, with PER-SERIES counters (two queued shows never blend
    /// into one global count). nil when idle.
    @Published private(set) var statusText: String?
    /// Episodes still waiting in the queue per series (excludes the one resolving now).
    @Published private(set) var remainingBySeries: [String: Int] = [:]
    /// The finished batch's result; sticks until dismissed or a new batch starts.
    @Published private(set) var summary: BatchSummary?

    private var pending: [Job] = []
    private var worker: Task<Void, Never>?
    private var currentVideoId: String?
    private var currentLabel: String?
    private var tally: BatchSummary?
    /// Per-series "N of M" counters behind `statusText`.
    private var plannedBySeries: [String: Int] = [:]
    private var startedBySeries: [String: Int] = [:]

    /// The coordinator's OWN contributor fetchers, mirroring the per-view `@StateObject`s the manual
    /// pages hold, reused across the whole batch. All protection lives inside the types and is reused,
    /// never reimplemented: `TorBoxSearchSource.refresh` carries the session cache, the in-flight
    /// guard, and the 429 scraper-cooldown backoff (one round trip per show, and a cooldown wall stops
    /// further requests), so a batch can never stampede the TorBox search API; `SourceIndexServeSource`
    /// applies the Singularity toggle + sign-in + consent gates internally (gates off = empty group =
    /// pass-through merge, exactly like the manual page).
    private let torboxSearch = TorBoxSearchSource()
    private let sourceIndex = SourceIndexServeSource()
    /// The series whose contributors were last refreshed, so the refresh fires once per series, not
    /// per episode (both clients also dedup internally; this keeps the intent explicit).
    private var contributorSeriesKey: String?

    var isRunning: Bool { worker != nil }

    private init() { restoreInterruptedSnapshot() }

    // MARK: Public API

    /// Queue a batch of episodes (a season, or a hand-picked selection) for offline download.
    /// Episodes that already have a non-failed download record are counted as `alreadyDownloaded` and
    /// skipped with a note; episodes already pending in this batch are deduplicated silently. Calling
    /// again while a batch runs APPENDS to the walk (the per-series totals grow), so "download season
    /// 1" then "download season 2" behaves as one longer queue.
    func enqueue(seriesId: String, seriesName: String, seriesImdbId: String?, fallbackPoster: String?,
                 episodes: [CoreVideo], continuity: String?, pin: ResolvedPin?, cachedHashes: Set<String>) {
        guard !episodes.isEmpty else { return }
        // A fresh batch (nothing running) starts a clean tally and clears the previous summary.
        if worker == nil {
            tally = BatchSummary()
            summary = nil
            plannedBySeries = [:]
            startedBySeries = [:]
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
            jobs.append(Job(seriesId: seriesId, seriesName: seriesName, seriesImdbId: seriesImdbId,
                            fallbackPoster: fallbackPoster, video: video, continuity: continuity,
                            pin: pin, cachedHashes: cachedHashes))
        }

        pending.append(contentsOf: jobs)
        plannedBySeries[seriesId, default: 0] += jobs.count
        republishQueueState()
        persistSnapshot()

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
            currentLabel = episodeLabel(job.video)
            currentSeriesId = job.seriesId
            startedBySeries[job.seriesId, default: 0] += 1
            statusText = "\(episodeLabel(job.video)) · \(startedBySeries[job.seriesId] ?? 0) of \(plannedBySeries[job.seriesId] ?? 0)"
            republishQueueState()
            persistSnapshot()
            // Re-check at resolve time: an episode enqueued twice in quick succession, or downloaded
            // manually while earlier episodes resolved, must not double-queue.
            if DownloadStore.shared.hasDownload(videoId: job.video.id) {
                tally?.alreadyDownloaded += 1
                continue
            }
            refreshContributorsIfNeeded(for: job)
            switch await resolveAndQueue(job) {
            case .queued: tally?.queued += 1
            case .noSource: tally?.skipped.append(episodeLabel(job.video))
            case .cancelled: break
            }
        }
        finish(cancelled: Task.isCancelled)
    }

    /// Fire the two contributor refreshes ONCE PER SERIES (the manual episode page refreshes them
    /// show-level on appear, exactly this shape). Both calls are fire-and-forget: results land async
    /// and are picked up by the per-iteration merge in `resolveAndQueue`, the same async-contribution
    /// pattern the pages use.
    private func refreshContributorsIfNeeded(for job: Job) {
        guard job.seriesId != contributorSeriesKey else { return }
        contributorSeriesKey = job.seriesId
        torboxSearch.refresh(imdbId: job.seriesImdbId)
        sourceIndex.refresh(contentID: SourceIndexClient.contentID(imdbId: job.seriesImdbId),
                            isSignedIn: VortXSyncManager.shared.isSignedIn)
    }

    /// The per-episode pipeline, mirroring the manual episode page step for step (load + settle with
    /// the contributor merge, rank with the user's continuity/pin/filters, cached-debrid resolve,
    /// torrent prime, enqueue). Returns `.noSource` instead of throwing so the walk continues past a
    /// dead episode.
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
            // The manual `displayGroups` composition: TorBox search merged first, the community pool
            // second, THEN the Direct-links-only filter, so a search/pool torrent obeys the same rule
            // as an add-on's. Re-merged every iteration so contributor results landing mid-settle count.
            groups = iOSDisplayGroups(
                sourceIndex.merged(into: torboxSearch.merged(into: core.streamGroups(forStreamId: job.video.id))))
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
        if Task.isCancelled { return .cancelled }   // don't start a debrid resolve for a stopped batch
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
        currentLabel = nil
        currentSeriesId = nil
        pending = []
        plannedBySeries = [:]
        startedBySeries = [:]
        contributorSeriesKey = nil
        statusText = nil
        runningSeriesIds = []
        remainingBySeries = [:]
        clearSnapshot()
        if var result = tally {
            result.wasCancelled = cancelled
            summary = result
        }
        tally = nil
    }

    /// Recompute the published queue shape (which series are involved + how many episodes each still
    /// has waiting), so every open detail page renders only ITS OWN truthful line.
    private func republishQueueState() {
        var remaining: [String: Int] = [:]
        for job in pending { remaining[job.seriesId, default: 0] += 1 }
        remainingBySeries = remaining
        var ids = Set(remaining.keys)
        if let currentSeriesId { ids.insert(currentSeriesId) }
        runningSeriesIds = ids
    }

    private func episodeLabel(_ video: CoreVideo) -> String {
        guard let season = video.season else { return "E\(video.episodeNumber)" }
        return "S\(season)E\(video.episodeNumber)"
    }

    // MARK: Interruption snapshot

    /// What survives a process death mid-batch: enough to say WHAT was lost, not to resume it.
    private struct Snapshot: Codable {
        var seriesIds: [String]
        /// Episode labels (SxEy) not yet handed to DownloadManager: the resolving one + the queue.
        var remaining: [String]
        var queued: Int
        var alreadyDownloaded: Int
        var skipped: [String]
    }

    private static let snapshotKey = "vortx.downloads.batchSnapshot"

    /// Persist the tiny walk snapshot on every job transition. Cleared on normal finish/cancel, so a
    /// snapshot present at launch means the process died mid-walk.
    private func persistSnapshot() {
        var remaining: [String] = []
        if let currentLabel { remaining.append(currentLabel) }
        remaining.append(contentsOf: pending.map { episodeLabel($0.video) })
        guard !remaining.isEmpty else {
            clearSnapshot()
            return
        }
        var ids = Set(pending.map { $0.seriesId })
        if let currentSeriesId { ids.insert(currentSeriesId) }
        let snap = Snapshot(seriesIds: Array(ids), remaining: remaining,
                            queued: tally?.queued ?? 0,
                            alreadyDownloaded: tally?.alreadyDownloaded ?? 0,
                            skipped: tally?.skipped ?? [])
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        }
    }

    private func clearSnapshot() {
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
    }

    /// A snapshot present at init means the last process died mid-batch (the pending walk is memory
    /// only). Surface it as a one-shot summary on the affected series' pages, then clear it.
    /// Deliberately NO auto-resume in this pass: the user re-runs the batch (already-downloaded
    /// episodes skip with a note, so a re-run is cheap and idempotent).
    private func restoreInterruptedSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey) else { return }
        clearSnapshot()
        guard let snap = try? JSONDecoder().decode(Snapshot.self, from: data), !snap.remaining.isEmpty else { return }
        var restored = BatchSummary()
        restored.seriesIds = Set(snap.seriesIds)
        restored.queued = snap.queued
        restored.alreadyDownloaded = snap.alreadyDownloaded
        restored.skipped = snap.skipped
        restored.interrupted = snap.remaining.count
        summary = restored
    }
}
