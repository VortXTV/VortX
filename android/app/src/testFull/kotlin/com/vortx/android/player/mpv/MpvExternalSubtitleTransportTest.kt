package com.vortx.android.player.mpv

import com.vortx.android.model.ExternalSubtitle
import com.vortx.android.model.Playable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.InputStream
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MpvExternalSubtitleTransportTest {
    @Test
    fun `structured subtitle tracks win over legacy URL list`() {
        val playable = Playable(
            url = "https://video.example/movie",
            title = "Movie",
            externalSubtitles = listOf("https://legacy.example/old.srt"),
            externalSubtitleTracks = listOf(
                ExternalSubtitle("https://sidecar.example/new.srt"),
                ExternalSubtitle("https://sidecar.example/new.srt"),
            ),
        )

        assertEquals(
            listOf("https://sidecar.example/new.srt"),
            MpvExternalSubtitleTransport.normalizedTracks(playable).map { it.url },
        )
    }

    @Test
    fun `offline subtitle paths stay local while remote private URLs remain rejected`() {
        assertEquals("/storage/emulated/0/Downloads/sub.srt", MpvExternalSubtitleTransport.localFileFor(
            "/storage/emulated/0/Downloads/sub.srt",
        )?.path)
        assertEquals("/storage/emulated/0/Downloads/sub.srt", MpvExternalSubtitleTransport.localFileFor(
            "file:///storage/emulated/0/Downloads/sub.srt",
        )?.path)
        assertTrue(MpvExternalSubtitleTransport.isContentUri("content://documents/subtitle/42"))
        assertEquals(null, MpvExternalSubtitleTransport.localFileFor("https://127.0.0.1/private.srt"))
        assertEquals(null, MpvExternalSubtitleTransport.requestFor(ExternalSubtitle("https://127.0.0.1/private.srt")))
    }

    @Test
    fun `sidecar headers are isolated sanitized and cache identity does not expose credentials`() {
        val first = MpvExternalSubtitleTransport.sanitizeHeaders(
            linkedMapOf(
                "Authorization" to "Bearer rotated-secret-a",
                "X-Provider-Token" to "one",
                "Host" to "video.example",
                "Content-Length" to "1",
                "Bad\rName" to "no",
                "Referer" to "https://provider.example",
            ),
        )
        val second = MpvExternalSubtitleTransport.sanitizeHeaders(
            mapOf("Authorization" to "Bearer rotated-secret-b"),
        )
        val a = MpvExternalSubtitleTransport.Request(URI("https://1.1.1.1/sub.srt"), first)
        val b = MpvExternalSubtitleTransport.Request(URI("https://1.1.1.1/sub.srt"), second)

        assertEquals(setOf("Authorization", "Referer", "X-Provider-Token"), first.keys)
        assertFalse(first.containsKey("Host"))
        assertFalse(first.containsKey("Content-Length"))
        assertNotEquals(MpvExternalSubtitleTransport.cacheKey(a), MpvExternalSubtitleTransport.cacheKey(b))
        assertFalse(MpvExternalSubtitleTransport.cacheKey(a).contains("rotated-secret-a"))
    }

    @Test
    fun `same origin redirects retain headers while cross origin redirects redact them`() {
        val current = MpvExternalSubtitleTransport.Request(
            URI("https://1.1.1.1/path/sub.srt"),
            mapOf("Authorization" to "Bearer secret", "X-Provider" to "yes"),
        )

        val same = MpvExternalSubtitleTransport.redirectFor(current, "/next.srt", hop = 0)
        val cross = MpvExternalSubtitleTransport.redirectFor(current, "https://8.8.8.8/next.srt", hop = 0)

        assertEquals(current.headers, same?.headers)
        assertTrue(cross?.headers.orEmpty().isEmpty())
    }

    @Test
    fun `unsafe malformed and exhausted redirects are rejected`() {
        val current = MpvExternalSubtitleTransport.Request(URI("https://1.1.1.1/sub.srt"), emptyMap())

        assertEquals(null, MpvExternalSubtitleTransport.redirectFor(current, "http://1.1.1.1/plain.srt", 0))
        assertEquals(null, MpvExternalSubtitleTransport.redirectFor(current, "https://127.0.0.1/private.srt", 0))
        assertEquals(null, MpvExternalSubtitleTransport.redirectFor(current, "https://1.1.1.1/\r\n.srt", 0))
        assertEquals(null, MpvExternalSubtitleTransport.redirectFor(current, "/next.srt", MpvExternalSubtitleTransport.MAX_REDIRECTS))
    }

    @Test
    fun `cancellation propagates and stale subtitle generations cannot mount`() {
        var cancellationRethrown = false
        try {
            MpvExternalSubtitleTransport.rethrowIfFatal(CancellationException("stop"))
        } catch (_: CancellationException) {
            cancellationRethrown = true
        }

        assertTrue(cancellationRethrown)
        assertTrue(MpvExternalSubtitleTransport.shouldMount(7L, 7L))
        assertFalse(MpvExternalSubtitleTransport.shouldMount(7L, 8L))
    }

    @Test
    fun `protected client rejects private and mixed DNS answers before a request can connect`() {
        listOf(
            listOf("127.0.0.1"),
            listOf("1.1.1.1", "127.0.0.1"),
        ).forEach { answers ->
            val dns = MpvExternalSubtitleTransport.publicDns(1_000) { answers.map(java.net.InetAddress::getByName) }
            val client = MpvExternalSubtitleTransport.protectedClient(timeoutMs = 1_000, dns = dns)
            val result = runCatching {
                client.newCall(Request.Builder().url("https://sidecar.test/sub.srt").build()).execute().close()
            }

            assertTrue(result.isFailure)
        }
    }

    @Test
    fun `cancelling a blocked content stream closes it and removes its partial file`() = runBlocking(Dispatchers.Default) {
        val readStarted = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val target = File.createTempFile("vortx-content-test-", ".srt")
        val blockingInput = object : InputStream() {
            override fun read(): Int {
                readStarted.countDown()
                closed.await()
                return -1
            }

            override fun close() {
                closed.countDown()
            }
        }
        val job = launch(Dispatchers.Default) {
            copyBoundedContentSubtitle(
                openInput = { blockingInput },
                target = target,
                maxBytes = 8L * 1024L * 1024L,
                timeoutMs = 20_000L,
            )
        }

        try {
            assertTrue("content read did not begin", readStarted.await(2, TimeUnit.SECONDS))
        } finally {
            job.cancelAndJoin()
        }
        assertTrue("cancellation did not close the live content stream", closed.await(2, TimeUnit.SECONDS))
        assertFalse("partial content subtitle remained", target.exists())
    }

    @Test
    fun `content subtitle deadline is cumulative elapsed time and closes its live stream`() = runBlocking(Dispatchers.Default) {
        val readStarted = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val target = File.createTempFile("vortx-content-deadline-", ".srt")
        val blockingInput = object : InputStream() {
            override fun read(): Int = -1

            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                readStarted.countDown()
                closed.await()
                return -1
            }

            override fun close() {
                closed.countDown()
            }
        }
        val startedAt = System.nanoTime()
        val result = runCatching {
            copyBoundedContentSubtitle(
                openInput = { blockingInput },
                target = target,
                maxBytes = 8L * 1024L * 1024L,
                timeoutMs = 100L,
            )
        }
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)

        assertTrue("content read did not begin", readStarted.await(2, TimeUnit.SECONDS))
        assertTrue("deadline did not close the live content stream", closed.await(2, TimeUnit.SECONDS))
        assertTrue("expected deadline failure, got ${result.exceptionOrNull()}", result.exceptionOrNull() is java.util.concurrent.TimeoutException)
        assertTrue("deadline fired too early after ${elapsedMs}ms", elapsedMs >= 75L)
        assertTrue("deadline did not bound elapsed copy time: ${elapsedMs}ms", elapsedMs < 2_000L)
        assertFalse("timed-out content subtitle remained", target.exists())
    }
}
