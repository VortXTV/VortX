package com.vortx.android.downloads

import com.vortx.android.engine.PublicAddressPolicy
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class HlsOfflinePackageTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun redirectedMasterPackagesSelectedVariantKeysMapsAndSegmentsWithEvidence() {
        Fixture { request ->
            when (request.path) {
                "/start" -> Reply(302, headers = mapOf("Location" to "/catalog/master.m3u8"))
                "/catalog/master.m3u8" -> Reply.text("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200\nhigh.m3u8\n")
                "/catalog/high.m3u8" -> Reply.text(playlist("#EXT-X-MEDIA-SEQUENCE:17\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\",IV=0x11\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\nsegment.m4s"))
                "/catalog/key" -> Reply(body = ByteArray(16) { it.toByte() })
                "/catalog/init.mp4" -> Reply(body = ByteArray(16) { 4 })
                "/catalog/segment.m4s" -> Reply(body = ByteArray(32) { 8 })
                else -> Reply(404)
            }
        }.use { fixture ->
            val directory = staging()
            val progress = mutableListOf<Long>()
            val result = downloader().download(fixture.url("/start"), mapOf("Authorization" to "Bearer fixture-secret"), directory, {}, { it() }, progress::add)
            assertEquals(File(directory, "index.m3u8"), result.playlistFile)
            assertTrue(result.playlistFile.readText().contains("#EXT-X-MEDIA-SEQUENCE:17"))
            assertEquals(setOf("key-000000.bin", "map-000001.bin", "segment-000002.bin", "index.m3u8", "complete.json"), directory.list()!!.toSet())
            assertEquals(result.totalBytes, HlsOfflinePackage.safeSize(directory))
            assertNotNull(HlsOfflinePackage.verify(directory))
            assertNotNull(HlsOfflinePackage.verify(directory, fullHash = false))
            assertFalse(result.manifestFile.readText().contains("fixture-secret"))
            assertFalse(result.manifestFile.readText().contains("127.0.0.1"))
            assertEquals(result.totalBytes, progress.last())
            assertTrue(fixture.requests.none { it.path.contains("low") })
            assertTrue(fixture.requests.all { it.header("Authorization") == "Bearer fixture-secret" })
            assertTrue(Files.getPosixFilePermissions(File(directory, "key-000000.bin").toPath()).none {
                it in setOf(PosixFilePermission.GROUP_READ, PosixFilePermission.GROUP_WRITE, PosixFilePermission.OTHERS_READ, PosixFilePermission.OTHERS_WRITE)
            })
        }
    }

    @Test
    fun mapAndSegmentByteRangesRequireExact206AndBecomeStandaloneFiles() {
        val source = "0123456789abcdef".toByteArray()
        Fixture { request ->
            if (request.path == "/index.m3u8") {
                Reply.text(playlist("#EXT-X-MAP:URI=\"data\",BYTERANGE=\"4@8\"\n#EXTINF:4,\n#EXT-X-BYTERANGE:4@0\ndata\n#EXTINF:4,\n#EXT-X-BYTERANGE:4\ndata"))
            } else {
                val range = request.header("Range")!!.removePrefix("bytes=").split('-').map(String::toInt)
                Reply(206, source.copyOfRange(range[0], range[1] + 1), mapOf("Content-Range" to "bytes ${range[0]}-${range[1]}/${source.size}"))
            }
        }.use { fixture ->
            val result = download(fixture)
            assertArrayEquals("89ab".toByteArray(), File(result.playlistFile.parentFile, "map-000000.bin").readBytes())
            assertArrayEquals("0123".toByteArray(), File(result.playlistFile.parentFile, "segment-000001.bin").readBytes())
            assertArrayEquals("4567".toByteArray(), File(result.playlistFile.parentFile, "segment-000002.bin").readBytes())
            assertFalse(result.playlistFile.readText().contains("BYTERANGE"))
            assertEquals(listOf("bytes=8-11", "bytes=0-3", "bytes=4-7"), fixture.requests.drop(1).map { it.header("Range") })
        }
    }

    @Test
    fun ignoredMismatchedAndOversizedRangesNeverComplete() {
        for (reply in listOf(
            Reply(200, "0123".toByteArray()),
            Reply(206, "0123".toByteArray(), mapOf("Content-Range" to "bytes 1-4/8")),
            Reply(206, "01234".toByteArray(), mapOf("Content-Range" to "bytes 0-3/8")),
            Reply(206, "0123".toByteArray(), mapOf("Content-Range" to "bytes 0-3/3")),
        )) {
            Fixture { request -> if (request.path == "/index.m3u8") Reply.text(playlist("#EXTINF:4,\n#EXT-X-BYTERANGE:4@0\ndata")) else reply }.use { fixture ->
                val directory = staging()
                assertTrue(runCatching { download(fixture, directory) }.isFailure)
                assertNull(HlsOfflinePackage.verify(directory))
            }
        }
    }

    @Test
    fun invalidKeyLengthNeverProducesCompletionMarker() {
        Fixture { request ->
            if (request.path == "/index.m3u8") Reply.text(playlist("#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:4,\ndata"))
            else Reply(body = ByteArray(15))
        }.use { fixture ->
            val directory = staging()
            assertTrue(runCatching { download(fixture, directory) }.exceptionOrNull() is HlsOfflineException)
            assertFalse(File(directory, HlsOfflinePackage.MANIFEST_FILE_NAME).exists())
        }
    }

    @Test
    fun segmentCannotHideANetworkPlaylistInsideTheLocalPackage() {
        Fixture { request ->
            if (request.path == "/index.m3u8") Reply.text(playlist("#EXTINF:4,\ndata"))
            else Reply.text(playlist("#EXTINF:4,\nhttps://external.example/hidden.ts"))
        }.use { fixture ->
            val directory = staging()
            assertTrue(runCatching { download(fixture, directory) }.exceptionOrNull() is HlsOfflineException)
            assertFalse(File(directory, HlsOfflinePackage.MANIFEST_FILE_NAME).exists())
        }
    }

    @Test
    fun htmlAndXmlSuccessResponsesDoNotBecomeCompletedSegmentsOrMaps() {
        val documents = listOf(
            Reply.text("  <!DOCTYPE html><html><body>Login required</body></html>"),
            Reply.text("\uFEFF<?xml version=\"1.0\"?><Error>Access denied</Error>"),
            Reply.text("<Error><Code>AccessDenied</Code></Error>"),
            Reply(body = ByteArray(32), headers = mapOf("Content-Type" to "application/xhtml+xml; charset=utf-8")),
            Reply(body = ByteArray(32), headers = mapOf("Content-Type" to "text/html")),
        )
        for (document in documents) {
            for (map in listOf(false, true)) {
                Fixture { request ->
                    if (request.path == "/index.m3u8") Reply.text(playlist((if (map) "#EXT-X-MAP:URI=\"data\"\n" else "") + "#EXTINF:4,\ndata"))
                    else document
                }.use { fixture ->
                    val directory = staging()
                    assertTrue(runCatching { download(fixture, directory) }.exceptionOrNull() is HlsOfflineException)
                    assertFalse(File(directory, HlsOfflinePackage.MANIFEST_FILE_NAME).exists())
                }
            }
        }
    }

    @Test
    fun matchingHashesDoNotMakeCachedHtmlOrXmlPlayableInEitherVerificationMode() {
        Fixture { request -> if (request.path == "/index.m3u8") Reply.text(playlist("#EXTINF:4,\ndata")) else Reply(body = ByteArray(128) { 8 }) }.use { fixture ->
            for (document in listOf("<html>Login required</html>", "<?xml version=\"1.0\"?><Error>Denied</Error>")) {
                val directory = staging()
                download(fixture, directory)
                val invalidMedia = document.padEnd(128, ' ').toByteArray()
                File(directory, "segment-000000.bin").writeBytes(invalidMedia)
                val manifestFile = File(directory, HlsOfflinePackage.MANIFEST_FILE_NAME)
                val manifest = JSONObject(manifestFile.readText())
                val evidence = manifest.getJSONArray("files")
                for (index in 0 until evidence.length()) {
                    val entry = evidence.getJSONObject(index)
                    if (entry.getString("name") == "segment-000000.bin") {
                        entry.put("sha256", MessageDigest.getInstance("SHA-256").digest(invalidMedia).joinToString("") { "%02x".format(it.toInt() and 0xff) })
                    }
                }
                manifestFile.writeText(manifest.toString())
                assertNull(HlsOfflinePackage.verify(directory, fullHash = true))
                assertNull(HlsOfflinePackage.verify(directory, fullHash = false))
            }
        }
    }

    @Test
    fun crossOriginRedirectAndDescendantsStripEveryNonPublicHeader() {
        Fixture { request ->
            if (request.path == "/redirected.m3u8") Reply.text(playlist("#EXTINF:4,\ndata")) else Reply(body = "segment".toByteArray())
        }.use { destination ->
            Fixture { Reply(302, headers = mapOf("Location" to destination.url("/redirected.m3u8"))) }.use { origin ->
                downloader().download(origin.url("/index.m3u8"), mapOf("Authorization" to "secret", "Cookie" to "session=secret", "Referer" to "https://private.example/", "X-Api-Key" to "secret", "User-Agent" to "Fixture/1"), staging(), {}, { it() })
                assertEquals("secret", origin.requests.single().header("Authorization"))
                assertEquals(2, destination.requests.size)
                destination.requests.forEach { request ->
                    listOf("Authorization", "Cookie", "Referer", "X-Api-Key").forEach { assertNull(request.header(it)) }
                    assertEquals("Fixture/1", request.header("User-Agent"))
                }
            }
        }
    }

    @Test
    fun privateRootRedirectAndDescendantAreRejectedByProductionPolicy() {
        for (host in listOf("127.0.0.1", "127.1", "2130706433", "169.254.169.254", "10.0.0.1", "[::1]")) {
            assertTrue(runCatching { HlsOfflinePackageDownloader().download("http://$host/index.m3u8", emptyMap(), staging(), {}, { it() }) }.isFailure)
        }
        listOf(true, false).forEach { redirect ->
            val requests = mutableListOf<Request>()
            val transport = object : HlsOfflineTransport {
                override fun validate(url: HttpUrl) = PublicAddressPolicy.requireLiteralPublicOrHostname(url.host)
                override fun execute(request: Request): Response {
                    requests += request
                    return if (redirect) response(request, 302, "", mapOf("Location" to "http://169.254.169.254/key"))
                    else response(request, 200, playlist("#EXTINF:4,\nhttp://169.254.169.254/data"))
                }
            }
            assertTrue(runCatching { HlsOfflinePackageDownloader(transport).download("http://93.184.216.34/index.m3u8", emptyMap(), staging(), {}, { it() }) }.isFailure)
            assertEquals(1, requests.size)
        }
    }

    @Test
    fun httpsDowngradeAndRedirectLoopsAreRejectedBeforeTargetRequest() {
        val requests = mutableListOf<Request>()
        val transport = object : HlsOfflineTransport {
            override fun validate(url: HttpUrl) = PublicAddressPolicy.requireLiteralPublicOrHostname(url.host)
            override fun execute(request: Request): Response {
                requests += request
                return response(request, 302, "", mapOf("Location" to "http://93.184.216.34/index.m3u8"))
            }
        }
        assertTrue(runCatching { HlsOfflinePackageDownloader(transport).download("https://93.184.216.34/index.m3u8", emptyMap(), staging(), {}, { it() }) }.isFailure)
        assertEquals(1, requests.size)
        Fixture { Reply(302, headers = mapOf("Location" to "/index.m3u8")) }.use { fixture ->
            assertTrue(runCatching { download(fixture) }.isFailure)
            assertEquals(1, fixture.requests.size)
        }
    }

    @Test
    fun incompletePackageRestartsFromZeroAndVerifiedPackageReusesWithoutHttp() {
        Fixture { request -> if (request.path == "/index.m3u8") Reply.text(playlist("#EXTINF:4,\ndata")) else Reply(body = "complete-segment".toByteArray()) }.use { fixture ->
            val directory = staging().apply { mkdir() }
            File(directory, "segment-000000.bin").writeText("partial")
            File(directory, "complete.json").writeText("{truncated")
            val first = download(fixture, directory)
            assertEquals("complete-segment", File(directory, "segment-000000.bin").readText())
            assertTrue(fixture.requests.none { it.header("Range") != null })
            val requestCount = fixture.requests.size
            val second = download(fixture, directory)
            assertEquals(first.totalBytes, second.totalBytes)
            assertEquals(requestCount, fixture.requests.size)
        }
    }

    @Test
    fun fullyRenamedPackageRecoversWithoutHttpAndRequiresTheSameSourceIdentity() {
        Fixture { request -> if (request.path == "/index.m3u8") Reply.text(playlist("#EXTINF:4,\ndata")) else Reply(body = "complete-segment".toByteArray()) }.use { fixture ->
            val directory = staging()
            val first = download(fixture, directory)
            val published = File(directory.parentFile, "fixture.hls")
            assertTrue(directory.renameTo(published))
            val requests = fixture.requests.size
            val recovered = downloader().completedPackage(published, fixture.url("/index.m3u8"), emptyMap())
            assertNotNull(recovered)
            assertEquals(first.totalBytes, recovered!!.totalBytes)
            assertEquals(File(published, "index.m3u8"), recovered.playlistFile)
            assertNull(downloader().completedPackage(published, fixture.url("/different.m3u8"), emptyMap()))
            assertNull(downloader().completedPackage(published, fixture.url("/index.m3u8"), mapOf("Authorization" to "different-owner")))
            assertEquals(requests, fixture.requests.size)
        }
    }

    @Test
    fun hashCorruptionIsDetectedAndRedownloadedWhileCheapModeChecksStructure() {
        Fixture { request -> if (request.path == "/index.m3u8") Reply.text(playlist("#EXTINF:4,\ndata")) else Reply(body = "original".toByteArray()) }.use { fixture ->
            val directory = staging()
            download(fixture, directory)
            File(directory, "segment-000000.bin").writeText("tampered")
            assertNull(HlsOfflinePackage.verify(directory))
            assertNotNull(HlsOfflinePackage.verify(directory, fullHash = false))
            download(fixture, directory)
            assertEquals("original", File(directory, "segment-000000.bin").readText())
            assertEquals(4, fixture.requests.size)
            File(directory, "segment-000000.bin").delete()
            assertNull(HlsOfflinePackage.verify(directory, fullHash = false))
        }
    }

    @Test
    fun staleMutationAndVerificationCallbacksPropagateUnchanged() {
        Fixture { request -> if (request.path == "/index.m3u8") Reply.text(playlist("#EXTINF:4,\ndata")) else Reply(body = "original".toByteArray()) }.use { fixture ->
            val directory = staging()
            val stale = IllegalStateException("stale fixture generation")
            var mutations = 0
            val error = runCatching {
                downloader().download(fixture.url("/index.m3u8"), emptyMap(), directory, {}, { operation ->
                    mutations++
                    if (mutations == 3) throw stale
                    operation()
                })
            }.exceptionOrNull()
            assertSame(stale, error)
            assertEquals(3, mutations)
            assertEquals(0, File(directory, "segment-000000.bin").length())
            assertFalse(File(directory, "complete.json").exists())
            download(fixture, directory)
            var checks = 0
            assertSame(stale, runCatching { HlsOfflinePackage.verify(directory) { if (++checks == 3) throw stale } }.exceptionOrNull())
        }
    }

    @Test
    fun fileAndDirectorySymlinksNeverEscapeThePackage() {
        val outside = temporary.newFile("outside").apply { writeText("protected") }
        val directory = staging().apply { mkdir() }
        Files.createSymbolicLink(File(directory, "segment-000000.bin").toPath(), outside.toPath())
        assertEquals(0, HlsOfflinePackage.safeSize(directory))
        assertNull(HlsOfflinePackage.verify(directory))
        assertTrue(HlsOfflinePackage.safeDelete(directory))
        assertEquals("protected", outside.readText())
        val linked = staging()
        Files.createSymbolicLink(linked.toPath(), outside.parentFile.toPath())
        assertFalse(HlsOfflinePackage.safeDelete(linked))
        assertEquals(0, HlsOfflinePackage.safeSize(linked))
        assertTrue(outside.exists())
    }

    @Test
    fun nestedAndOversizedPlaylistsNeverComplete() {
        Fixture { request -> Reply.text("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\n${request.path}next\n") }.use { fixture ->
            assertTrue(runCatching { download(fixture) }.isFailure)
            assertEquals(4, fixture.requests.size)
        }
        Fixture { Reply.text("#EXTM3U\n#" + "a".repeat(HlsOfflinePlaylistParser.MAX_PLAYLIST_BYTES)) }.use { fixture ->
            assertTrue(runCatching { download(fixture) }.isFailure)
            assertEquals(1, fixture.requests.size)
        }
    }

    private fun staging() = File(temporary.newFolder().canonicalFile, "fixture.hls.part")
    private fun downloader() = HlsOfflinePackageDownloader(LiteralLoopbackTransport())
    private fun download(fixture: Fixture, directory: File = staging()) = downloader().download(fixture.url("/index.m3u8"), emptyMap(), directory, {}, { it() })

    private class LiteralLoopbackTransport : HlsOfflineTransport {
        private val client = OkHttpClient.Builder().proxy(Proxy.NO_PROXY).followRedirects(false).followSslRedirects(false).build()
        override fun validate(url: HttpUrl) {
            require(url.scheme == "http" && url.host == "127.0.0.1") { "Fixture transport only accepts literal IPv4 loopback" }
        }
        override fun execute(request: Request): Response {
            validate(request.url)
            return client.newCall(request).execute()
        }
    }

    private data class RecordedRequest(val path: String, val headers: Map<String, List<String>>) {
        fun header(name: String) = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value?.firstOrNull()
    }

    private data class Reply(val status: Int = 200, val body: ByteArray = ByteArray(0), val headers: Map<String, String> = emptyMap()) {
        companion object { fun text(body: String) = Reply(body = body.toByteArray()) }
    }

    private class Fixture(reply: (RecordedRequest) -> Reply) : Closeable {
        val requests = CopyOnWriteArrayList<RecordedRequest>()
        private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        private val activeSocket = AtomicReference<Socket?>()
        private val failure = AtomicReference<Throwable?>()
        @Volatile private var closed = false
        private val worker = Thread({
            var accepted = 0
            while (!closed) {
                try {
                    server.accept().use { socket ->
                        activeSocket.set(socket)
                        if (!closed) {
                            check(++accepted <= 128) { "HLS fixture request limit exceeded" }
                            socket.soTimeout = 5_000
                            val request = readRequest(socket.getInputStream().buffered())
                            requests += request
                            val response = reply(request)
                            val responseHeaders = buildString {
                                append("HTTP/1.1 ${response.status} Fixture\r\n")
                                append("Content-Length: ${response.body.size}\r\n")
                                append("Connection: close\r\n")
                                response.headers.forEach { (name, value) -> append("$name: $value\r\n") }
                                append("\r\n")
                            }
                            try {
                                socket.getOutputStream().apply {
                                    write(responseHeaders.toByteArray(Charsets.US_ASCII))
                                    write(response.body)
                                    flush()
                                }
                            } catch (_: IOException) {
                                // Oversized-response rejection can close the client before the body is written.
                            }
                        }
                    }
                } catch (error: IOException) {
                    if (!closed) failure.compareAndSet(null, error)
                    break
                } catch (error: Throwable) {
                    failure.compareAndSet(null, error)
                    break
                } finally {
                    runCatching { activeSocket.getAndSet(null)?.close() }
                }
            }
        }, "hls-offline-http-fixture").apply {
            isDaemon = true
            start()
        }

        private fun readRequest(input: InputStream): RecordedRequest {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            var remainingBytes = 64 * 1024
            fun line(): String {
                val bytes = ByteArrayOutputStream()
                while (true) {
                    check(System.nanoTime() < deadline) { "HLS fixture request deadline exceeded" }
                    check(remainingBytes-- > 0 && bytes.size() < 8192) { "HLS fixture request headers too large" }
                    val value = input.read()
                    check(value >= 0) { "Incomplete HLS fixture request" }
                    if (value == '\n'.code) return bytes.toString(Charsets.US_ASCII.name()).removeSuffix("\r")
                    bytes.write(value)
                }
            }
            val requestLine = line().split(' ')
            check(requestLine.size == 3 && requestLine[0] == "GET" && requestLine[2] in setOf("HTTP/1.0", "HTTP/1.1")) {
                "Unexpected HLS fixture request line"
            }
            val headers = linkedMapOf<String, MutableList<String>>()
            repeat(100) {
                val header = line()
                if (header.isEmpty()) return RecordedRequest(URI(requestLine[1]).path, headers)
                val separator = header.indexOf(':')
                check(separator > 0) { "Invalid HLS fixture request header" }
                headers.getOrPut(header.substring(0, separator)) { mutableListOf() }.add(header.substring(separator + 1).trim())
            }
            error("HLS fixture header count exceeded")
        }

        fun url(path: String) = "http://127.0.0.1:${server.localPort}$path"

        override fun close() {
            closed = true
            runCatching { server.close() }.onFailure { failure.compareAndSet(null, it) }
            runCatching { activeSocket.get()?.close() }.onFailure { failure.compareAndSet(null, it) }
            worker.join(2_000)
            check(!worker.isAlive) { "HLS fixture thread did not terminate" }
            failure.get()?.let { throw AssertionError("HLS fixture failed", it) }
        }
    }

    private companion object {
        fun playlist(body: String) = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:4\n$body\n#EXT-X-ENDLIST\n"
        fun response(request: Request, status: Int, body: String, headers: Map<String, String> = emptyMap()): Response = Response.Builder()
            .request(request).protocol(Protocol.HTTP_1_1).code(status).message("Fixture").body(body.toResponseBody())
            .apply { headers.forEach { (name, value) -> header(name, value) } }.build()
    }
}
