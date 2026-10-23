package com.vortx.android.engine

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

/** Fake boundary tests only: no native source-validation, encrypted-store or account proof. */
class NativeOwnerHistoryRuntimeTest {
    private val accept = NativeOwnerHistoryVerifier { true }
    private class Bindings : NativeOwnerHistoryBindings {
        var next = 10L
        val live = mutableSetOf<Long>()
        val closed = mutableListOf<Long>()
        var closeAccepted = true
        var closeThrows = false
        var requestBody: ((Long, ByteArray, Long, NativeOwnerHistoryVerifier) -> ByteArray?)? = null
        var lastSnapshot = byteArrayOf()
        var lastRequest = byteArrayOf()
        var lastClock = -1L
        var openRejected = false
        var forkRejected = false
        override fun canonicalize(evidence: ByteArray) = evidence.copyOf()
        override fun open(snapshot: ByteArray, verifier: NativeOwnerHistoryVerifier): Long {
            lastSnapshot = snapshot.copyOf()
            if (openRejected || !verifier.verify("open".toByteArray())) return 0L
            return (++next).also { live += it }
        }
        override fun fork(handle: Long, fence: ByteArray, verifier: NativeOwnerHistoryVerifier): Long {
            check(handle in live)
            if (forkRejected || !verifier.verify(fence)) return 0L
            return (++next).also { live += it }
        }
        override fun request(handle: Long, json: ByteArray, now: Long, verifier: NativeOwnerHistoryVerifier): ByteArray? {
            check(handle in live)
            lastRequest = json.copyOf(); lastClock = now
            return requestBody?.invoke(handle, json, now, verifier) ?: json.copyOf()
        }
        override fun close(handle: Long): Boolean {
            closed += handle
            if (closeThrows) error("synthetic uncertain retirement")
            if (!closeAccepted) return false
            check(live.remove(handle))
            return true
        }
    }
    private fun failed(body: () -> Unit) {
        assertTrue("operation must reject", runCatching(body).isFailure)
    }
    @Test fun rawBytesAndExplicitClockAreUnchangedAndInputsAreCopied() {
        val bindings = Bindings()
        val snapshot = """{"counter":18446744073709551615,"negative":-0.0,"future":1e999}""".toByteArray()
        val expected = snapshot.copyOf()
        val runtime = NativeOwnerHistoryRuntime.open(bindings, snapshot, accept)
        snapshot.fill(0)
        assertArrayEquals(expected, bindings.lastSnapshot)
        assertArrayEquals(expected, runtime.request(expected, 123L, accept))
        assertArrayEquals(expected, bindings.lastRequest)
        assertEquals(123L, bindings.lastClock)
        assertTrue(runtime.close()); assertTrue(runtime.close())
        assertEquals(1, bindings.closed.size)
        failed { runtime.request(expected, 123L, accept) }
    }
    @Test fun failedOpenAndForkDoNotReplaceOrFreeParent() {
        val bindings = Bindings()
        bindings.openRejected = true
        failed { NativeOwnerHistoryRuntime.open(bindings, "{}".toByteArray(), accept) }
        assertTrue(bindings.live.isEmpty())
        bindings.openRejected = false
        val parent = NativeOwnerHistoryRuntime.open(bindings, "{}".toByteArray(), accept)
        bindings.forkRejected = true
        failed { parent.fork("{}".toByteArray(), accept) }
        assertEquals(1, bindings.live.size); assertTrue(bindings.closed.isEmpty())
        bindings.forkRejected = false
        val child = parent.fork("{}".toByteArray(), accept)
        assertEquals(2, bindings.live.size)
        assertTrue(child.close()); assertEquals(1, bindings.live.size)
        assertArrayEquals("{}".toByteArray(), parent.request("{}".toByteArray(), 0L, accept))
        assertTrue(parent.close())
    }
    @Test fun callbackReentryAndCloseRejectWithoutMonitorBlocking() {
        val bindings = Bindings()
        val runtime = NativeOwnerHistoryRuntime.open(bindings, "{}".toByteArray(), accept)
        var invoked = false
        bindings.requestBody = { _, _, _, verifier ->
            assertTrue(verifier.verify("lease".toByteArray()))
            "ok".toByteArray()
        }
        val verifier = NativeOwnerHistoryVerifier {
            invoked = true
            failed { runtime.request("{}".toByteArray(), 0, accept) }
            failed { runtime.fork("{}".toByteArray(), accept) }
            assertFalse(runtime.close())
            true
        }
        assertArrayEquals("ok".toByteArray(), runtime.request("{}".toByteArray(), 0, verifier))
        assertTrue(invoked); assertTrue(bindings.closed.isEmpty())
        assertTrue(runtime.close())
    }
    @Test fun overlappingCallAndCloseRejectAndOriginalCallCompletes() {
        val bindings = Bindings()
        val runtime = NativeOwnerHistoryRuntime.open(bindings, "{}".toByteArray(), accept)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        bindings.requestBody = { _, _, _, _ ->
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
            "ok".toByteArray()
        }
        val worker = Thread {
            try { assertArrayEquals("ok".toByteArray(), runtime.request("{}".toByteArray(), 0, accept)) }
            catch (error: Throwable) { failure.set(error) }
        }
        worker.start()
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            failed { runtime.request("{}".toByteArray(), 0, accept) }
            assertFalse(runtime.close())
        } finally { release.countDown(); worker.join(5000) }
        assertFalse(worker.isAlive); assertNull(failure.get())
        assertTrue(runtime.close())
    }
    @Test fun unconfirmedOrThrowingCloseRetainsSameHandleAndQuarantinesCalls() {
        for (throwing in listOf(false, true)) {
            val bindings = Bindings()
            val runtime = NativeOwnerHistoryRuntime.open(bindings, "{}".toByteArray(), accept)
            bindings.closeAccepted = false; bindings.closeThrows = throwing
            assertFalse(runtime.close())
            assertEquals(1, bindings.live.size)
            failed { runtime.request("{}".toByteArray(), 0, accept) }
            failed { runtime.fork("{}".toByteArray(), accept) }
            val original = bindings.closed.single()
            bindings.closeAccepted = true; bindings.closeThrows = false
            assertTrue(runtime.close())
            assertEquals(listOf(original, original), bindings.closed)
            assertTrue(bindings.live.isEmpty())
        }
    }
    @Test fun malformedOverboundAndNegativeClockRejectBeforeBinding() {
        val bindings = Bindings()
        val bad = byteArrayOf(0xc0.toByte(), 0xaf.toByte())
        failed { NativeOwnerHistoryRuntime.open(bindings, bad, accept) }
        failed { NativeOwnerHistoryRuntime.open(bindings, byteArrayOf(), accept) }
        assertTrue(bindings.live.isEmpty())
        val runtime = NativeOwnerHistoryRuntime.open(bindings, "{}".toByteArray(), accept)
        failed { runtime.request(bad, 0, accept) }
        failed { runtime.fork(ByteArray(NativeOwnerHistoryRuntime.MAX_FENCE_BYTES + 1) { 32 }, accept) }
        failed { runtime.request("{}".toByteArray(), -1, accept) }
        assertEquals(-1L, bindings.lastClock)
        bindings.requestBody = { _, _, _, _ -> bad }
        failed { runtime.request("{}".toByteArray(), 0, accept) }
        assertTrue(runtime.close())
    }
    @Test fun bindingFailureReleasesCallGuardButNeverConfirmsAnAck() {
        val bindings = Bindings()
        val runtime = NativeOwnerHistoryRuntime.open(bindings, "{}".toByteArray(), accept)
        bindings.requestBody = { _, _, _, _ -> error("synthetic native failure") }
        failed { runtime.request("{}".toByteArray(), 0, accept) }
        assertTrue(bindings.closed.isEmpty())
        assertTrue(runtime.close())
    }
}
