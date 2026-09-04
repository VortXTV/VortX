package com.vortx.android.player.mpv

import com.vortx.android.player.EngineFailureCoordinator
import com.vortx.android.player.EngineFailureResolution
import com.vortx.android.player.EngineFallbackReason
import com.vortx.android.player.PlayerState
import com.vortx.android.player.requestEngineFallback
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvRuntimeSafetyTest {
    @Test
    fun `audio health remains pending until an observed track list proves audio presence`() {
        assertEquals(
            MpvAudioTrackListHealthAction.PENDING_TRACK_LIST,
            mpvAudioTrackListHealthAction(
                trackListObserved = false,
                hasAudioTrack = false,
                timedOut = false,
            ),
        )
        assertEquals(
            MpvAudioTrackListHealthAction.CHECK_AUDIO_OUTPUT,
            mpvAudioTrackListHealthAction(
                trackListObserved = true,
                hasAudioTrack = true,
                timedOut = false,
            ),
        )
    }

    @Test
    fun `audio health accepts no audio only after track list arrival or bounded timeout`() {
        assertEquals(
            MpvAudioTrackListHealthAction.NO_AUDIO_TRACK,
            mpvAudioTrackListHealthAction(
                trackListObserved = true,
                hasAudioTrack = false,
                timedOut = false,
            ),
        )
        assertEquals(
            MpvAudioTrackListHealthAction.NO_AUDIO_TRACK,
            mpvAudioTrackListHealthAction(
                trackListObserved = false,
                hasAudioTrack = false,
                timedOut = true,
            ),
        )
    }

    @Test
    fun `stale generation track list cannot rearm audio health`() {
        assertFalse(
            shouldRearmMpvAudioHealthForTrackList(
                loadedGeneration = 9L,
                callbackGeneration = 8L,
                trackListPreviouslyObserved = false,
                trackListPreviouslyHadAudio = false,
                hasAudioTrack = true,
            ),
        )
    }

    @Test
    fun `audio arrival rearms once then preserves one recovery limit`() {
        assertTrue(
            shouldRearmMpvAudioHealthForTrackList(
                loadedGeneration = 9L,
                callbackGeneration = 9L,
                trackListPreviouslyObserved = true,
                trackListPreviouslyHadAudio = false,
                hasAudioTrack = true,
            ),
        )
        assertFalse(
            shouldRearmMpvAudioHealthForTrackList(
                loadedGeneration = 9L,
                callbackGeneration = 9L,
                trackListPreviouslyObserved = true,
                trackListPreviouslyHadAudio = true,
                hasAudioTrack = true,
            ),
        )
        assertEquals(
            MpvAudioOutputHealthAction.RETRY_DECODED_STEREO,
            mpvAudioOutputHealthAction(true, null, null, recoveryAttempted = false),
        )
        assertEquals(
            MpvAudioOutputHealthAction.FAIL_SOURCE,
            mpvAudioOutputHealthAction(true, null, null, recoveryAttempted = true),
        )
    }

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
    fun `terminal first still resolves failed AO to exactly one engine demotion`() {
        val coordinator = EngineFailureCoordinator<PlayerState>()
        val opportunity = coordinator.beginOpportunity()
        val terminal = PlayerState(positionMs = 37_000L, hasError = true)
        assertEquals(EngineFailureResolution.None, coordinator.onTerminal(terminal))

        val aoVerdict = mpvAudioOutputHealthAction(
            hasAudioTrack = true,
            currentAo = null,
            outputChannelCount = null,
            recoveryAttempted = true,
        )
        val resolution = coordinator.completeOpportunity(
            opportunity,
            fallbackReason = if (aoVerdict == MpvAudioOutputHealthAction.FAIL_SOURCE) {
                EngineFallbackReason.AUDIO_OUTPUT_FAILED
            } else {
                null
            },
        )
        assertEquals(
            EngineFailureResolution.Demote(EngineFallbackReason.AUDIO_OUTPUT_FAILED),
            resolution,
        )
        val replacementState = terminal.requestEngineFallback(EngineFallbackReason.AUDIO_OUTPUT_FAILED)
        assertEquals(37_000L, replacementState.positionMs)
        assertFalse(replacementState.hasError)
        assertEquals(
            EngineFailureResolution.None,
            coordinator.onTerminal(terminal.copy(positionMs = 38_000L)),
        )
        assertEquals(
            EngineFailureResolution.None,
            coordinator.completeOpportunity(opportunity, EngineFallbackReason.AUDIO_OUTPUT_FAILED),
        )
    }

    @Test
    fun `teardown resets held audio opportunity before cancellation completion`() {
        val coordinator = EngineFailureCoordinator<PlayerState>()
        val opportunity = coordinator.beginOpportunity()
        val terminal = PlayerState(positionMs = 42_000L, hasError = true)
        assertEquals(EngineFailureResolution.None, coordinator.onTerminal(terminal))

        // Mirrors release(): reset the coordinator before cancelling the coroutine whose finally block
        // completes its held opportunity. That completion must not revive the pending terminal or demote.
        coordinator.reset()
        assertEquals(
            EngineFailureResolution.None,
            coordinator.completeOpportunity(opportunity, EngineFallbackReason.AUDIO_OUTPUT_FAILED),
        )
    }

    @Test
    fun `failure resolution obtained during teardown is not published`() {
        assertTrue(shouldPublishMpvFailureResolution(released = false))
        // Models a health job which woke naturally after release's CAS and obtained a coordinator
        // resolution before its cancellation was observed.
        assertFalse(shouldPublishMpvFailureResolution(released = true))
    }

    @Test
    fun `healthy AO explicitly releases pending genuine terminal`() {
        val coordinator = EngineFailureCoordinator<PlayerState>()
        val opportunity = coordinator.beginOpportunity()
        val terminal = PlayerState(positionMs = 19_000L, hasError = true)
        assertEquals(EngineFailureResolution.None, coordinator.onTerminal(terminal))

        val aoVerdict = mpvAudioOutputHealthAction(
            hasAudioTrack = true,
            currentAo = "audiotrack",
            outputChannelCount = 2,
            recoveryAttempted = false,
        )
        val resolution = coordinator.completeOpportunity(
            opportunity,
            fallbackReason = if (aoVerdict == MpvAudioOutputHealthAction.FAIL_SOURCE) {
                EngineFallbackReason.AUDIO_OUTPUT_FAILED
            } else {
                null
            },
        )
        assertEquals(EngineFailureResolution.CommitTerminal(terminal), resolution)
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
