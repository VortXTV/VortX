package com.vortx.android.usenet

import java.io.FileOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.io.path.createTempDirectory
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsenetProgressiveSessionTest {
    @Test
    fun `loopback bind failure unregisters the session`() {
        val home = createTempDirectory("usenet-progressive").toFile()
        val before = UsenetProgressiveLoopback.activeSessionCountForTest()
        val session = UsenetProgressiveSession(File(home, "title.mkv"))
        try {
            assertTrue(session.admitTotal(1))
            UsenetProgressiveLoopback.bindPortOverrideForTest = { throw IOException("test bind failure") }
            assertTrue(runCatching { session.url }.isFailure)
            assertEquals(before, UsenetProgressiveLoopback.activeSessionCountForTest())
        } finally {
            UsenetProgressiveLoopback.bindPortOverrideForTest = null
            session.close()
            home.deleteRecursively()
        }
    }

    @Test
    fun `failed loopback provider is cancelled and fallback advances to next server`() = runTest {
        val home = createTempDirectory("usenet-progressive").toFile()
        val before = UsenetProgressiveLoopback.activeSessionCountForTest()
        val attempts = mutableListOf<String>()
        var failedSession: UsenetProgressiveSession? = null
        var successfulSession: UsenetProgressiveSession? = null
        try {
            val url = UsenetProviderFallbackPolicy.firstReady(
                servers = listOf(testServer("first"), testServer("second")),
                stillCurrent = { true },
            ) { server ->
                attempts += server.id
                val session = UsenetProgressiveSession(File(home, "${server.id}.mkv"))
                check(session.admitTotal(1))
                if (server.id == "first") {
                    failedSession = session
                    UsenetProgressiveLoopback.bindPortOverrideForTest = { throw IOException("test bind failure") }
                } else {
                    successfulSession = session
                    UsenetProgressiveLoopback.bindPortOverrideForTest = null
                }
                try {
                    session.url
                } catch (error: Throwable) {
                    session.close()
                    throw error
                }
            }
            assertTrue(url.contains("127.0.0.1"))
            assertEquals(listOf("first", "second"), attempts)
            assertTrue("failed provider session was not cancelled", runCatching { failedSession!!.appendCommitted(1) }.isFailure)
        } finally {
            UsenetProgressiveLoopback.bindPortOverrideForTest = null
            failedSession?.close()
            successfulSession?.close()
            assertEquals(before, UsenetProgressiveLoopback.activeSessionCountForTest())
            home.deleteRecursively()
        }
    }

    @Test
    fun `producer cancellation is rethrown instead of reporting a failed session`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/usenet/UsenetLocalResolver.kt")
        val producer = source.substringAfter("session.launchProducer {")
            .substringBefore("return session")
        val cancellation = producer.indexOf("catch (error: CancellationException)")
        val failure = producer.indexOf("catch (error: Throwable)")

        assertTrue(cancellation >= 0)
        assertTrue(failure > cancellation)
        assertTrue(producer.substring(cancellation, failure).contains("throw error"))
        assertFalse(producer.substring(cancellation, failure).contains("session.fail"))
        val session = readProjectFile("src/main/kotlin/com/vortx/android/usenet/UsenetProgressiveSession.kt")
        assertTrue(session.contains("private val producerRoot = SupervisorJob()"))
        assertTrue(session.contains("producerRoot.cancel()"))
    }

    @Test
    fun `resolver proves a committed prefix before exposing its loopback result`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/usenet/UsenetLocalResolver.kt")
        val resolve = source.substringAfter("suspend fun resolve(").substringBefore("private fun startProgressiveAssembly")
        assertTrue(resolve.contains("session.awaitUsablePrefix(INITIAL_PREFIX_TIMEOUT_MS)"))
        assertTrue(resolve.contains("session.close()"))
        assertTrue(resolve.contains("Usenet provider was not ready"))
        assertTrue(source.contains("assembledBytes != session.totalBytes()"))
        assertTrue(source.contains("yEnc part coverage is not contiguous"))
    }

    @Test
    fun `failed initial prefix is terminal rather than an empty successful url`() {
        val home = createTempDirectory("usenet-progressive").toFile()
        val session = UsenetProgressiveSession(File(home, "title.mkv"))
        try {
            session.fail(IllegalStateException("authentication failed"))
            val failure = runCatching { kotlinx.coroutines.runBlocking { session.awaitUsablePrefix(100) } }.exceptionOrNull()
            assertTrue(failure != null)
        } finally {
            session.close()
            home.deleteRecursively()
        }
    }

    @Test
    fun `loopback url cannot exist until an authoritative total is admitted`() {
        val home = createTempDirectory("usenet-progressive").toFile()
        val session = UsenetProgressiveSession(File(home, "title.mkv"))
        try {
            assertTrue(runCatching { session.url }.isFailure)
            assertTrue(session.admitTotal(7))
            assertTrue(session.url.contains("127.0.0.1"))
        } finally {
            session.close()
            home.deleteRecursively()
        }
    }

    @Test
    fun `loopback range headers arrive before the requested ordered bytes`() {
        val home = createTempDirectory("usenet-progressive").toFile()
        val file = java.io.File(home, "title.mkv")
        val session = UsenetProgressiveSession(file)
        try {
            assertTrue(session.admitTotal(6))
            val url = URL(session.url)
            val connection = (url.openConnection() as HttpURLConnection).apply { setRequestProperty("Range", "bytes=2-5") }
            assertEquals(206, connection.responseCode)
            assertEquals("bytes 2-5/6", connection.getHeaderField("Content-Range"))
            assertEquals("bytes", connection.getHeaderField("Accept-Ranges"))
            val body = AtomicReference<ByteArray?>()
            val done = CountDownLatch(1)
            Thread {
                body.set(connection.inputStream.readBytes())
                done.countDown()
            }.start()
            assertFalse("range read must wait for the ordered append frontier", done.await(150, TimeUnit.MILLISECONDS))
            FileOutputStream(file, true).use { it.write("abcdef".toByteArray()) }
            session.appendCommitted(6)
            session.finish()
            assertTrue("range read did not resume after ordered bytes committed", done.await(2, TimeUnit.SECONDS))
            assertEquals("cdef", body.get()!!.toString(Charsets.UTF_8))
        } finally {
            session.close()
            home.deleteRecursively()
        }
    }

    @Test fun `suffix range and ordinary GET have RFC status and container type`() {
        val home = createTempDirectory("usenet-progressive").toFile()
        val file = java.io.File(home, "title.mp4"); file.writeBytes("abcdef".toByteArray())
        val session = UsenetProgressiveSession(file, "video/mp4")
        try {
            assertTrue(session.admitTotal(6))
            session.appendCommitted(6); session.finish()
            val suffix = (URL(session.url).openConnection() as HttpURLConnection).apply { setRequestProperty("Range", "bytes=-2") }
            assertEquals(206, suffix.responseCode); assertEquals("bytes 4-5/6", suffix.getHeaderField("Content-Range")); assertEquals("ef", suffix.inputStream.readBytes().toString(Charsets.UTF_8))
            val plain = URL(session.url).openConnection() as HttpURLConnection
            assertEquals(200, plain.responseCode); assertEquals("video/mp4", plain.contentType); assertEquals("abcdef", plain.inputStream.readBytes().toString(Charsets.UTF_8))
        } finally { session.close(); home.deleteRecursively() }
    }

    @Test fun `non-byte and unsatisfiable ranges are refused with RFC 416 metadata`() {
        val home = createTempDirectory("usenet-progressive").toFile(); val file = java.io.File(home, "title.mkv")
        file.writeBytes("abcdef".toByteArray()); val session = UsenetProgressiveSession(file)
        try {
            assertTrue(session.admitTotal(6))
            session.appendCommitted(6); session.finish()
            val wrongUnit = (URL(session.url).openConnection() as HttpURLConnection).apply { setRequestProperty("Range", "widgets=0-1") }
            assertEquals(416, wrongUnit.responseCode); assertEquals("bytes */6", wrongUnit.getHeaderField("Content-Range"))
            val beyond = (URL(session.url).openConnection() as HttpURLConnection).apply { setRequestProperty("Range", "bytes=9-") }
            assertEquals(416, beyond.responseCode); assertEquals("bytes */6", beyond.getHeaderField("Content-Range"))
            val mixed = (URL(session.url).openConnection() as HttpURLConnection).apply { setRequestProperty("rAnGe", "bytes=1-2") }
            assertEquals(206, mixed.responseCode); assertEquals("bc", mixed.inputStream.readBytes().toString(Charsets.UTF_8))
        } finally { session.close(); home.deleteRecursively() }
    }

    @Test
    fun `HEAD describes the bounded loopback resource without downloading`() {
        val home = createTempDirectory("usenet-progressive").toFile()
        val session = UsenetProgressiveSession(java.io.File(home, "title.mkv"))
        try {
            assertTrue(session.admitTotal(9))
            val connection = (URL(session.url).openConnection() as HttpURLConnection).apply { requestMethod = "HEAD" }
            assertEquals(200, connection.responseCode)
            assertEquals("9", connection.getHeaderField("Content-Length"))
            assertEquals("bytes", connection.getHeaderField("Accept-Ranges"))
        } finally {
            session.close()
            home.deleteRecursively()
        }
    }

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }

    private fun testServer(id: String) = UsenetProviderServer(
        id = id,
        name = id,
        host = "$id.example",
        port = 563,
        username = "user-$id",
        password = "secret-$id",
        maxConnections = 1,
        useSSL = true,
        enabled = true,
    )
}
