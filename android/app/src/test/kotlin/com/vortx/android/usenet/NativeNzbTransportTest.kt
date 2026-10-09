package com.vortx.android.usenet

import com.vortx.android.debrid.DebridAccountOwnerBinding
import com.vortx.android.debrid.DebridAccountOwnerState
import com.vortx.android.debrid.DebridCoordinator
import com.vortx.android.debrid.DebridKeyValueStore
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridResolver
import com.vortx.android.debrid.DebridStorageAvailability
import com.vortx.android.debrid.DebridStorageSnapshot
import com.vortx.android.debrid.LegacyOwnerReservation
import com.vortx.android.engine.VortxServerStartup
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class NativeNzbTransportTest {
    private val mirrors = listOf("https://one.invalid/nzb?token=SECRET", "https://two.invalid/nzb")
    private val servers = listOf("nntps://user:SECRET@one.invalid:563/4", "nntp://two.invalid:119/3")

    @Test fun `literal loopback only and mandatory cancellation selector capabilities`() {
        assertEquals("http://127.0.0.1:1234", NativeNzbTransport.localBase("http://127.0.0.1:1234/"))
        for (url in listOf("http://localhost:1234", "http://127.1:1234", "http://[::1]:1234", "https://127.0.0.1:1234",
            "http://127.0.0.1:1234/path", "http://u:p@127.0.0.1:1234", "http://127.0.0.1:1234?key=secret")) {
            assertThrows(NativeNzbTransport.Unavailable::class.java) { NativeNzbTransport.localBase(url) }
        }
        assertTrue(NativeNzbTransport.acceptsCapabilities(CAPABILITIES))
        assertFalse(NativeNzbTransport.acceptsCapabilities(JSONObject(CAPABILITIES).also { it.remove("operationCancellation") }.toString()))
        assertFalse(NativeNzbTransport.acceptsCapabilities(JSONObject(CAPABILITIES).put("selection", JSONObject()).toString()))
    }

    @Test fun `ordered arrays selectors and unique operation survive exactly and close retires only own ID`() = runBlocking {
        Fixture().use { fixture ->
            val posted = CopyOnWriteArrayList<JSONObject>()
            val canceled = CopyOnWriteArrayList<String>()
            val close = CountDownLatch(1)
            fixture.handle = { exchange ->
                when {
                    exchange.requestURI.path == "/nzb/capabilities" -> exchange.reply(200, CAPABILITIES)
                    exchange.requestURI.path == "/nzb/create" -> {
                        posted += JSONObject(exchange.requestBody.bufferedReader().readText())
                        exchange.reply(200, """{"key":"${"a".repeat(32)}"}""")
                    }
                    exchange.requestURI.path.endsWith("/cancel") -> { canceled += exchange.requestURI.path; exchange.reply(204); close.countDown() }
                    else -> error("Unexpected route")
                }
            }
            val result = fixture.transport().create(mirrors, servers, 3_000,
                NativeNzbTransport.Selection(0, "/S01E02/i", 1, 2)) { true }
            assertEquals(mirrors, posted.single().getJSONArray("nzbUrls").let { (0 until it.length()).map(it::getString) })
            assertEquals(servers, posted.single().getJSONArray("servers").let { (0 until it.length()).map(it::getString) })
            assertEquals(0, posted.single().getInt("fileIdx"))
            assertFalse(posted.single().has("fileIdxOrder"))
            assertEquals("/S01E02/i", posted.single().getString("fileMustInclude"))
            assertEquals(2, posted.single().getJSONObject("episode").getInt("episode"))
            assertTrue(posted.single().getString("operationId").matches(Regex("[0-9a-f-]{36}")))
            assertTrue(result.url.startsWith(fixture.base + "/nzb/stream?key="))
            result.lease.close(); result.lease.close()
            assertTrue(close.await(2, TimeUnit.SECONDS))
            assertEquals(listOf("/nzb/operations/${posted.single().getString("operationId")}/cancel"), canceled)
        }
    }

    @Test fun `unsupported artifact sends no credentials and redirects are never followed`() = runBlocking {
        Fixture().use { redirected -> Fixture().use { fixture ->
            var leaked = false
            redirected.handle = { exchange -> leaked = true; exchange.reply(200, CAPABILITIES) }
            fixture.handle = { exchange -> exchange.responseHeaders.add("Location", redirected.base + "/nzb/create"); exchange.reply(307) }
            try { fixture.transport().create(mirrors, servers, 2_000) { true }; fail("Redirect accepted") }
            catch (e: NativeNzbTransport.Unavailable) { assertFalse(e.toString().contains("SECRET")); assertNull(e.cause) }
            assertFalse(leaked)
            fixture.handle = { exchange -> assertEquals("/nzb/capabilities", exchange.requestURI.path); exchange.reply(200, "{}") }
            try { fixture.transport().create(mirrors, servers, 2_000) { true }; fail("Old artifact accepted") }
            catch (_: NativeNzbTransport.Unavailable) { }
        } }
    }

    @Test fun `cancellation before key retires precreated ID while successor remains independent`() = runBlocking {
        Fixture().use { fixture ->
            val started = CompletableDeferred<String>()
            val cancellation = CompletableDeferred<String>()
            val firstRelease = CountDownLatch(1)
            val requests = CopyOnWriteArrayList<String>()
            fixture.handle = { exchange ->
                when {
                    exchange.requestURI.path == "/nzb/capabilities" -> exchange.reply(200, CAPABILITIES)
                    exchange.requestURI.path == "/nzb/create" -> {
                        val id = JSONObject(exchange.requestBody.bufferedReader().readText()).getString("operationId")
                        requests += id
                        if (requests.size == 1) {
                            started.complete(id); firstRelease.await(4, TimeUnit.SECONDS)
                            runCatching { exchange.reply(200, """{"key":"${"b".repeat(32)}"}""") }
                        } else exchange.reply(200, """{"key":"${"c".repeat(32)}"}""")
                    }
                    exchange.requestURI.path.endsWith("/cancel") -> {
                        cancellation.complete(exchange.requestURI.path.split('/')[3]); exchange.reply(204)
                    }
                }
            }
            val transport = fixture.transport()
            val task = async {
                try { transport.create(mirrors, servers, 5_000) { true }; fail("Canceled create returned") }
                catch (_: CancellationException) { }
            }
            val old = started.await(); task.cancel(); task.join()
            assertEquals(old, withTimeout(2_000) { cancellation.await() })
            val next = transport.create(mirrors, servers, 2_000) { true }
            assertNotEquals(old, requests.last())
            firstRelease.countDown()
            next.lease.close()
        }
    }

    @Test fun `caller deadline cancels hung response body and does not expose response secret`() = runBlocking {
        Fixture().use { fixture ->
            val canceled = CompletableDeferred<Unit>()
            val release = CountDownLatch(1)
            fixture.handle = { exchange ->
                when {
                    exchange.requestURI.path == "/nzb/capabilities" -> exchange.reply(200, CAPABILITIES)
                    exchange.requestURI.path == "/nzb/create" -> {
                        exchange.sendResponseHeaders(200, 500)
                        exchange.responseBody.write("SECRET".toByteArray()); exchange.responseBody.flush()
                        release.await(2, TimeUnit.SECONDS); exchange.close()
                    }
                    exchange.requestURI.path.endsWith("/cancel") -> { exchange.reply(204); canceled.complete(Unit) }
                }
            }
            try { fixture.transport().create(mirrors, servers, 300) { true }; fail("Deadline ignored") }
            catch (_: NativeNzbTransport.Unavailable) { }
            withTimeout(2_000) { canceled.await() }
            release.countDown()
        }
    }

    @Test fun `local attempt timeout retires ID and falls through to the complete saved route`() = runBlocking {
        Fixture().use { fixture ->
            val canceled = CompletableDeferred<Unit>()
            val release = CountDownLatch(1)
            fixture.handle = { exchange ->
                when {
                    exchange.requestURI.path == "/nzb/capabilities" -> exchange.reply(200, CAPABILITIES)
                    exchange.requestURI.path == "/nzb/create" -> { release.await(3, TimeUnit.SECONDS); exchange.close() }
                    exchange.requestURI.path.endsWith("/cancel") -> { exchange.reply(204); canceled.complete(Unit) }
                }
            }
            val transport = fixture.transport()
            val saved = listOf("nntps://saved.invalid:563/5", "nntps://backup.invalid:563/6")
            var attempts = 0
            val result = NativeNzbRouting.resolve(mirrors, servers, saved, null, false, timeoutMs = 3_000, isCurrent = { true },
                local = { urls, providers ->
                    attempts++
                    if (attempts == 1) transport.create(urls, providers, 500) { true }
                    else { assertEquals(saved, providers); NativeNzbPlayback("saved", AutoCloseable {}) }
                }, torBox = { error("No cloud") })
            assertEquals("saved", result?.url); assertEquals(2, attempts)
            withTimeout(2_000) { canceled.await() }
            release.countDown(); result?.lease?.close()
            Unit
        }
    }

    @Test fun `create redirect cannot forward server credentials and failed cancellation retries exact ID`() = runBlocking {
        Fixture().use { recipient -> Fixture().use { fixture ->
            val cancellation = CompletableDeferred<Unit>()
            val canceledIds = CopyOnWriteArrayList<String>()
            var leaked = false
            recipient.handle = { exchange -> leaked = true; exchange.reply(200, "{}") }
            fixture.handle = { exchange ->
                when {
                    exchange.requestURI.path == "/nzb/capabilities" -> exchange.reply(200, CAPABILITIES)
                    exchange.requestURI.path == "/nzb/create" -> {
                        exchange.responseHeaders.add("Location", recipient.base + "/steal"); exchange.reply(307)
                    }
                    exchange.requestURI.path.endsWith("/cancel") -> {
                        canceledIds += exchange.requestURI.path
                        if (canceledIds.size == 1) exchange.reply(503)
                        else { exchange.reply(204); cancellation.complete(Unit) }
                    }
                }
            }
            try { fixture.transport().create(mirrors, servers, 2_000) { true }; fail("Redirect accepted") }
            catch (_: NativeNzbTransport.Unavailable) { }
            withTimeout(2_000) { cancellation.await() }
            assertFalse(leaked); assertEquals(2, canceledIds.size); assertEquals(canceledIds[0], canceledIds[1])
        } }
    }

    @Test fun `handed off lease outlives resolve job and prewarm but retires on captured playback authority`() = runBlocking {
        Fixture().use { fixture ->
            val pending = AtomicBoolean(true)
            val lifetime = AtomicBoolean(true)
            val afterHandoff = CompletableDeferred<Unit>()
            val canceled = CompletableDeferred<String>()
            val ids = CopyOnWriteArrayList<String>()
            fixture.handle = { exchange ->
                when {
                    exchange.requestURI.path == "/nzb/capabilities" -> exchange.reply(200, CAPABILITIES)
                    exchange.requestURI.path == "/nzb/create" -> {
                        ids += JSONObject(exchange.requestBody.bufferedReader().readText()).getString("operationId")
                        exchange.reply(200, """{"key":"${"d".repeat(32)}"}""")
                    }
                    exchange.requestURI.path.endsWith("/cancel") -> {
                        canceled.complete(exchange.requestURI.path.split('/')[3]); exchange.reply(204)
                    }
                }
            }
            // The launching coroutine ends; its Job/next source request must not retire an admitted player.
            val result = async {
                fixture.transport().create(mirrors, servers, 2_000, playbackIsCurrent = {
                    if (!pending.get()) afterHandoff.complete(Unit)
                    lifetime.get()
                }, isCurrent = pending::get)
            }.await()
            pending.set(false)
            withTimeout(2_000) { afterHandoff.await() }
            assertFalse(canceled.isCompleted)
            val next = fixture.transport().create(mirrors, servers, 2_000) { true }
            lifetime.set(false)
            assertEquals(ids.first(), withTimeout(2_000) { canceled.await() })
            assertNotEquals(ids.first(), ids.last())
            result.lease.close() // idempotent after retirement
            next.lease.close()
        }
    }

    @Test fun `production coordinator routes plural addon source through native transport and fences account lifetime`() = runBlocking {
        Fixture().use { fixture ->
            val state = AtomicReference<DebridAccountOwnerState>(DebridAccountOwnerState.Account("fixture", generation = 1))
            val keys = DebridKeys(object : DebridKeyValueStore {
                override fun snapshot(vararg keys: String) = DebridStorageSnapshot(DebridStorageAvailability.AVAILABLE, keys.associateWith { null })
                override fun write(values: Map<String, String?>) = true
                override fun legacyOwnerReservation() = LegacyOwnerReservation.Missing
                override fun claimLegacyOwner(owner: String) = true
            }, DebridAccountOwnerBinding().apply { bind { state.get() } })
            val canceled = CompletableDeferred<Unit>()
            val posts = AtomicInteger()
            fixture.handle = { exchange ->
                when {
                    exchange.requestURI.path == "/nzb/capabilities" -> exchange.reply(200, CAPABILITIES)
                    exchange.requestURI.path == "/nzb/create" -> {
                        val body = JSONObject(exchange.requestBody.bufferedReader().readText())
                        assertEquals(2, body.getJSONArray("servers").length())
                        assertEquals(2, body.getJSONArray("nzbUrls").length())
                        posts.incrementAndGet(); exchange.reply(200, """{"key":"${"e".repeat(32)}"}""")
                    }
                    exchange.requestURI.path.endsWith("/cancel") -> { exchange.reply(204); canceled.complete(Unit) }
                }
            }
            val candidate = DebridCoordinator.DebridCandidate(nzbUrls = mirrors, usenetServers = servers)
            val native = DebridCoordinator(DebridResolver(keys), keys, nativeUsenetEnabled = true, nzbTransport = fixture.transport())
            val result = requireNotNull(native.resolvePlaybackRef(candidate))
            assertTrue(result.isNativeFile); assertNotNull(result.progressiveSession); assertEquals(1, posts.get())
            state.set(DebridAccountOwnerState.Account("fixture", generation = 2)) // same account ABA retires old operation
            withTimeout(2_000) { canceled.await() }
            result.progressiveSession?.close()
            val legacy = DebridCoordinator(DebridResolver(keys), keys, nativeUsenetEnabled = false, nzbTransport = fixture.transport())
            assertNull(legacy.resolvePlaybackRef(candidate))
            assertEquals(1, posts.get()) // explicit legacy never secretly invokes the native transport
        }
    }

    @Test fun `blocked shared startup does not hold timed out or canceled waiters and successor reuses it`() = runBlocking {
        Fixture().use { fixture ->
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val startup = VortxServerStartup(scope)
            val entered = CompletableDeferred<Unit>()
            val release = CountDownLatch(1)
            val starts = AtomicInteger()
            val posts = AtomicInteger()
            fixture.handle = { exchange ->
                when {
                    exchange.requestURI.path == "/nzb/capabilities" -> exchange.reply(200, CAPABILITIES)
                    exchange.requestURI.path == "/nzb/create" -> {
                        posts.incrementAndGet(); exchange.reply(200, """{"key":"${"f".repeat(32)}"}""")
                    }
                    exchange.requestURI.path.endsWith("/cancel") -> exchange.reply(204)
                }
            }
            val base: suspend () -> String? = {
                startup.await(0, { 0 }) {
                    starts.incrementAndGet(); entered.complete(Unit)
                    check(release.await(5, TimeUnit.SECONDS)); fixture.base
                }
            }
            try {
                val timeout = async {
                    try { fixture.transport(base).create(mirrors, servers, 300) { true }; fail("Startup deadline ignored") }
                    catch (_: NativeNzbTransport.Unavailable) { }
                }
                withTimeout(2_000) { entered.await(); timeout.await() }
                assertEquals(1, starts.get()); assertEquals(0, posts.get())
                val secondEntered = CompletableDeferred<Unit>()
                val canceled = async {
                    fixture.transport { secondEntered.complete(Unit); base() }.create(mirrors, servers, 4_000) { true }
                }
                withTimeout(2_000) { secondEntered.await(); canceled.cancel(); canceled.join() }
                assertEquals(1, starts.get()); assertEquals(0, posts.get())
                val successor = async { fixture.transport(base).create(mirrors, servers, 3_000) { true } }
                release.countDown()
                val result = withTimeout(2_000) { successor.await() }
                assertEquals(1, starts.get()); assertEquals(1, posts.get())
                result.lease.close()
            } finally { release.countDown(); scope.cancel() }
        }
    }

    @Test fun `startup generation rejects stale result and failed start retries only after cooldown`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val now = AtomicLong(0)
        val generation = AtomicLong(0)
        val startup = VortxServerStartup(scope, now::get)
        val entered = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        val starts = AtomicInteger()
        try {
            val old = async { startup.await(0, generation::get) {
                starts.incrementAndGet(); entered.complete(Unit); check(release.await(5, TimeUnit.SECONDS)); "old"
            } }
            withTimeout(2_000) { entered.await() }
            generation.set(1); release.countDown()
            assertNull(withTimeout(2_000) { old.await() })
            assertEquals("new", startup.await(1, generation::get) { starts.incrementAndGet(); "new" })
            assertEquals("new", startup.await(1, generation::get) { error("Successful startup must be reused") })
            assertEquals(2, starts.get())
            generation.set(2)
            assertNull(startup.await(2, generation::get) { starts.incrementAndGet(); null })
            assertNull(startup.await(2, generation::get) { error("Failed start must not tight-loop") })
            now.set(1_000_000_000)
            assertEquals("retry", startup.await(2, generation::get) { starts.incrementAndGet(); "retry" })
            assertEquals(4, starts.get())
        } finally { release.countDown(); scope.cancel() }
    }

    private class Fixture : AutoCloseable {
        private val workers = Executors.newCachedThreadPool()
        private val server = ServerSocket().apply { bind(InetSocketAddress("127.0.0.1", 0)) }
        private val sockets = CopyOnWriteArrayList<Socket>()
        private val failure = AtomicReference<AssertionError?>()
        private val client = OkHttpClient()
        val base = "http://127.0.0.1:${server.localPort}"
        @Volatile var handle: (HttpExchange) -> Unit = { it.reply(500) }
        init {
            workers.execute {
                while (!server.isClosed) {
                    val socket = try { server.accept() } catch (_: Exception) { break }
                    sockets += socket
                    workers.execute {
                        try { socket.use { it.soTimeout = 5_000; handle(HttpExchange(it)) } }
                        catch (error: AssertionError) { failure.compareAndSet(null, error) }
                        catch (_: Exception) { /* A canceled HTTP client may close during fixture response. */ }
                        finally { sockets -= socket }
                    }
                }
            }
        }
        fun transport(serverBase: suspend () -> String? = { base }) = NativeNzbTransport(serverBase, client)
        override fun close() {
            server.close(); sockets.forEach { runCatching { it.close() } }; workers.shutdownNow()
            client.dispatcher.executorService.shutdownNow(); client.connectionPool.evictAll()
            assertTrue("Fixture workers did not stop", workers.awaitTermination(2, TimeUnit.SECONDS))
            failure.get()?.let { throw it }
        }
    }

    /** Bounded one-request HTTP/1.1 fixture; no JDK HTTP-server module in Android's test classpath. */
    private class HttpExchange(private val socket: Socket) {
        val requestURI: URI
        val requestBody: ByteArrayInputStream
        val responseBody: OutputStream get() = socket.getOutputStream()
        val responseHeaders = Headers()
        init {
            val input = socket.getInputStream()
            fun line(): String {
                val bytes = ByteArrayOutputStream()
                while (true) {
                    val byte = input.read()
                    require(byte >= 0) { "Fixture request ended" }
                    if (byte == 10) break
                    require(bytes.size() < 8192) { "Fixture request line too long" }
                    if (byte != 13) bytes.write(byte)
                }
                return bytes.toString("US-ASCII")
            }
            val request = line().split(' ')
            require(request.size == 3 && request[0] in listOf("GET", "POST"))
            requestURI = URI(request[1])
            var length = 0
            var headers = 0
            while (true) {
                val header = line()
                if (header.isEmpty()) break
                require(++headers <= 64) { "Fixture request has too many headers" }
                if (header.startsWith("Content-Length:", ignoreCase = true)) length = header.substringAfter(':').trim().toInt()
                require(!header.startsWith("Transfer-Encoding:", ignoreCase = true)) { "Fixture requires exact request length" }
            }
            require(length in 0..65_536) { "Fixture request body too large" }
            val body = ByteArray(length)
            var offset = 0
            while (offset < length) {
                val count = input.read(body, offset, length - offset)
                require(count > 0) { "Fixture request body ended" }; offset += count
            }
            requestBody = ByteArrayInputStream(body)
        }
        fun sendResponseHeaders(status: Int, length: Long) {
            val raw = buildString {
                append("HTTP/1.1 $status Fixture\r\nConnection: close\r\nContent-Length: ${length.coerceAtLeast(0)}\r\n")
                responseHeaders.values.forEach { (name, value) -> append("$name: $value\r\n") }
                append("\r\n")
            }
            responseBody.write(raw.toByteArray(Charsets.US_ASCII)); responseBody.flush()
        }
        fun close() = socket.close()
        class Headers {
            val values = mutableListOf<Pair<String, String>>()
            fun add(name: String, value: String) { values += name to value }
        }
    }

    companion object {
        internal const val CAPABILITIES = """{"version":1,"raw":true,"multipartYenc":true,"checksumsRequired":true,"archives":["rar4-store","rar5-store","7z-copy"],"operationCancellation":true,"operationIdFormat":"uuid","selection":{"fileIdx":true,"fileMustInclude":true,"episode":true,"fileIdxOrder":"nzb-media-or-archive-entry-order","regexSyntax":"bare-or-js-ims"}}"""
        private fun HttpExchange.reply(status: Int, body: String = "") {
            val bytes = body.toByteArray()
            sendResponseHeaders(status, if (status == 204) -1 else bytes.size.toLong())
            responseBody.use { if (status != 204) it.write(bytes) }
        }
    }
}
