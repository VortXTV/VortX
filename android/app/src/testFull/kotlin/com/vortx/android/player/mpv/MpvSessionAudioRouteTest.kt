package com.vortx.android.player.mpv

import com.vortx.android.player.SessionAudioRouteRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Actual identity/one-shot primitives; source contracts separately bind their real controller callers. */
class MpvSessionAudioRouteTest {
    @Test fun `command first defers latest automatic route until matching loaded entry`() {
        val identity = MpvMetadataLoadIdentity()
        val pending = SessionAudioRouteRequest<String>()
        identity.begin(1)
        pending.defer("older")
        pending.defer("latest")
        identity.commandReturned(1, 42)
        assertNull(identity.capture(1, 42))
        identity.started(42)
        assertNull(identity.capture(1, 42))
        identity.loaded()
        assertEquals(42L, identity.capture(1, 42)?.entryID)
        assertEquals("latest", pending.take())
        assertNull(pending.take())
    }

    @Test fun `loaded first keeps automatic request until matching command return`() {
        val identity = MpvMetadataLoadIdentity()
        val pending = SessionAudioRouteRequest<String>()
        identity.begin(1)
        pending.defer("latest")
        identity.started(42)
        identity.loaded()
        assertNull(identity.capture(1, 42))
        identity.commandReturned(1, 42)
        assertEquals(42L, identity.capture(1, 42)?.entryID)
        assertEquals("latest", pending.take())
        assertNull(pending.take())
    }

    @Test fun `explicit submission retires previous automatic request and failure cannot loop`() {
        val pending = SessionAudioRouteRequest<String>()
        pending.defer("old passthrough")
        pending.clear() // The live submission supersedes the automatic request before readback.
        assertNull(pending.take())
        pending.defer("new route")
        assertEquals("new route", pending.take())
        assertNull(pending.take()) // A failed one-shot application cannot automatically retry.
    }

    @Test fun `release clears request and retired identity never admits old entry`() {
        val identity = MpvMetadataLoadIdentity()
        val pending = SessionAudioRouteRequest<String>()
        identity.begin(1)
        pending.defer("route")
        identity.retire()
        pending.clear()
        identity.commandReturned(1, 42)
        identity.started(42)
        identity.loaded()
        assertNull(identity.capture(1, 42))
        assertNull(pending.take())
    }
}
