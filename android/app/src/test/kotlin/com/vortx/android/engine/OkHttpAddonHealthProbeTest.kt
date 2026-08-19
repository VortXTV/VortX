package com.vortx.android.engine

import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.Call
import okhttp3.Dns
import okhttp3.EventListener
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OkHttpAddonHealthProbeTest {
    private val servers = mutableListOf<TestHttpServer>()

    @After
    fun tearDown() {
        servers.forEach(TestHttpServer::close)
    }

    @Test
    fun `production probe admits only two cold DNS calls at once`() = runBlocking {
        val server = server { socket, _ -> socket.respond(204) }
        val twoDnsCallsEntered = CountDownLatch(2)
        val releaseDns = CountDownLatch(1)
        val dnsCalls = AtomicInteger()
        val activeDns = AtomicInteger()
        val maxActiveDns = AtomicInteger()
        val dns = dns { _ ->
            dnsCalls.incrementAndGet()
            val active = activeDns.incrementAndGet()
            maxActiveDns.accumulateAndGet(active, ::maxOf)
            twoDnsCallsEntered.countDown()
            try {
                check(releaseDns.await(2, TimeUnit.SECONDS)) { "DNS release timed out" }
                listOf(InetAddress.getLoopbackAddress())
            } finally {
                activeDns.decrementAndGet()
            }
        }
        val client = testClient(dns)
        val probe = OkHttpAddonHealthProbe(
            timeoutMillis = 5_000,
            publicClient = client,
            loopbackClient = client,
        )

        val results = listOf("one.test", "two.test", "three.test").map { host ->
            async(Dispatchers.Default) {
                probe.probe("http://$host:${server.port}/manifest.json".toHttpUrl())
            }
        }

        assertTrue("first two DNS calls did not enter", twoDnsCallsEntered.await(2, TimeUnit.SECONDS))
        Thread.sleep(100)
        assertEquals("third DNS lookup must wait for a production permit", 2, dnsCalls.get())
        assertEquals(2, maxActiveDns.get())

        releaseDns.countDown()
        assertEquals(listOf(204, 204, 204), results.awaitAll().map(AddonProbeResult::statusCode))
        assertEquals(3, dnsCalls.get())
    }

    @Test
    fun `health and manifest DNS share capacity without rejecting overlap`() = runBlocking {
        val server = server { socket, _ -> socket.respond(204) }
        val manifestEntered = CountDownLatch(1)
        val releaseManifest = CountDownLatch(1)
        val firstHealthEntered = CountDownLatch(1)
        val secondHealthEntered = CountDownLatch(1)
        val releaseFirstHealth = CountDownLatch(1)
        val healthDnsCalls = AtomicInteger()
        val manifestDns = DeadlinePublicDns(timeoutMs = 5_000) {
            manifestEntered.countDown()
            check(releaseManifest.await(3, TimeUnit.SECONDS)) { "manifest DNS release timed out" }
            listOf(InetAddress.getLoopbackAddress())
        }
        val healthDns = DeadlinePublicDns(timeoutMs = 5_000) {
            when (healthDnsCalls.incrementAndGet()) {
                1 -> {
                    firstHealthEntered.countDown()
                    check(releaseFirstHealth.await(3, TimeUnit.SECONDS)) { "health DNS release timed out" }
                }
                2 -> secondHealthEntered.countDown()
            }
            listOf(InetAddress.getLoopbackAddress())
        }
        val client = testClient(healthDns)
        val probe = OkHttpAddonHealthProbe(
            timeoutMillis = 5_000,
            publicClient = client,
            loopbackClient = client,
        )

        val manifestLookup = async(Dispatchers.IO) { manifestDns.lookup("manifest.test") }
        assertTrue(manifestEntered.await(2, TimeUnit.SECONDS))
        val firstHealth = async(Dispatchers.Default) {
            probe.probe("http://one.test:${server.port}/manifest.json".toHttpUrl())
        }
        assertTrue(firstHealthEntered.await(2, TimeUnit.SECONDS))
        val secondHealth = async(Dispatchers.Default) {
            probe.probe("http://two.test:${server.port}/manifest.json".toHttpUrl())
        }

        Thread.sleep(100)
        assertEquals(1, healthDnsCalls.get())
        assertFalse("overlap was rejected instead of waiting for shared DNS capacity", secondHealth.isCompleted)

        releaseManifest.countDown()
        assertTrue("waiting health lookup never inherited released capacity", secondHealthEntered.await(2, TimeUnit.SECONDS))
        releaseFirstHealth.countDown()

        assertEquals(1, manifestLookup.await().size)
        assertEquals(204, firstHealth.await().statusCode)
        assertEquals(204, secondHealth.await().statusCode)
    }

    @Test
    fun `cancel before DNS Callable start releases its lease exactly once`() {
        val releases = AtomicInteger()
        val lease = DnsAdmissionLease { releases.incrementAndGet() }

        assertTrue(lease.releasePending())
        assertFalse(lease.tryStart())
        assertFalse(lease.releasePending())
        assertFalse(lease.releaseRunning())
        assertEquals(1, releases.get())
    }

    @Test
    fun `running DNS lease is held through cancellation until resolver exits`() {
        val releases = AtomicInteger()
        val lease = DnsAdmissionLease { releases.incrementAndGet() }

        assertTrue(lease.tryStart())
        assertFalse(lease.releasePending())
        assertEquals(0, releases.get())
        assertTrue(lease.releaseRunning())
        assertFalse(lease.releaseRunning())
        assertEquals(1, releases.get())
    }

    @Test
    fun `timed out resolvers neither expose phantom capacity nor leak permits`() = runBlocking {
        val twoResolversEntered = CountDownLatch(2)
        val releaseResolvers = CountDownLatch(1)
        val blockedResolver: (String) -> List<InetAddress> = {
            twoResolversEntered.countDown()
            var released = false
            while (!released) {
                released = try {
                    releaseResolvers.await(50, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    false
                }
            }
            listOf(InetAddress.getLoopbackAddress())
        }
        val first = DeadlinePublicDns(timeoutMs = 150, resolver = blockedResolver)
        val second = DeadlinePublicDns(timeoutMs = 150, resolver = blockedResolver)

        val timedOut = listOf(
            async(Dispatchers.IO) { runCatching { first.lookup("one.test") } },
            async(Dispatchers.IO) { runCatching { second.lookup("two.test") } },
        )
        assertTrue(twoResolversEntered.await(2, TimeUnit.SECONDS))
        timedOut.awaitAll().forEach { result ->
            assertTrue(result.exceptionOrNull() is UnknownHostException)
        }

        val enteredWhileWorkersStillRunning = AtomicInteger()
        val whileBlocked = DeadlinePublicDns(timeoutMs = 150) {
            enteredWhileWorkersStillRunning.incrementAndGet()
            listOf(InetAddress.getLoopbackAddress())
        }
        val blockedResult = runCatching { whileBlocked.lookup("three.test") }
        assertTrue(blockedResult.exceptionOrNull() is UnknownHostException)
        assertEquals("timed-out workers released phantom capacity", 0, enteredWhileWorkersStillRunning.get())

        releaseResolvers.countDown()
        val afterExit = DeadlinePublicDns(timeoutMs = 2_000) {
            listOf(InetAddress.getLoopbackAddress())
        }
        assertEquals(1, afterExit.lookup("four.test").size)
    }

    @Test
    fun `production probe reports redirect without following it`() = runBlocking {
        val targetRequests = AtomicInteger()
        val server = server { socket, path ->
            when (path) {
                "/redirect" -> socket.respond(302, headers = mapOf("Location" to "/target"))
                else -> {
                    targetRequests.incrementAndGet()
                    socket.respond(204)
                }
            }
        }

        val result = OkHttpAddonHealthProbe(2_000).probe(server.url("/redirect").toHttpUrl())

        assertEquals(302, result.statusCode)
        assertEquals(0, targetRequests.get())
    }

    @Test
    fun `production probe rejects an oversized manifest body`() = runBlocking {
        val body = ByteArray(1024 * 1024 + 1) { 'x'.code.toByte() }
        val server = server { socket, _ -> socket.respond(200, body = body) }

        val result = OkHttpAddonHealthProbe(2_000).probe(server.url("/manifest.json").toHttpUrl())

        assertEquals(0, result.statusCode)
    }

    @Test
    fun `production DNS rejects private and rebinding answers before transport`() = runBlocking {
        val serverRequests = AtomicInteger()
        val server = server { socket, _ ->
            serverRequests.incrementAndGet()
            socket.respond(204)
        }
        val publicAddress = InetAddress.getByName("93.184.216.34")
        val privateAddress = InetAddress.getLoopbackAddress()
        val guardedDns = DeadlinePublicDns(timeoutMs = 1_000) { host ->
            val answers = when (host) {
                "private.test" -> listOf(privateAddress)
                else -> listOf(publicAddress, privateAddress)
            }
            if (answers.isEmpty() || answers.any(PublicAddressPolicy::isBlocked)) {
                throw UnknownHostException("Add-on host resolved to a non-public address")
            }
            answers
        }
        val client = testClient(guardedDns)
        val store = AddonHealthStore(
            probe = OkHttpAddonHealthProbe(
                timeoutMillis = 2_000,
                publicClient = client,
                loopbackClient = client,
            ),
            nowMillis = { 0L },
            timeoutMillis = 2_000,
        )
        val urls = listOf(
            "http://private.test:${server.port}/manifest.json",
            "http://rebind.test:${server.port}/manifest.json",
        )

        assertTrue(store.refresh(urls))

        assertEquals(0, serverRequests.get())
        urls.forEach { url ->
            val key = requireNotNull(AddonHealthStore.normalizeUrl(url))
            assertEquals(AddonHealth.Unreachable, store.status.value[key])
        }
    }

    @Test
    fun `strict loopback host uses the loopback client`() = runBlocking {
        val server = server { socket, _ -> socket.respond(204) }
        val publicDnsCalls = AtomicInteger()
        val publicClient = testClient(
            dns {
                publicDnsCalls.incrementAndGet()
                throw UnknownHostException("public DNS must not resolve strict loopback")
            },
        )
        val loopbackClient = testClient(Dns.SYSTEM)
        val probe = OkHttpAddonHealthProbe(
            timeoutMillis = 2_000,
            publicClient = publicClient,
            loopbackClient = loopbackClient,
        )

        val result = probe.probe(server.url("/manifest.json").toHttpUrl())

        assertEquals(204, result.statusCode)
        assertEquals(0, publicDnsCalls.get())
    }

    @Test
    fun `cancelling a production probe cancels its OkHttp call`() = runBlocking {
        val requestStarted = CountDownLatch(1)
        val releaseResponse = CountDownLatch(1)
        val server = server { socket, _ ->
            val output = socket.getOutputStream()
            output.write(
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                    .toByteArray(),
            )
            output.flush()
            requestStarted.countDown()
            releaseResponse.await(3, TimeUnit.SECONDS)
            runCatching {
                output.write("1\r\nx\r\n0\r\n\r\n".toByteArray())
                output.flush()
            }
        }
        val callCancelled = CountDownLatch(1)
        val loopbackClient = testClient(Dns.SYSTEM).newBuilder()
            .eventListenerFactory {
                object : EventListener() {
                    override fun canceled(call: Call) {
                        callCancelled.countDown()
                    }
                }
            }
            .build()
        val probe = OkHttpAddonHealthProbe(
            timeoutMillis = 5_000,
            publicClient = loopbackClient,
            loopbackClient = loopbackClient,
        )

        val job = launch(Dispatchers.Default) {
            probe.probe(server.url("/manifest.json").toHttpUrl())
        }
        assertTrue("server never received the request", requestStarted.await(2, TimeUnit.SECONDS))

        job.cancelAndJoin()

        assertTrue("OkHttp Call.cancel was not observed", callCancelled.await(2, TimeUnit.SECONDS))
        releaseResponse.countDown()
    }

    private fun server(handler: (Socket, String) -> Unit): TestHttpServer =
        TestHttpServer(handler).also(servers::add)

    private fun dns(resolve: (String) -> List<InetAddress>): Dns = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> = resolve(hostname)
    }

    private fun testClient(dns: Dns): OkHttpClient = OkHttpClient.Builder()
        .dns(dns)
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(2, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .callTimeout(5, TimeUnit.SECONDS)
        .build()

    private class TestHttpServer(private val handler: (Socket, String) -> Unit) : AutoCloseable {
        private val executor: ExecutorService = Executors.newCachedThreadPool { task ->
            Thread(task, "addon-health-test-http").apply { isDaemon = true }
        }
        private val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        private val acceptor = Thread({
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                executor.execute {
                    socket.use { connection ->
                        val reader = connection.getInputStream().bufferedReader()
                        val requestLine = reader.readLine().orEmpty()
                        val path = requestLine.split(' ').getOrNull(1).orEmpty()
                        while (reader.readLine()?.isNotEmpty() == true) Unit
                        handler(connection, path)
                    }
                }
            }
        }, "addon-health-test-accept").apply {
            isDaemon = true
            start()
        }

        val port: Int get() = server.localPort

        fun url(path: String): String = "http://127.0.0.1:$port$path"

        override fun close() {
            server.close()
            acceptor.join(1_000)
            executor.shutdownNow()
        }
    }

    private fun Socket.respond(
        code: Int,
        body: ByteArray = ByteArray(0),
        headers: Map<String, String> = emptyMap(),
    ) {
        val reason = when (code) {
            200 -> "OK"
            204 -> "No Content"
            302 -> "Found"
            else -> "Response"
        }
        val headerText = buildString {
            append("HTTP/1.1 $code $reason\r\n")
            headers.forEach { (name, value) -> append("$name: $value\r\n") }
            append("Content-Length: ${body.size}\r\n")
            append("Connection: close\r\n\r\n")
        }
        getOutputStream().use { output ->
            output.write(headerText.toByteArray())
            output.write(body)
        }
    }
}
