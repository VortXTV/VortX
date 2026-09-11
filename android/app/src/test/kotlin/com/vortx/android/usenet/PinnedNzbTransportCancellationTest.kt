package com.vortx.android.usenet

import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertTrue
import org.junit.Test

class PinnedNzbTransportCancellationTest {
    @Test
    fun `cancelling a stalled NZB body cancels the live OkHttp socket`() = runBlocking {
        ServerSocket(0).use { server ->
            server.soTimeout = 5_000
            val bodyStarted = CountDownLatch(1)
            val peerClosed = CountDownLatch(1)
            val acceptedSocket = AtomicReference<Socket?>()
            val serverFailure = AtomicReference<Throwable?>()
            val serverThread = Thread {
                try {
                    server.accept().use { socket ->
                        acceptedSocket.set(socket)
                        socket.soTimeout = 5_000
                        val input = socket.getInputStream().bufferedReader(Charsets.US_ASCII)
                        while (true) {
                            val line = input.readLine() ?: error("request closed before headers")
                            if (line.isEmpty()) break
                        }
                        socket.getOutputStream().write(
                            // One byte proves body consumption; the remaining declared body stalls.
                            "HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\nx".toByteArray(Charsets.US_ASCII),
                        )
                        socket.getOutputStream().flush()
                        try {
                            check(input.read() == -1) { "unexpected request data after headers" }
                        } catch (_: SocketException) {
                            // OkHttp cancellation may close with RST instead of an orderly EOF.
                        }
                        peerClosed.countDown()
                    }
                } catch (failure: Throwable) {
                    serverFailure.set(failure)
                }
            }.also { it.start() }
            val request = NzbFetchPolicy.CheckedRequest(
                "http://127.0.0.1:${server.localPort}/stalled.nzb".toHttpUrl(),
                listOf(InetAddress.getByName("127.0.0.1")),
            )
            val transport = PinnedNzbTransport(
                // The assertion proves cancel, not expiry: this timeout is intentionally much longer than
                // the measured cancellation budget.
                timeoutMs = 60_000,
                client = OkHttpClient.Builder().eventListener(object : EventListener() {
                    override fun responseBodyStart(call: Call) {
                        bodyStarted.countDown()
                    }
                }).build(),
            )
            val fetch = async(Dispatchers.IO) { transport.execute(request) }
            try {
                assertTrue("OkHttp never began reading the response body", bodyStarted.await(2, TimeUnit.SECONDS))
                assertTrue("socket closed before cancellation", peerClosed.count == 1L)
                val cancelledAt = System.nanoTime()
                fetch.cancel()
                fetch.join()
                assertTrue("cancellation did not close the stalled OkHttp body", peerClosed.await(2, TimeUnit.SECONDS))
                assertTrue(
                    "cancellation waited for the configured 60-second timeout",
                    TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - cancelledAt) < 2_000,
                )
                assertTrue("server failed: ${serverFailure.get()}", serverFailure.get() == null)
            } finally {
                fetch.cancel()
                fetch.join()
                acceptedSocket.get()?.close()
                server.close()
                serverThread.join(2_000)
                assertTrue("fixture server thread did not stop", !serverThread.isAlive)
            }
        }
    }
}
