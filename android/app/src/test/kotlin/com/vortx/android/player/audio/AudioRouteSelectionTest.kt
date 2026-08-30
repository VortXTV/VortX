package com.vortx.android.player.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioRouteSelectionTest {
    @Test
    fun `actual routed media device wins over inactive connected device precedence`() {
        val hdmi = AudioRoute(AudioRouteKind.HDMI, 8)
        val inactiveBluetooth = AudioRoute(AudioRouteKind.BLUETOOTH, 2)

        assertEquals(
            hdmi,
            AudioRoute.selectRoute(
                routed = listOf(hdmi),
                connected = listOf(inactiveBluetooth, hdmi),
            ),
        )
    }

    @Test
    fun `legacy connected inventory infers a single external kind beside speaker`() {
        val hdmi = AudioRoute(AudioRouteKind.HDMI, 8)

        assertEquals(
            hdmi,
            AudioRoute.selectRoute(
                routed = emptyList(),
                connected = listOf(AudioRoute.STEREO_DEFAULT, hdmi),
            ),
        )
    }

    @Test
    fun `legacy connected inventory fails stereo safe when external kinds conflict`() {
        assertEquals(
            AudioRoute.STEREO_DEFAULT,
            AudioRoute.selectRoute(
                routed = emptyList(),
                connected = listOf(
                    AudioRoute.STEREO_DEFAULT,
                    AudioRoute(AudioRouteKind.BLUETOOTH, 2),
                    AudioRoute(AudioRouteKind.HDMI, 8),
                ),
            ),
        )
    }

    @Test
    fun `legacy duplicate devices preserve the most capable channel count`() {
        assertEquals(
            AudioRoute(AudioRouteKind.USB, 8),
            AudioRoute.selectRoute(
                routed = emptyList(),
                connected = listOf(
                    AudioRoute(AudioRouteKind.USB, 2),
                    AudioRoute(AudioRouteKind.USB, 8),
                ),
            ),
        )
    }
}
