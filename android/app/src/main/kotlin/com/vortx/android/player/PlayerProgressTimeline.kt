package com.vortx.android.player

import com.vortx.android.cast.CastConfirmedProgress

/** Ephemeral mounted timeline identity. This is not a persisted account/schema field. */
data class PlayerProgressSnapshot(val owner: String, val positionMs: Long, val durationMs: Long)

/** The phone and TV final caches retain the same owner-qualified pair delivered by the real player. */
internal class PlaybackProgressCache(
    private val sessions: com.vortx.android.data.PlaybackSessionLifecycle,
    private val handle: com.vortx.android.data.PlaybackSessionLifecycle.Handle,
) {
    var snapshot: PlayerProgressSnapshot? = null
        private set
    val positionMs: Long get() = snapshot?.positionMs ?: 0L
    val durationMs: Long get() = snapshot?.durationMs ?: 0L
    fun report(point: PlayerProgressSnapshot) {
        snapshot = point
        sessions.report(handle, point.positionMs, point.durationMs)
    }
    fun end(onDurableWatch: (com.vortx.android.data.DurableWatchedPlaybackReceipt) -> Unit = {}) {
        sessions.end(handle, positionMs, durationMs, onDurableWatch)
    }
}

/** Shared by the production Cast callback, local tick and final-dispose/intentional-exit paths. */
internal class PlayerProgressTimeline(
    private val owner: String,
    private val admitted: () -> Boolean,
    private val valid: (Long, Long) -> Boolean,
    private val emit: (PlayerProgressSnapshot) -> Unit,
) {
    private var remote: PlayerProgressSnapshot? = null
    private var remoteActive = false
    private var awaitingLocalResume: Long? = null
    private var remoteProtected = false
    private var closed = false
    private var resumeGeneration = 0L
    internal class LocalResumeTicket internal constructor(
        val owner: String, val engine: Any, val generation: Long, val baseline: Any, val targetMs: Long,
    )
    var localResumeTicket: LocalResumeTicket? = null
        private set

    fun remote(point: CastConfirmedProgress?, active: Boolean, resumePositionMs: Long?) {
        if (closed || point?.owner?.let { it != owner } == true) return
        if (!active && point == null) {
            // An unconfirmed LOAD has no remote history to flush. Do not replay an earlier Cast
            // snapshot over resumed local history or erase its still-pending handback receipt.
            remoteActive = false
            if (remote == null) {
                remoteProtected = false
                awaitingLocalResume = null
                localResumeTicket = null
            }
            return
        }
        if (active && !remoteActive && point == null) remote = null
        if (point != null) remote = PlayerProgressSnapshot(owner, point.positionMs, point.durationMs)
        remoteActive = active
        if (active) {
            remoteProtected = true
            localResumeTicket = null
        } else if (remoteProtected && remote != null) awaitingLocalResume = resumePositionMs
        else if (remote == null) remoteProtected = false
        flushRemote()
    }
    private fun flushRemote() { remote?.let(::publish) }
    private fun publish(point: PlayerProgressSnapshot) {
        if (!closed && admitted() && valid(point.positionMs, point.durationMs)) emit(point)
    }
    /** Capture the actual engine's pre-seek state, before issuing the returned-point seek. */
    fun beginLocalResume(engine: Any, baseline: Any): LocalResumeTicket? {
        val target = awaitingLocalResume ?: return null
        if (closed || remoteActive || !remoteProtected || !admitted()) return null
        return LocalResumeTicket(owner, engine, ++resumeGeneration, baseline, target).also { localResumeTicket = it }
    }
    /** Called on each real engine StateFlow emission, independently of the five-second history loop. */
    fun acknowledgeLocalResume(ticket: LocalResumeTicket, engine: Any, mountedOwner: String,
        sample: Any, positionMs: Long, durationMs: Long, buffering: Boolean): Boolean {
        if (closed || remoteActive || !remoteProtected || localResumeTicket !== ticket ||
            ticket.generation != resumeGeneration || ticket.owner != owner || mountedOwner != owner ||
            ticket.engine !== engine || sample === ticket.baseline || buffering || !admitted() ||
            !valid(positionMs, durationMs) || kotlin.math.abs(positionMs - ticket.targetMs) > 2_000L) return false
        remoteProtected = false
        awaitingLocalResume = null
        localResumeTicket = null
        publish(PlayerProgressSnapshot(owner, positionMs, durationMs))
        return true
    }
    fun local(positionMs: Long, durationMs: Long, buffering: Boolean = false) {
        // Periodic samples cannot acknowledge a seek: the real engine/generation receipt above does.
        if (closed || remoteActive || remoteProtected || buffering) return
        publish(PlayerProgressSnapshot(owner, positionMs, durationMs))
    }
    fun finish(positionMs: Long, durationMs: Long) {
        if (remoteProtected) flushRemote() else local(positionMs, durationMs)
    }
    fun close() { closed = true; localResumeTicket = null }
}
