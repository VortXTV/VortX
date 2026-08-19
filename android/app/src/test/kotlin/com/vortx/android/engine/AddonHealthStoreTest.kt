package com.vortx.android.engine

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger

@OptIn(ExperimentalCoroutinesApi::class)
class AddonHealthStoreTest {
    @Test
    fun `classifies successful latency and failures from the real probe result`() = runTest {
        val store = store(
            probe = AddonHealthProbe { url ->
                when (url.host) {
                    "fast.example" -> AddonProbeResult(statusCode = 204, latencyMillis = 1_500)
                    "slow.example" -> AddonProbeResult(statusCode = 399, latencyMillis = 1_501)
                    "error.example" -> AddonProbeResult(statusCode = 500, latencyMillis = 20)
                    else -> throw IOException("offline")
                }
            },
        )

        store.refresh(
            listOf(
                "https://fast.example/manifest.json",
                "https://slow.example/manifest.json",
                "https://error.example/manifest.json",
                "https://offline.example/manifest.json",
            ),
        )

        assertEquals(AddonHealth.Online(1_500), store.status.value[key("https://fast.example/manifest.json")])
        assertEquals(AddonHealth.Slow(1_501), store.status.value[key("https://slow.example/manifest.json")])
        assertEquals(AddonHealth.Unreachable, store.status.value[key("https://error.example/manifest.json")])
        assertEquals(AddonHealth.Unreachable, store.status.value[key("https://offline.example/manifest.json")])
    }

    @Test
    fun `probes two at a time and bounds a hung request after admission`() = runTest {
        val completed = AtomicInteger()
        val store = store(
            timeoutMillis = 6_000,
            probe = AddonHealthProbe { url ->
                if (url.host == "hung.example") {
                    delay(Long.MAX_VALUE)
                    AddonProbeResult(statusCode = 200, latencyMillis = Long.MAX_VALUE)
                } else {
                    delay(500)
                    completed.incrementAndGet()
                    AddonProbeResult(statusCode = 200, latencyMillis = 500)
                }
            },
        )

        val refresh = async {
            store.refresh(
                listOf(
                    "https://hung.example/manifest.json",
                    "https://one.example/manifest.json",
                    "https://two.example/manifest.json",
                ),
            )
        }
        runCurrent()
        advanceTimeBy(500)
        runCurrent()

        assertEquals(1, completed.get())
        assertFalse(refresh.isCompleted)

        advanceTimeBy(500)
        runCurrent()

        assertEquals(2, completed.get())
        assertFalse(refresh.isCompleted)

        advanceTimeBy(5_000)
        runCurrent()

        assertTrue(refresh.await())
        assertEquals(AddonHealth.Unreachable, store.status.value[key("https://hung.example/manifest.json")])
    }

    @Test
    fun `queued URL receives its full timeout only after a probe slot is admitted`() = runTest {
        val transportSlots = Semaphore(2)
        val starts = mutableMapOf<String, Long>()
        val store = store(
            timeoutMillis = 6_000,
            probe = AddonHealthProbe { url ->
                transportSlots.withPermit {
                    starts[url.host] = testScheduler.currentTime
                    delay(if (url.host == "late.example") 1_000 else 5_900)
                    AddonProbeResult(statusCode = 200, latencyMillis = 20)
                }
            },
        )
        val lateUrl = "https://late.example/manifest.json"

        val refresh = async {
            store.refresh(
                listOf(
                    "https://one.example/manifest.json",
                    "https://two.example/manifest.json",
                    lateUrl,
                ),
            )
        }
        runCurrent()
        advanceTimeBy(6_899)
        runCurrent()

        assertFalse(refresh.isCompleted)
        advanceTimeBy(1)
        assertTrue(refresh.await())
        assertEquals(5_900L, starts["late.example"])
        assertEquals(AddonHealth.Online(20), store.status.value[key(lateUrl)])
    }

    @Test
    fun `bulk refresh is rate limited while force and elapsed window refresh`() = runTest {
        var nowMillis = 10_000L
        val calls = AtomicInteger()
        val store = store(
            nowMillis = { nowMillis },
            probe = AddonHealthProbe {
                calls.incrementAndGet()
                AddonProbeResult(statusCode = 200, latencyMillis = 10)
            },
        )
        val urls = listOf("https://addon.example/manifest.json")

        assertTrue(store.refresh(urls))
        assertFalse(store.refresh(urls))
        assertEquals(1, calls.get())

        assertTrue(store.refresh(urls, force = true))
        assertEquals(2, calls.get())

        nowMillis += 19_999
        assertFalse(store.refresh(urls))
        nowMillis += 1
        assertTrue(store.refresh(urls))
        assertEquals(3, calls.get())
    }

    @Test
    fun `late result from an older generation cannot overwrite forced refresh`() = runTest {
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val call = AtomicInteger()
        val store = store(
            probe = AddonHealthProbe {
                if (call.incrementAndGet() == 1) {
                    firstStarted.complete(Unit)
                    releaseFirst.await()
                    AddonProbeResult(statusCode = 200, latencyMillis = 3_000)
                } else {
                    AddonProbeResult(statusCode = 200, latencyMillis = 20)
                }
            },
        )
        val url = "https://addon.example/manifest.json"

        val first = async { store.refresh(listOf(url)) }
        firstStarted.await()
        assertTrue(store.refresh(listOf(url), force = true))
        assertEquals(AddonHealth.Online(20), store.status.value[key(url)])

        releaseFirst.complete(Unit)
        assertTrue(first.await())

        assertEquals(AddonHealth.Online(20), store.status.value[key(url)])
    }

    @Test
    fun `caller cancellation cancels in flight probes without publishing a failure`() = runTest {
        val started = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        val store = store(
            probe = AddonHealthProbe {
                started.complete(Unit)
                try {
                    delay(Long.MAX_VALUE)
                    AddonProbeResult(statusCode = 200, latencyMillis = 0)
                } finally {
                    cancelled.complete(Unit)
                }
            },
        )
        val url = "https://addon.example/manifest.json"

        val refresh = launch { store.refresh(listOf(url)) }
        started.await()
        assertEquals(AddonHealth.Checking, store.status.value[key(url)])

        refresh.cancelAndJoin()
        cancelled.await()

        assertEquals(AddonHealth.Checking, store.status.value[key(url)])
    }

    @Test
    fun `canonical URL key deduplicates equivalent transports`() = runTest {
        val calls = AtomicInteger()
        val store = store(
            probe = AddonHealthProbe {
                calls.incrementAndGet()
                AddonProbeResult(statusCode = 200, latencyMillis = 12)
            },
        )

        store.refresh(
            listOf(
                " HTTPS://EXAMPLE.com:443/addons/../manifest.json ",
                "https://example.com/manifest.json",
            ),
        )

        assertEquals(1, calls.get())
        assertEquals(
            mapOf("https://example.com/manifest.json" to AddonHealth.Online(12)),
            store.status.value,
        )
        assertEquals("https://example.com/manifest.json", AddonHealthStore.normalizeUrl("HTTPS://EXAMPLE.COM:443/manifest.json"))
        assertNull(AddonHealthStore.normalizeUrl("file:///manifest.json"))
    }

    @Test
    fun `public policy blocks private targets while strict loopback remains probeable`() = runTest {
        val requested = mutableListOf<String>()
        val store = store(
            probe = AddonHealthProbe { url ->
                requested += url.host
                AddonProbeResult(statusCode = 200, latencyMillis = 5)
            },
        )
        val privateLan = "http://192.168.1.20/manifest.json"
        val metadata = "http://169.254.169.254/latest/meta-data"
        val shorthandLoopback = "http://127.1/manifest.json"

        store.refresh(
            listOf(
                "https://example.com/manifest.json",
                "http://127.0.0.1:11470/manifest.json",
                "http://localhost:11470/manifest.json",
                "http://[::1]:11470/manifest.json",
                privateLan,
                metadata,
                shorthandLoopback,
            ),
        )

        assertEquals(setOf("example.com", "127.0.0.1", "localhost", "::1"), requested.toSet())
        assertEquals(AddonHealth.Unreachable, store.status.value[key(privateLan)])
        assertEquals(AddonHealth.Unreachable, store.status.value[key(metadata)])
        assertEquals(AddonHealth.Unreachable, store.status.value[key(shorthandLoopback)])
    }

    private fun store(
        probe: AddonHealthProbe,
        nowMillis: () -> Long = { 0L },
        timeoutMillis: Long = 6_000,
    ): AddonHealthStore = AddonHealthStore(
        probe = probe,
        nowMillis = nowMillis,
        timeoutMillis = timeoutMillis,
    )

    private fun key(url: String): String = requireNotNull(AddonHealthStore.normalizeUrl(url))
}
