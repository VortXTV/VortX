package com.vortx.android.imports

import com.vortx.android.engine.PublicAddressPolicy
import com.vortx.android.engine.buildAddonManifestClient
import kotlinx.coroutines.CancellationException
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.UnknownHostException
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread
import okhttp3.Request
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ImportTextFetcherTest {
    private data class Call(val url: String, val headers: Map<String, String>, val timeout: Long)
    private class Fixture(vararg responses: ImportTextResponse) {
        val calls = mutableListOf<Call>()
        val remaining = responses.toMutableList()
        val transport = ImportTextTransport { url, headers, timeout ->
            calls += Call(url.toString(), headers.toMap(), timeout)
            remaining.removeAt(0)
        }
        fun fetcher(validator: (String) -> Unit = PublicAddressPolicy::requireLiteralPublicOrHostname) =
            ImportTextFetcher("fixture", hostValidator = validator, transport = transport)
    }
    private fun ok(text: String = "list") = ImportTextResponse(200, body = text.toByteArray())
    private fun redirect(url: String) = ImportTextResponse(302, location = url)

    @Test fun privateInitialHostsNeverReachTransport() {
        val f = Fixture(ok())
        for (host in listOf("127.0.0.1", "2130706433", "10.1.2.3", "169.254.169.254", "[::1]")) {
            assertNull(f.fetcher().fetch("http://$host/list"))
        }
        assertTrue(f.calls.isEmpty())
    }
    @Test fun privateRedirectNeverReceivesARequest() {
        val f = Fixture(redirect("http://127.0.0.1/private"), ok())
        assertNull(f.fetcher().fetch("https://public.test/list"))
        assertEquals(1, f.calls.size)
    }
    @Test fun hostnameAdmissionRunsAgainOnEveryRedirect() {
        val f = Fixture(redirect("https://internal.test/private"), ok())
        val checked = mutableListOf<String>()
        assertNull(f.fetcher { checked += it; require(it != "internal.test") }.fetch("https://public.test/list"))
        assertEquals(listOf("public.test", "internal.test"), checked)
        assertEquals(1, f.calls.size)
    }
    @Test fun relativeRedirectRetainsSameOriginHeaders() {
        val f = Fixture(redirect("/v2/list"), ok())
        assertEquals("list", f.fetcher().fetch("https://public.test/list", mapOf("trakt-api-key" to "fixture")))
        assertEquals("https://public.test/v2/list", f.calls.last().url)
        assertEquals("fixture", f.calls.last().headers["trakt-api-key"])
    }
    @Test fun crossOriginHeadersAreRemovedAndNeverReattached() {
        val f = Fixture(redirect("https://other.test/list"), redirect("https://public.test/final"), ok())
        assertEquals("list", f.fetcher().fetch("https://public.test/list", mapOf("Authorization" to "fixture")))
        assertEquals(mapOf("Authorization" to "fixture"), f.calls.first().headers)
        assertTrue(f.calls.drop(1).all { it.headers.isEmpty() })
    }
    @Test fun changedPortIsAnotherOrigin() {
        val f = Fixture(redirect("https://public.test:444/list"), ok())
        assertEquals("list", f.fetcher().fetch("https://public.test/list", mapOf("trakt-api-key" to "fixture")))
        assertTrue(f.calls.last().headers.isEmpty())
    }
    @Test fun httpsDowngradeNeverReceivesARequest() {
        val f = Fixture(redirect("http://public.test/list"), ok())
        assertNull(f.fetcher().fetch("https://public.test/list"))
        assertEquals(1, f.calls.size)
    }
    @Test fun authenticatedQueryRequestDoesNotFollowAnyRedirect() {
        val f = Fixture(redirect("/v2/items"), ok())
        assertNull(f.fetcher().fetch("https://api.mdblist.com/lists/u/s/items?apikey=fixture", followRedirects = false))
        assertEquals(1, f.calls.size)
    }
    @Test fun redirectLoopsStopAtFiveHops() {
        val f = Fixture(*Array(7) { redirect("/loop") })
        assertNull(f.fetcher().fetch("https://public.test/list"))
        assertEquals(6, f.calls.size)
    }
    @Test fun userInfoAndUnsupportedSchemesAreRejected() {
        val f = Fixture(ok())
        for (url in listOf("https://u:p@public.test/list", "file:///etc/passwd", "ftp://public.test/list")) {
            assertNull(f.fetcher().fetch(url))
        }
        assertTrue(f.calls.isEmpty())
        val redirect = Fixture(redirect("https://u:p@public.test/list"), ok())
        assertNull(redirect.fetcher().fetch("https://public.test/list"))
        assertEquals(1, redirect.calls.size)
    }
    @Test fun allHopsShareOneTimeoutBudget() {
        val f = Fixture(redirect("/next"), ok())
        var now = 0L
        val fetcher = ImportTextFetcher("fixture", transport = f.transport, nanoTime = { now.also { now += 10_000_000_000L } })
        assertNull(fetcher.fetch("https://public.test/list"))
        assertEquals(1, f.calls.size)
        assertEquals(10_000L, f.calls.single().timeout)
    }
    @Test fun failuresAreSoftButCancellationSurvives() {
        val error = ImportTextTransport { _, _, _ -> throw IOException("fixture") }
        assertNull(ImportTextFetcher("fixture", transport = error).fetch("https://public.test/list"))
        val cancel = ImportTextTransport { _, _, _ -> throw CancellationException("fixture") }
        try {
            ImportTextFetcher("fixture", transport = cancel).fetch("https://public.test/list")
            fail("cancellation must propagate")
        } catch (_: CancellationException) { }
    }
    @Test fun responseLimitCountsUtf8Bytes() {
        val cap = ImportTextFetcher.MAX_BYTES
        val exact = ByteArray(cap) { 'a'.code.toByte() }
        assertEquals(cap, readLimitedImportBytes(ByteArrayInputStream(exact))!!.size)
        assertNull(readLimitedImportBytes(ByteArrayInputStream(ByteArray(cap + 1))))
        val f = Fixture(ImportTextResponse(200, body = ByteArray(cap + 1)))
        assertNull(f.fetcher().fetch("https://public.test/list"))
    }
    @Test fun nonSuccessAndMissingRedirectLocationsFailSoft() {
        assertNull(Fixture(ImportTextResponse(404)).fetcher().fetch("https://public.test/list"))
        assertNull(Fixture(ImportTextResponse(302)).fetcher().fetch("https://public.test/list"))
    }
    @Test fun laterHopDnsUsesRemainingBudgetAndKeepsTheBasePool() {
        val base = buildAddonManifestClient(20_000)
        val entered = CountDownLatch(1)
        val requestClient = importTextRequestClient(base, 100) {
            entered.countDown()
            Thread.sleep(1_500)
            listOf(InetAddress.getByAddress(byteArrayOf(93, 184.toByte(), 216.toByte(), 34)))
        }
        assertSame(base.connectionPool, requestClient.connectionPool)
        val started = System.nanoTime()
        val failure = runCatching { requestClient.dns.lookup("fixture.test") }.exceptionOrNull()
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        assertTrue(failure is UnknownHostException)
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 500)
    }
    @Test fun cancellationAfterFirstResponseDoesNotFollowItsRedirect() {
        val f = Fixture(redirect("/next"), ok())
        var checks = 0
        try {
            f.fetcher().fetch("https://public.test/list", checkActive = {
                checks += 1
                if (checks == 2) throw CancellationException("fixture")
            })
            fail("cancellation must propagate")
        } catch (_: CancellationException) { }
        assertEquals(1, f.calls.size)
    }
    @Test fun deadlineDifferencesKeepTheSameDnsPolicyButDifferentResolversDoNot() {
        val base = buildAddonManifestClient(20_000)
        val first = importTextRequestClient(base, 1_000).dns
        val second = importTextRequestClient(base, 2_000).dns
        assertEquals(first, second)
        assertEquals(first.hashCode(), second.hashCode())
        val otherPolicy = importTextRequestClient(base, 2_000) { emptyList() }.dns
        assertNotEquals(first, otherPolicy)
    }
    @Test fun sameOriginRequestsWithDifferentDeadlinesReuseAnAdmittedSocket() {
        // Disposable loopback server only. Production's default public resolver is replaced solely
        // for this transport/pool fixture; no public provider, credential or app endpoint is used.
        val loopback = InetAddress.getLoopbackAddress()
        val server = ServerSocket(0, 5, loopback)
        val ports = Collections.synchronizedList(mutableListOf<Int>())
        val sockets = Collections.synchronizedList(mutableListOf<Socket>())
        val acceptor = thread(isDaemon = true) {
            try {
                while (!server.isClosed) {
                    val socket = server.accept()
                    sockets.add(socket)
                    thread(isDaemon = true) connection@ {
                        try {
                            socket.use {
                                socket.soTimeout = 2_000
                                val reader = socket.getInputStream().bufferedReader()
                                val output = socket.getOutputStream()
                                while (reader.readLine() != null) {
                                    while (true) {
                                        val line = reader.readLine() ?: return@connection
                                        if (line.isEmpty()) break
                                    }
                                    ports.add(socket.port)
                                    output.write("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\nlist".toByteArray())
                                    output.flush()
                                }
                            }
                        } catch (_: IOException) { }
                    }
                }
            } catch (_: IOException) { }
        }
        val base = buildAddonManifestClient(20_000)
        val resolve: (String) -> List<InetAddress> = { listOf(loopback) }
        try {
            for (deadline in listOf(2_000L, 1_000L)) {
                val client = importTextRequestClient(base, deadline, resolve)
                val request = Request.Builder().url("http://fixture.test:${server.localPort}/list").build()
                client.newCall(request).execute().use { response ->
                    assertEquals(200, response.code)
                    assertEquals("list", response.body!!.string())
                }
            }
            assertEquals(2, ports.size)
            assertEquals("Both requests must use the same client TCP port", ports[0], ports[1])
        } finally {
            base.connectionPool.evictAll()
            server.close()
            sockets.toList().forEach { it.close() }
            acceptor.join(1_000)
        }
    }
}
