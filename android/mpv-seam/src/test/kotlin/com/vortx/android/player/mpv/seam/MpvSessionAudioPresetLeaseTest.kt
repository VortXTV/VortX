package com.vortx.android.player.mpv.seam

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Exercises the production lease + serialization helper, not an imitation lifetime algorithm. */
class MpvSessionAudioPresetLeaseTest {
    @Test fun `destroy closes admission while serialized transaction owns live handle and releases monitor before finalization`() {
        val gate = MpvNativeHandleGate(41L)
        val monitor = Any()
        val entered = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val finalized = CountDownLatch(1)
        val nativeCalls = AtomicInteger()
        val destroys = AtomicInteger()
        val failure = AtomicReference<Throwable?>()
        val worker = Thread {
            try {
                gate.withSerializedHandle(monitor, Unit) { handle ->
                    assertEquals(41L, handle)
                    nativeCalls.incrementAndGet()
                    entered.countDown()
                    assertTrue(finish.await(5, TimeUnit.SECONDS))
                    assertEquals(0, destroys.get())
                }
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        worker.start()
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val immediate = gate.requestDestroy { handle ->
                assertEquals(41L, handle)
                assertFalse(Thread.holdsLock(monitor))
                destroys.incrementAndGet()
                finalized.countDown()
            }
            assertEquals(null, immediate)
            assertEquals(-1, gate.withSerializedHandle(monitor, -1) { nativeCalls.incrementAndGet() })
            assertEquals(1, nativeCalls.get())
            assertEquals(0, destroys.get())
        } finally {
            finish.countDown()
            worker.join(5_000)
        }
        assertFalse(worker.isAlive)
        failure.get()?.let { throw AssertionError("Lease worker failed", it) }
        assertTrue(finalized.await(5, TimeUnit.SECONDS))
        assertEquals(1, destroys.get())
        assertEquals(null, gate.requestDestroy { destroys.incrementAndGet() })
    }
}
