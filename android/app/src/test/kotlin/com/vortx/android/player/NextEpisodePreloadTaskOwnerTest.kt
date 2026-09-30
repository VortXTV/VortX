package com.vortx.android.player

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NextEpisodePreloadTaskOwnerTest {
    private val target = NextEpisodePreloadPolicy.Target("episode-2", generation = 1L)

    @Test
    fun `cancelling mounted playback stops preparation and rejects its late completion`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = NextEpisodePreloadTaskOwner(scope)
        val started = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        var completions = 0

        owner.launch(
            target = target,
            prepare = {
                started.complete(Unit)
                try {
                    CompletableDeferred<Unit>().await()
                    true
                } catch (error: CancellationException) {
                    cancelled.complete(Unit)
                    throw error
                }
            },
            onComplete = { completions++ },
        )
        withTimeout(5_000L) { started.await() }

        owner.cancel()

        withTimeout(5_000L) { cancelled.await() }
        assertEquals(0, completions)
        scope.cancel()
    }

    @Test
    fun `new target cancels old preparation and only current target completes`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = NextEpisodePreloadTaskOwner(scope)
        val firstStarted = CompletableDeferred<Unit>()
        val firstCancelled = CompletableDeferred<Unit>()
        val completed = mutableListOf<String>()

        owner.launch(
            target = target,
            prepare = {
                firstStarted.complete(Unit)
                try {
                    CompletableDeferred<Unit>().await()
                    false
                } catch (error: CancellationException) {
                    firstCancelled.complete(Unit)
                    throw error
                }
            },
            onComplete = { completed += "old" },
        )
        withTimeout(5_000L) { firstStarted.await() }

        owner.launch(
            target = target.copy(episodeId = "episode-3"),
            prepare = { true },
            onComplete = { completed += "new" },
        )

        withTimeout(5_000L) { firstCancelled.await() }
        withTimeout(5_000L) {
            while (completed.isEmpty()) delay(10L)
        }
        assertEquals(listOf("new"), completed)
        assertTrue(completed.none { it == "old" })
        scope.cancel()
    }

    @Test
    fun `late completion from cancellation-ignoring preparation cannot mark successor ready`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val owner = NextEpisodePreloadTaskOwner(scope)
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val firstFinished = CompletableDeferred<Unit>()
        val completed = mutableListOf<String>()

        owner.launch(
            target = target,
            prepare = {
                withContext(NonCancellable) {
                    firstStarted.complete(Unit)
                    releaseFirst.await()
                    true
                }.also { firstFinished.complete(Unit) }
            },
            onComplete = { completed += "old" },
        )
        withTimeout(5_000L) { firstStarted.await() }

        owner.launch(
            target = target.copy(episodeId = "episode-3"),
            prepare = { true },
            onComplete = { completed += "new" },
        )
        releaseFirst.complete(Unit)

        withTimeout(5_000L) { firstFinished.await() }
        withTimeout(5_000L) {
            while (completed.none { it == "new" }) delay(10L)
        }
        assertEquals(listOf("new"), completed)
        scope.cancel()
    }
}
