package com.vortx.android.skip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AutoSkipPolicyTest {
    private val intro = SkipSegment(SkipSegment.Kind.INTRO, start = 5.0, end = 42.0)

    @Test
    fun returnsAnActiveSegmentOnlyOnce() {
        assertEquals(intro, AutoSkipPolicy.target(listOf(intro), positionMs = 10_000, skippedStarts = emptySet()))
        assertNull(AutoSkipPolicy.target(listOf(intro), positionMs = 10_000, skippedStarts = setOf(5.0)))
    }

    @Test
    fun ignoresPositionsOutsideTheSegment() {
        assertNull(AutoSkipPolicy.target(listOf(intro), positionMs = 4_999, skippedStarts = emptySet()))
        assertNull(AutoSkipPolicy.target(listOf(intro), positionMs = 42_000, skippedStarts = emptySet()))
    }
}
