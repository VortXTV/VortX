package com.vortx.android.player

import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.Episode
import com.vortx.android.model.MediaRef
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Stable host authority across player recompositions. Every authority transition and accepted completion shares
 * one lock, while the atomic holder lets an old resolver query the exact live token without a Compose-state capture.
 */
internal class PlayerSourceSwitchCoordinator {
    private data class LiveAuthority(
        val outerSessionId: Long,
        val request: PlayerSourceSwitchAuthority?,
    )

    private val lock = Any()
    private val outerSessionIds = AtomicLong(0L)
    private val requestIds = AtomicLong(0L)
    private val liveAuthority = AtomicReference<LiveAuthority?>(null)

    fun replaceOuterSession(): Long = synchronized(lock) {
        outerSessionIds.incrementAndGet().also { outerSessionId ->
            liveAuthority.set(LiveAuthority(outerSessionId, request = null))
        }
    }

    fun beginRequest(outerSessionId: Long): PlayerSourceSwitchAuthority? = synchronized(lock) {
        val live = liveAuthority.get()?.takeIf { it.outerSessionId == outerSessionId } ?: return@synchronized null
        PlayerSourceSwitchAuthority(
            outerSessionId = outerSessionId,
            requestId = requestIds.incrementAndGet(),
        ).also { request -> liveAuthority.set(live.copy(request = request)) }
    }

    fun isCurrent(authority: PlayerSourceSwitchAuthority): Boolean =
        liveAuthority.get()?.let { it.outerSessionId == authority.outerSessionId && it.request == authority } == true

    /**
     * Linearization point for a resolver completion. Replacement, a newer request, and disposal cannot enter
     * while [finish] accepts host state and commits ViewModel side effects. The token is one-shot on success.
     */
    fun finishIfCurrent(authority: PlayerSourceSwitchAuthority, finish: () -> Unit): Boolean = synchronized(lock) {
        val live = liveAuthority.get()
        if (live?.outerSessionId != authority.outerSessionId || live.request != authority) return@synchronized false
        finish()
        liveAuthority.compareAndSet(live, live.copy(request = null))
        true
    }

    /** Old keyed effects may dispose after a replacement has published, so invalidate only their exact session. */
    fun invalidateIfCurrent(outerSessionId: Long) = synchronized(lock) {
        if (liveAuthority.get()?.outerSessionId == outerSessionId) liveAuthority.set(null)
    }
}

/** Exact host authority for one resolver completion. A source handle alone is never authority. */
internal data class PlayerSourceSwitchAuthority(
    val outerSessionId: Long,
    val requestId: Long,
)

internal data class PendingPlayerSourceSwitch(
    val authority: PlayerSourceSwitchAuthority,
    val source: StreamSource,
    val automatic: Boolean = false,
) {
    val sourceHandle: String = playerSourceHandle(source)
}

internal data class PendingPlayerEpisodeSwitch(
    val authority: PlayerSourceSwitchAuthority,
    val episode: Episode,
)

/**
 * Invalidated with the producing ViewModel. This prevents a resolution returned by an obsolete ViewModel
 * instance from mutating its source identity or the profile's sticky preference after host acceptance.
 */
internal class PlayerSourceSwitchCommitGate {
    @Volatile private var valid = true

    fun invalidate() {
        valid = false
    }

    fun isValid(): Boolean = valid
}

/**
 * A resolver result owns its incoming resource until the host accepts it or [discard] retires it. The host
 * calls [commitIfCurrent] only for the exact request authority. The second authority check belongs to the
 * producing ViewModel and protects its identity and sticky write if its request, owner or lifetime changed.
 */
class PlayerSourceSwitchResolution internal constructor(
    val playable: Playable,
    /// The exact source the resolution came from. Carried for the episode-switch path so the accepted
    /// state records the new episode's playing source; the source-switch path leaves it null (the pending
    /// source is already known there).
    internal val resolvedSource: StreamSource? = null,
    private val commitGate: PlayerSourceSwitchCommitGate,
    private val commitAuthorityIsCurrent: () -> Boolean,
    private val commitAccepted: () -> Unit,
    private val commitRejected: () -> Unit = {},
) {
    private enum class Ownership { PENDING, ADOPTED, DISCARDED }
    private val ownershipLock = Any()
    private var ownership = Ownership.PENDING

    /** Transfer the incoming lease to the mounted player only once, at host acceptance. */
    internal fun commitIfCurrent(hostAuthorityIsCurrent: () -> Boolean): Boolean =
        commitIfCurrent(hostAuthorityIsCurrent, acceptReplacement = {})

    /** The production host publishes inside the same transfer so an unmounted result cannot leak. */
    internal fun commitIfCurrent(
        hostAuthorityIsCurrent: () -> Boolean,
        acceptReplacement: () -> Unit,
    ): Boolean = synchronized(ownershipLock) {
        if (ownership != Ownership.PENDING) return@synchronized false
        try {
            if (!commitGate.isValid() || !commitAuthorityIsCurrent() || !hostAuthorityIsCurrent()) {
                discard()
                return@synchronized false
            }
            // Claim before invoking callbacks so duplicate/reentrant acceptance cannot commit twice.
            ownership = Ownership.ADOPTED
            try {
                commitAccepted()
                acceptReplacement()
            } catch (failure: Throwable) {
                ownership = Ownership.PENDING
                throw failure
            }
            true
        } catch (failure: Throwable) {
            discard()
            throw failure
        }
    }

    /** A stale, cancelled or malformed result still owns its new resource, never the outgoing one. */
    internal fun discard() {
        val rejected = synchronized(ownershipLock) {
            if (ownership != Ownership.PENDING) false else {
                ownership = Ownership.DISCARDED
                true
            }
        }
        if (!rejected) return
        // Rollback is producer-owned and may itself be stale; its callback checks that authority.
        // Neither callback failure may mask cancellation or prevent the other cleanup from running.
        runCatching { commitRejected() }
        runCatching { playable.playbackLease?.close() }
    }
}

/**
 * Source-owned player state. [revision] changes only after a replacement has resolved successfully, so a
 * failed switch leaves the live engine and every keyed playback effect untouched. The accepted revision is
 * part of [sessionKey], which also forces a rebuild when two distinct source rows resolve to the same URL.
 */
internal data class PlayerSourceSwitchState(
    val outerSessionId: Long,
    val playable: Playable,
    val currentSource: StreamSource?,
    val revision: Long = 0L,
    val pendingSwitch: PendingPlayerSourceSwitch? = null,
    val pendingEpisodeSwitch: PendingPlayerEpisodeSwitch? = null,
    val errorMessage: String? = null,
    val failedEpisode: Episode? = null,
) {
    val isSwitching: Boolean get() = pendingSwitch != null || pendingEpisodeSwitch != null
    val sessionKey: PlayerPlaybackSessionKey get() = PlayerPlaybackSessionKey(outerSessionId, playable, revision)
}

/** A stable key for every engine-owned effect in [PlayerScreen]. */
internal data class PlayerPlaybackSessionKey(
    val outerSessionId: Long,
    val playable: Playable,
    val revision: Long,
)

internal data class PlayerSourceChoice(
    val source: StreamSource,
    val label: String,
    val detail: String,
    val selected: Boolean,
)

internal data class PlayerQualityChoice(
    val source: StreamSource,
    val label: String,
    val detail: String,
    val selected: Boolean,
)

internal data class PlayerEpisodeChoice(
    val episode: Episode,
    val label: String,
    val selected: Boolean,
)

/**
 * A pending resolver is cancellable by selecting a different row. The selected row itself remains
 * inert, but all other choices stay reachable so a slow or non-cooperative resolver cannot trap the
 * viewer behind a "Switching" status message.
 */
internal fun playerReplacementChoiceEnabled(selected: Boolean): Boolean = !selected

/**
 * Quarantines a terminal callback observed while an old source is being replaced. If that replacement
 * fails, the old revision stays visible but its EOF/error is still stale with respect to the viewer's
 * selection and must not advance an episode or restart the automatic retry ladder. A successful
 * replacement increments the revision, naturally admitting terminals from the new engine.
 */
internal class PlayerTerminalFence {
    private var quarantinedRevision: Long? = null

    fun suppress(revision: Long, replacementPending: Boolean, terminal: Boolean): Boolean {
        if (!terminal) return false
        if (replacementPending) {
            quarantinedRevision = revision
            return true
        }
        return quarantinedRevision == revision
    }

    /** A deliberate new picker choice supersedes a failed predecessor's terminal verdict. */
    fun reopenManualRetry(revision: Long) {
        if (quarantinedRevision == revision) quarantinedRevision = null
    }
}

/// The current-season episodes for the in-player picker, in episode order, with the playing one selected.
/// Empty for movies / an unmappable ref, so the chrome hides the control. Mirrors Apple's `.episodes` panel.
internal fun playerEpisodeChoices(
    episodes: List<Episode>,
    currentMediaRef: MediaRef?,
): List<PlayerEpisodeChoice> {
    val current = currentMediaRef?.takeIf { it.isSeries } ?: return emptyList()
    val season = current.season ?: return emptyList()
    return episodes.asSequence()
        .filter { it.season == season }
        .sortedWith(compareBy<Episode> { it.episode }.thenBy { it.id })
        .map { episode ->
            PlayerEpisodeChoice(
                episode = episode,
                label = "S${episode.season} E${episode.episode} · ${episode.title}",
                selected = episode.season == current.season && episode.episode == current.episode,
            )
        }
        .toList()
}

/**
 * Match the semantic handle used by ranking and retry de-duplication. The NUL suffix is the cache-busting
 * decoration applied after an account cache check; it must not make the same row lose its current checkmark.
 */
internal fun playerSourceHandle(source: StreamSource): String =
    source.id.substringBefore('#').substringBefore('\u0000')

internal fun playerSourceIsCurrent(source: StreamSource, currentSource: StreamSource?): Boolean =
    currentSource != null && playerSourceHandle(source) == playerSourceHandle(currentSource)

internal fun playerSourceChoices(
    sources: List<StreamSource>,
    currentSource: StreamSource?,
    audioLanguageHint: String? = null,
): List<PlayerSourceChoice> = playerSourcesRankedByAudioHint(sources, audioLanguageHint).map { source ->
    val (tags, size) = StreamRanking.sourceDetail(source)
    val title = source.title.lineSequence().firstOrNull()?.trim().orEmpty()
        .ifBlank { source.addon }
        .take(SOURCE_LABEL_LIMIT)
    PlayerSourceChoice(
        source = source,
        label = title,
        detail = listOfNotNull(source.addon.takeIf(String::isNotBlank), tags, size).distinct().joinToString(" · "),
        selected = playerSourceIsCurrent(source, currentSource),
    )
}

/**
 * Reorder the in-player source list from conservative release-name metadata only. An explicit match floats
 * first, an unlabelled or multi-language release stays in the middle, and a clearly different single-language
 * release moves last. Every source remains visible in its original relative order inside each bucket because
 * filenames are only a hint. The mounted engine's real [PlayerTrack] inventory remains authoritative for audio
 * selection through [TrackSelector].
 */
internal fun playerSourcesRankedByAudioHint(
    sources: List<StreamSource>,
    audioLanguageHint: String?,
): List<StreamSource> {
    val wanted = TrackSelector.canonical(audioLanguageHint).takeIf(String::isNotEmpty) ?: return sources
    return sources.withIndex()
        .sortedWith(
            compareByDescending<IndexedValue<StreamSource>> { playerSourceAudioHintPriority(it.value, wanted) }
                .thenBy(IndexedValue<StreamSource>::index),
        )
        .map(IndexedValue<StreamSource>::value)
}

private fun playerSourceAudioHintPriority(source: StreamSource, wanted: String): Int {
    val text = listOfNotNull(
        source.title,
        source.description,
        source.filename,
        source.quality,
    ).joinToString(" ").lowercase()
    val advertised = StreamRanking.languageCodesAdvertised(text).map(TrackSelector::canonical)
    return when {
        wanted in advertised -> 2
        StreamRanking.isMultiLanguage(text) || advertised.isEmpty() -> 1
        else -> 0
    }
}

internal fun playerQualityChoices(
    options: List<Pair<String, StreamSource>>,
    currentSource: StreamSource?,
): List<PlayerQualityChoice> {
    val currentQuality = currentSource?.let(StreamRanking::qualityLabel)
    return options.map { (label, source) ->
        PlayerQualityChoice(
            source = source,
            label = label,
            detail = StreamRanking.sizeText(source).orEmpty(),
            selected = currentQuality == label,
        )
    }
}

internal fun beginPlayerSourceSwitch(
    state: PlayerSourceSwitchState,
    source: StreamSource,
    authority: PlayerSourceSwitchAuthority,
): PlayerSourceSwitchState = beginPlayerSourceSwitch(state, source, authority, automatic = false)

internal fun beginPlayerSourceSwitch(
    state: PlayerSourceSwitchState,
    source: StreamSource,
    authority: PlayerSourceSwitchAuthority,
    automatic: Boolean,
): PlayerSourceSwitchState = state.copy(
    pendingSwitch = PendingPlayerSourceSwitch(authority, source, automatic),
    pendingEpisodeSwitch = null,
    errorMessage = null,
)

internal fun beginPlayerEpisodeSwitch(
    state: PlayerSourceSwitchState,
    episode: Episode,
    authority: PlayerSourceSwitchAuthority,
): PlayerSourceSwitchState = state.copy(
    pendingSwitch = null,
    pendingEpisodeSwitch = PendingPlayerEpisodeSwitch(authority, episode),
    errorMessage = null,
)

internal data class PlayerSourceSwitchCompletion(
    val state: PlayerSourceSwitchState,
    val requestAccepted: Boolean,
    val resolution: PlayerSourceSwitchResolution? = null,
)

internal data class PlayerEpisodeSwitchCompletion(
    val state: PlayerSourceSwitchState,
    val requestAccepted: Boolean,
    val resolution: PlayerSourceSwitchResolution? = null,
)

/**
 * Accept only the result for the pending episode. Success advances the session key and starts the new
 * episode from the top; failure keeps the current [Playable] and revision so playback continues.
 */
internal fun completePlayerEpisodeSwitch(
    state: PlayerSourceSwitchState,
    pending: PendingPlayerEpisodeSwitch,
    result: Result<PlayerSourceSwitchResolution>,
): PlayerEpisodeSwitchCompletion {
    if (
        pending.authority.outerSessionId != state.outerSessionId ||
        state.pendingEpisodeSwitch != pending
    ) {
        result.getOrNull()?.discard()
        return PlayerEpisodeSwitchCompletion(state, requestAccepted = false)
    }
    return result.fold(
        onSuccess = { resolution ->
            if (resolution.playable.url.isBlank() || resolution.resolvedSource == null) {
                resolution.discard()
                PlayerEpisodeSwitchCompletion(
                    state.copy(pendingEpisodeSwitch = null, failedEpisode = pending.episode, errorMessage = ""),
                    requestAccepted = true,
                )
            } else {
                PlayerEpisodeSwitchCompletion(
                    state = state.copy(
                        playable = resolution.playable.copy(startPositionMs = 0L),
                        currentSource = resolution.resolvedSource,
                        revision = state.revision + 1L,
                        pendingEpisodeSwitch = null,
                        errorMessage = null,
                        failedEpisode = null,
                    ),
                    requestAccepted = true,
                    resolution = resolution,
                )
            }
        },
        onFailure = { error ->
            PlayerEpisodeSwitchCompletion(
                state.copy(pendingEpisodeSwitch = null, failedEpisode = pending.episode, errorMessage = error.message.orEmpty()),
                requestAccepted = true,
            )
        },
    )
}

internal fun applyPlayerEpisodeSwitchCompletion(
    currentState: PlayerSourceSwitchState,
    pending: PendingPlayerEpisodeSwitch,
    completion: PlayerEpisodeSwitchCompletion,
    publishAccepted: (PlayerSourceSwitchState) -> Unit = {},
    hostAuthorityIsCurrent: () -> Boolean,
): PlayerSourceSwitchState {
    if (
        !completion.requestAccepted ||
        currentState.outerSessionId != pending.authority.outerSessionId ||
        currentState.pendingEpisodeSwitch != pending ||
        !hostAuthorityIsCurrent()
    ) {
        completion.resolution?.discard()
        return currentState
    }
    val resolution = completion.resolution ?: return completion.state
    if (resolution.commitIfCurrent(hostAuthorityIsCurrent) { publishAccepted(completion.state) }) return completion.state
    return currentState.copy(pendingEpisodeSwitch = null, failedEpisode = pending.episode, errorMessage = "")
}

/**
 * Host-owned history identity for the app shell. [acceptedRevision] makes an accepted episode transition
 * observable even when the replacement [Playable] is value-equal to the previous one.
 */
internal data class PlayerEpisodeHistoryIdentity(
    val playable: Playable,
    val acceptedRevision: Long = 0L,
)

internal fun advancePlayerEpisodeHistory(
    current: PlayerEpisodeHistoryIdentity,
    replacement: Playable?,
    acceptedRevision: Long?,
): PlayerEpisodeHistoryIdentity {
    if (replacement == null || acceptedRevision == null || acceptedRevision <= current.acceptedRevision) {
        return current
    }
    return PlayerEpisodeHistoryIdentity(replacement, acceptedRevision)
}

internal data class AcceptedPlayerEpisodeReplacement(
    val playable: Playable,
    val revision: Long,
)

/**
 * An episode replacement is accepted by its owned revision transition, not by [Playable] value inequality:
 * two episodes may legitimately resolve to value-equal handles when canonical ids are unavailable.
 */
internal fun acceptedEpisodeReplacement(
    previousState: PlayerSourceSwitchState,
    acceptedState: PlayerSourceSwitchState,
): AcceptedPlayerEpisodeReplacement? = if (
    previousState.pendingEpisodeSwitch != null &&
        acceptedState.outerSessionId == previousState.outerSessionId &&
        acceptedState.pendingEpisodeSwitch == null &&
        acceptedState.revision == previousState.revision + 1L
) {
    AcceptedPlayerEpisodeReplacement(acceptedState.playable, acceptedState.revision)
} else {
    null
}

/**
 * Accept only the result for the pending row. Success advances the session key; failure deliberately keeps
 * the current [Playable], source, and revision so playback continues on the old engine.
 */
internal fun completePlayerSourceSwitch(
    state: PlayerSourceSwitchState,
    pending: PendingPlayerSourceSwitch,
    result: Result<PlayerSourceSwitchResolution>,
    latestPositionMs: Long,
): PlayerSourceSwitchCompletion {
    if (
        pending.authority.outerSessionId != state.outerSessionId ||
        state.pendingSwitch != pending
    ) {
        result.getOrNull()?.discard()
        return PlayerSourceSwitchCompletion(state, requestAccepted = false)
    }
    return result.fold(
        onSuccess = { resolution ->
            if (resolution.playable.url.isBlank()) {
                resolution.discard()
                PlayerSourceSwitchCompletion(
                    state.copy(pendingSwitch = null, errorMessage = ""),
                    requestAccepted = true,
                )
            } else {
                val replacement = resolution.playable
                    .atSourceSwitchPosition(latestPositionMs)
                    .copy(userForcedSource = !pending.automatic || resolution.playable.userForcedSource)
                PlayerSourceSwitchCompletion(
                    state = state.copy(
                        playable = replacement,
                        currentSource = pending.source,
                        revision = state.revision + 1L,
                        pendingSwitch = null,
                        errorMessage = null,
                        failedEpisode = null,
                    ),
                    requestAccepted = true,
                    resolution = resolution,
                )
            }
        },
        onFailure = { error ->
            PlayerSourceSwitchCompletion(
                state.copy(
                    pendingSwitch = null,
                    errorMessage = error.message.orEmpty(),
                ),
                requestAccepted = true,
            )
        },
    )
}

/** Commit an exact-token success, or retain the outgoing session if the producing ViewModel is stale. */
internal fun applyPlayerSourceSwitchCompletion(
    currentState: PlayerSourceSwitchState,
    pending: PendingPlayerSourceSwitch,
    completion: PlayerSourceSwitchCompletion,
    publishAccepted: (PlayerSourceSwitchState) -> Unit = {},
    hostAuthorityIsCurrent: () -> Boolean,
): PlayerSourceSwitchState {
    if (
        !completion.requestAccepted ||
        currentState.outerSessionId != pending.authority.outerSessionId ||
        currentState.pendingSwitch != pending ||
        !hostAuthorityIsCurrent()
    ) {
        completion.resolution?.discard()
        return currentState
    }
    val resolution = completion.resolution ?: return completion.state
    if (resolution.commitIfCurrent(hostAuthorityIsCurrent) { publishAccepted(completion.state) }) return completion.state
    return currentState.copy(pendingSwitch = null, errorMessage = "")
}

/**
 * Production host path for one resolver job. A resolver may ignore coroutine cancellation; only the stable
 * coordinator can accept its result, commit the producing ViewModel, and publish the replacement state.
 */
internal suspend fun resolveAndApplyPlayerSourceSwitch(
    coordinator: PlayerSourceSwitchCoordinator,
    pending: PendingPlayerSourceSwitch,
    resolver: suspend (StreamSource) -> Result<PlayerSourceSwitchResolution>,
    currentState: () -> PlayerSourceSwitchState,
    latestPositionMs: () -> Long,
    publishState: (PlayerSourceSwitchState) -> Unit,
) {
    val resolutionContext = currentCoroutineContext()
    val result = try {
        resolver(pending.source)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Result.failure(error)
    }
    try {
        // Some resolvers return successfully after swallowing cancellation. Such a result is owned,
        // but cannot replace a mounted player even if its host token has not been retired yet.
        resolutionContext.ensureActive()
        coordinator.finishIfCurrent(pending.authority) {
            resolutionContext.ensureActive()
            val liveState = currentState()
            val completion = completePlayerSourceSwitch(
                state = liveState,
                pending = pending,
                result = result,
                latestPositionMs = latestPositionMs(),
            )
            var published = false
            val accepted = applyPlayerSourceSwitchCompletion(
                currentState = liveState,
                pending = pending,
                completion = completion,
                publishAccepted = { publishState(it); published = true },
                hostAuthorityIsCurrent = { resolutionContext.isActive && coordinator.isCurrent(pending.authority) },
            )
            if (!published && coordinator.isCurrent(pending.authority)) publishState(accepted)
        }
    } finally {
        result.getOrNull()?.discard()
    }
}

/**
 * Production host path for one episode-switch resolver job. Mirrors [resolveAndApplyPlayerSourceSwitch]:
 * only the stable coordinator can accept the result, commit the producing ViewModel, and publish the
 * replacement state, so a resolver that ignores cancellation still cannot mutate a superseded session.
 */
internal suspend fun resolveAndApplyPlayerEpisodeSwitch(
    coordinator: PlayerSourceSwitchCoordinator,
    pending: PendingPlayerEpisodeSwitch,
    resolver: suspend (Episode) -> Result<PlayerSourceSwitchResolution>,
    currentState: () -> PlayerSourceSwitchState,
    publishState: (PlayerSourceSwitchState) -> Unit,
) {
    val resolutionContext = currentCoroutineContext()
    val result = try {
        resolver(pending.episode)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Result.failure(error)
    }
    try {
        resolutionContext.ensureActive()
        coordinator.finishIfCurrent(pending.authority) {
            resolutionContext.ensureActive()
            val liveState = currentState()
            val completion = completePlayerEpisodeSwitch(liveState, pending, result)
            var published = false
            val accepted = applyPlayerEpisodeSwitchCompletion(
                currentState = liveState,
                pending = pending,
                completion = completion,
                publishAccepted = { publishState(it); published = true },
                hostAuthorityIsCurrent = { resolutionContext.isActive && coordinator.isCurrent(pending.authority) },
            )
            if (!published && coordinator.isCurrent(pending.authority)) publishState(accepted)
        }
    } finally {
        result.getOrNull()?.discard()
    }
}

/** The replacement resumes exactly where the outgoing engine is when its resolution is accepted. */
internal fun Playable.atSourceSwitchPosition(positionMs: Long): Playable =
    copy(startPositionMs = positionMs.coerceAtLeast(0L))

private const val SOURCE_LABEL_LIMIT = 72
