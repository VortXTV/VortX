package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Test

class PlayerSyncControlsTest {
    @Test
    fun delayAdjustmentUsesAppleOneDecimalGrid() {
        assertEquals(0.5, adjustedPlayerDelay(0.0, 0.5), 0.0)
        assertEquals(0.6, adjustedPlayerDelay(0.5, 0.1), 0.0)
        assertEquals(0.5, adjustedPlayerDelay(0.6, -0.1), 0.0)
        assertEquals(-0.5, adjustedPlayerDelay(0.0, -0.5), 0.0)
    }

    @Test
    fun resetCanonicalizesZero() {
        assertEquals(0.0, adjustedPlayerDelay(1.7, -1.7), 0.0)
        assertEquals(0.0, adjustedPlayerDelay(-0.1, 0.1), 0.0)
    }
}
