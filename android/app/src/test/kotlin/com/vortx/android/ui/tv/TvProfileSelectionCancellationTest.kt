package com.vortx.android.ui.tv

import kotlinx.coroutines.CancellationException
import org.junit.Assert.*
import org.junit.Test

class TvProfileSelectionCancellationTest {
    @Test fun `cancelled legacy admission propagates through selection without entering the store`() {
        val cancellation = CancellationException("synthetic cancelled admission")
        val admission = legacyTvProfileAdmission { throw cancellation }
        var selected = false
        try {
            selectTvProfile(admission) { selected = true; error("Cancelled admission entered selection") }
            fail("Cancellation became an ordinary selection result")
        } catch (actual: CancellationException) {
            assertSame(cancellation, actual)
        }
        assertFalse(selected)
    }

    @Test fun `cancellation from admitted selection escapes both production adapters`() {
        val cancellation = CancellationException("synthetic cancelled selection")
        val admission = legacyTvProfileAdmission { action -> action() }
        try {
            selectTvProfile(admission) { throw cancellation }
            fail("Cancellation became a rejected admission or Result failure")
        } catch (actual: CancellationException) {
            assertSame(cancellation, actual)
        }
    }

    @Test fun `stale legacy admission remains an ordinary actionable failure`() {
        val admission = legacyTvProfileAdmission { error("Synthetic stale admission") }
        var selected = false
        val result = selectTvProfile(admission) { selected = true; error("Stale admission entered selection") }
        assertTrue(result.isFailure)
        assertFalse(selected)
        assertEquals("The profile changed. Open it again before switching.", result.exceptionOrNull()?.message)
    }
}
