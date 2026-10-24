package com.vortx.android.player.subtitles

import org.junit.Assert.*
import org.junit.Test

/** Real timing policy with an explicit final-operation refusal; not a native/JNI test. */
class SubtitleTimingAdmissionTest {
    private val admit: ((() -> Boolean) -> Boolean) = { it() }

    @Test fun rejectedCommunityNativeWriteDoesNotSeedOrBlockAnAcceptedRetry() {
        val session = SubtitleTimingSession(null)
        val applied = mutableListOf<Double>()
        assertFalse(session.applyCommunityAccepted(900, true, admit) { false })
        assertTrue(session.applyCommunityAccepted(1100, true, admit) { applied.add(it) })
        assertEquals(listOf(1.1), applied)
        assertFalse(session.applyCommunityAccepted(1300, true, admit) { error("already seeded") })
    }

    @Test fun rejectedManualNativeWriteDoesNotPoisonCommunityButAcceptedZeroStillWins() {
        val session = SubtitleTimingSession(null)
        val applied = mutableListOf<Double>()
        assertFalse(session.applyManualAccepted(0.0, true, admit) { false })
        assertTrue(session.applyCommunityAccepted(700, true, admit) { applied.add(it) })
        assertTrue(session.applyManualAccepted(0.0, true, admit) { applied.add(it) })
        assertFalse(session.applyCommunityAccepted(900, true, admit) { error("manual wins") })
        assertEquals(listOf(0.7, 0.0), applied)
    }
}
