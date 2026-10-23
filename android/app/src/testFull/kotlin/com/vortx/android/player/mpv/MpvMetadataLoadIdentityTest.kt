package com.vortx.android.player.mpv

import org.junit.Assert.*
import org.junit.Test

/** Calls the actual production correlation primitive. Authored, UNRUN; no native playback claim. */
class MpvMetadataLoadIdentityTest {
    @Test fun startAndLoadedBeforeReturnStillAdmitExactLongID() {
        val gate = MpvMetadataLoadIdentity()
        val id = Int.MAX_VALUE.toLong() + 100L
        gate.begin(1); gate.started(id); gate.loaded()
        assertNull(gate.capture(1, id))
        gate.commandReturned(1, id)
        assertEquals(id, gate.capture(1, id)?.entryID)
    }

    @Test fun returnBeforeEventsNeedsBothOriginalEvents() {
        val gate = MpvMetadataLoadIdentity()
        gate.begin(1); gate.commandReturned(1, 42)
        assertNull(gate.capture(1, 42))
        gate.started(42); assertNull(gate.capture(1, 42))
        gate.loaded(); assertNotNull(gate.capture(1, 42))
    }

    @Test fun lateOldEventsAndReturnCannotRebindSameURLReload() {
        val gate = MpvMetadataLoadIdentity()
        gate.begin(1); gate.commandReturned(1, 10); gate.started(10); gate.loaded()
        val old = requireNotNull(gate.capture(1, 10))
        gate.begin(2); gate.commandReturned(2, 11)
        gate.started(10); gate.loaded(); gate.commandReturned(1, 10)
        assertNull(gate.capture(2, 11)); assertFalse(gate.accepts(old, 2, 10))
        gate.started(11); gate.loaded(); assertNotNull(gate.capture(2, 11))
        gate.begin(3); gate.commandReturned(3, 12)
        assertNull(gate.capture(3, 10)) // Same URL A again is a different native ID, not A's old receipt.
    }

    @Test fun nativePlayingEntryChangeInvalidatesSuspendedSample() {
        val gate = MpvMetadataLoadIdentity()
        gate.begin(7); gate.commandReturned(7, 71); gate.started(71); gate.loaded()
        val read = requireNotNull(gate.capture(7, 71))
        assertFalse(gate.accepts(read, 7, 72))
        gate.started(72); gate.loaded()
        assertFalse(gate.accepts(read, 7, 71))
    }

    @Test fun missingMalformedFailedAndEndedIdentityNeverProduceFacts() {
        val gate = MpvMetadataLoadIdentity()
        gate.begin(1); gate.commandReturned(1, null); gate.started(10); gate.loaded()
        assertNull(gate.capture(1, 10))
        gate.commandReturned(1, -1); assertNull(gate.capture(1, -1))
        gate.commandReturned(1, 10); gate.started(-1); gate.loaded()
        assertNull(gate.capture(1, 10))
        gate.started(10); gate.loaded(); gate.ended(); assertNull(gate.capture(1, 10))
    }

    @Test fun lostEventOrderAndReleaseFailClosedUntilNewLoad() {
        val gate = MpvMetadataLoadIdentity()
        gate.begin(1); gate.commandReturned(1, 10); gate.started(10); gate.loaded()
        gate.queueOverflow(); gate.started(10); gate.loaded(); assertNull(gate.capture(1, 10))
        gate.begin(2); gate.commandReturned(2, 20); gate.started(20); gate.loaded()
        assertNotNull(gate.capture(2, 20))
        gate.retire(); gate.started(20); gate.loaded(); gate.commandReturned(2, 20)
        assertNull(gate.capture(2, 20))
    }
}
