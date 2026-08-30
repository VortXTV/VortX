package com.vortx.android.player.mpv.seam

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvNativeHandleGateTest {
    @Test
    fun `destroy is idempotent and later calls fail closed`() {
        val gate = MpvNativeHandleGate(41L)
        val destroyCount = AtomicInteger()

        assertEquals(42L, gate.withHandle(-1L) { it + 1L })
        gate.destroy { destroyCount.incrementAndGet() }
        gate.destroy { destroyCount.incrementAndGet() }

        assertEquals(1, destroyCount.get())
        assertEquals(-1L, gate.withHandle(-1L) { error("must not run") })
    }

    @Test
    fun `destroy waits for leased native call before freeing handle`() {
        val gate = MpvNativeHandleGate(73L)
        val enteredCall = CountDownLatch(1)
        val finishCall = CountDownLatch(1)
        val destroyed = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            pool.execute {
                gate.withHandle(Unit) {
                    enteredCall.countDown()
                    assertTrue(finishCall.await(5, TimeUnit.SECONDS))
                }
            }
            assertTrue(enteredCall.await(5, TimeUnit.SECONDS))

            pool.execute {
                gate.destroy { destroyed.countDown() }
            }
            assertFalse(destroyed.await(100, TimeUnit.MILLISECONDS))

            finishCall.countDown()
            assertTrue(destroyed.await(5, TimeUnit.SECONDS))
            assertEquals(null, gate.withHandle<String?>(null) { "unsafe" })
        } finally {
            finishCall.countDown()
            pool.shutdownNow()
        }
    }

    @Test
    fun `concurrent callers and destroyers never use a freed handle`() {
        val gate = MpvNativeHandleGate(101L)
        val start = CountDownLatch(1)
        val destroyed = java.util.concurrent.atomic.AtomicBoolean(false)
        val destroyCount = AtomicInteger()
        val callsAfterFree = AtomicInteger()
        val pool = Executors.newFixedThreadPool(12)
        try {
            val callers = (0 until 8).map {
                pool.submit {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    repeat(2_000) {
                        gate.withHandle(Unit) {
                            if (destroyed.get()) callsAfterFree.incrementAndGet()
                        }
                    }
                }
            }
            val destroyers = (0 until 4).map {
                pool.submit {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    gate.destroy {
                        destroyed.set(true)
                        destroyCount.incrementAndGet()
                    }
                }
            }

            start.countDown()
            (callers + destroyers).forEach { it.get(10, TimeUnit.SECONDS) }

            assertEquals(1, destroyCount.get())
            assertEquals(0, callsAfterFree.get())
            assertEquals(-1L, gate.withHandle(-1L) { it })
        } finally {
            start.countDown()
            pool.shutdownNow()
        }
    }
}
