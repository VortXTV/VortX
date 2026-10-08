package com.vortx.android.player

import com.vortx.android.ui.viewmodel.DetailAutoPickIntent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DetailAutoPickIntentTest {
    @Test fun `Back cancels cold advance before delayed sources become ready`() {
        val intent = DetailAutoPickIntent()
        intent.setArmed(true)
        assertTrue(intent.consume(selectionReady = false) == null)
        intent.setArmed(false) // route abandoned, source fetch may still finish
        assertTrue(intent.consume(selectionReady = true) == null)
    }

    @Test fun `source target replacement preserves the newly armed advance until one ready batch`() {
        val intent = DetailAutoPickIntent()
        intent.setArmed(true)
        assertTrue(intent.consume(selectionReady = false) == null)
        assertTrue(intent.consume(selectionReady = true) != null)
        assertTrue(intent.consume(selectionReady = true) == null)
    }

    @Test fun `new deliberate episode selection may arm again after dismissal`() {
        val intent = DetailAutoPickIntent()
        intent.setArmed(true)
        intent.setArmed(false)
        intent.setArmed(true)
        assertTrue(intent.consume(selectionReady = true) != null)
    }

    @Test fun `Back after consumed intent rejects delayed settled source result`() {
        val intent = DetailAutoPickIntent()
        intent.setArmed(true)
        val lease = requireNotNull(intent.consume(selectionReady = true))
        assertTrue(intent.accepts(lease))
        intent.setArmed(false)
        assertFalse(intent.accepts(lease))
        intent.setArmed(true)
        assertFalse(intent.accepts(lease))
        assertTrue(intent.accepts(requireNotNull(intent.consume(selectionReady = true))))
    }
}
