package com.vortx.android.ui.viewmodel

import com.vortx.android.data.SourcePreparation
import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.debrid.DebridOwnerToken
import com.vortx.android.sources.SourceRequestFence
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.player.PlayerSourceSwitchCommitGate
import com.vortx.android.player.PlayerSourceSwitchResolution
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.CancellationException

/** Mapping an owned playable must retire it if validation or construction rejects the result. */
internal fun <T> Result<Playable>.mapOwnedPlayable(transform: (Playable) -> T): Result<T> = fold(
    onSuccess = { playable ->
        try { Result.success(transform(playable)) } catch (failure: Throwable) {
            runCatching { playable.playbackLease?.close() }
            if (failure is CancellationException) throw failure
            Result.failure(failure)
        }
    },
    onFailure = { Result.failure(it) },
)

internal data class PreparedEpisodeAuthority(
    val episodeId: String,
    val profileId: String,
    val owner: ContinueWatchingOwner,
    val sourceRequest: SourceRequestFence.Token?,
    val prewarmGeneration: Long,
    val debridOwner: DebridOwnerToken?,
    val credentialRevision: Long,
    val audioRevision: Long,
) {
    fun accepts(current: PreparedEpisodeAuthority): Boolean = this == current && sourceRequest === current.sourceRequest
}

/** Shared only across the pending slot and host-resolution owners during their explicit transfer. */
internal class PreparedPlaybackLease(private val resource: AutoCloseable) : AutoCloseable {
    private var closed = false
    override fun close() {
        val release = synchronized(this) { if (closed) false else { closed = true; true } }
        if (release) resource.close()
    }
}

internal class PreparedEpisode(
    val episodeId: String,
    val source: StreamSource,
    playable: Playable,
    val preparation: SourcePreparation,
) : AutoCloseable {
    val playable = playable.copy(playbackLease = playable.playbackLease?.let(::PreparedPlaybackLease))
    private var closed = false
    override fun close() {
        synchronized(this) { if (closed) return; closed = true }
        try { playable.playbackLease?.close() } finally { preparation.close() }
    }
}

/** Both automatic and manual hosts consume the same prepared value through the acknowledged handoff. */
internal fun preparedEpisodeHandoff(
    prepared: PreparedEpisode,
    playable: Playable = prepared.playable,
    commitGate: PlayerSourceSwitchCommitGate,
    isCurrent: () -> Boolean,
    install: (List<StreamGroup>) -> Unit,
    rollback: () -> Unit,
): PlayerSourceSwitchResolution {
    var adoption: com.vortx.android.data.SourcePreparationAdoption? = null
    return PlayerSourceSwitchResolution(playable.copy(startPositionMs = 0L), prepared.source, commitGate,
        commitAuthorityIsCurrent = { isCurrent() && prepared.preparation.isCurrent() },
        commitAccepted = {
            adoption = checkNotNull(prepared.preparation.adopt()) { "Prepared episode expired" }
            install(requireNotNull(adoption).groups)
        },
        commitRejected = {
            try { adoption?.rollback(); rollback() } finally { prepared.close() }
        })
}

/** Single prepared value; a claimed ticket stays fenced until acceptance or a newer intent invalidates it. */
internal class PreparedEpisodeSlot<C : Any>(
    private val isAuthorityCurrent: (C) -> Boolean,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000L },
    private val freshnessMs: Long = 120_000L,
) {
    data class Ticket<C>(val generation: Long, val capture: C)
    data class Claim<C>(val ticket: Ticket<C>, val episode: PreparedEpisode)
    private var generation = 0L
    private var active: Ticket<C>? = null
    private var ready: PreparedEpisode? = null
    // Retained through claim: a delayed host must not adopt a value after its freshness window.
    private var readyAt: Long? = null

    @Synchronized fun invalidate() {
        generation++
        active = null
        val previous = ready
        ready = null
        readyAt = null
        previous?.let { runCatching { it.close() } }
    }

    @Synchronized fun begin(capture: C): Ticket<C> {
        invalidate()
        return Ticket(++generation, capture).also { active = it }
    }

    @Synchronized fun accepts(ticket: Ticket<C>): Boolean =
        active === ticket && isAuthorityCurrent(ticket.capture) &&
            (readyAt?.let { nowMs() - it < freshnessMs } != false)

    @Synchronized fun hasReady(episodeId: String): Boolean {
        val value = ready ?: return false
        if (active?.let(::accepts) != true || !value.preparation.isCurrent()) {
            invalidate()
            return false
        }
        return value.episodeId == episodeId
    }

    @Synchronized fun claim(episodeId: String): Claim<C>? {
        if (!hasReady(episodeId)) return null
        return Claim(requireNotNull(active), requireNotNull(ready)).also { ready = null }
    }

    /** The real timer covers source fanout AND resolution, even when playback ticks cease. */
    suspend fun prepare(
        ticket: Ticket<C>,
        episodeId: String,
        preparation: SourcePreparation,
        choose: (List<StreamGroup>) -> StreamSource?,
        timeoutMs: Long = 15_000L,
    ): Boolean {
        var produced: PreparedEpisode? = null
        var retained = false
        try {
            retained = withTimeoutOrNull(timeoutMs) {
                preparation.updates().first { it.selectionReady }
                if (!accepts(ticket) || !preparation.isCurrent()) return@withTimeoutOrNull false
                val source = choose(preparation.groups) ?: return@withTimeoutOrNull false
                val playable = preparation.resolve(source).getOrNull() ?: return@withTimeoutOrNull false
                val value = PreparedEpisode(episodeId, source, playable, preparation).also { produced = it }
                currentCoroutineContext().ensureActive()
                synchronized(this@PreparedEpisodeSlot) {
                    if (!accepts(ticket) || !preparation.isCurrent() || playable.url.isBlank()) false else {
                        ready = value
                        readyAt = nowMs()
                        true
                    }
                }
            } == true
            return retained
        } finally {
            if (!retained) {
                synchronized(this) { if (ready === produced) ready = null }
                runCatching { produced?.close() ?: preparation.close() }
            }
        }
    }
}
