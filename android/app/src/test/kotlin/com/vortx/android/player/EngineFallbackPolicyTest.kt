package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineFallbackPolicyTest {
    @Test fun `surface and ao failures request same source engine fallback without source error`() {
        for (reason in EngineFallbackReason.entries) {
            val state = PlayerState(positionMs = 42_000L).requestEngineFallback(reason)
            assertEquals(reason, state.engineFallbackReason)
            assertEquals(42_000L, state.positionMs)
            assertFalse(state.hasError)
            assertFalse(state.hasEnded)
        }
    }

    @Test fun `each source session demotes at most once`() {
        assertTrue(shouldDemoteEngine(EngineFallbackReason.AUDIO_OUTPUT_FAILED, alreadyDemoted = false))
        assertFalse(shouldDemoteEngine(EngineFallbackReason.AUDIO_OUTPUT_FAILED, alreadyDemoted = true))
        assertFalse(shouldDemoteEngine(null, alreadyDemoted = false))
    }

    @Test fun `terminal before fallback is discarded in favor of one demotion`() {
        val subject = EngineFailurePrecedence()
        assertEquals(EngineFailureAction.NONE, subject.observe(PlayerState(hasError = true, positionMs = 10_000)))
        assertEquals(
            EngineFailureAction.DEMOTE,
            subject.observe(
                PlayerState(
                    hasError = true,
                    positionMs = 10_000,
                    engineFallbackReason = EngineFallbackReason.AUDIO_OUTPUT_FAILED,
                ),
            ),
        )
        assertFalse(subject.commitTerminal())
    }

    @Test fun `fallback before terminal ignores old engine terminal and never demotes twice`() {
        val subject = EngineFailurePrecedence()
        val fallback = PlayerState(
            positionMs = 25_000,
            engineFallbackReason = EngineFallbackReason.SURFACE_ATTACH_FAILED,
        )
        assertEquals(EngineFailureAction.DEMOTE, subject.observe(fallback))
        assertEquals(EngineFailureAction.NONE, subject.observe(fallback.copy(hasError = true)))
        assertEquals(EngineFailureAction.NONE, subject.observe(fallback))
        assertFalse(subject.commitTerminal())
        assertEquals(25_000L, fallback.positionMs)
    }
}
