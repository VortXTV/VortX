package com.vortx.android.player.mpv

import org.junit.Assert.*
import org.junit.Test

class MpvSubtitleRetirementGateTest {
    @Test fun sourceReplacementDropsOldTerminalButKeepsOriginalHandleCleanup() {
        val gate = MpvSubtitleRetirementGate<String>()
        gate.beginSource(1)
        val original = gate.beginRetirement()!!
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.onTerminal(1, "old EOF"))
        gate.beginSource(2)
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.onTerminal(2, "new EOF"))
        assertEquals(MpvSubtitleRetirementGate.Resolution.Terminal(2, "new EOF"), gate.complete(original, false))
    }

    @Test fun delayedOldVerdictRetainsItsOriginalGenerationAfterSourceReset() {
        val gate = MpvSubtitleRetirementGate<String>()
        gate.beginSource(1)
        val retirement = gate.beginRetirement()!!
        gate.beginSource(2)
        // The real host carries generation in the immutable verdict through its source coordinator.
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.onTerminal(1, "delayed old EOF"))
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.complete(retirement, false))
        assertEquals(MpvSubtitleRetirementGate.Resolution.Terminal(2, "new EOF"), gate.onTerminal(2, "new EOF"))
    }

    @Test fun unknownRetirementDestroysThisPermanentHandleAcrossSourceChanges() {
        val gate = MpvSubtitleRetirementGate<String>()
        gate.beginSource(1)
        val original = gate.beginRetirement()!!
        gate.beginSource(2)
        gate.onTerminal(2, "must not complete")
        assertEquals(MpvSubtitleRetirementGate.Resolution.HandleUnavailable, gate.complete(original, true))
        assertFalse(gate.isUsable)
        assertFalse(gate.beginSource(3))
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.onTerminal(2, "late EOF"))
        assertNull(gate.beginRetirement())
    }

    @Test fun everyCloseMustFinishAndDuplicateOrForeignReceiptsCannotReleaseTheHold() {
        val gate = MpvSubtitleRetirementGate<String>()
        val other = MpvSubtitleRetirementGate<String>()
        gate.beginSource(7)
        val first = gate.beginRetirement()!!
        val second = gate.beginRetirement()!!
        val foreign = other.beginRetirement()!!
        gate.onTerminal(7, "EOF")
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.complete(foreign, false))
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.complete(first, false))
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.complete(first, true))
        assertEquals(MpvSubtitleRetirementGate.Resolution.Terminal(7, "EOF"), gate.complete(second, false))
    }

    @Test fun retiredHostCannotReceiveLateCleanupOrTerminalPublication() {
        val gate = MpvSubtitleRetirementGate<String>()
        gate.beginSource(1)
        val original = gate.beginRetirement()!!
        gate.onTerminal(1, "EOF")
        gate.retire()
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.complete(original, true))
        assertEquals(MpvSubtitleRetirementGate.Resolution.None, gate.onTerminal(1, "EOF"))
        assertFalse(gate.isUsable)
    }
}
