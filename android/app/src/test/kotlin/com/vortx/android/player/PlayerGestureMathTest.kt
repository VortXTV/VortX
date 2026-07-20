package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// The pure gesture decision math (PlayerGestures.kt): axis latch, side split, seek mapping +
/// clamping, level mapping + clamping. See AudioFocusPolicyTest for the test-toolchain note.
class PlayerGestureMathTest {

    // ---- axis classification -----------------------------------------------------------------

    @Test
    fun `no axis until the accumulated delta passes the lock slop`() {
        assertNull(PlayerGestureMath.classifyAxis(totalDx = 5f, totalDy = 5f, slopPx = 12f))
        assertNull(PlayerGestureMath.classifyAxis(totalDx = -11.9f, totalDy = 0f, slopPx = 12f))
    }

    @Test
    fun `dominant horizontal delta classifies horizontal`() {
        assertEquals(
            PlayerGestureMath.Axis.HORIZONTAL,
            PlayerGestureMath.classifyAxis(totalDx = 30f, totalDy = 10f, slopPx = 12f),
        )
        assertEquals(
            PlayerGestureMath.Axis.HORIZONTAL,
            PlayerGestureMath.classifyAxis(totalDx = -30f, totalDy = 10f, slopPx = 12f),
        )
    }

    @Test
    fun `dominant vertical delta classifies vertical`() {
        assertEquals(
            PlayerGestureMath.Axis.VERTICAL,
            PlayerGestureMath.classifyAxis(totalDx = 4f, totalDy = -25f, slopPx = 12f),
        )
    }

    @Test
    fun `perfect diagonal resolves horizontal, the preview-only axis`() {
        assertEquals(
            PlayerGestureMath.Axis.HORIZONTAL,
            PlayerGestureMath.classifyAxis(totalDx = 20f, totalDy = 20f, slopPx = 12f),
        )
    }

    // ---- side split --------------------------------------------------------------------------

    @Test
    fun `left half is brightness, right half is volume`() {
        assertTrue(PlayerGestureMath.isBrightnessSide(startX = 100f, widthPx = 1000f))
        assertFalse(PlayerGestureMath.isBrightnessSide(startX = 900f, widthPx = 1000f))
        // The exact midpoint belongs to the right (volume) half.
        assertFalse(PlayerGestureMath.isBrightnessSide(startX = 500f, widthPx = 1000f))
    }

    // ---- seek mapping + clamping -------------------------------------------------------------

    @Test
    fun `full-width drag seeks the full sweep`() {
        val target = PlayerGestureMath.seekTargetMs(
            startPositionMs = 600_000L,
            totalDx = 1000f,
            widthPx = 1000f,
            durationMs = 7_200_000L,
            fullWidthSeekMs = 120_000L,
        )
        assertEquals(720_000L, target)
    }

    @Test
    fun `half-width drag seeks half the sweep, backwards for negative dx`() {
        val target = PlayerGestureMath.seekTargetMs(
            startPositionMs = 600_000L,
            totalDx = -500f,
            widthPx = 1000f,
            durationMs = 7_200_000L,
            fullWidthSeekMs = 120_000L,
        )
        assertEquals(540_000L, target)
    }

    @Test
    fun `seek clamps at zero`() {
        val target = PlayerGestureMath.seekTargetMs(
            startPositionMs = 10_000L,
            totalDx = -1000f,
            widthPx = 1000f,
            durationMs = 7_200_000L,
            fullWidthSeekMs = 120_000L,
        )
        assertEquals(0L, target)
    }

    @Test
    fun `seek clamps at the duration`() {
        val target = PlayerGestureMath.seekTargetMs(
            startPositionMs = 7_150_000L,
            totalDx = 1000f,
            widthPx = 1000f,
            durationMs = 7_200_000L,
            fullWidthSeekMs = 120_000L,
        )
        assertEquals(7_200_000L, target)
    }

    @Test
    fun `unknown duration clamps only the floor`() {
        val forward = PlayerGestureMath.seekTargetMs(
            startPositionMs = 30_000L,
            totalDx = 1000f,
            widthPx = 1000f,
            durationMs = 0L,
            fullWidthSeekMs = 120_000L,
        )
        assertEquals(150_000L, forward)
        val backward = PlayerGestureMath.seekTargetMs(
            startPositionMs = 30_000L,
            totalDx = -1000f,
            widthPx = 1000f,
            durationMs = 0L,
            fullWidthSeekMs = 120_000L,
        )
        assertEquals(0L, backward)
    }

    @Test
    fun `zero width degrades to the clamped start position`() {
        assertEquals(
            5_000L,
            PlayerGestureMath.seekTargetMs(
                startPositionMs = 5_000L,
                totalDx = 300f,
                widthPx = 0f,
                durationMs = 60_000L,
            ),
        )
    }

    // ---- level mapping + clamping ------------------------------------------------------------

    @Test
    fun `dragging up raises the level`() {
        val fraction = PlayerGestureMath.adjustedFraction(startFraction = 0.5f, totalDy = -500f, heightPx = 1000f)
        assertEquals(1.0f, fraction, 1e-4f)
    }

    @Test
    fun `dragging down lowers the level`() {
        val fraction = PlayerGestureMath.adjustedFraction(startFraction = 0.5f, totalDy = 250f, heightPx = 1000f)
        assertEquals(0.25f, fraction, 1e-4f)
    }

    @Test
    fun `level clamps to the unit range`() {
        assertEquals(1f, PlayerGestureMath.adjustedFraction(0.9f, totalDy = -900f, heightPx = 1000f), 0f)
        assertEquals(0f, PlayerGestureMath.adjustedFraction(0.1f, totalDy = 900f, heightPx = 1000f), 0f)
    }

    @Test
    fun `zero height degrades to the clamped start level`() {
        assertEquals(0.7f, PlayerGestureMath.adjustedFraction(0.7f, totalDy = 100f, heightPx = 0f), 0f)
        assertEquals(1f, PlayerGestureMath.adjustedFraction(1.4f, totalDy = 100f, heightPx = 0f), 0f)
    }

    @Test
    fun `volume index maps and clamps across the stream range`() {
        assertEquals(0, PlayerGestureMath.volumeIndexFor(0f, maxIndex = 15))
        assertEquals(15, PlayerGestureMath.volumeIndexFor(1f, maxIndex = 15))
        assertEquals(8, PlayerGestureMath.volumeIndexFor(0.5f, maxIndex = 15))
        assertEquals(0, PlayerGestureMath.volumeIndexFor(-0.5f, maxIndex = 15))
        assertEquals(15, PlayerGestureMath.volumeIndexFor(1.5f, maxIndex = 15))
    }
}
