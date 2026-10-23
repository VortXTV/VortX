package com.vortx.android.player.extras

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlayerHandoffResultTest {
    private fun returned(ok: Boolean = true, knownDurationMs: Long = 0L, extras: Map<String, Any> = emptyMap()) =
        PlayerHandoff.returnedPositionMs(ok, extras::get, knownDurationMs)

    @Test fun `MX Player and Just Player report Int milliseconds`() {
        assertEquals(1_834_000L, returned(extras = mapOf("position" to 1_834_000, "duration" to 3_000_000)))
    }

    @Test fun `VLC reports its own Long keys`() {
        assertEquals(754_000L, returned(extras = mapOf("extra_position" to 754_000L, "extra_duration" to 3_000_000L)))
    }

    @Test fun `finished playback lands on the end`() {
        assertEquals(3_000_000L, returned(extras = mapOf("end_by" to "playback_completion", "position" to 12_000, "duration" to 3_000_000)))
        assertEquals(2_400_000L, returned(knownDurationMs = 2_400_000L, extras = mapOf("end_by" to "playback_completion")))
    }

    @Test fun `a position past the duration is clamped and the player's own duration wins`() {
        assertEquals(3_000_000L, returned(knownDurationMs = 1_000L, extras = mapOf("position" to 3_500_000, "duration" to 3_000_000)))
        assertEquals(2_000_000L, returned(knownDurationMs = 2_000_000L, extras = mapOf("position" to 2_500_000)))
    }

    @Test fun `nothing usable saves nothing`() {
        assertNull(returned(ok = false, extras = mapOf("position" to 900_000)))
        assertNull(returned(extras = mapOf("position" to 3_000)))
        assertNull(returned(extras = mapOf("position" to "900000")))
        assertNull(returned())
        assertNull(returned(extras = mapOf("end_by" to "playback_completion")))
    }

    @Test fun `the start is whole milliseconds only once it matters`() {
        assertNull(PlayerHandoff.startPositionMs(0L))
        assertNull(PlayerHandoff.startPositionMs(4_999L))
        assertEquals(5_000, PlayerHandoff.startPositionMs(5_000L))
        assertNull(PlayerHandoff.startPositionMs(Long.MAX_VALUE))
    }
}
