package com.vortx.android.ui.randompick

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.random.Random

internal enum class RandomEpisodePickNotice { EMPTY, PROFILE_LOCKED, LOAD_ERROR, PICK_UNAVAILABLE }

internal data class RandomEpisodePickState(
    val episode: Episode? = null,
    val seriesName: String? = null,
    val loading: Boolean = false,
    val notice: RandomEpisodePickNotice? = null,
)

/**
 * A session-only preview of a locally cached episode. Call public methods on the owning UI scope.
 * [currentOwner] returns null while selection is locked; its value must include the full profile,
 * PIN/Kids admission and route/owner revisions. The caller also invalidates on owner transitions,
 * so returning from profile A through B cannot revive an earlier A request.
 *
 * Picking never resolves a source, starts playback or changes watched/library/saved state. Only an
 * explicit [forAction] may hand a fresh, admitted episode back to normal Detail routing.
 */
internal class RandomEpisodePickModel<O : Any>(
    private val scope: CoroutineScope,
    private val currentOwner: () -> O?,
    private val readDetail: suspend () -> MetaDetail?,
    private val currentEpisodeId: () -> String?,
    private val now: () -> Instant = Instant::now,
    private val nextInt: (Int) -> Int = { Random.nextInt(it) },
) {
    private data class Preview<O>(
        val owner: O,
        val detailId: String,
        val detailType: MediaType,
        val episode: Episode,
    ) {
        fun belongsTo(detail: MetaDetail): Boolean = detail.id == detailId && detail.type == detailType
    }

    private val _state = MutableStateFlow(RandomEpisodePickState())
    val state: StateFlow<RandomEpisodePickState> = _state.asStateFlow()
    private var preview: Preview<O>? = null
    private var selectionRequest: Any? = null
    private var actionRequest: Any? = null
    private var pickJob: Job? = null
    private var actionJob: Job? = null

    fun pick() {
        val previous = preview
        invalidate()
        val owner = currentOwner() ?: run {
            _state.value = RandomEpisodePickState(notice = RandomEpisodePickNotice.PROFILE_LOCKED)
            return
        }
        val request = Any()
        selectionRequest = request
        _state.value = RandomEpisodePickState(loading = true)
        pickJob = scope.launch {
            try {
                val detail = readDetail()
                currentCoroutineContext().ensureActive()
                if (!selectionIsCurrent(request, owner)) return@launch
                val candidates = detail?.let { RandomPickPolicy.episodeCandidates(it, now()) }.orEmpty()
                val selectedId = currentEpisodeId()
                val withoutSelected = candidates.filterNot { it.id == selectedId }
                val selectable = withoutSelected.ifEmpty { candidates }
                val previousKey = previous?.takeIf { it.owner == owner && detail != null && it.belongsTo(detail) }
                    ?.episode?.let(::episodePickKey)
                val picked = RandomPickPolicy.pick(selectable, previousKey, ::episodePickKey, nextInt)
                currentCoroutineContext().ensureActive()
                if (!selectionIsCurrent(request, owner)) return@launch
                preview = if (detail != null && picked != null) {
                    Preview(owner, detail.id, detail.type, picked)
                } else {
                    null
                }
                _state.value = RandomEpisodePickState(
                    episode = picked,
                    seriesName = detail?.name.takeIf { picked != null },
                    notice = RandomEpisodePickNotice.EMPTY.takeIf { picked == null },
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                if (selectionIsCurrent(request, owner)) {
                    preview = null
                    _state.value = RandomEpisodePickState(notice = RandomEpisodePickNotice.LOAD_ERROR)
                }
            } finally {
                if (selectionRequest === request) {
                    pickJob = null
                    if (currentOwner() != owner) {
                        finishRequest(RandomEpisodePickNotice.PROFILE_LOCKED)
                    } else if (_state.value.loading) {
                        _state.value = _state.value.copy(loading = false)
                    }
                }
            }
        }
    }

    /**
     * Re-check fresh local inventory, airdate and the complete owner before Open or Play. An
     * accepted preview is consumed before the callback, so it cannot dispatch a second action.
     */
    fun forAction(onAccepted: (MetaDetail, Episode, O) -> Unit) {
        val expected = preview ?: return
        val selection = selectionRequest ?: return
        if (currentOwner() != expected.owner) {
            invalidate()
            _state.value = RandomEpisodePickState(notice = RandomEpisodePickNotice.PROFILE_LOCKED)
            return
        }
        val request = Any()
        val previousAction = actionJob
        actionRequest = request
        _state.value = _state.value.copy(loading = true, notice = null)
        previousAction?.cancel()
        actionJob = scope.launch {
            var acceptedDetail: MetaDetail? = null
            var acceptedEpisode: Episode? = null
            try {
                val detail = readDetail()
                currentCoroutineContext().ensureActive()
                if (!actionIsCurrent(request, selection, expected)) return@launch
                val episode = detail?.takeIf(expected::belongsTo)
                    ?.let { RandomPickPolicy.episodeCandidates(it, now()) }
                    ?.firstOrNull { sameEpisode(it, expected.episode) }
                if (detail == null || episode == null) {
                    finishRequest(RandomEpisodePickNotice.PICK_UNAVAILABLE)
                } else {
                    acceptedDetail = detail
                    acceptedEpisode = episode
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                if (actionIsCurrent(request, selection, expected)) {
                    finishRequest(RandomEpisodePickNotice.LOAD_ERROR)
                }
            } finally {
                if (actionRequest === request) {
                    actionJob = null
                    if (currentOwner() != expected.owner) {
                        finishRequest(RandomEpisodePickNotice.PROFILE_LOCKED)
                    } else if (_state.value.loading) {
                        _state.value = _state.value.copy(loading = false)
                    }
                }
            }
            val detail = acceptedDetail ?: return@launch
            val episode = acceptedEpisode ?: return@launch
            currentCoroutineContext().ensureActive()
            if (!actionIsCurrent(request, selection, expected)) return@launch
            finishRequest()
            onAccepted(detail, episode, expected.owner)
        }
    }

    /** Retire identities before cancelling, including reads suspended inside NonCancellable code. */
    fun invalidate() {
        val previousPick = pickJob
        val previousAction = actionJob
        finishRequest()
        previousPick?.cancel()
        previousAction?.cancel()
    }

    private fun selectionIsCurrent(request: Any, owner: O): Boolean =
        selectionRequest === request && currentOwner() == owner

    private fun actionIsCurrent(request: Any, selection: Any, expected: Preview<O>): Boolean =
        actionRequest === request && selectionRequest === selection && preview === expected &&
            currentOwner() == expected.owner

    /** Completes the owning request without cancelling its own coroutine before a callback. */
    private fun finishRequest(notice: RandomEpisodePickNotice? = null) {
        selectionRequest = null
        actionRequest = null
        preview = null
        pickJob = null
        actionJob = null
        _state.value = RandomEpisodePickState(notice = notice)
    }
}

private fun episodePickKey(episode: Episode): String = episode.id

private fun sameEpisode(first: Episode, second: Episode): Boolean =
    first.id == second.id && first.season == second.season && first.episode == second.episode
