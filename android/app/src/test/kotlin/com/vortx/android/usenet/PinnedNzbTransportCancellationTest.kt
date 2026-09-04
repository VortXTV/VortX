package com.vortx.android.usenet

import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertTrue
import org.junit.Test

class PinnedNzbTransportCancellationTest {
    @Test
    fun `cancelling a stalled NZB body cancels the live OkHttp socket`() = runBlocking {
        ServerSocket(0).use { server ->
            val accepted = CountDownLatch(1)
            val peerClosed = CountDownLatch(1)
            val serverThread = Thread {
                server.accept().use { socket ->
                    val input = socket.getInputStream()
                    while (true) {
                        var previous = -1
                        while (true) {
                            val current = input.read()
                            if (current < 0 || (previous == '\r'.code && current == '\n'.code)) break
                            previous = current
                        }
                        if (previous == '\r'.code) break
                    }
                    socket.getOutputStream().write(
                        "HTTP/1.1 200 OK\\r\\nContent-Length: 999999\\r\\n\\r\\n".toByteArray(),
                    )
                    socket.getOutputStream().flush()
                    accepted.countDown()
                    input.readBytes()
                    peerClosed.countDown()
                }
            }.also { it.start() }
            val request = NzbFetchPolicy.CheckedRequest(
                "http://127.0.0.1:${server.localPort}/stalled.nzb".toHttpUrl(),
                listOf(InetAddress.getByName("127.0.0.1")),
            )
            val transport = PinnedNzbTransport(
                timeoutMs = 5_000,
                client = OkHttpClient.Builder().build(),
            )
            val fetch = async(Dispatchers.IO) { transport.execute(request) }
            assertTrue("server never received the OkHttp request", accepted.await(2, TimeUnit.SECONDS))
            fetch.cancel()
            fetch.join()
            assertTrue("cancellation did not close the stalled OkHttp body", peerClosed.await(2, TimeUnit.SECONDS))
            serverThread.join(2_000)
        }
    }
}
