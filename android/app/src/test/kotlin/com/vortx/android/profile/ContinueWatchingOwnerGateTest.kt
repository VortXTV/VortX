package com.vortx.android.profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class ContinueWatchingOwnerGateTest {
    @Test
    fun `transition captures the binding before mutation and advances even when defaults compare equal`() {
        var binding = "owner-default"
        val revisionBefore = ContinueWatchingOwnerGate.serialized { it }

        val captured = ContinueWatchingOwnerGate.transition(capture = { binding }) { before ->
            binding = "owner-default"
            before
        }

        val revisionAfter = ContinueWatchingOwnerGate.serialized { it }
        assertEquals("owner-default", captured)
        assertEquals("owner-default", binding)
        assertTrue(revisionAfter > revisionBefore)
    }

    @Test
    fun `owner revision is monotonic and transition cannot enter during mutation`() {
        val before = ContinueWatchingOwnerGate.serialized { it }
        val after = ContinueWatchingOwnerGate.advance()
        assertTrue(after > before)

        val mutationEntered = CountDownLatch(1)
        val releaseMutation = CountDownLatch(1)
        val transitionAttempted = CountDownLatch(1)
        val transitionEntered = AtomicBoolean(false)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val mutation = executor.submit {
                ContinueWatchingOwnerGate.serialized {
                    mutationEntered.countDown()
                    releaseMutation.await(2, TimeUnit.SECONDS)
                }
            }
            assertTrue(mutationEntered.await(1, TimeUnit.SECONDS))
            val transition = executor.submit {
                transitionAttempted.countDown()
                ContinueWatchingOwnerGate.serialized {
                    transitionEntered.set(true)
                    ContinueWatchingOwnerGate.advance()
                }
            }
            assertTrue(transitionAttempted.await(1, TimeUnit.SECONDS))
            assertFalse(transitionEntered.get())

            releaseMutation.countDown()
            mutation.get(1, TimeUnit.SECONDS)
            transition.get(1, TimeUnit.SECONDS)
            assertTrue(transitionEntered.get())
        } finally {
            releaseMutation.countDown()
            executor.shutdownNow()
        }
    }
}
