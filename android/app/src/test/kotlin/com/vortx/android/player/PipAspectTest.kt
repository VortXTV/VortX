package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Test

/// The PiP aspect-ratio clamp (PlayerPip.kt), kept off android.util.Rational precisely so this
/// test runs on the JVM. The framework rejects ratios outside [0.418410, 2.390000]; the clamp must
/// keep every real-world video inside that band. See AudioFocusPolicyTest for the toolchain note.
class PipAspectTest {

    @Test
    fun `standard video passes through untouched`() {
        assertEquals(1920 to 1080, pipAspect(1920, 1080))
        assertEquals(1280 to 720, pipAspect(1280, 720))
        // 2.35:1 scope sits inside the legal band and must not be clamped.
        assertEquals(1880 to 800, pipAspect(1880, 800))
    }

    @Test
    fun `ultra-wide video clamps to the widest legal ratio`() {
        // 2.76:1 (Ben-Hur class) is over the 2.39 ceiling.
        assertEquals(239 to 100, pipAspect(2760, 1000))
    }

    @Test
    fun `tall video clamps to the tallest legal ratio`() {
        // 9:16 vertical is under the 0.42 floor.
        assertEquals(42 to 100, pipAspect(1080, 1920))
    }

    @Test
    fun `unknown or degenerate size falls back to sixteen-nine`() {
        assertEquals(16 to 9, pipAspect(0, 0))
        assertEquals(16 to 9, pipAspect(-1, 1080))
        assertEquals(16 to 9, pipAspect(1920, 0))
    }
}
