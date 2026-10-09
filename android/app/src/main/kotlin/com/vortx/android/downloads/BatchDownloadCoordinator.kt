package com.vortx.android.downloads

import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.DownloadState
import com.vortx.android.model.DownloadRecord
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.StreamSource
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.Playable
import com.vortx.android.data.DownloadSourceResolver
import com.vortx.android.engine.SourceListModel
import com.vortx.android.sources.ResolvedPin
import com.vortx.android.sources.SeriesSourceSticky
import com.vortx.android.sources.SourcePin
import com.vortx.android.sources.SourcePinScope
import com.vortx.android.sources.SourcePrefsSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

enum class BatchDownloadItemState { WAITING, PREPARING, ACCEPTED, ALREADY_SAVED, FAILED, CANCELLED }

data class BatchDownloadItem(val episode: Episode, val state: BatchDownloadItemState = BatchDownloadItemState.WAITING,
    val recordId: String? = null, val note: String? = null)

data class BatchDownloadState(val running: Boolean = false, val items: List<BatchDownloadItem> = emptyList()) {
    val accepted: Int get() = items.count { it.state == BatchDownloadItemState.ACCEPTED }
    val failed: Int get() = items.count { it.state == BatchDownloadItemState.FAILED }
}

/** Every preference and owner is captured before the first suspend; settings changes cannot retarget a batch. */
internal data class BatchDownloadSnapshot(
    val detail: MetaDetail,
    val episodes: List<Episode>,
    val owner: ContinueWatchingOwner,
    val debridOwner: DebridOwnerToken?,
    val prefs: SourcePrefsSnapshot,
    val desiredSource: StreamSource?,
    val pin: ResolvedPin?,
    val sticky: SeriesSourceSticky.Preference?,
    val directLinksOnly: Boolean,
)

internal object BatchDownloadPolicy {
    const val MAX_EPISODES = 500
    const val MAX_SOURCE_ATTEMPTS = 3

    fun select(detail: MetaDetail, ids: Set<String>): List<Episode> {
        require(detail.type == MediaType.SERIES && ids.isNotEmpty() && ids.size <= MAX_EPISODES) {
            "Choose between 1 and $MAX_EPISODES episodes."
        }
        require(ids.all { id -> detail.videos.any { it.id == id } }) { "The episode selection changed. Reopen downloads." }
        return detail.videos.filter { it.id in ids }.distinctBy { it.id }
            .sortedWith(compareBy<Episode> { it.season }.thenBy { it.episode })
    }

    fun desiredPin(snapshot: BatchDownloadSnapshot): ResolvedPin? = snapshot.desiredSource?.let {
        ResolvedPin(SourcePin(it.addon, StreamRanking.qualityLabel(it), StreamRanking.releaseFlavor(it), it.bingeGroup),
            SourcePinScope.ENTRY)
    } ?: snapshot.pin

    fun candidates(snapshot: BatchDownloadSnapshot, groups: List<StreamGroup>): List<StreamSource> {
        val wanted = snapshot.desiredSource
        val filtered = SourceListModel.directLinkDisplayGroups(groups, snapshot.directLinksOnly)
        return StreamRanking.rankedCandidates(filtered, continuity = wanted?.let(StreamRanking::signature),
            binge = wanted?.bingeGroup, pin = desiredPin(snapshot), sticky = snapshot.sticky, prefs = snapshot.prefs)
            .filter { candidate ->
                // An explicit source selection locks provider and quality. A missing release must be reported,
                // rather than silently downloading another language or provider for part of a season.
                (wanted == null || (candidate.addon == wanted.addon &&
                    StreamRanking.qualityLabel(candidate) == StreamRanking.qualityLabel(wanted) &&
                    (StreamRanking.releaseFlavor(wanted).isBlank() ||
                        StreamRanking.releaseFlavor(candidate) == StreamRanking.releaseFlavor(wanted)) &&
                    (wanted.bingeGroup.isNullOrBlank() || candidate.bingeGroup == wanted.bingeGroup))) &&
                    StreamRanking.languageScore(listOfNotNull(candidate.title, candidate.description,
                        candidate.filename).joinToString(" ").lowercase(), snapshot.prefs) >= 0
            }.take(MAX_SOURCE_ATTEMPTS)
    }
}

/** Small side-effect boundary used by deterministic batch lifecycle tests. */
internal interface BatchDownloadQueue {
    fun contains(videoId: String): Boolean
    fun preparationHasCapacity(): Boolean
    fun accept(resolver: DownloadSourceResolver, playable: Playable, source: StreamSource,
        snapshot: BatchDownloadSnapshot, episode: Episode): DownloadRecord?
}

private object ManagedBatchDownloadQueue : BatchDownloadQueue {
    override fun contains(videoId: String) = DownloadStore.hasDownload(videoId)
    override fun preparationHasCapacity() = DownloadStore.records.value.count {
        it.state == DownloadState.DOWNLOADING || it.state == DownloadState.QUEUED
    } < DownloadManager.maxConcurrentDownloads.value + 1
    override fun accept(resolver: DownloadSourceResolver, playable: Playable, source: StreamSource,
        snapshot: BatchDownloadSnapshot, episode: Episode) = DownloadManager.downloadResolved(resolver, playable,
        source, snapshot.detail, episode, snapshot.debridOwner)
}

/** Sequential preparation with one bounded look-ahead item. Transfers remain entirely manager-owned. */
class BatchDownloadCoordinator internal constructor(private val repo: CatalogRepository, private val scope: CoroutineScope,
    private val queue: BatchDownloadQueue) {
    constructor(repo: CatalogRepository, scope: CoroutineScope) : this(repo, scope, ManagedBatchDownloadQueue)
    private val _state = MutableStateFlow(BatchDownloadState())
    val state: StateFlow<BatchDownloadState> = _state.asStateFlow()
    private var job: Job? = null
    private var generation = 0L

    internal fun start(snapshot: BatchDownloadSnapshot, contextIsCurrent: () -> Boolean): Boolean {
        if (job?.isActive == true) return false
        val episodes = BatchDownloadPolicy.select(snapshot.detail, snapshot.episodes.map { it.id }.toSet())
        val session = repo.captureDownloadSession(snapshot.owner) ?: run {
            _state.value = BatchDownloadState(items = episodes.map { BatchDownloadItem(it,
                BatchDownloadItemState.FAILED, note = "Batch downloads are unavailable for this source session.") })
            return false
        }
        val run = ++generation
        _state.value = BatchDownloadState(running = true, items = episodes.map(::BatchDownloadItem))
        fun update(id: String, state: BatchDownloadItemState, recordId: String? = null, note: String? = null) {
            if (generation == run) _state.value = _state.value.copy(items = _state.value.items.map {
                if (it.episode.id == id) it.copy(state = state, recordId = recordId, note = note) else it
            })
        }
        job = scope.launch {
            fun requireCurrent() {
                check(contextIsCurrent() && repo.continueWatchingOwner() == snapshot.owner) {
                    "The account, profile, or title changed. Remaining episodes were not queued."
                }
            }
            try {
                for (episode in episodes) {
                    currentCoroutineContext().ensureActive()
                    requireCurrent()
                    if (queue.contains(episode.id)) {
                        update(episode.id, BatchDownloadItemState.ALREADY_SAVED, note = "Already in downloads")
                        continue
                    }
                    // Do not mint hundreds of native producers ahead of the transfer cap. One spare queue item
                    // keeps transfers fed, while cancellation stops the remaining preparations immediately.
                    while (!queue.preparationHasCapacity()) {
                        delay(250)
                        requireCurrent()
                    }
                    update(episode.id, BatchDownloadItemState.PREPARING)
                    try {
                        withTimeout(90_000) {
                            val groups = session.streams(snapshot.detail.type, snapshot.detail.id, episode,
                                snapshot.desiredSource?.let(StreamRanking::qualityLabel),
                                snapshot.desiredSource?.addon ?: snapshot.sticky?.addon).getOrThrow()
                            currentCoroutineContext().ensureActive()
                            requireCurrent()
                            val candidates = BatchDownloadPolicy.candidates(snapshot, groups)
                            check(candidates.isNotEmpty()) { "No sources matched the captured download preferences." }
                            var accepted = false
                            for (source in candidates) {
                                currentCoroutineContext().ensureActive()
                                requireCurrent()
                                val resolver = session.pin(source, episode) ?: continue
                                val resolved = resolver.resolve()
                                val playable = resolved.getOrNull() ?: continue
                                var transferred = false
                                try {
                                    currentCoroutineContext().ensureActive()
                                    requireCurrent()
                                    // Manager enters its lifecycle lock before the native session admission fence.
                                    val record = queue.accept(resolver, playable, source, snapshot, episode)
                                    transferred = true // downloadResolved consumes the lease even on rejection.
                                    if (record != null && record.state != DownloadState.FAILED) {
                                        update(episode.id, BatchDownloadItemState.ACCEPTED, record.id)
                                        accepted = true
                                        break
                                    }
                                } finally {
                                    if (!transferred) runCatching { playable.playbackLease?.close() }
                                }
                            }
                            check(accepted) { "The available sources could not start this episode. Try another source." }
                        }
                    } catch (cancelled: CancellationException) {
                        // A per-episode deadline is a failure; user/owner/scope cancellation remains terminal.
                        currentCoroutineContext().ensureActive()
                        update(episode.id, BatchDownloadItemState.FAILED, note = "Source preparation timed out.")
                    } catch (_: Exception) {
                        requireCurrent()
                        update(episode.id, BatchDownloadItemState.FAILED,
                            note = "Couldn't prepare this episode with the selected sources.")
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // An owner/context retirement cancels all not-yet-admitted episodes. Never recapture an owner.
            } finally {
                session.close()
                if (generation == run) _state.value = _state.value.copy(running = false,
                    items = _state.value.items.map { item ->
                        if (item.state in setOf(BatchDownloadItemState.WAITING, BatchDownloadItemState.PREPARING))
                            item.copy(state = BatchDownloadItemState.CANCELLED,
                                note = "Not queued. Downloads already accepted will continue.") else item
                    })
            }
        }
        return true
    }

    /** Stops unresolved items only. Accepted rows continue under the manager and remain controllable in Queue. */
    fun cancel() { job?.cancel() }
}
