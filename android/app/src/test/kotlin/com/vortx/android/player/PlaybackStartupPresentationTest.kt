package com.vortx.android.player

import org.junit.Assert.*
import org.junit.Test

class PlaybackStartupPresentationTest {
    private val pending = PlaybackStartupEvidence.AWAITING
    private fun video(clock: Double = 1.0) = MpvStartupSample(clock, null, true, true, false, 1920, 1080, false, false)
    private fun audio(clock: Double = 1.0) = MpvStartupSample(clock, clock, false, false, true, 0, 0, false, false)

    @Test fun deadlineDismissalIsNotAnEngineReceiptAndNeverRearms() {
        val window = StartupCoverWindow(100)
        assertTrue(window.pending(100, pending, true))
        assertTrue(window.pending(12_099, pending, true))
        assertFalse(window.pending(12_100, pending, true))
        assertFalse(window.pending(101, pending, true))
        assertEquals(PlaybackStartupEvidence.AWAITING, pending)
    }
    @Test fun actualSettlingAndHealthyRebufferNeverRearmSameAttempt() {
        PlaybackStartupEvidence.entries.filter { it != pending }.forEach { settled ->
            val window = StartupCoverWindow(0)
            assertTrue(window.pending(0, pending, true))
            assertFalse(window.pending(1, settled, true))
            assertFalse(window.pending(2, pending, true))
            assertEquals(settled, settledStartupEvidence(settled, pending))
        }
    }
    @Test fun unknownUnsupportedOrFailedEngineFailsOpenWithoutFrameClaim() {
        assertFalse(StartupCoverWindow(0).pending(0, PlaybackStartupEvidence.UNAVAILABLE, true))
        assertEquals(PlaybackStartupEvidence.UNAVAILABLE,
            settledStartupEvidence(PlaybackStartupEvidence.UNAVAILABLE, PlaybackStartupEvidence.MEDIA3_RENDERED_FIRST_FRAME))
    }
    @Test fun ownerTransitionCannotResurrectOldAttemptEvenWhenPublicBindingReturns() {
        val window = StartupCoverWindow(0)
        assertTrue(window.pending(0, pending, true))
        assertFalse(window.pending(1, pending, false))
        assertFalse(window.pending(2, pending, true))
    }
    @Test fun errorExitOrPipDisposalRetiresOnlyThisAttempt() {
        val old = StartupCoverWindow(0)
        assertFalse(old.pending(1, pending, true, allowed = false))
        assertFalse(old.pending(2, pending, true))
        assertTrue(StartupCoverWindow(2).pending(2, pending, true))
    }
    @Test fun clockRollbackFailsOpenRatherThanExtendingDeadline() {
        val window = StartupCoverWindow(100)
        assertFalse(window.pending(99, pending, true))
        assertFalse(window.pending(101, pending, true))
    }
    @Test fun nativeSampleBudgetThrottlesAndStopsAtFiniteDeadline() {
        val budget = StartupSampleBudget(0)
        assertTrue(budget.take(0))
        assertFalse(budget.take(0))
        assertFalse(budget.take(199))
        assertTrue(budget.take(200))
        assertFalse(budget.take(12_000))
        assertFalse(budget.take(12_200))
        assertFalse(budget.take(0))
    }
    @Test fun nativeSampleBudgetCannotBecomePermanentPolling() {
        val budget = StartupSampleBudget(0)
        assertEquals(60, (0..1000).count { budget.take(it * 200L) })
        assertFalse(budget.take(Long.MAX_VALUE))
    }
    @Test fun twoSettledConfiguredNativeSamplesAreNotCalledFirstPixels() {
        assertEquals(PlaybackStartupEvidence.MPV_CONFIGURED_SETTLED_CLOCK,
            mpvStartupEvidence(video(), video(1.2)))
        assertNotEquals(PlaybackStartupEvidence.MEDIA3_RENDERED_FIRST_FRAME,
            mpvStartupEvidence(video(), video(1.2)))
        assertNull(mpvStartupEvidence(null, video(1.2)))
    }
    @Test fun previousUnsettledOrUnconfiguredVideoCannotSeedReceipt() {
        listOf(video().copy(seeking = true), video().copy(cachePaused = true),
            video().copy(selectedVideo = false), video().copy(hasVideoTracks = false),
            video().copy(videoWidth = 0), video().copy(videoHeight = 0),
            video(Double.NaN), video(-1.0)).forEach { prior ->
            assertNull("Rejected prior: $prior", mpvStartupEvidence(prior, video(1.2)))
        }
    }
    @Test fun currentUnknownOrStaticClockCannotDismiss() {
        listOf(video().copy(seeking = true), video().copy(cachePaused = true),
            video().copy(selectedVideo = false), video().copy(hasVideoTracks = false),
            video().copy(videoWidth = 0), video().copy(videoHeight = 0),
            video(Double.NaN), video(Double.POSITIVE_INFINITY), video(-1.0), video(1.0)).forEach { current ->
            assertNull("Rejected current: $current", mpvStartupEvidence(video(), current))
        }
    }
    @Test fun definitiveAudioOnlyRequiresSelectedAdvancingAudioInBothSamples() {
        assertEquals(PlaybackStartupEvidence.AUDIO_ONLY, mpvStartupEvidence(audio(), audio(1.2)))
        listOf(audio().copy(selectedAudio = false), audio().copy(hasVideoTracks = true),
            audio().copy(audioClockSeconds = null), audio().copy(audioClockSeconds = Double.NaN),
            audio().copy(seeking = true), audio().copy(cachePaused = true)).forEach { prior ->
            assertNull(mpvStartupEvidence(prior, audio(1.2)))
        }
        assertNull(mpvStartupEvidence(audio(), audio(1.2).copy(hasVideoTracks = true)))
        assertNull(mpvStartupEvidence(audio(), audio(1.2).copy(audioClockSeconds = 1.0)))
        assertNull(mpvStartupEvidence(video(), audio(1.2)))
    }
    @Test fun absentOrRejectedNativeReadPerformsNoSample() {
        var sampled = 0
        assertNull(withAdmittedStartupRead<Any, Int>(null, { true }) { sampled += 1; 1 })
        assertNull(withAdmittedStartupRead(Any(), { false }) { sampled += 1; 1 })
        assertEquals(0, sampled)
    }
    @Test fun ownerOrEntryChangeDuringFreshReadRejectsResult() {
        var admitted = true
        val read = Any()
        assertNull(withAdmittedStartupRead(read, { admitted }) { admitted = false; 7 })
        assertEquals(7, withAdmittedStartupRead(read, { true }) { 7 })
    }
}
