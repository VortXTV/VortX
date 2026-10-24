package com.vortx.android.player

import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import org.junit.Assert.*
import org.junit.Test

@UnstableApi
class ExoStartupAdmissionTest {
    private fun context(load: ExoMetadataInputs.Load, sequence: Long = 1L, uid: String = "period") =
        ExoMetadataInputs.Context(load, MediaPeriodId(uid, sequence))

    @Test fun eventPlayingPeriodAndActualTagAllMustMatch() {
        val inputs = ExoMetadataInputs()
        val load = inputs.begin()
        val current = context(load)
        inputs.observeCurrent(current)
        assertTrue(inputs.acceptsPresentation(current, current, load, "period"))
        assertFalse(inputs.acceptsPresentation(current, context(load, 2), load, "period"))
        assertFalse(inputs.acceptsPresentation(current, current, Any(), "period"))
        assertFalse(inputs.acceptsPresentation(current, current, load, "other"))
        assertFalse(inputs.acceptsPresentation(current, current, load, null))
    }
    @Test fun oldSameUrlPeriodAndLoadCannotReviveSuccessor() {
        val inputs = ExoMetadataInputs()
        val oldLoad = inputs.begin()
        val old = context(oldLoad)
        inputs.observeCurrent(old)
        val nextLoad = inputs.begin()
        val next = context(nextLoad)
        inputs.observeCurrent(next)
        assertFalse(inputs.acceptsPresentation(old, old, oldLoad, "period"))
        assertFalse(inputs.acceptsPresentation(old, next, nextLoad, "period"))
        assertTrue(inputs.acceptsPresentation(next, next, nextLoad, "period"))
    }
    @Test fun adsUnknownSequenceAndMissingContextsAreNotFrameReceipts() {
        val inputs = ExoMetadataInputs()
        val load = inputs.begin()
        val current = context(load)
        inputs.observeCurrent(current)
        val ad = ExoMetadataInputs.Context(load, MediaPeriodId("period", 0, 0, 1L))
        assertFalse(inputs.acceptsPresentation(ad, ad, load, "period"))
        assertFalse(inputs.acceptsPresentation(context(load, -1), context(load, -1), load, "period"))
        assertFalse(inputs.acceptsPresentation(null, current, load, "period"))
        assertFalse(inputs.acceptsPresentation(current, null, load, "period"))
    }
    @Test fun failAndReleaseCloseAllPresentationAdmission() {
        val inputs = ExoMetadataInputs()
        val load = inputs.begin()
        val current = context(load)
        inputs.observeCurrent(current)
        inputs.fail()
        assertFalse(inputs.acceptsPresentation(current, current, load, "period"))
        inputs.release()
        val late = inputs.begin()
        val lateContext = context(late)
        inputs.observeCurrent(lateContext)
        assertFalse(inputs.acceptsPresentation(lateContext, lateContext, late, "period"))
    }
}
