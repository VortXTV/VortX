package com.vortx.android.usenet

import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertTrue
import org.junit.Test

class NntpCancellationTest {
    @Test
    fun `closing NntpClient interrupts a stalled TLS handshake`() {
        ServerSocket(0).use { server ->
            val accepted = CountDownLatch(1)
            val holdPeer = CountDownLatch(1)
            val serverThread = Thread {
                server.accept().use {
                    accepted.countDown()
                    holdPeer.await(3, TimeUnit.SECONDS)
                }
            }.also { it.start() }
            val client = NntpClient("127.0.0.1", server.localPort, "user", "secret", useSSL = true, timeoutMs = 60_000)
            val finished = CountDownLatch(1)
            val result = AtomicReference<Throwable?>()
            val connectThread = Thread {
                try { client.connect() } catch (error: Throwable) { result.set(error) } finally { finished.countDown() }
            }.also { it.start() }
            assertTrue("TLS peer was never connected", accepted.await(2, TimeUnit.SECONDS))
            client.close()
            assertTrue("closing the client did not interrupt TLS handshake", finished.await(2, TimeUnit.SECONDS))
            assertTrue("interrupted TLS handshake should report an IO failure", result.get() is IOException)
            holdPeer.countDown()
            connectThread.join(2_000)
            serverThread.join(2_000)
        }
    }

    @Test
    fun `closing a live NNTP socket interrupts a blocked protocol read`() {
        ServerSocket(0).use { server ->
            val accepted = CountDownLatch(1)
            val holdPeer = CountDownLatch(1)
            val serverThread = Thread {
                server.accept().use {
                    accepted.countDown()
                    holdPeer.await(3, TimeUnit.SECONDS)
                }
            }.also { it.start() }
            Socket("127.0.0.1", server.localPort).use { socket ->
                assertTrue("NNTP peer was never connected", accepted.await(2, TimeUnit.SECONDS))
                val finished = CountDownLatch(1)
                val failure = AtomicReference<Throwable?>()
                val readerThread = Thread {
                    try { NntpLineReader(socket.getInputStream()).readLine(1024) } catch (error: Throwable) { failure.set(error) } finally { finished.countDown() }
                }.also { it.start() }
                socket.close()
                assertTrue("closing NNTP socket did not interrupt the blocked read", finished.await(2, TimeUnit.SECONDS))
                assertTrue("blocked read should fail after close", failure.get() is IOException)
                readerThread.join(2_000)
            }
            holdPeer.countDown()
            serverThread.join(2_000)
        }
    }
}
