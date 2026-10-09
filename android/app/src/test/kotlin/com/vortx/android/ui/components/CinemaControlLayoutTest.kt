package com.vortx.android.ui.components

import org.junit.Assert.*
import org.junit.Test

class CinemaControlLayoutTest {
    @Test fun `phone and narrow split windows remain compact`() {
        for (width in listOf(320f, 390f, 599.9f)) {
            val layout = cinemaControlLayout(width)
            assertFalse(layout.spacious)
            assertEquals(16, layout.cardPaddingDp)
            assertEquals(48, layout.addonLogoDp)
        }
    }
    @Test fun `regular tablet windows use spacious bounded cards`() {
        for (width in listOf(600f, 840f, 1366f)) {
            val layout = cinemaControlLayout(width)
            assertTrue(layout.spacious)
            assertEquals(1120, layout.maxContentWidthDp)
            assertEquals(24, layout.cardPaddingDp)
            assertEquals(20, layout.cardGapDp)
            assertEquals(64, layout.addonLogoDp)
        }
    }
    @Test fun `unmeasured malformed widths cannot opt into spacious layout`() {
        for (width in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, -1f)) {
            assertFalse(cinemaControlLayout(width).spacious)
        }
    }
}
