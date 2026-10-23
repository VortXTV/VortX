package com.vortx.android.ui.prefs

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Settings > Effects and performance, the same policy as Apple `VisualEffectsTests`. */
class VisualEffectsTest {
    @Test fun `auto backdrop animates on a capable box and stays still on a reduced one`() {
        assertEquals(VisualEffects.Backdrop.ANIMATED, VisualEffects.backdrop("auto", reduced = false))
        assertEquals(VisualEffects.Backdrop.STILL, VisualEffects.backdrop(null, reduced = true))
    }

    @Test fun `an explicit backdrop wins and unknown values read as auto`() {
        assertEquals(VisualEffects.Backdrop.OFF, VisualEffects.backdrop("off", reduced = false))
        assertEquals(VisualEffects.Backdrop.ANIMATED, VisualEffects.backdrop("animated", reduced = true))
        assertEquals(VisualEffects.Backdrop.STILL, VisualEffects.backdrop("sparkly", reduced = true))
    }

    @Test fun `glass and motion follow Performance unless chosen`() {
        assertTrue(VisualEffects.glass(null, reduced = false))
        assertFalse(VisualEffects.glass("auto", reduced = true))
        assertTrue(VisualEffects.glass("on", reduced = true))
        assertFalse(VisualEffects.motion("off", reduced = false))
        assertFalse(VisualEffects.motion(null, reduced = true))
    }

    @Test fun `artwork caps at HD only when asked or reduced`() {
        assertFalse(VisualEffects.hdArtworkOnly(null, reduced = false))
        assertTrue(VisualEffects.hdArtworkOnly("auto", reduced = true))
        assertTrue(VisualEffects.hdArtworkOnly("hd", reduced = false))
        assertFalse(VisualEffects.hdArtworkOnly("full", reduced = true))
    }
}
