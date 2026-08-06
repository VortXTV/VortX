package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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

    @Test
    fun outputChoicesRequireAnEngineThatCanApplyThem() {
        assertEquals(AudioOutputMode.entries, visibleAudioOutputModes(available = true))
        assertTrue(visibleAudioOutputModes(available = false).isEmpty())
    }

    @Test
    fun leavingPassthroughAlwaysClearsSpdifAndSetsChannels() {
        val expectedChannels = mapOf(
            AudioOutputMode.AUTO to "auto-safe",
            AudioOutputMode.STEREO to "stereo",
            AudioOutputMode.SURROUND to "auto",
        )

        expectedChannels.forEach { (target, channels) ->
            assertEquals(
                listOf("audio-channels" to channels, "audio-spdif" to ""),
                target.mpvLiveProperties(),
            )
        }
    }

    @Test
    fun passthroughLivePropertiesArmSupportedCodecs() {
        assertEquals(
            listOf(
                "audio-channels" to "auto",
                "audio-spdif" to "ac3,dts,eac3,truehd,dts-hd",
            ),
            AudioOutputMode.PASSTHROUGH.mpvLiveProperties(),
        )
    }
}
