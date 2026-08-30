package com.vortx.android.player.mpv.seam

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvNativeDestroyDispatcherTest {
    @Test
    fun `event callback destroy requests exit only after listener returns`() {
        val dispatcher = MpvNativeDestroyDispatcher()
        val gate = MpvNativeHandleGate(131L)
        val listenerReturned = AtomicBoolean(false)
        val nativeDestroyCalled = AtomicBoolean(false)
        val freed = AtomicBoolean(false)
        val destroyCount = AtomicInteger()

        dispatcher.withinNativeCallback {
            val destroyAction = gate.requestDestroy {
                nativeDestroyCalled.set(true)
                destroyCount.incrementAndGet()
                // Models nativeDestroy's event-thread branch: request loop exit, never join or free here.
            }
            dispatcher.dispatchDestroy(requireNotNull(destroyAction))
            assertFalse(nativeDestroyCalled.get())
            listenerReturned.set(true)
        }

        assertTrue(listenerReturned.get())
        assertTrue(nativeDestroyCalled.get())
        assertFalse(freed.get())

        // Models event.cpp after CallVoidMethod and local-ref cleanup have returned.
        freed.set(true)
        assertEquals(1, destroyCount.get())
        assertEquals(-1L, gate.withHandle(-1L) { it })
    }

    @Test
    fun `outstanding lease hands destroy to releaser without blocking event callback`() {
        val dispatcher = MpvNativeDestroyDispatcher()
        val gate = MpvNativeHandleGate(197L)
        val leaseEntered = CountDownLatch(1)
        val callbackReturned = CountDownLatch(1)
        val destroyFinished = CountDownLatch(1)
        val destroyThread = AtomicReference<Thread>()
        val eventThread = AtomicReference<Thread>()
        val pool = Executors.newFixedThreadPool(2)
        try {
            pool.execute {
                gate.withHandle(Unit) {
                    leaseEntered.countDown()
                    assertTrue(callbackReturned.await(5, TimeUnit.SECONDS))
                }
            }
            assertTrue(leaseEntered.await(5, TimeUnit.SECONDS))

            val eventResult = pool.submit {
                eventThread.set(Thread.currentThread())
                dispatcher.withinNativeCallback {
                    val immediate = gate.requestDestroy {
                        destroyThread.set(Thread.currentThread())
                        destroyFinished.countDown()
                    }
                    assertEquals(null, immediate)
                }
                callbackReturned.countDown()
            }

            eventResult.get(1, TimeUnit.SECONDS)
            assertTrue(destroyFinished.await(5, TimeUnit.SECONDS))
            assertFalse(eventThread.get() === destroyThread.get())
            assertEquals(-1L, gate.withHandle(-1L) { it })
        } finally {
            callbackReturned.countDown()
            pool.shutdownNow()
        }
    }
}
