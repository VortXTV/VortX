package com.vortx.android.torbox

import com.vortx.android.model.StreamSource
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TorBoxSearchSourceConcurrencyTest {
    @Test
    fun `credential replaced before queued fetch cannot be spent on the network`() = runBlocking {
        val executor = Executors.newSingleThreadExecutor()
        val fetchDispatcher = executor.asCoroutineDispatcher()
        val credential = AtomicReference(TorBoxSearchSource.Credential("key-a", 1L))
        val workerOccupied = CompletableDeferred<Unit>()
        val releaseWorker = CompletableDeferred<Unit>()
        val fetchedKeys = CopyOnWriteArrayList<String>()
        val scope = CoroutineScope(SupervisorJob() + fetchDispatcher)
        val blocker = scope.launch {
            workerOccupied.complete(Unit)
            releaseWorker.await()
        }
        val source = TorBoxSearchSource(
            scope = scope,
            fetchStreams = { _, _, _, requestKey ->
                fetchedKeys += requestKey
                TorBoxSearch.Result(listOf(stream("a".repeat(40))), false, false)
            },
            torBoxCredential = credential::get,
        )

        try {
            withTimeout(5_000) { workerOccupied.await() }
            source.refresh("tt1234567", season = 0, episode = 0)

            credential.set(TorBoxSearchSource.Credential("key-b", 2L))
            releaseWorker.complete(Unit)
            blocker.join()
            withContext(fetchDispatcher) { Unit }

            assertTrue(fetchedKeys.isEmpty())
            assertTrue(source.streams.value.isEmpty())

            source.refresh("tt1234567", season = 0, episode = 0)
            withTimeout(5_000) {
                while (fetchedKeys != listOf("key-b")) kotlinx.coroutines.yield()
            }
            assertEquals(listOf("key-b"), fetchedKeys)
        } finally {
            releaseWorker.complete(Unit)
            source.close()
            fetchDispatcher.close()
        }
    }

    @Test
    fun `closing the key gate clears episode A before episode B can assemble`() = runBlocking {
        val fetchDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        val configured = AtomicBoolean(true)
        val fetchCount = AtomicInteger()
        val source = TorBoxSearchSource(
            scope = CoroutineScope(SupervisorJob() + fetchDispatcher),
            fetchStreams = { _, _, episode, _ ->
                fetchCount.incrementAndGet()
                TorBoxSearch.Result(
                    streams = listOf(stream(episode.toString().repeat(40))),
                    rateLimited = false,
                    transportError = false,
                )
            },
            torBoxCredential = {
                TorBoxSearchSource.Credential(if (configured.get()) "test-key" else "", 0L)
            },
        )

        try {
            source.refresh("tt1234567", season = 1, episode = 1)
            withTimeout(5_000) {
                while (source.streams.value.singleOrNull()?.infoHash != "1".repeat(40)) {
                    kotlinx.coroutines.yield()
                }
            }
            val episodeAEpoch = source.epoch
            assertEquals("1".repeat(40), source.streamsFor("tt1234567:1:1").single().infoHash)
            assertTrue(source.streamsFor("tt1234567:1:2").isEmpty())

            configured.set(false)
            source.refresh("tt1234567", season = 1, episode = 2)

            assertTrue(source.streams.value.isEmpty())
            assertEquals(episodeAEpoch + 1, source.epoch)
            assertEquals(1, fetchCount.get())

            configured.set(true)
            source.refresh("tt1234567", season = 1, episode = 2)
            withTimeout(5_000) {
                while (source.streams.value.singleOrNull()?.infoHash != "2".repeat(40)) {
                    kotlinx.coroutines.yield()
                }
            }
            assertEquals(2, fetchCount.get())
            assertTrue(source.streamsFor("tt1234567:1:1").isEmpty())
            assertEquals("2".repeat(40), source.streamsFor("tt1234567:1:2").single().infoHash)
        } finally {
            source.close()
            fetchDispatcher.close()
        }
    }

    @Test
    fun `late episode A response cannot reopen a key gate closed for episode B`() = runBlocking {
        val executor = Executors.newSingleThreadExecutor()
        val fetchDispatcher = executor.asCoroutineDispatcher()
        val configured = AtomicBoolean(true)
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val fetchCount = AtomicInteger()
        val source = TorBoxSearchSource(
            scope = CoroutineScope(SupervisorJob() + fetchDispatcher),
            fetchStreams = { _, _, _, _ ->
                fetchCount.incrementAndGet()
                firstStarted.complete(Unit)
                // Reproduce a blocking transport that returns even after its coroutine is canceled.
                withContext(NonCancellable) { releaseFirst.await() }
                TorBoxSearch.Result(listOf(stream("a".repeat(40))), false, false)
            },
            torBoxCredential = {
                TorBoxSearchSource.Credential(if (configured.get()) "test-key" else "", 0L)
            },
        )

        try {
            source.refresh("tt1234567", season = 1, episode = 1)
            withTimeout(5_000) { firstStarted.await() }

            configured.set(false)
            source.refresh("tt1234567", season = 1, episode = 2)
            val closedEpoch = source.epoch

            releaseFirst.complete(Unit)
            // The single-thread executor orders this barrier after the resumed fetch completion.
            withContext(fetchDispatcher) { Unit }

            assertTrue(source.streams.value.isEmpty())
            assertEquals(closedEpoch, source.epoch)
            assertEquals(1, fetchCount.get())
        } finally {
            releaseFirst.complete(Unit)
            source.close()
            fetchDispatcher.close()
        }
    }

    @Test
    fun `response fetched with a replaced key cannot publish`() = runBlocking {
        val executor = Executors.newSingleThreadExecutor()
        val fetchDispatcher = executor.asCoroutineDispatcher()
        val key = AtomicReference("key-a")
        val revision = java.util.concurrent.atomic.AtomicLong(1L)
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val fetchedKeys = CopyOnWriteArrayList<String>()
        val source = TorBoxSearchSource(
            scope = CoroutineScope(SupervisorJob() + fetchDispatcher),
            fetchStreams = { _, _, _, requestKey ->
                fetchedKeys += requestKey
                if (requestKey == "key-a") {
                    firstStarted.complete(Unit)
                    withContext(NonCancellable) { releaseFirst.await() }
                }
                val hash = if (requestKey == "key-a") "a".repeat(40) else "b".repeat(40)
                TorBoxSearch.Result(listOf(stream(hash)), false, false)
            },
            torBoxCredential = { TorBoxSearchSource.Credential(key.get(), revision.get()) },
        )

        try {
            source.refresh("tt1234567", season = 1, episode = 1, requestGeneration = 41L)
            withTimeout(5_000) { firstStarted.await() }

            key.set("key-b")
            revision.incrementAndGet()
            releaseFirst.complete(Unit)
            withContext(fetchDispatcher) { Unit }

            assertTrue(source.streams.value.isEmpty())
            assertTrue(source.streamsFor("tt1234567:1:1").isEmpty())
            assertEquals(
                com.vortx.android.engine.SourceContributorSettlement(41L, settled = true),
                source.settlement.value,
            )

            source.refresh("tt1234567", season = 1, episode = 2)
            withTimeout(5_000) {
                while (source.streams.value.singleOrNull()?.infoHash != "b".repeat(40)) {
                    kotlinx.coroutines.yield()
                }
            }
            assertEquals(listOf("key-a", "key-b"), fetchedKeys)
        } finally {
            releaseFirst.complete(Unit)
            source.close()
            fetchDispatcher.close()
        }
    }

    @Test
    fun `same target cached under key A cannot cross into key B`() = runBlocking {
        val fetchDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        val credential = AtomicReference(TorBoxSearchSource.Credential("key-a", 1L))
        val fetchedKeys = CopyOnWriteArrayList<String>()
        val keyBStarted = CompletableDeferred<Unit>()
        val releaseKeyB = CompletableDeferred<Unit>()
        val source = TorBoxSearchSource(
            scope = CoroutineScope(SupervisorJob() + fetchDispatcher),
            fetchStreams = { _, _, _, requestKey ->
                fetchedKeys += requestKey
                if (requestKey == "key-b") {
                    keyBStarted.complete(Unit)
                    releaseKeyB.await()
                }
                val hash = if (requestKey == "key-a") "a".repeat(40) else "b".repeat(40)
                TorBoxSearch.Result(listOf(stream(hash)), false, false)
            },
            torBoxCredential = credential::get,
        )

        try {
            source.refresh("tt1234567", season = 0, episode = 0)
            withTimeout(5_000) {
                while (source.streamsFor("tt1234567:0:0").singleOrNull()?.infoHash != "a".repeat(40)) {
                    kotlinx.coroutines.yield()
                }
            }

            credential.set(TorBoxSearchSource.Credential("key-b", 2L))
            source.refresh("tt1234567", season = 0, episode = 0)

            assertTrue(source.streams.value.isEmpty())
            assertTrue(source.streamsFor("tt1234567:0:0").isEmpty())
            withTimeout(5_000) { keyBStarted.await() }
            releaseKeyB.complete(Unit)
            withTimeout(5_000) {
                while (source.streamsFor("tt1234567:0:0").singleOrNull()?.infoHash != "b".repeat(40)) {
                    kotlinx.coroutines.yield()
                }
            }
            assertEquals(listOf("key-a", "key-b"), fetchedKeys)
        } finally {
            releaseKeyB.complete(Unit)
            source.close()
            fetchDispatcher.close()
        }
    }

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
