package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionAudioPresetSessionTest {
    @Test fun `stock engine state has no DSP checkmark and no enabled choice`() {
        val state = SessionAudioPresetState()
        assertEquals(SessionAudioPresetAvailability.UNSUPPORTED, state.availability)
        assertNull(state.selected)
        SessionAudioPreset.entries.forEach { assertFalse(state.canSelect(it)) }
    }

    @Test fun `load hides checkmark but keeps session intent until actual receipt`() {
        val session = SessionAudioPresetSession()
        assertTrue(session.receive(SessionAudioPreset.NIGHT, intArrayOf(0, 2), false))
        session.loading()
        assertEquals(SessionAudioPreset.NIGHT, session.wanted)
        assertNull(session.state.selected)
        assertFalse(session.state.canSelect(SessionAudioPreset.NORMAL))
        assertTrue(session.receive(session.wanted, intArrayOf(0, 2), false))
        assertEquals(SessionAudioPreset.NIGHT, session.state.selected)
    }

    @Test fun `rejection restores prior native selection without changing wanted intent`() {
        val session = SessionAudioPresetSession()
        session.receive(SessionAudioPreset.DIALOGUE, intArrayOf(0, 1), false)
        assertFalse(session.receive(SessionAudioPreset.NIGHT, intArrayOf(2, 1), false))
        assertEquals(SessionAudioPreset.DIALOGUE, session.wanted)
        assertEquals(SessionAudioPreset.DIALOGUE, session.state.selected)
        assertEquals(SessionAudioPresetNotice.REJECTED_RESTORED, session.state.notice)
    }

    @Test fun `failed rollback is unknown with only Normal recovery available`() {
        val session = SessionAudioPresetSession()
        session.receive(SessionAudioPreset.DIALOGUE, intArrayOf(0, 1), false)
        assertFalse(session.receive(SessionAudioPreset.NIGHT, intArrayOf(3, -1), false))
        assertNull(session.state.selected)
        assertEquals(SessionAudioPresetAvailability.UNKNOWN, session.state.availability)
        assertTrue(session.state.canSelect(SessionAudioPreset.NORMAL))
        assertFalse(session.state.canSelect(SessionAudioPreset.NIGHT))
    }

    @Test fun `restored status without observed prior preset is unknown not a restoration claim`() {
        val session = SessionAudioPresetSession()
        assertTrue(session.receive(SessionAudioPreset.DIALOGUE, intArrayOf(0, 1), false))
        assertFalse(session.receive(SessionAudioPreset.NIGHT, intArrayOf(2, -1), false))
        assertEquals(SessionAudioPreset.DIALOGUE, session.wanted)
        assertNull(session.state.selected)
        assertEquals(SessionAudioPresetAvailability.UNKNOWN, session.state.availability)
        assertEquals(SessionAudioPresetNotice.UNKNOWN, session.state.notice)
    }

    @Test fun `missing ABI collision and malformed receipts never claim requested choice`() {
        listOf(null, intArrayOf(), intArrayOf(0), intArrayOf(99, 2), intArrayOf(0, 1),
            intArrayOf(0, -1), intArrayOf(0, 3), intArrayOf(4, -1)).forEach { receipt ->
            val session = SessionAudioPresetSession()
            assertFalse(session.receive(SessionAudioPreset.NIGHT, receipt, false))
            assertNull(session.state.selected)
            assertEquals(SessionAudioPreset.NORMAL, session.wanted)
        }
    }

    @Test fun `passthrough disables added DSP and checked Normal withdraws wanted processing`() {
        val session = SessionAudioPresetSession()
        session.receive(SessionAudioPreset.NIGHT, intArrayOf(0, 2), false)
        session.refuse(SessionAudioPresetAvailability.PASSTHROUGH)
        assertFalse(session.state.canSelect(SessionAudioPreset.NIGHT))
        assertTrue(session.state.canSelect(SessionAudioPreset.NORMAL))
        assertTrue(session.receive(SessionAudioPreset.NORMAL, intArrayOf(0, 0), true))
        assertEquals(SessionAudioPreset.NORMAL, session.wanted)
        assertEquals(SessionAudioPresetAvailability.PASSTHROUGH, session.state.availability)
    }

    @Test fun `unchanged means observed native identity matched not an optimistic shortcut`() {
        val session = SessionAudioPresetSession()
        assertTrue(session.receive(SessionAudioPreset.NORMAL, intArrayOf(1, 0), false))
        assertFalse(session.receive(SessionAudioPreset.NIGHT, intArrayOf(1, 0), false))
        assertNull(session.state.selected)
    }

    @Test fun `teardown resets both wanted intent and published selection`() {
        val session = SessionAudioPresetSession()
        session.receive(SessionAudioPreset.DIALOGUE, intArrayOf(0, 1), false)
        session.reset()
        assertEquals(SessionAudioPreset.NORMAL, session.wanted)
        assertNull(session.state.selected)
        assertEquals(SessionAudioPresetAvailability.NOT_READY, session.state.availability)
    }
}
