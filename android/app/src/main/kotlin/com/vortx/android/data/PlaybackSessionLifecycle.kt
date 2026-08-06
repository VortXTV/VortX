package com.vortx.android.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicReference

/**
 * Orders player composition lifecycle calls without blocking the UI thread. Compose disposes the old
 * keyed effect before starting the replacement; enqueueing synchronously preserves that order even
 * though repository work runs on [scope]. Progress stays independent and carries its immutable token,
 * so a delayed tick is rejected by the repository after replacement.
 */
class PlaybackSessionLifecycle internal constructor(
    private val scope: CoroutineScope,
    private val beginSession: suspend () -> PlaybackSessionToken?,
    private val reportSession: suspend (PlaybackSessionToken, Long, Long) -> Unit,
    private val endSession: suspend (PlaybackSessionToken, Long, Long) -> Unit,
) {
    constructor(repository: CatalogRepository, scope: CoroutineScope) : this(
        scope = scope,
        beginSession = { repository.beginPlaybackSession().getOrNull() },
        reportSession = { token, positionMs, durationMs ->
            repository.reportProgress(token, positionMs, durationMs)
        },
        endSession = { token, positionMs, durationMs ->
            repository.endPlaybackSession(token, positionMs, durationMs)
        },
    )

    class Handle internal constructor() {
        internal val token = AtomicReference<PlaybackSessionToken?>(null)
    }

    private val orderLock = Any()
    private var lifecycleTail: Job? = null

    fun newHandle(): Handle = Handle()

    fun begin(handle: Handle) {
        enqueue {
            handle.token.set(beginSession())
        }
    }

    fun report(handle: Handle, positionMs: Long, durationMs: Long) {
        val token = handle.token.get() ?: return
        scope.launch { reportSession(token, positionMs, durationMs) }
    }

    fun end(handle: Handle, positionMs: Long, durationMs: Long) {
        enqueue {
            val token = handle.token.getAndSet(null) ?: return@enqueue
            endSession(token, positionMs, durationMs)
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
}
