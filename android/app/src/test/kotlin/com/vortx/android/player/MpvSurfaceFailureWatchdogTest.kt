package com.vortx.android.player

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class MpvSurfaceFailureWatchdogTest {
    @Test
    fun `watchdog observes a surface failure delivered after composition`() = runTest {
        var reads = 0

        val failed = awaitMpvSurfaceFailure(
            readFailed = { ++reads == 4 },
            maxChecks = 8,
            pollIntervalMs = 100L,
        )

        assertTrue(failed)
        assertEquals(4, reads)
        assertEquals(300L, testScheduler.currentTime)
    }

    @Test
    fun `watchdog stops after its bounded attach window`() = runTest {
        var reads = 0

        val failed = awaitMpvSurfaceFailure(
            readFailed = {
                reads += 1
                false
            },
            maxChecks = 5,
            pollIntervalMs = 100L,
        )

        assertFalse(failed)
        assertEquals(5, reads)
        assertEquals(400L, testScheduler.currentTime)
    }

    @Test
    fun `watchdog demotes immediately when failure already exists`() = runTest {
        val failed = awaitMpvSurfaceFailure(
            readFailed = { true },
            maxChecks = 5,
            pollIntervalMs = 100L,
        )

        assertTrue(failed)
        assertEquals(0L, testScheduler.currentTime)
    }
}
