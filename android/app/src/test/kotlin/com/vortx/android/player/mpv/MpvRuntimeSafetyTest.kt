package com.vortx.android.player.mpv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvRuntimeSafetyTest {
    @Test
    fun `audio health ignores files without an audio track`() {
        assertEquals(
            MpvAudioOutputHealthAction.NONE,
            mpvAudioOutputHealthAction(false, null, null, recoveryAttempted = false),
        )
    }

    @Test
    fun `named ao or opened output channels prove audio output health`() {
        assertEquals(
            MpvAudioOutputHealthAction.NONE,
            mpvAudioOutputHealthAction(true, "audiotrack", null, recoveryAttempted = false),
        )
        assertEquals(
            MpvAudioOutputHealthAction.NONE,
            mpvAudioOutputHealthAction(true, null, 2, recoveryAttempted = false),
        )
    }

    @Test
    fun `missing ao retries once then fails source`() {
        assertEquals(
            MpvAudioOutputHealthAction.RETRY_DECODED_STEREO,
            mpvAudioOutputHealthAction(true, "null", 0, recoveryAttempted = false),
        )
        assertEquals(
            MpvAudioOutputHealthAction.FAIL_SOURCE,
            mpvAudioOutputHealthAction(true, null, null, recoveryAttempted = true),
        )
    }

    @Test
    fun `safe audio retry clears passthrough before reopening a stereo ao`() {
        assertEquals(
            listOf(
                "audio-spdif" to "",
                "audio-channels" to "stereo",
                "ao" to "audiotrack,opensles,",
                "aid" to "auto",
            ),
            safeMpvAudioRecoveryProperties(),
        )
    }

    @Test
    fun `frame capture rejects direct hwdec and permits readable decoders`() {
        assertFalse(canSafelyCaptureMpvFrame(null))
        assertFalse(canSafelyCaptureMpvFrame("mediacodec"))
        assertTrue(canSafelyCaptureMpvFrame("mediacodec-copy"))
        assertTrue(canSafelyCaptureMpvFrame("no"))
    }
}
