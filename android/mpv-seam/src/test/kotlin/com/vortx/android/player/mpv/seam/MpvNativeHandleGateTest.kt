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
        gate.requestDestroy { destroyCount.incrementAndGet() }?.invoke()
        gate.requestDestroy { destroyCount.incrementAndGet() }?.invoke()

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

            val destroyAction = gate.requestDestroy { destroyed.countDown() }
            assertEquals(null, destroyAction)
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
    fun `serialized call releases monitor before deferred destroy joins event thread`() {
        val gate = MpvNativeHandleGate(79L)
        val surfaceMonitor = Any()
        val enteredSurfaceCall = CountDownLatch(1)
        val finishSurfaceCall = CountDownLatch(1)
        val destroyed = CountDownLatch(1)
        val destroyHeldSurfaceMonitor = AtomicInteger()
        val pool = Executors.newSingleThreadExecutor()
        try {
            pool.execute {
                gate.withSerializedHandle(surfaceMonitor, Unit) {
                    assertTrue(Thread.holdsLock(surfaceMonitor))
                    enteredSurfaceCall.countDown()
                    assertTrue(finishSurfaceCall.await(5, TimeUnit.SECONDS))
                }
            }
            assertTrue(enteredSurfaceCall.await(5, TimeUnit.SECONDS))

            assertEquals(
                null,
                gate.requestDestroy {
                    if (Thread.holdsLock(surfaceMonitor)) destroyHeldSurfaceMonitor.incrementAndGet()
                    destroyed.countDown()
                },
            )
            finishSurfaceCall.countDown()

            assertTrue(destroyed.await(5, TimeUnit.SECONDS))
            assertEquals(0, destroyHeldSurfaceMonitor.get())
        } finally {
            finishSurfaceCall.countDown()
            pool.shutdownNow()
        }
    }

    @Test
    fun `reentrant destroy returns while another destroy is still finalizing`() {
        val gate = MpvNativeHandleGate(89L)
        val firstDestroyEntered = CountDownLatch(1)
        val finishFirstDestroy = CountDownLatch(1)
        val reentrantReturned = CountDownLatch(1)
        val destroyCount = AtomicInteger()
        val pool = Executors.newFixedThreadPool(2)
        try {
            val firstDestroyAction = gate.requestDestroy {
                    firstDestroyEntered.countDown()
                    assertTrue(finishFirstDestroy.await(5, TimeUnit.SECONDS))
                    destroyCount.incrementAndGet()
            }
            pool.execute { firstDestroyAction?.invoke() }
            assertTrue(firstDestroyEntered.await(5, TimeUnit.SECONDS))

            pool.execute {
                gate.requestDestroy { error("reentrant destroy must not run") }?.invoke()
                reentrantReturned.countDown()
            }
            assertTrue(reentrantReturned.await(1, TimeUnit.SECONDS))

            finishFirstDestroy.countDown()
            pool.shutdown()
            assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS))
            assertEquals(1, destroyCount.get())
        } finally {
            finishFirstDestroy.countDown()
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
                    gate.requestDestroy {
                        destroyed.set(true)
                        destroyCount.incrementAndGet()
                    }?.invoke()
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
