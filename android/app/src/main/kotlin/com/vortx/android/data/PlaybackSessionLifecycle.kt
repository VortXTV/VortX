package com.vortx.android.data

import com.vortx.android.model.PlaybackContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicReference

/**
 * Orders player composition lifecycle calls without blocking the UI thread. Compose disposes the old
 * keyed effect before starting the replacement; enqueueing synchronously preserves that order even
 * though repository work runs on [scope]. Progress stays independent and carries its immutable token,
 * so a delayed tick is rejected by the repository after replacement. The [PlaybackContext] and the
 * [ContinueWatchingOwner] token handed to [begin] are each captured once: they flow into exactly one
 * [beginSession] invocation and are then owned by the bound session, so later shell, profile, or
 * engine state changes can never retarget the session's identity or owner.
 */
class PlaybackSessionLifecycle internal constructor(
    private val scope: CoroutineScope,
    private val beginSession: suspend (PlaybackContext?, ContinueWatchingOwner?) -> PlaybackSessionToken?,
    private val reportSession: suspend (PlaybackSessionToken, Long, Long) -> Unit,
    private val endSession: suspend (PlaybackSessionToken, Long, Long) -> DurableWatchedPlaybackReceipt?,
    private val nanoClock: () -> Long = System::nanoTime,
) {
    constructor(repository: CatalogRepository, scope: CoroutineScope) : this(
        scope = scope,
        beginSession = { context, ownerToken ->
            repository.beginPlaybackSession(context, ownerToken).getOrNull()
        },
        reportSession = { token, positionMs, durationMs ->
            repository.reportProgress(token, positionMs, durationMs)
        },
        endSession = { token, positionMs, durationMs ->
            repository.endPlaybackSessionWithDurableWatchReceipt(token, positionMs, durationMs).getOrNull()
        },
    )

    class Handle internal constructor() {
        internal val token = AtomicReference<PlaybackSessionToken?>(null)
        /** The session and monotonic time of the last progress report that reached the engine. */
        internal val lastReport = AtomicReference<Pair<PlaybackSessionToken, Long>?>(null)
    }

    private val orderLock = Any()
    private var lifecycleTail: Job? = null

    fun newHandle(): Handle = Handle()

    fun begin(
        handle: Handle,
        context: PlaybackContext? = null,
        ownerToken: ContinueWatchingOwner? = null,
    ) {
        enqueue {
            handle.token.set(beginSession(context, ownerToken))
        }
    }

    /**
     * Each report is a full native transaction that re-seals the whole account checkpoint, so the
     * player's 5 s ticks reach the engine at most every [REPORT_INTERVAL_NANOS] (the Apple cadence).
     * A new session reports at once, and [end] still records the final position.
     */
    fun report(handle: Handle, positionMs: Long, durationMs: Long) {
        val token = handle.token.get() ?: return
        val now = nanoClock()
        val last = handle.lastReport.get()
        if (last != null && last.first == token && now - last.second < REPORT_INTERVAL_NANOS) return
        handle.lastReport.set(token to now)
        scope.launch { reportSession(token, positionMs, durationMs) }
    }

    fun end(
        handle: Handle,
        positionMs: Long,
        durationMs: Long,
        onDurableWatch: (DurableWatchedPlaybackReceipt) -> Unit = {},
    ) {
        enqueue {
            val token = handle.token.getAndSet(null) ?: return@enqueue
            endSession(token, positionMs, durationMs)?.let(onDurableWatch)
        }
    }

    private fun enqueue(block: suspend () -> Unit) {
        synchronized(orderLock) {
            val predecessor = lifecycleTail
            lifecycleTail = scope.launch(start = CoroutineStart.LAZY) {
                predecessor?.join()
                block()
            }.also { it.start() }
        }
    }

    private companion object {
        const val REPORT_INTERVAL_NANOS = 20_000_000_000L
    }
}
