import Foundation
import Combine

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
///     refreshed once per exact episode target. Both owners are fenced against that target and merged
///     into the engine groups in the same order before the Direct-links-only filter. Without this merge,
///     a TorBox-primary user's batch would
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
/// skipped and the walk CONTINUES; the summary surfaces the skip count + labels at the end. When a
/// queued episode's byte TRANSFER later fails (#119 remainder), the coordinator arms ONE auto-swap: it
/// removes the failed download and re-queues the episode's next-best DISTINCT source (the same ranking
/// the batch used), tagging the new record with an honest retry note. The swap is bounded to one per
/// episode (the plan is consumed on use), so a dead episode can never loop; a still-failing alternate
/// simply shows `.failed` with its retry note in DownloadsView.
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
        /// The show's identity ROLES, exactly as the detail page states them. Not a pre-picked id: this
        /// coordinator used to carry `ratingsImdbID`, a SHOW-level default value, and hand it to both
        /// contributor fetchers for every episode. That is the default-video role standing in for the
        /// selected current-video role, so a show whose IMDb identity lives only on its episode video ids
        /// contributed under no key at all. The per-episode role is applied in `refreshContributorsIfNeeded`.
        let identityRoles: SourceIndexIdentity.Roles
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

    /// One bounded auto-swap for a batch-queued episode whose byte transfer FAILS (#119 remainder). Carries
    /// the episode's NEXT-best distinct source (the ranking the batch already computed) plus the context to
    /// re-queue it. Consumed after a SINGLE swap, so a still-dead episode can never loop: one swap per episode.
    private struct RetryPlan {
        let alternate: CoreStream
        let pm: PlaybackMeta
        let episode: DebridEpisode?
    }

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

    /// Pending one-shot failure swaps, keyed by the DownloadRecord id the batch queued (#119 remainder). An
    /// entry is registered ONLY when a distinct next-best source exists, and is CONSUMED on the first swap
    /// (or dropped when the download completes), so a dead episode swaps at most once and never loops.
    private var retryPlans: [UUID: RetryPlan] = [:]
    /// Watches DownloadStore for a tracked batch download flipping to `.failed` (the byte transfer failing,
    /// which happens asynchronously after the walk has moved on) so the swap can fire independent of the walk.
    private var downloadObserver: AnyCancellable?

    var isRunning: Bool { worker != nil }

    private init() {
        restoreInterruptedSnapshot()
        // Watch DownloadStore for a tracked batch download flipping to `.failed`. The sink hops onto the main
        // actor (this type is @MainActor) via the same Task idiom DownloadManager uses; the handler reads the
        // committed records itself, so nothing non-Sendable crosses the boundary.
        downloadObserver = DownloadStore.shared.$records
            .sink { [weak self] _ in
                Task { @MainActor in self?.handleBatchDownloadStates() }
            }
    }

    // MARK: Public API

    /// Queue a batch of episodes (a season, or a hand-picked selection) for offline download.
    /// Episodes that already have a non-failed download record are counted as `alreadyDownloaded` and
    /// skipped with a note; episodes already pending in this batch are deduplicated silently. Calling
    /// again while a batch runs APPENDS to the walk (the per-series totals grow), so "download season
    /// 1" then "download season 2" behaves as one longer queue.
    func enqueue(seriesId: String, seriesName: String, identityRoles: SourceIndexIdentity.Roles,
                 fallbackPoster: String?,
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
            jobs.append(Job(seriesId: seriesId, seriesName: seriesName, identityRoles: identityRoles,
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
            let target = refreshContributorsIfNeeded(for: job)
            switch await resolveAndQueue(job, auxiliaryTarget: target) {
            case .queued: tally?.queued += 1
            case .noSource: tally?.skipped.append(episodeLabel(job.video))
            case .cancelled: break
            }
        }
        finish(cancelled: Task.isCancelled)
    }

    /// Refresh both auxiliary contributors for the exact episode target. Both calls are fire-and-forget: results land async
    /// and are picked up by the per-iteration merge in `resolveAndQueue`, the same async-contribution
    /// pattern the pages use.
    ///
    /// INVARIANT: contributor pools are PER-SERIES; a series that cannot query them must see them
    /// EMPTY, never a predecessor's results. The manual pages get this for free (fresh per-view
    /// @StateObjects die with their screen), but the coordinator reuses two instances across the
    /// whole batch, and BOTH refresh methods early-return on a nil id WITHOUT clearing their
    /// published streams (TorBox guards the tt prefix + key before touching state; Singularity only
    /// clears when its GATE closes, not on a nil content id with the gate open). Without the explicit
    /// reset below, a tmdb:/kitsu:-only series (nil imdb id) batched after an imdb-keyed one would
    /// merge the PREVIOUS show's streams into its pool, and a stale row could WIN ranking: another
    /// title's file downloading under this series' episode label. clearResults() empties only the
    /// published results, leaving the TorBox session cache + scraper-cooldown state and the
    /// Singularity result bank intact (those protect the APIs session-wide, which is why the
    /// instances are cleared rather than recreated).
    private func refreshContributorsIfNeeded(for job: Job) -> SourceIndexIdentity.TargetResolution {
        let season = job.video.season
        let episode = job.video.episode
        // The episode ACTUALLY being resolved supplies the current-video role, so the key this batch
        // publishes under is the same key the manual episode page would use.
        let roles = job.identityRoles.selecting(currentVideoID: job.video.id)
        let target = SourceIndexIdentity.publicationTarget(roles, season: season, episode: episode)
        let ownerKey = target.target?.contentID ?? "meta:\(job.seriesId)|video:\(job.video.id)"
        guard ownerKey != contributorSeriesKey else { return target }
        contributorSeriesKey = ownerKey
        // Reset FIRST, unconditionally: this also closes the valid-id window where the previous
        // series' streams linger until the new series' own fetch lands (Singularity does not clear
        // on a content-id change until its fetch returns).
        torboxSearch.clearResults()
        sourceIndex.clearResults()
        torboxSearch.refresh(target: target)
        sourceIndex.refresh(target: target, isSignedIn: VortXSyncManager.shared.isSignedIn)
        return target
    }

    /// The per-episode pipeline, mirroring the manual episode page step for step (load + settle with
    /// the contributor merge, rank with the user's continuity/pin/filters, cached-debrid resolve,
    /// torrent prime, enqueue). Returns `.noSource` instead of throwing so the walk continues past a
    /// dead episode.
    private func resolveAndQueue(
        _ job: Job,
        auxiliaryTarget: SourceIndexIdentity.TargetResolution
    ) async -> Outcome {
        let core = CoreBridge.shared
        // Point the engine's SINGLE shared meta_details slot at THIS episode's streams. The slot is
        // engine-wide (the open series-detail page and every sibling episode share it), so an episode load
        // issued while the engine / detail page is still settling the series meta can be RACED: loadMeta
        // writes the pre-load state back onto `metaDetails`, and the engine's episode NewState can land
        // BEFORE that write, leaving the Swift-side slot stale (zero groups for this episode) even though the
        // engine actually resolved it. That is the "first selected episode says no sources" report (#142):
        // the FIRST episode's load collides with the in-flight detail load while later episodes run from a
        // quiescent slot. So keep (re)asserting the per-episode load until the engine registers this
        // episode's stream loadables, rather than trusting one up-front dispatch. loadMeta re-reads the LIVE
        // engine state, so a re-assert also re-syncs a stale slot even when the dispatch itself is de-duped.
        func assertEpisodeLoad() {
            core.loadMeta(type: "series", id: job.seriesId, streamType: "series", streamId: job.video.id)
        }
        // Only load when this episode's streams aren't already resident (the user just had its source page
        // open): less churn on the shared meta slot, identical result.
        if core.streamGroups(forStreamId: job.video.id).isEmpty { assertEpisodeLoad() }
        var groups: [CoreStreamSourceGroup] = []
        var firstPlayableAt: Date? = nil
        var lastAssertAt = Date()
        for _ in 0 ..< 80 {                                // ~20s ceiling, matching the episode page
            if Task.isCancelled { return .cancelled }
            // The manual `displayGroups` composition: TorBox search merged first, the community pool
            // second, THEN the Direct-links-only filter, so a search/pool torrent obeys the same rule
            // as an add-on's. Re-merged every iteration so contributor results landing mid-settle count.
            groups = iOSDisplayGroups(sourceIndex.merged(
                into: torboxSearch.merged(
                    into: core.streamGroups(forStreamId: job.video.id),
                    for: auxiliaryTarget
                ),
                for: auxiliaryTarget
            ))
            if !groups.isEmpty, firstPlayableAt == nil { firstPlayableAt = Date() }
            let progress = core.streamLoadProgress(forStreamId: job.video.id)
            // The engine has registered NO loadable for this episode (total == 0) and nothing is resident:
            // the shared slot never actually switched to this episode (the #142 race). Re-assert the load,
            // bounded to roughly every 2.5s, so a dropped or stale first-episode selection recovers instead
            // of timing out to a FALSE "no source". A no-op once the episode's loadables register (total > 0),
            // and skipped entirely once any groups (engine or contributor) are in hand.
            if progress.total == 0, groups.isEmpty, Date().timeIntervalSince(lastAssertAt) > 2.5 {
                lastAssertAt = Date()
                assertEpisodeLoad()
            }
            let elapsed = firstPlayableAt.map { Date().timeIntervalSince($0) } ?? 0
            if StreamRanking.resolveSettled(groups, loaded: progress.loaded, total: progress.total,
                                            secondsSinceFirstPlayable: elapsed,
                                            rememberedQuality: job.continuity) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let best = StreamRanking.best(groups, continuity: job.continuity, pin: job.pin,
                                            debridCachedHashes: job.cachedHashes) else { return .noSource }
        if Task.isCancelled { return .cancelled }   // don't start a debrid resolve for a stopped batch
        // PRESENCE, not truthiness: episode ZERO is a valid coordinate (specials), and both coordinates are
        // already optionals here, so absence is expressed by the flatMap rather than by a sentinel value.
        let ep = job.video.season.flatMap { season in
            job.video.episode.flatMap { episode in
                season >= 0 && episode >= 0 ? DebridEpisode(season: season, episode: episode) : nil
            }
        }
        let resolved: URL?
        if best.url == nil, ep == nil {
            resolved = nil
        } else {
            resolved = await DebridCoordinator.shared.resolvedPlaybackURL(for: best, episode: ep)
        }
        if Task.isCancelled { return .cancelled }
        guard let url = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: best.isUsenet, resolvedURL: resolved,
            fallbackURL: best.playableURL(isEpisode: true)
        ) else { return .noSource }
        // Raw torrent: the loopback server must be told to /create it first (#21). Fire-and-forget:
        // the prime's retry loop is self-terminating (~15s max), same as the CW-resume prime.
        if resolved == nil, best.isTorrent { _ = prepareTorrentStream(best) }
        let pm = PlaybackMeta(libraryId: job.seriesId, videoId: job.video.id, type: "series",
                              name: job.seriesName, poster: job.video.thumbnail ?? job.fallbackPoster,
                              season: job.video.season, episode: job.video.episode)
        let record = DownloadManager.shared.download(stream: best, meta: pm, resolvedURL: url,
                                                     sourceName: best.name,
                                                     qualityText: StreamRanking.signature(best))
        // download() can refuse synchronously (an HLS source on a device that can't save HLS, a storage
        // shortfall): that episode was NOT queued, so report it as skipped, not as a success.
        if DownloadStore.shared.record(id: record.id)?.state == .failed { return .noSource }
        // #119 remainder: arm ONE auto-swap to the next-best DISTINCT source if this download later fails its
        // byte transfer. Same ranking the batch just used (rankedCandidates mirrors best()); a nil alternate
        // (nothing else playable) arms no plan, so that episode simply fails honestly as before.
        let candidates = StreamRanking.rankedCandidates(groups, continuity: job.continuity, pin: job.pin,
                                                        debridCachedHashes: job.cachedHashes)
        if let alternate = candidates.first(where: { !sameSource($0, best) }) {
            retryPlans[record.id] = RetryPlan(alternate: alternate, pm: pm, episode: ep)
        }
        return .queued
    }

    private func sameSource(_ lhs: CoreStream, _ rhs: CoreStream) -> Bool {
        if let left = lhs.url, let right = rhs.url { return left == right }
        if let left = lhs.infoHash, let right = rhs.infoHash {
            return left.caseInsensitiveCompare(right) == .orderedSame && lhs.fileIdx == rhs.fileIdx
        }
        if let left = lhs.nzbUrl, let right = rhs.nzbUrl { return left == right }
        return false
    }

    // MARK: One-shot failure swap (#119 remainder)

    /// React to DownloadStore changes for the batch downloads we armed a swap for: a tracked record that
    /// flipped to `.failed` gets ONE swap to its next-best source; one that completed (or the user deleted)
    /// drops its armed plan. Cheap: a no-op unless a swap is armed, and each plan fires at most once.
    private func handleBatchDownloadStates() {
        guard !retryPlans.isEmpty else { return }
        let records = DownloadStore.shared.records
        for (id, plan) in retryPlans {
            guard let record = records.first(where: { $0.id == id }) else { retryPlans[id] = nil; continue }
            switch record.state {
            case .failed: performRetrySwap(failedRecordID: id, plan: plan)
            case .completed: retryPlans[id] = nil   // succeeded: the armed swap is no longer needed
            default: break
            }
        }
    }

    /// The one-shot swap: consume the plan FIRST (so a still-failing alternate can never re-arm and loop),
    /// then resolve + queue the next-best source, and only AFTER the replacement is queued cancel the failed
    /// download through DownloadManager (the canonical path that also clears the stashed resume data and the
    /// HLS asset-task map, which DownloadStore.remove leaves behind). Queue-before-cancel means an app kill in
    /// the swap window leaves the original failed row on disk to retry from, never a vanished episode.
    private func performRetrySwap(failedRecordID id: UUID, plan: RetryPlan) {
        guard retryPlans.removeValue(forKey: id) != nil else { return }   // already swapped: one swap per episode
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved: URL?
            if plan.alternate.url == nil, plan.episode == nil {
                resolved = nil
            } else {
                resolved = await DebridCoordinator.shared.resolvedPlaybackURL(
                    for: plan.alternate, episode: plan.episode
                )
            }
            if resolved == nil, plan.alternate.isTorrent { _ = prepareTorrentStream(plan.alternate) }
            guard let fallback = EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
                isUsenet: plan.alternate.isUsenet, resolvedURL: resolved,
                fallbackURL: plan.alternate.playableURL(isEpisode: true)
            ) else { return }   // no URL: keep the failed row, do not orphan the episode
            let record = DownloadManager.shared.download(stream: plan.alternate, meta: plan.pm,
                                                         resolvedURL: fallback,
                                                         sourceName: plan.alternate.name,
                                                         qualityText: StreamRanking.signature(plan.alternate))
            // Replacement is queued: now drop the failed download via the canonical DownloadManager path
            // (cancels the live task, clears taskForRecord / resumeData / cannotCreateFileRetries / the HLS
            // asset-task map, then removes the record + file). DownloadStore.remove would leak that bookkeeping.
            DownloadManager.shared.cancel(id: id)
            // Honest per-episode note (shown in the DownloadsView row) so the swap is never silent.
            DownloadStore.shared.update(id: record.id) {
                $0.retryNote = String(localized: "Retried with next-best source (first source failed)")
            }
        }
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
