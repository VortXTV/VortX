package com.vortx.android.library

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class WatchlistCodecTest {
    @Test
    fun `round trip keeps apple compatible fields newest first`() {
        val entries = listOf(
            WatchlistEntry("tt1", "series", "Show", "show.jpg", 10.0),
            WatchlistEntry("tmdb:2", "movie", null, null, 20.0),
        )

        val decoded = WatchlistCodec.decode(WatchlistCodec.encode(entries))

        assertEquals(listOf("tmdb:2", "tt1"), decoded.map { it.id })
        assertEquals("Show", decoded[1].name)
        assertEquals("show.jpg", decoded[1].poster)
    }

    @Test
    fun `garbled unsafe and duplicate entries fail soft`() {
        assertTrue(WatchlistCodec.decode("not-json").isEmpty())
        val decoded = WatchlistCodec.decode(
            """[
                {"id":"magnet:unsafe","type":"movie","addedAt":30},
                {"id":"tt1","type":"series","addedAt":20},
                {"id":"tt1","type":"movie","addedAt":10}
            ]""",
        )

        assertEquals(1, decoded.size)
        assertEquals("series", decoded.single().type)
    }

    @Test
    fun `store confines serialized read encode write to injected IO dispatcher`() = runBlocking {
        val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "watchlist-test-io") }
        val dispatcher = executor.asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val persistence = FakeWatchlistPersistence()
            val store = WatchlistStore(
                persistence = persistence,
                activeProfileId = { "OWNER" },
                registerProfileSwitch = {},
                scope = scope,
                ioDispatcher = dispatcher,
                nowEpochSeconds = { 42.0 },
            )
            store.reload()
            persistence.threadNames.clear()

            assertTrue(store.toggle(MetaItem("tt-io", MediaType.MOVIE, "IO Movie")))

            assertEquals(listOf("tt-io"), store.items.value.map { it.id })
            assertTrue(persistence.threadNames.isNotEmpty())
            assertTrue(persistence.threadNames.all { it.contains("watchlist-test-io") })
            assertEquals(
                listOf("tt-io"),
                WatchlistCodec.decode(persistence.values.getValue("vortx.watchlist.OWNER")).map { it.id },
            )
        } finally {
            scope.cancel()
            dispatcher.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun `profile switch clears old flow then loads the new compatible key and caps at 1000`() = runBlocking {
        val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "watchlist-profile-io") }
        val dispatcher = executor.asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val active = AtomicReference("PROFILE-A")
            var switchListener: () -> Unit = {}
            val persistence = FakeWatchlistPersistence().apply {
                values["vortx.watchlist.PROFILE-A"] = WatchlistCodec.encode(
                    listOf(WatchlistEntry("tt-a", "movie", "A", null, 1.0)),
                )
                values["vortx.watchlist.PROFILE-B"] = WatchlistCodec.encode(
                    (0..WatchlistStore.MAX_ENTRIES).map { index ->
                        WatchlistEntry("tt-b-$index", "movie", "B $index", null, index.toDouble())
                    },
                )
            }
            val store = WatchlistStore(
                persistence = persistence,
                activeProfileId = active::get,
                registerProfileSwitch = { switchListener = it },
                scope = scope,
                ioDispatcher = dispatcher,
                nowEpochSeconds = { 10_000.0 },
            )
            store.reload()
            assertEquals(listOf("tt-a"), store.items.value.map { it.id })

            active.set("PROFILE-B")
            switchListener()
            assertTrue(store.items.value.isEmpty())
            store.reload()
            assertEquals(WatchlistStore.MAX_ENTRIES, store.items.value.size)
            assertFalse(store.items.value.any { it.id == "tt-a" })

            assertTrue(store.toggle(MetaItem("tt-b-new", MediaType.MOVIE, "New B")))
            val persistedB = WatchlistCodec.decode(persistence.values.getValue("vortx.watchlist.PROFILE-B"))
            assertEquals(WatchlistStore.MAX_ENTRIES, persistedB.size)
            assertEquals("tt-b-new", persistedB.first().id)
            assertEquals(
                listOf("tt-a"),
                WatchlistCodec.decode(persistence.values.getValue("vortx.watchlist.PROFILE-A")).map { it.id },
            )
        } finally {
            scope.cancel()
            dispatcher.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun `blocked same profile reload cannot publish after a queued toggle`() = runBlocking {
        val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "watchlist-race-io") }
        val dispatcher = executor.asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val key = "vortx.watchlist.OWNER"
            val persistence = FakeWatchlistPersistence().apply {
                values[key] = entries("tt-initial")
            }
            val store = WatchlistStore(
                persistence = persistence,
                activeProfileId = { "OWNER" },
                registerProfileSwitch = {},
                scope = scope,
                ioDispatcher = dispatcher,
                nowEpochSeconds = { 50.0 },
            )
            store.reload()
            assertEquals(listOf("tt-initial"), store.items.value.map { it.id })

            persistence.values[key] = entries("tt-stale")
            val blockedRead = persistence.blockNextRead()
            val olderReload = async(Dispatchers.Default) { store.reload() }
            assertTrue(blockedRead.started.await(5, TimeUnit.SECONDS))

            persistence.values[key] = WatchlistCodec.encode(emptyList())
            val newerToggle = async(Dispatchers.Default) {
                store.toggle(MetaItem("tt-new", MediaType.MOVIE, "New"))
            }
            blockedRead.release.countDown()

            withTimeout(5_000L) {
                olderReload.await()
                assertTrue(newerToggle.await())
            }
            assertEquals(listOf("tt-new"), store.items.value.map { it.id })
            assertEquals(listOf("tt-new"), WatchlistCodec.decode(persistence.values.getValue(key)).map { it.id })
        } finally {
            scope.cancel()
            dispatcher.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun `A B A switch rejects the first A reload snapshot`() = runBlocking {
        val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "watchlist-aba-io") }
        val dispatcher = executor.asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val active = AtomicReference("PROFILE-A")
            var switchListener: () -> Unit = {}
            val keyA = "vortx.watchlist.PROFILE-A"
            val persistence = FakeWatchlistPersistence().apply {
                values[keyA] = entries("tt-initial")
                values["vortx.watchlist.PROFILE-B"] = entries("tt-profile-b")
            }
            val store = WatchlistStore(
                persistence = persistence,
                activeProfileId = active::get,
                registerProfileSwitch = { switchListener = it },
                scope = scope,
                ioDispatcher = dispatcher,
            )
            store.reload()
            assertEquals(listOf("tt-initial"), store.items.value.map { it.id })
            val observed = Collections.synchronizedList(mutableListOf<List<String>>())
            scope.launch { store.items.collect { items -> observed += items.map { it.id } } }

            persistence.values[keyA] = entries("tt-stale")
            val blockedRead = persistence.blockNextRead()
            val oldA = async(Dispatchers.Default) { store.reload() }
            assertTrue(blockedRead.started.await(5, TimeUnit.SECONDS))

            active.set("PROFILE-B")
            switchListener()
            active.set("PROFILE-A")
            switchListener()
            persistence.values[keyA] = entries("tt-current")
            blockedRead.release.countDown()

            withTimeout(5_000L) {
                oldA.await()
                // This queues behind both profile-switch reloads and therefore acts as their join.
                store.reload()
            }
            assertEquals(listOf("tt-current"), store.items.value.map { it.id })
            assertFalse(store.items.value.any { it.id == "tt-stale" || it.id == "tt-profile-b" })
            assertFalse(observed.any { ids -> "tt-stale" in ids || "tt-profile-b" in ids })
        } finally {
            scope.cancel()
            dispatcher.close()
            executor.shutdownNow()
        }
    }

    private fun entries(vararg ids: String): String = WatchlistCodec.encode(
        ids.mapIndexed { index, id ->
            WatchlistEntry(id, "movie", id, null, index.toDouble())
        },
    )

    private class FakeWatchlistPersistence : WatchlistPersistence {
        val values = ConcurrentHashMap<String, String>()
        val threadNames: MutableList<String> = Collections.synchronizedList(mutableListOf())
        private val nextReadBlock = AtomicReference<ReadBlock?>()

        fun blockNextRead(): ReadBlock = ReadBlock().also { block ->
            check(nextReadBlock.compareAndSet(null, block)) { "A read is already blocked" }
        }

        override fun read(key: String): String? {
            threadNames += Thread.currentThread().name
            val snapshot = values[key]
            nextReadBlock.getAndSet(null)?.let { block ->
                block.started.countDown()
                check(block.release.await(5, TimeUnit.SECONDS)) { "Timed out waiting to release watchlist read" }
            }
            return snapshot
        }

        override fun write(key: String, value: String) {
            threadNames += Thread.currentThread().name
            values[key] = value
        }
    }

    private class ReadBlock {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
    }
}
