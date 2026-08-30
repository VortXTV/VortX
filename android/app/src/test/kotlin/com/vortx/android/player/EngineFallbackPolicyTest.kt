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
}
