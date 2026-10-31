package com.vortx.android.player

import com.vortx.android.model.SubtitleRequestMetadata
import java.net.ServerSocket
import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import okhttp3.HttpUrl.Companion.toHttpUrl
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SubtitleAddonHttpTest {
    private fun withServer(status: Int = 200, bodyOverride: ByteArray? = null, advertisedLength: Int? = null, locationOverride: String? = null, block: suspend (SubtitleAddonSource, List<String>) -> Unit) = runBlocking {
        val paths = CopyOnWriteArrayList<String>()
        val server = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        val worker = thread(isDaemon = true, name = "subtitle-http-fixture") {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: java.net.SocketException) { break }
                socket.use {
                    socket.soTimeout = 4_000
                    val reader = socket.getInputStream().bufferedReader()
                    val path = reader.readLine().split(' ')[1]
                    paths += path
                    while (!reader.readLine().isNullOrEmpty()) { /* request headers */ }
                    val code = when {
                        locationOverride != null -> 302
                        status in listOf(404, 405) && !path.contains("/filename=") -> 200
                        else -> status
                    }
                    val bytes = bodyOverride ?: """{"subtitles":[{"url":"https://cdn.invalid/en.srt","lang":"eng","subtitleFileName":"Matched release"},9,{"url":null},{"url":17},{"url":"https://cdn.invalid/other.srt","lang":8,"subtitleFileName":8}]}""".toByteArray()
                    val output = socket.getOutputStream()
                    output.write(("HTTP/1.1 $code Fixture\r\n" + (locationOverride?.let { "Location: $it\r\n" } ?: "") +
                        "Content-Type: application/json\r\nContent-Length: ${advertisedLength ?: bytes.size}\r\nConnection: close\r\n\r\n").toByteArray())
                    output.write(bytes)
                    output.flush()
                }
            }
        }
        try {
            block(SubtitleAddonSource("http://127.0.0.1:${server.localPort}", "Fixture"), paths)
        } finally { server.close(); worker.join(1_000) }
    }

    @Test fun exactFileRequestSurvivesPartialMalformedRows() = withServer { source, paths ->
        val rows = SubtitleAddonService.fetch(listOf(source), "series", "tt123:1:9",
            SubtitleRequestMetadata("Episode 9 & #1/%?.mkv", "0123456789abcdef", 6_750_000_000L))
        assertEquals(listOf("/subtitles/series/tt123:1:9/videoHash=0123456789abcdef&videoSize=6750000000&filename=Episode%209%20%26%20%231%2F%25%3F.mkv.json"), paths)
        assertEquals(2, rows.size)
        assertEquals("Fixture · Matched release", rows[0].displayTitle)
        assertEquals("und", rows[1].lang)
        assertEquals("Fixture", rows[1].displayTitle)
    }

    @Test fun legacyRouterGetsOnlyOneBoundedRouteFallback() {
        for (status in listOf(404, 405)) withServer(status) { source, paths ->
            val rows = SubtitleAddonService.fetch(listOf(source), "movie", "tt123", SubtitleRequestMetadata(filename = "a.mkv"))
            assertEquals(listOf("/subtitles/movie/tt123/filename=a.mkv.json", "/subtitles/movie/tt123.json"), paths)
            assertEquals(2, rows.size)
        }
    }

    @Test fun serverFailureDoesNotRetryAnIdOnlyRoute() = withServer(502) { source, paths ->
        val rows = SubtitleAddonService.fetch(listOf(source), "movie", "tt123", SubtitleRequestMetadata(filename = "a.mkv"))
        assertTrue(rows.isEmpty())
        assertEquals(1, paths.size)
    }

    @Test fun relativeRowsResolveAgainstFinalIndexAndRetainOriginalInstalledBase() = runBlocking {
        val paths = CopyOnWriteArrayList<String>()
        val server = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        val port = server.localPort
        val payload = """{"subtitles":[{"url":"../../../files/en.srt?token=abc","lang":"eng"}]}""".toByteArray()
        val worker = thread(isDaemon = true, name = "subtitle-index-redirect-fixture") {
            repeat(2) {
                val socket = try { server.accept() } catch (_: java.net.SocketException) { return@thread }
                socket.use {
                    socket.soTimeout = 4_000
                    val reader = socket.getInputStream().bufferedReader()
                    val path = reader.readLine().split(' ')[1]
                    paths += path
                    while (!reader.readLine().isNullOrEmpty()) { /* request headers */ }
                    val redirect = path == "/subtitles/movie/tt123.json"
                    val body = if (redirect) ByteArray(0) else payload
                    val response = if (redirect) {
                        "HTTP/1.1 302 Found\r\nLocation: /moved/subtitles/movie/tt123.json\r\n"
                    } else "HTTP/1.1 200 OK\r\n"
                    val output = socket.getOutputStream()
                    output.write((response + "Content-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n").toByteArray())
                    output.write(body)
                    output.flush()
                }
            }
        }
        val base = "http://127.0.0.1:$port"
        val installed = "$base/manifest.json"
        try {
            val rows = SubtitleAddonService.fetch(
                listOf(SubtitleAddonSource(base, "Fixture", installed)), "movie", "tt123",
            )
            assertEquals(listOf("/subtitles/movie/tt123.json", "/moved/subtitles/movie/tt123.json"), paths)
            assertEquals(1, rows.size)
            assertEquals("$base/files/en.srt?token=abc", rows.single().url)
            assertEquals(installed, rows.single().originalInstalledBase)
            assertEquals("$base/moved/subtitles/movie/tt123.json", rows.single().actualFinalIndexUri)
        } finally {
            server.close()
            worker.join(1_000)
        }
    }



    @Test fun foreignPrivateRedirectIsRejectedAtTheIndexBoundary() {
        val foreign = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        foreign.soTimeout = 250
        val contacted = AtomicBoolean(false)
        val finished = AtomicBoolean(false)
        val workerDone = CountDownLatch(1)
        val worker = thread(isDaemon = true, name = "subtitle-foreign-origin-fixture") {
            try {
                while (true) {
                    try {
                        foreign.accept().use { socket ->
                            contacted.set(true)
                            socket.soTimeout = 1_000
                            val reader = socket.getInputStream().bufferedReader()
                            reader.readLine()
                            while (!reader.readLine().isNullOrEmpty()) { /* request headers */ }
                            // A missing policy must fail through contact/result evidence, not refusal.
                            val body = """{"subtitles":[{"url":"https://cdn.invalid/foreign.srt"}]}""".toByteArray()
                            socket.getOutputStream().apply {
                                write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                                write(body)
                                flush()
                            }
                        }
                    } catch (_: java.net.SocketTimeoutException) {
                        if (finished.get()) break
                    }
                }
            } catch (_: Exception) {
            } finally {
                workerDone.countDown()
            }
        }
        try {
            withServer(
                locationOverride = "http://127.0.0.1:${foreign.localPort}/private.json",
                bodyOverride = ByteArray(0),
            ) { source, paths ->
                val rows = SubtitleAddonService.fetch(listOf(source), "movie", "tt123")
                assertTrue(rows.isEmpty())
                assertEquals(listOf("/subtitles/movie/tt123.json"), paths)
            }
            finished.set(true)
            assertTrue(workerDone.await(1, TimeUnit.SECONDS))
            assertTrue(!contacted.get())
        } finally {
            finished.set(true)
            foreign.close()
            worker.join(1_000)
        }
    }

    @Test fun oversizedIndexBodyAndRedirectLocationAreRejected() {
        withServer(bodyOverride = ByteArray(0), advertisedLength = 1024 * 1024 + 1) { source, paths ->
            assertTrue(SubtitleAddonService.fetch(listOf(source), "movie", "tt123").isEmpty())
            assertEquals(1, paths.size)
        }
        withServer(
            bodyOverride = ByteArray(0),
            locationOverride = "https://cdn.example/" + "x".repeat(128 * 1024 + 1),
        ) { source, paths ->
            assertTrue(SubtitleAddonService.fetch(listOf(source), "movie", "tt123").isEmpty())
            assertEquals(1, paths.size)
        }
    }

    @Test fun expiredIndexDeadlineDoesNotIssueARequest() = runBlocking {
        val server = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        server.soTimeout = 350
        val accepted = AtomicBoolean(false)
        val workerDone = CountDownLatch(1)
        val worker = thread(isDaemon = true, name = "subtitle-expired-fixture") {
            try {
                server.accept().use { accepted.set(true) }
            } catch (_: java.net.SocketTimeoutException) {
                // Expected: an already-expired request must never reach the listening socket.
            } finally {
                workerDone.countDown()
            }
        }
        val base = "http://127.0.0.1:${server.localPort}"
        try {
            assertEquals(null, AddonSubtitleIndexTransport.get(
                "$base/subtitles/movie/tt123.json", "$base/manifest.json", System.nanoTime() - 1L,
            ))
            assertTrue(withContext(Dispatchers.IO) { workerDone.await(1, TimeUnit.SECONDS) })
            assertTrue(!accepted.get())
        } finally {
            server.close()
            withContext(Dispatchers.IO) { worker.join(1_000) }
        }
    }

    @Test fun cancellingActiveIndexFetchCancelsItsNetworkCallAndClosesAcceptedSocket() = runBlocking {
        val server = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        val requestReceived = CountDownLatch(1)
        val workerDone = CountDownLatch(1)
        val acceptedSocket = AtomicReference<java.net.Socket?>(null)
        val worker = thread(isDaemon = true, name = "subtitle-cancel-fixture") {
            try {
                server.accept().use { socket ->
                    acceptedSocket.set(socket)
                    val reader = socket.getInputStream().bufferedReader()
                    reader.readLine()
                    while (!reader.readLine().isNullOrEmpty()) { /* request headers */ }
                    requestReceived.countDown()
                    socket.getInputStream().read() // Must observe the cancelled OkHttp socket closing.
                }
            } catch (_: Exception) {
            } finally {
                workerDone.countDown()
            }
        }
        val base = "http://127.0.0.1:${server.localPort}"
        val job = launch(Dispatchers.IO) {
            SubtitleAddonService.fetch(
                listOf(SubtitleAddonSource(base, "Fixture", "$base/manifest.json")), "movie", "tt123",
            )
        }
        try {
            assertTrue(withContext(Dispatchers.IO) { requestReceived.await(2, TimeUnit.SECONDS) })
            withTimeout(2_000) { job.cancelAndJoin() }
            assertTrue(job.isCancelled)
            assertTrue(withContext(Dispatchers.IO) { workerDone.await(2, TimeUnit.SECONDS) })
        } finally {
            if (job.isActive) job.cancel()
            acceptedSocket.get()?.close()
            server.close()
            withTimeoutOrNull(1_000) { job.join() }
            withContext(Dispatchers.IO) { worker.join(1_000) }
        }
    }

    @Test fun queuedAdmissionDoesNotDropTheSeventeenthInstalledSource() = runBlocking {
        val server = ServerSocket(0, 32, InetAddress.getByName("127.0.0.1"))
        val firstWaveRequests = CountDownLatch(2)
        val releaseResponses = CountDownLatch(1)
        val acceptedRequests = AtomicInteger(0)
        val handlers = CopyOnWriteArrayList<Thread>()
        val serverWorker = thread(isDaemon = true, name = "subtitle-queued-fixture") {
            try {
                repeat(17) {
                    val socket = server.accept()
                    val handler = thread(isDaemon = true, name = "subtitle-queued-response") responseHandler@ {
                        try {
                            socket.use {
                                socket.soTimeout = 4_000
                                val reader = socket.getInputStream().bufferedReader()
                                reader.readLine()
                                while (!reader.readLine().isNullOrEmpty()) { /* request headers */ }
                                acceptedRequests.incrementAndGet()
                                firstWaveRequests.countDown()
                                if (!releaseResponses.await(5, TimeUnit.SECONDS)) return@responseHandler
                                val body = """{"subtitles":[{"url":"subtitle.srt","lang":"eng"}]}""".toByteArray()
                                val output = socket.getOutputStream()
                                output.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                                output.write(body)
                                output.flush()
                            }
                        } catch (_: Exception) { }
                    }
                    handlers += handler
                }
            } catch (_: Exception) { }
        }
        val origin = "http://127.0.0.1:${server.localPort}"
        val sources = (0 until 17).map { index ->
            SubtitleAddonSource("$origin/addon$index", "Fixture $index", "$origin/manifest.json")
        }
        try {
            val fetch = async { SubtitleAddonService.fetch(sources, "movie", "tt123") }
            assertTrue(withContext(Dispatchers.IO) { firstWaveRequests.await(2, TimeUnit.SECONDS) })
            // Per-host dispatch admits two calls. Hold that wave while remaining sources queue.
            delay(250)
            releaseResponses.countDown()
            val rows = withTimeout(10_000) { fetch.await() }
            assertEquals(17, rows.size)
            assertEquals(17, acceptedRequests.get())
        } finally {
            releaseResponses.countDown()
            server.close()
            withContext(Dispatchers.IO) {
                serverWorker.join(1_000)
                handlers.forEach { it.join(1_000) }
            }
        }
    }

    @Test fun rawLiteralCheckAllowsDottedHostnamesAndNormalizedIPv6ButRejectsIPv4Aliases() {
        assertTrue(AddonSubtitleIndexTransport.sameRawLiteral("https://media.example.test/path", "https://media.example.test".toHttpUrl()))
        assertTrue(AddonSubtitleIndexTransport.sameRawLiteral("https://[0:0:0:0:0:0:0:1]/path", "https://[::1]/".toHttpUrl()))
        assertTrue(AddonSubtitleIndexTransport.sameRawLiteral("../subtitles.json", "http://127.0.0.1/".toHttpUrl()))
        assertTrue(!AddonSubtitleIndexTransport.sameRawLiteral("http://127.1/path", "http://127.0.0.1/".toHttpUrl()))
        assertTrue(!AddonSubtitleIndexTransport.sameRawLiteral("//127.0.0.2/path", "http://127.0.0.1/".toHttpUrl()))
    }
}
