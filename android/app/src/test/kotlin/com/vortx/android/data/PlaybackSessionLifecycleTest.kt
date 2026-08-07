package com.vortx.android.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlaybackSessionLifecycleTest {
    @Test
    fun `outgoing end completes before replacement begin`() = runTest {
        val events = mutableListOf<String>()
        val allowEnd = CompletableDeferred<Unit>()
        var generation = 0L
        val lifecycle = PlaybackSessionLifecycle(
            scope = this,
            beginSession = {
                val token = PlaybackSessionToken(++generation)
                events += "begin-${token.generation}"
                token
            },
            reportSession = { _, _, _ -> },
            endSession = { token, _, _ ->
                events += "end-${token.generation}-start"
                allowEnd.await()
                events += "end-${token.generation}-finish"
            },
        )
        val first = lifecycle.newHandle()
        lifecycle.begin(first)
        runCurrent()

        lifecycle.end(first, 1_000L, 10_000L)
        val second = lifecycle.newHandle()
        lifecycle.begin(second)
        runCurrent()
        assertEquals(listOf("begin-1", "end-1-start"), events)

        allowEnd.complete(Unit)
        advanceUntilIdle()
        assertEquals(listOf("begin-1", "end-1-start", "end-1-finish", "begin-2"), events)
    }
}
