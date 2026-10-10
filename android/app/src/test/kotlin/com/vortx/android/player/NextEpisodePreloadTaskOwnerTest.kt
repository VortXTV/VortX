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
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.advanceTimeBy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NextEpisodePreloadTaskOwnerTest {
    private val target = NextEpisodePreloadPolicy.Target("episode-2", generation = 1L)

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test fun `dispatch queue cannot restart an already elapsed attempt deadline`() = kotlinx.coroutines.test.runTest {
        var now = 100L
        val owner = NextEpisodePreloadTaskOwner(this, nowMs = { now })
        var preparations = 0
        val outcomes = mutableListOf<Boolean>()
        owner.launch(target, prepare = { preparations++; true }, onComplete = { outcomes += it }, timeoutMs = 10)
        now = 111L
        runCurrent()
        assertEquals(0, preparations)
        assertEquals(listOf(false), outcomes)
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test fun `real task deadline completes failure without further playback ticks`() = kotlinx.coroutines.test.runTest {
        val owner = NextEpisodePreloadTaskOwner(this)
        var stopped = false
        val outcomes = mutableListOf<Boolean>()
        owner.launch(target, prepare = {
            try { kotlinx.coroutines.awaitCancellation() } finally { stopped = true }
        }, onComplete = { outcomes += it })
        runCurrent()
        advanceTimeBy(15_000L)
        runCurrent()
        try {
            assertTrue(stopped)
            assertEquals(listOf(false), outcomes)
        } finally { owner.cancel() }
    }

    @Test fun `phone and TV advance enter the acknowledged player handoff not ordinary playback flow`() {
        val root = generateSequence(java.io.File(System.getProperty("user.dir"))) { it.parentFile }
            .first { java.io.File(it, "src/main/kotlin/com/vortx/android/ui/VortXApp.kt").isFile }
        for (relative in listOf("ui/VortXApp.kt", "ui/tv/TvApp.kt")) {
            val source = java.io.File(root, "src/main/kotlin/com/vortx/android/$relative").readText()
            assertTrue(relative, source.contains("episodeHandoffRequest ="))
            org.junit.Assert.assertFalse(relative, source.contains(".playNextEpisode()"))
        }
    }

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
