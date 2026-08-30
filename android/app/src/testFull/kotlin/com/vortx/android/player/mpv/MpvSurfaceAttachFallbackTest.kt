package com.vortx.android.player.mpv

import com.vortx.android.player.EngineFallbackReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class MpvSurfaceAttachFallbackTest {
    @Test fun `successful attach needs no fallback`() {
        assertNull(attachMpvSurfaceOrFallback {})
    }

    @Test fun `ordinary attach failure requests Media3 fallback`() {
        assertEquals(
            EngineFallbackReason.SURFACE_ATTACH_FAILED,
            attachMpvSurfaceOrFallback { throw IllegalStateException("surface rejected") },
        )
    }

    @Test fun `virtual machine failure propagates`() {
        val failure = OutOfMemoryError("fatal")
        assertSame(failure, thrownBy { attachMpvSurfaceOrFallback { throw failure } })
    }

    @Test fun `thread death propagates`() {
        val failure = ThreadDeath()
        assertSame(failure, thrownBy { attachMpvSurfaceOrFallback { throw failure } })
    }

    private fun thrownBy(block: () -> Unit): Throwable = try {
        block()
        throw AssertionError("expected failure")
    } catch (failure: Throwable) {
        failure
    }
}
