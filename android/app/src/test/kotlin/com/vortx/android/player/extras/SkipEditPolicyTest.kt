package com.vortx.android.player.extras

import com.vortx.android.skip.SkipSegment
import org.junit.Assert.assertEquals
import org.junit.Test

class SkipEditPolicyTest {

    @Test
    fun `existing span correction preserves kind and millisecond bounds`() {
        val draft = SkipEditPolicy.correctionDraft(
            SkipSegment(SkipSegment.Kind.CREDITS, start = 1_234.567, end = 1_987.654),
        )

        assertEquals(SkipSegment.Kind.CREDITS, draft.kind)
        assertEquals(1_234_567L, draft.startMs)
        assertEquals(1_987_654L, draft.endMs)
    }
}
