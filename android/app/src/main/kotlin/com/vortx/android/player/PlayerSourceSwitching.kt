package com.vortx.android.player

import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CancellationException
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
) {
    val sourceHandle: String = playerSourceHandle(source)
}

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
 * A side-effect-free resolver result. The host calls [commitIfCurrent] only after the result's exact request
 * authority has been accepted. The second authority check belongs to the producing ViewModel and protects its
 * identity and sticky write if that ViewModel's request, account owner, profile, or lifetime changed meanwhile.
 */
class PlayerSourceSwitchResolution internal constructor(
    val playable: Playable,
    private val commitGate: PlayerSourceSwitchCommitGate,
    private val commitAuthorityIsCurrent: () -> Boolean,
    private val commitAccepted: () -> Unit,
) {
    internal fun commitIfCurrent(hostAuthorityIsCurrent: () -> Boolean): Boolean {
        if (!commitGate.isValid() || !commitAuthorityIsCurrent() || !hostAuthorityIsCurrent()) return false
        commitAccepted()
        return true
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
    val errorMessage: String? = null,
) {
    val isSwitching: Boolean get() = pendingSwitch != null
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
): List<PlayerSourceChoice> = sources.map { source ->
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
): PlayerSourceSwitchState = state.copy(
    pendingSwitch = PendingPlayerSourceSwitch(authority, source),
    errorMessage = null,
)

internal data class PlayerSourceSwitchCompletion(
    val state: PlayerSourceSwitchState,
    val requestAccepted: Boolean,
    val resolution: PlayerSourceSwitchResolution? = null,
)

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
        return PlayerSourceSwitchCompletion(state, requestAccepted = false)
    }
    return result.fold(
        onSuccess = { resolution ->
            if (resolution.playable.url.isBlank()) {
                PlayerSourceSwitchCompletion(
                    state.copy(pendingSwitch = null, errorMessage = ""),
                    requestAccepted = true,
                )
            } else {
                val replacement = resolution.playable
                    .atSourceSwitchPosition(latestPositionMs)
                    .copy(userForcedSource = true)
                PlayerSourceSwitchCompletion(
                    state = state.copy(
                        playable = replacement,
                        currentSource = pending.source,
                        revision = state.revision + 1L,
                        pendingSwitch = null,
                        errorMessage = null,
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
    hostAuthorityIsCurrent: () -> Boolean,
): PlayerSourceSwitchState {
    if (
        !completion.requestAccepted ||
        currentState.outerSessionId != pending.authority.outerSessionId ||
        currentState.pendingSwitch != pending ||
        !hostAuthorityIsCurrent()
    ) {
        return currentState
    }
    val resolution = completion.resolution ?: return completion.state
    if (resolution.commitIfCurrent(hostAuthorityIsCurrent)) return completion.state
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
    val result = try {
        resolver(pending.source)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Result.failure(error)
    }
    coordinator.finishIfCurrent(pending.authority) {
        val liveState = currentState()
        val completion = completePlayerSourceSwitch(
            state = liveState,
            pending = pending,
            result = result,
            latestPositionMs = latestPositionMs(),
        )
        val accepted = applyPlayerSourceSwitchCompletion(
            currentState = liveState,
            pending = pending,
            completion = completion,
            hostAuthorityIsCurrent = { coordinator.isCurrent(pending.authority) },
        )
        if (coordinator.isCurrent(pending.authority)) publishState(accepted)
    }
}

/** The replacement resumes exactly where the outgoing engine is when its resolution is accepted. */
internal fun Playable.atSourceSwitchPosition(positionMs: Long): Playable =
    copy(startPositionMs = positionMs.coerceAtLeast(0L))

private const val SOURCE_LABEL_LIMIT = 72
