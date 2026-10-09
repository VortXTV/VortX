package com.vortx.android.integrations

import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** SIMKL permits one POST per second. This gate is shared by ratings, watchlist and history writes. */
internal class SimklPostPacer(
    private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000 },
    private val waitMillis: suspend (Long) -> Unit = { delay(it) },
) {
    private val mutex = Mutex()
    private var lastDispatch: Long? = null

    suspend fun <T> dispatch(current: () -> Boolean, send: suspend () -> T): T? = mutex.withLock {
        if (!current()) return@withLock null
        lastDispatch?.let { last ->
            val wait = (1_100 - (nowMillis() - last)).coerceAtLeast(0)
            if (wait > 0) waitMillis(wait)
        }
        if (!current()) return@withLock null
        lastDispatch = nowMillis()
        send()
    }

    companion object { val shared = SimklPostPacer() }
}
