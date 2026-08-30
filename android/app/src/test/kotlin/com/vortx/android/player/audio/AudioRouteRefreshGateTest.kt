package com.vortx.android.player.audio

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioRouteRefreshGateTest {
    @Test fun `start schedules one current route refresh and is idempotent`() {
        val gate = AudioRouteRefreshGate()
        assertTrue(gate.start())
        assertFalse(gate.start())
        assertTrue(gate.consume())
        assertFalse(gate.consume())
    }

    @Test fun `route bursts coalesce and stop cancels pending refresh`() {
        val gate = AudioRouteRefreshGate()
        gate.start()
        gate.consume()
        assertTrue(gate.schedule())
        assertTrue(gate.schedule())
        assertTrue(gate.stop())
        assertFalse(gate.consume())
        assertFalse(gate.schedule())
        assertFalse(gate.stop())
    }
}
