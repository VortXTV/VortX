package com.vortx.android.engine

import com.vortx.android.integrations.CredentialMutationCoordinator
import com.vortx.android.integrations.IntegrationsHttp
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderAdmission
import com.vortx.android.integrations.NativeProviderCredentials
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.integrations.NativeProviderVault
import com.vortx.android.integrations.ProviderMirrorResponse
import com.vortx.android.integrations.ProviderMirrorResult
import com.vortx.android.integrations.ProviderMirrorTransport
import com.vortx.android.integrations.result
import com.vortx.android.security.AccountFileProviderWriters
import com.vortx.android.sync.SessionOperationCoordinator
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeout
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okio.Timeout
import org.junit.Assert.*
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.lang.reflect.InvocationTargetException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn

/** Real transport and original native Session, synthetic provider vault and manager owner. */
internal object ProviderMirrorTransportJniFixture {
    private const val TIMEOUT_MS = 5_000
    private const val BODY = """{"fixture":true}"""

    suspend fun refusedAtInterceptor(session: VortxNativeSession) {
        Loopback().use { loopback ->
            withCredential(session) { fixture ->
                val mountChecks = AtomicInteger()
                val materialChecks = AtomicInteger()
                val origin = fixture.origin { action -> mountChecks.incrementAndGet() == 1 && action() }
                val outcome = fixture.post(origin, loopback.url) { materialChecks.incrementAndGet(); true }
                assertSame(ProviderMirrorResponse.Refused, outcome)
                assertEquals(1, fixture.permits.get())
                assertEquals(1, materialChecks.get())
                assertEquals(2, mountChecks.get())
                loopback.assertNoConnection()
                assertWriterReleased()
            }
        }
    }

    suspend fun cancelsAfterStart(session: VortxNativeSession) = coroutineScope {
        for (retireManager in listOf(false, true)) Loopback().use { loopback ->
            withCredential(session) { fixture ->
                val materialChecks = AtomicInteger()
                val pending = async(Dispatchers.IO) {
                    fixture.post(fixture.origin(), loopback.url) { materialChecks.incrementAndGet(); true }
                }
                try {
                    loopback.accept().use { peer ->
                        assertEquals("POST /fresh HTTP/1.1", peer.requestLine)
                        assertEquals(BODY, peer.body)
                        peer.beginPartialResponse()
                        assertEquals(1, materialChecks.get())
                        assertWriterHeld()
                        if (retireManager) fixture.manager.invalidate {}
                        else assertTrue(NativeProviderAccess.edit(mapOf("simklAccess" to "replacement", "simklExpiry" to "0")))
                        assertTrue("Prepared socket stayed open after retirement", peer.awaitClientClose())
                        val result = withTimeout(TIMEOUT_MS.toLong()) { pending.await() }
                        assertEquals(ProviderMirrorResponse.Started(IntegrationsHttp.Response(0, "")), result)
                        assertEquals(ProviderMirrorResult.ATTEMPTED_FAILURE, result.result())
                    }
                    loopback.assertNoConnection()
                    assertWriterReleased()
                } finally { pending.cancelAndJoin() }
            }
        }
    }

    suspend fun onePreparedCall(session: VortxNativeSession) = coroutineScope {
        for (status in listOf(307, 503, 0, 200)) Loopback().use { loopback ->
            withCredential(session) { fixture ->
                val materialChecks = AtomicInteger()
                val pending = async(Dispatchers.IO) {
                    fixture.post(fixture.origin(), loopback.url) { materialChecks.incrementAndGet(); true }
                }
                try {
                    loopback.accept().use { peer ->
                        assertEquals("POST /fresh HTTP/1.1", peer.requestLine)
                        assertEquals(BODY, peer.body)
                        when (status) {
                            307 -> peer.respond("307 Temporary Redirect", "Location: ${loopback.url.replace("/fresh", "/redirect")}\r\n")
                            503 -> peer.respond("503 Service Unavailable", "Retry-After: 0\r\n")
                            200 -> peer.respond("200 OK", "")
                            // A dropped connection after the title bytes were accepted is still an attempted status 0.
                            else -> Unit
                        }
                    }
                    val outcome = withTimeout(TIMEOUT_MS.toLong()) { pending.await() }
                    assertEquals(ProviderMirrorResponse.Started(IntegrationsHttp.Response(status, "")), outcome)
                    assertEquals(if (status == 200) ProviderMirrorResult.SUCCEEDED else ProviderMirrorResult.ATTEMPTED_FAILURE,
                        outcome.result())
                    assertEquals(1, materialChecks.get())
                    loopback.assertNoConnection()
                    assertWriterReleased()
                } finally { pending.cancelAndJoin() }
            }
        }
    }

    suspend fun holdsWriterThroughCallback() = coroutineScope {
        val call = DelayedCallbackCall()
        val worker = async(Dispatchers.IO) {
            AccountFileProviderWriters.withEffectfulWriter<IntegrationsHttp.Response?>(null) {
                invokeActualCallbackDrain(call)
            }
        }
        try {
            withTimeout(TIMEOUT_MS.toLong()) { call.submitted.await() }
            worker.cancel()
            withTimeout(TIMEOUT_MS.toLong()) { call.canceled.await() }
            assertFalse("The callback has not delivered its terminal signal", worker.isCompleted)
            assertWriterHeld()
        } finally {
            worker.cancel()
            call.finish()
            worker.join()
        }
        assertTrue(worker.isCancelled)
        assertWriterReleased()
    }

    // No test-only production visibility or timing hook. Invoke the same private suspend
    // callback driver that post() uses, with a deterministic Call that can delay its terminal callback.
    private suspend fun invokeActualCallbackDrain(call: Call): IntegrationsHttp.Response =
        suspendCoroutineUninterceptedOrReturn { continuation ->
            val method = ProviderMirrorTransport::class.java.getDeclaredMethod("awaitDrained", Call::class.java, Continuation::class.java)
            method.isAccessible = true
            try { method.invoke(ProviderMirrorTransport, call, continuation) }
            catch (failure: InvocationTargetException) { throw failure.targetException }
        }

    private class DelayedCallbackCall : Call by OkHttpClient().newCall(
        Request.Builder().url("http://127.0.0.1/").build()
    ) {
        val submitted = CompletableDeferred<Unit>()
        val canceled = CompletableDeferred<Unit>()
        private val finished = AtomicBoolean(false)
        private val callback = AtomicReference<Callback?>()
        override fun execute(): Response = error("Fixture expects the actual asynchronous callback path")
        override fun enqueue(responseCallback: Callback) {
            check(callback.compareAndSet(null, responseCallback))
            submitted.complete(Unit)
            if (finished.get()) deliver()
        }
        override fun cancel() { canceled.complete(Unit) }
        override fun isExecuted(): Boolean = submitted.isCompleted
        override fun isCanceled(): Boolean = canceled.isCompleted
        override fun timeout(): Timeout = Timeout.NONE
        override fun clone(): Call = DelayedCallbackCall()
        fun finish() { finished.set(true); deliver() }
        private fun deliver() { callback.getAndSet(null)?.onFailure(this, IOException("Synthetic terminal callback")) }
    }

    private class CredentialFixture(private val session: VortxNativeSession) {
        private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000321", 1)
        val manager = SessionOperationCoordinator()
        val permits = AtomicInteger()
        private val generation = manager.snapshot { it }
        private val owner = session.read().owner
        private val operation: CredentialMutationCoordinator.Operation

        init {
            NativeProviderAccess.bind(NativeProviderVault(NativeProviderTestStore()), object : NativeProviderAdmission {
                override fun <T> withCurrent(expected: SessionOwnerSnapshot.Account?, action: (SessionOwnerSnapshot.Account) -> T): T? =
                    manager.snapshot { current ->
                        if (current == generation && (expected == null || expected == account)) action(account) else null
                    }
            }) {}
            try {
                assertTrue(NativeProviderAccess.edit(mapOf("simklAccess" to "fixture-only", "simklExpiry" to "0")))
                operation = checkNotNull(CredentialMutationCoordinator(NativeProviderCredentials.GROUPS[1])
                    .snapshotForOwner(account) { true }).operation
            } catch (failure: Throwable) {
                NativeProviderAccess.unbindForTest()
                throw failure
            }
        }

        fun origin(mount: (() -> Boolean) -> Boolean = { it() }) =
            NativeLibraryMirrorOrigin(session, owner, account,
                { action -> manager.snapshot { it == generation && action() } }, mount) {
                manager.acquireSessionCallPermit(generation) { true }?.also { permits.incrementAndGet() }
            }

        suspend fun post(origin: NativeLibraryMirrorOrigin, url: String, matches: () -> Boolean): ProviderMirrorResponse =
            AccountFileProviderWriters.withEffectfulWriter<ProviderMirrorResponse>(ProviderMirrorResponse.Refused) {
                ProviderMirrorTransport.post(origin, operation, matches, url, emptyMap(), BODY)
            }
    }

    private suspend fun <T> withCredential(session: VortxNativeSession, work: suspend (CredentialFixture) -> T): T {
        val fixture = CredentialFixture(session)
        return try { work(fixture) } finally { NativeProviderAccess.unbindForTest() }
    }

    private fun assertWriterHeld() {
        val unexpected = AccountFileProviderWriters.tryReserve()
        if (unexpected != null) AccountFileProviderWriters.release(unexpected)
        assertNull("Restore must wait for the real callback drain", unexpected)
    }

    private fun assertWriterReleased() {
        val reservation = checkNotNull(AccountFileProviderWriters.tryReserve()) { "Provider writer did not drain" }
        AccountFileProviderWriters.release(reservation)
    }

    private class Loopback : AutoCloseable {
        private val server = ServerSocket().apply {
            bind(InetSocketAddress("127.0.0.1", 0))
            soTimeout = TIMEOUT_MS
        }
        val url = "http://127.0.0.1:${server.localPort}/fresh"

        init {
            // A misconfigured host proxy must not see this fixture's request.
            try { check(ProxySelector.getDefault()?.select(URI(url)).orEmpty().all { it == Proxy.NO_PROXY }) }
            catch (failure: Exception) { server.close(); throw failure }
        }

        fun accept(): Peer {
            val socket = server.accept().apply { soTimeout = TIMEOUT_MS }
            return try { Peer(socket) } catch (failure: Throwable) { socket.close(); throw failure }
        }

        fun assertNoConnection() {
            server.soTimeout = 250
            assertThrows(SocketTimeoutException::class.java) { server.accept().use { } }
        }

        override fun close() { server.close() }
    }

    private class Peer(private val socket: Socket) : AutoCloseable {
        private val input = BufferedInputStream(socket.getInputStream())
        val requestLine = readLine()
        val body: String

        init {
            val headers = linkedMapOf<String, String>()
            var ended = false
            var count = 0
            while (count++ < 64) {
                val line = readLine()
                if (line.isEmpty()) { ended = true; break }
                val delimiter = line.indexOf(':')
                require(delimiter > 0)
                headers[line.substring(0, delimiter).lowercase()] = line.substring(delimiter + 1).trim()
            }
            require(ended)
            val length = checkNotNull(headers["content-length"]).toInt()
            require(length in 1..1024)
            val bytes = ByteArray(length)
            var offset = 0
            while (offset < length) {
                val read = input.read(bytes, offset, length - offset)
                if (read <= 0) throw EOFException("Incomplete loopback request body")
                offset += read
            }
            body = bytes.toString(Charsets.UTF_8)
        }

        private fun readLine(): String {
            val bytes = ByteArrayOutputStream()
            while (bytes.size() < 8_192) {
                val next = input.read()
                if (next == -1) throw EOFException("Incomplete loopback request header")
                if (next == 10) return bytes.toByteArray().toString(Charsets.US_ASCII).trimEnd('\r')
                bytes.write(next)
            }
            error("Oversize loopback request header")
        }

        fun beginPartialResponse() {
            socket.getOutputStream().apply {
                write("HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\npartial".toByteArray())
                flush()
            }
        }

        fun respond(status: String, header: String) {
            socket.getOutputStream().apply {
                write("HTTP/1.1 $status\r\n${header}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                flush()
            }
        }

        fun awaitClientClose(): Boolean = try { input.read() == -1 } catch (_: SocketException) { true }
        override fun close() { socket.close() }
    }
}
