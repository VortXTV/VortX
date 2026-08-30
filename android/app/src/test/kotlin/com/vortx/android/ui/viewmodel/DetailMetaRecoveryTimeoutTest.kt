package com.vortx.android.ui.viewmodel

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DetailMetaRecoveryTimeoutTest {

    @Test
    fun stalledExternalIdLookupTimesOutAndCancelsItsChild() = runTest {
        var cancelled = false

        val result = boundedDetailRecoveryLookup(timeoutMs = 6_000L) {
            try {
                delay(60_000L)
                "tt1234567"
            } catch (error: CancellationException) {
                cancelled = true
                throw error
            }
        }

        assertNull(result)
        assertTrue("timed-out lookup must cancel its child", cancelled)
    }

    @Test
    fun successfulExternalIdLookupIsReturnedBeforeTheBound() = runTest {
        val result = boundedDetailRecoveryLookup(timeoutMs = 6_000L) {
            delay(250L)
            "tt1234567"
        }

        advanceTimeBy(250L)
        advanceUntilIdle()
        assertEquals("tt1234567", result)
    }
}
