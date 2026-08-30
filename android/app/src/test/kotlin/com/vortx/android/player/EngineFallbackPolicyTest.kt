package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineFallbackPolicyTest {
    @Test fun `surface and ao failures request same source engine fallback without source error`() {
        for (reason in EngineFallbackReason.entries) {
            val state = PlayerState(
                positionMs = 42_000L,
                hasError = true,
                hasEnded = true,
                isBuffering = true,
            ).requestEngineFallback(reason)
            assertEquals(reason, state.engineFallbackReason)
            assertEquals(42_000L, state.positionMs)
            assertFalse(state.hasError)
            assertFalse(state.hasEnded)
            assertFalse(state.isBuffering)
        }
    }

    @Test fun `each source session demotes at most once`() {
        assertTrue(shouldDemoteEngine(EngineFallbackReason.AUDIO_OUTPUT_FAILED, alreadyDemoted = false))
        assertFalse(shouldDemoteEngine(EngineFallbackReason.AUDIO_OUTPUT_FAILED, alreadyDemoted = true))
        assertFalse(shouldDemoteEngine(null, alreadyDemoted = false))
    }

    @Test fun `terminal before fallback is held then discarded by explicit engine verdict`() {
        val subject = EngineFailureCoordinator<String>()
        val opportunity = subject.beginOpportunity()
        assertEquals(EngineFailureResolution.None, subject.onTerminal("source-error"))
        assertEquals(
            EngineFailureResolution.Demote(EngineFallbackReason.AUDIO_OUTPUT_FAILED),
            subject.completeOpportunity(opportunity, EngineFallbackReason.AUDIO_OUTPUT_FAILED),
        )
        assertEquals(EngineFailureResolution.None, subject.onTerminal("late-error"))
    }

    @Test fun `fallback before terminal ignores old engine terminal and never demotes twice`() {
        val subject = EngineFailureCoordinator<String>()
        val opportunity = subject.beginOpportunity()
        val fallbackState = PlayerState(
            positionMs = 25_000,
            engineFallbackReason = EngineFallbackReason.SURFACE_ATTACH_FAILED,
        )
        assertEquals(
            EngineFailureResolution.Demote(EngineFallbackReason.SURFACE_ATTACH_FAILED),
            subject.completeOpportunity(opportunity, fallbackState.engineFallbackReason),
        )
        assertEquals(EngineFailureResolution.None, subject.onTerminal("old-engine-error"))
        assertEquals(EngineFailureResolution.None, subject.completeOpportunity(opportunity, fallbackState.engineFallbackReason))
        assertEquals(25_000L, fallbackState.positionMs)
    }

    @Test fun `genuine terminal commits only after explicit no fallback completion`() {
        val subject = EngineFailureCoordinator<String>()
        val surface = subject.beginOpportunity()
        val audio = subject.beginOpportunity()
        assertEquals(EngineFailureResolution.None, subject.onTerminal("source-error"))
        assertEquals(EngineFailureResolution.None, subject.completeOpportunity(surface))
        assertEquals(
            EngineFailureResolution.CommitTerminal("source-error"),
            subject.completeOpportunity(audio),
        )
        assertEquals(EngineFailureResolution.None, subject.onTerminal("duplicate"))
    }
}
