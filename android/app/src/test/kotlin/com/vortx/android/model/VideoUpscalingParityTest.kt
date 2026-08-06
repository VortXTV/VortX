package com.vortx.android.model

import com.vortx.android.player.PlaybackBehaviorSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoUpscalingParityTest {
    @Test
    fun androidExposesOnlyPresetsBackedByPackagedResources() {
        assertFalse(VideoUpscaling.ANIME4K in VideoUpscaling.androidChoices)
        assertTrue(VideoUpscaling.HIGH_QUALITY in VideoUpscaling.androidChoices)
        assertTrue(VideoUpscaling.PERFORMANCE.mpvOptions.isNotEmpty())
        assertEquals("stremiox.videoUpscaling", TrackPreferencesStore.KEY_UPSCALING)
    }

    @Test
    fun playbackSwitchesUseTheCrossPlatformKeys() {
        assertEquals("stremiox.directLinksOnly", PlaybackBehaviorSettings.DIRECT_LINKS_ONLY_KEY)
        assertEquals("stremiox.autoSkip", PlaybackBehaviorSettings.AUTO_SKIP_KEY)
    }
}
