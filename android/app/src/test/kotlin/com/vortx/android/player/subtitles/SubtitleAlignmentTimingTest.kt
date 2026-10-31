package com.vortx.android.player.subtitles

import org.junit.Assert.*
import org.junit.Test

class SubtitleAlignmentTimingTest {
    private val admit: ((() -> Boolean) -> Boolean) = { it() }

    @Test fun pendingAlignmentHoldsCommunityUntilTheExactAttemptFinishes() {
        val session = SubtitleTimingSession(null)
        val first = session.beginAlignment()!!
        assertFalse(session.applyCommunityAccepted(900, true, admit) { true })
        val second = session.beginAlignment()!!
        assertFalse(session.finishAlignment(first, aligned = false))
        assertFalse(session.applyCommunityAccepted(900, true, admit) { true })
        assertTrue(session.finishAlignment(second, aligned = false))
        assertTrue(session.applyCommunityAccepted(900, true, admit) { true })
    }

    @Test fun onlyAppliedCommunityTimingCanBeResetForNativeCapture() {
        val session = SubtitleTimingSession(null)
        assertTrue(session.applyCommunityAccepted(900, true, admit) { true })
        val attempt = session.beginAlignment()!!
        var clears = 0
        assertFalse(session.prepareAlignment(attempt, admit) { false })
        assertTrue(session.prepareAlignment(attempt, admit) { clears++; true })
        assertTrue(session.prepareAlignment(attempt, admit) { clears++; true })
        assertEquals(1, clears)
        assertTrue(session.finishAlignment(attempt, aligned = true))
        assertFalse(session.applyCommunityAccepted(1500, true, admit) { true })
    }

    @Test fun savedAndNewManualTimingAreNeverClearedToGainCapability() {
        for (manual in listOf(0.0, 1.4, -0.7)) {
            val session = SubtitleTimingSession(manual)
            val attempt = session.beginAlignment()!!
            assertTrue(session.prepareAlignment(attempt, admit) { fail("Manual offset was cleared"); false })
            assertTrue(session.finishAlignment(attempt, aligned = false))
            assertFalse(session.applyCommunityAccepted(900, true, admit) { true })
        }
        val session = SubtitleTimingSession(null)
        val pending = session.beginAlignment()!!
        assertTrue(session.applyManualAccepted(0.0, true, admit) { true })
        assertFalse(session.finishAlignment(pending, aligned = false))
        assertFalse(session.applyCommunityAccepted(900, true, admit) { true })
    }

    @Test fun rejectedManualWriteDoesNotReleasePendingAlignment() {
        val session = SubtitleTimingSession(null)
        val attempt = session.beginAlignment()!!
        assertFalse(session.applyManualAccepted(1.0, true, admit) { false })
        assertFalse(session.applyCommunityAccepted(900, true, admit) { true })
        assertTrue(session.finishAlignment(attempt, aligned = true))
    }

    @Test fun ownerDenialAndRetirementCannotResetOrSeedAnotherScope() {
        val session = SubtitleTimingSession(null)
        assertTrue(session.applyCommunityAccepted(900, true, admit) { true })
        val attempt = session.beginAlignment()!!
        assertFalse(session.prepareAlignment(attempt, { false }) { fail("Retired owner wrote native delay"); false })
        session.retire()
        assertFalse(session.prepareAlignment(attempt, admit) { fail("Retired source wrote native delay"); false })
        assertFalse(session.finishAlignment(attempt, aligned = true))
        assertNull(session.beginAlignment())
        val next = SubtitleTimingSession(null)
        assertTrue(next.applyCommunityAccepted(900, true, admit) { true })
    }
}
