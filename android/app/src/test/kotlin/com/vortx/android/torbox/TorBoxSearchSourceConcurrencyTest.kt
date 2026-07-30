package com.vortx.android.torbox

import com.vortx.android.model.StreamSource
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test

class TorBoxSearchSourceConcurrencyTest {
    @Test
    fun `concurrent refreshes for one title coalesce into one fetch and one cached result`() = runBlocking {
        val fetchDispatcher = Executors.newFixedThreadPool(4).asCoroutineDispatcher()
        // One worker per caller so every refresh reaches the start gate before any is released. A smaller
        // pool would deadlock the test harness itself with queued tasks waiting behind gated workers.
        val callers = Executors.newFixedThreadPool(64)
        val releaseFetch = CompletableDeferred<Unit>()
        val fetchCount = AtomicInteger()
        val source = TorBoxSearchSource(
            scope = CoroutineScope(SupervisorJob() + fetchDispatcher),
            fetchStreams = { _, _, _, _ ->
                fetchCount.incrementAndGet()
                releaseFetch.await()
                TorBoxSearch.Result(
                    streams = listOf(stream("a".repeat(40))),
                    rateLimited = false,
                    transportError = false,
                )
            },
        )

        try {
            val ready = CountDownLatch(64)
            val start = CountDownLatch(1)
            val futures = (0 until 64).map {
                callers.submit {
                    ready.countDown()
                    start.await()
                    source.refresh("tt1234567", season = 1, episode = 2)
                }
            }
            check(ready.await(5, TimeUnit.SECONDS))
            start.countDown()
            futures.forEach { it.get(5, TimeUnit.SECONDS) }

            withTimeout(5_000) {
                while (fetchCount.get() == 0) kotlinx.coroutines.yield()
            }
            assertEquals(1, fetchCount.get())

            releaseFetch.complete(Unit)
            withTimeout(5_000) {
                while (source.streams.value.isEmpty()) kotlinx.coroutines.yield()
            }

            repeat(64) { source.refresh("tt1234567", season = 1, episode = 2) }
            assertEquals(1, fetchCount.get())
            assertEquals("a".repeat(40), source.streams.value.single().infoHash)
        } finally {
            releaseFetch.complete(Unit)
            source.close()
            callers.shutdownNow()
            fetchDispatcher.close()
        }
    }

    @Test
    fun `late canceled response cannot clear or duplicate the newer in-flight fetch`() = runBlocking {
        val fetchDispatcher = Executors.newFixedThreadPool(2).asCoroutineDispatcher()
        val firstStarted = CompletableDeferred<Unit>()
        val secondStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val releaseSecond = CompletableDeferred<Unit>()
        val firstCalls = AtomicInteger()
        val secondCalls = AtomicInteger()
        val source = TorBoxSearchSource(
            scope = CoroutineScope(SupervisorJob() + fetchDispatcher),
            fetchStreams = { imdbId, _, _, _ ->
                if (imdbId == "tt0000001") {
                    firstCalls.incrementAndGet()
                    firstStarted.complete(Unit)
                    // HttpURLConnection is blocking and may return after cancellation. Reproduce that
                    // hostile late completion rather than letting a cooperative Deferred hide the race.
                    withContext(NonCancellable) { releaseFirst.await() }
                    TorBoxSearch.Result(listOf(stream("1".repeat(40))), false, false)
                } else {
                    secondCalls.incrementAndGet()
                    secondStarted.complete(Unit)
                    releaseSecond.await()
                    TorBoxSearch.Result(listOf(stream("2".repeat(40))), false, false)
                }
            },
        )

        try {
            source.refresh("tt0000001")
            withTimeout(5_000) { firstStarted.await() }
            source.refresh("tt0000002")
            withTimeout(5_000) { secondStarted.await() }

            releaseFirst.complete(Unit)
            repeat(64) { source.refresh("tt0000002") }
            assertEquals(1, firstCalls.get())
            assertEquals(1, secondCalls.get())

            releaseSecond.complete(Unit)
            withTimeout(5_000) {
                while (source.streams.value.singleOrNull()?.infoHash != "2".repeat(40)) {
                    kotlinx.coroutines.yield()
                }
            }
            assertEquals(1, secondCalls.get())
        } finally {
            releaseFirst.complete(Unit)
            releaseSecond.complete(Unit)
            source.close()
            fetchDispatcher.close()
        }
    }

    private fun stream(hash: String): StreamSource = StreamSource(
        id = hash,
        addon = TorBoxSearch.GROUP_ADDON,
        title = "Result",
        isTorrent = true,
        infoHash = hash,
    )
}
