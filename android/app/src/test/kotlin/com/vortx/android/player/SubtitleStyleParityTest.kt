package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Test

class SubtitleStyleParityTest {
    @Test
    fun greyAndBrightnessMatchThePersistedAppleContract() {
        val style = SubtitleStyle(
            fontId = SubtitleStyle.MODERN,
            sizeId = "m",
            sizeScale = 1.0,
            colorId = "grey",
            brightnessId = "80",
            backgroundId = "outline",
        )

        assertEquals("stremiox.sub.brightness", SubtitleStyle.KEY_BRIGHTNESS)
        assertEquals("#8F8F8F", style.colorHex)
    }

    @Test
    fun dimmingPreservesHueAndRejectsMalformedInput() {
        assertEquals("#CCCCCC", SubtitleStyle.dimmedHex("#FFFFFF", 0.8))
        assertEquals("#666600", SubtitleStyle.dimmedHex("#FFFF00", 0.4))
        assertEquals("invalid", SubtitleStyle.dimmedHex("invalid", 0.8))
    }
}
