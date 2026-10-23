package com.vortx.android.ui.viewmodel

import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import com.vortx.android.sources.SourceRequestFence

/** This signal is a network settlement, not an empty coalescer/UI publication. Tokens reject ABA. */
internal data class EpisodeSourceSettlement(val request: SourceRequestFence.Token? = null, val settled: Boolean = false)
internal suspend fun awaitEpisodeSourceSettlement(state: StateFlow<EpisodeSourceSettlement>, request: SourceRequestFence.Token) =
    state.first { it.request === request && it.settled }

/** Monotonic target-owned budget. Queue/source settlement and candidate preparation cannot restart it. */
internal class EpisodeResolutionBudget(
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000L },
    private val outerMs: Long = 65_000L,
    private val sourceMs: Long = 20_000L,
    private val candidateMs: Long = 35_000L,
) {
    private val started = nowMs()
    fun remainingMs(): Long = (outerMs - (nowMs() - started).coerceAtLeast(0L)).coerceAtLeast(0L)
    fun sourceRemainingMs(): Long = minOf(remainingMs(), (sourceMs - (nowMs() - started).coerceAtLeast(0L)).coerceAtLeast(0L))
    suspend fun <T> source(block: suspend () -> T): T? = withTimeoutOrNull(sourceRemainingMs()) { block() }
    suspend fun <T> candidate(discard: (T) -> Unit = {}, block: suspend () -> T): T? =
        ownedTimeout(minOf(candidateMs, remainingMs()), discard, block)
    suspend fun <T> outer(discard: (T) -> Unit = {}, block: suspend () -> T): T? =
        ownedTimeout(remainingMs(), discard, block)

    private class Produced<T>(val value: T)
    /** Timeout may win after a non-cooperative producer succeeds but before its value is delivered. */
    private suspend fun <T> ownedTimeout(timeoutMs: Long, discard: (T) -> Unit, block: suspend () -> T): T? {
        var produced: Produced<T>? = null
        var delivered = false
        try {
            val result = withTimeoutOrNull(timeoutMs) { Produced(block()).also { produced = it } }
            delivered = result != null
            return result?.value
        } finally {
            if (!delivered) produced?.let { runCatching { discard(it.value) } }
        }
    }
}
