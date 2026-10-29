package com.vortx.android.party

import org.junit.Assert.*
import org.junit.Test

class WatchPartyWireTest {
    private val room = "r".repeat(32)
    @Test fun encryptedRoundTripIsBoundToRoomTermAndReservedSequence() {
        val key = WatchPartyWire.roomKey()
        val control = WatchPartyWire.Control("seek", requireNotNull(WatchPartyWire.titleToken("tt12345:3:23")), 123_456)
        val sealed = WatchPartyWire.seal(control, key, room, 1, 7)
        assertEquals(control, WatchPartyWire.open(sealed, key, room, 1, 7))
        assertThrows(Exception::class.java) { WatchPartyWire.open(sealed, key, "x".repeat(32), 1, 7) }
        assertThrows(Exception::class.java) { WatchPartyWire.open(sealed, key, room, 2, 7) }
        assertThrows(Exception::class.java) { WatchPartyWire.open(sealed, key, room, 1, 8) }
        assertThrows(Exception::class.java) { WatchPartyWire.open(sealed, ByteArray(32), room, 1, 7) }
        assertFalse(sealed.contains("tt12345"))
    }
    @Test fun explicitFragmentInviteRoundTripsWithoutQueryCredential() {
        val invite = WatchPartyInvite.make(room, "i".repeat(32), ByteArray(32) { it.toByte() })
        val url = invite.link()
        assertTrue(url.startsWith("https://vortx.tv/watch-party#"))
        assertFalse(url.substringBefore('#').contains('?'))
        assertNull(WatchPartyInvite.parse(url.replace("https://vortx.tv/watch-party", "vortx://watch-party")))
        assertNull(WatchPartyInvite.parse(url.replace("https://", "http://")))
        assertNull(WatchPartyInvite.parse(url.replace("vortx.tv", "untrusted.example")))
        val parsed = requireNotNull(WatchPartyInvite.parse(url))
        assertEquals(room, parsed.roomId)
        assertArrayEquals(invite.copyKey(), parsed.copyKey())
        assertEquals("WatchPartyInvite(redacted)", parsed.toString())
    }
    @Test fun inviteRejectsDuplicateReorderedEncodedOrExternalFields() {
        val link = WatchPartyInvite.make(room, "i".repeat(32), ByteArray(32)).link()
        for (bad in listOf(link.replace("https:", "vortx:"), link.replace("#", "?"),
            "$link&key=other", link.replace("v=1&room=", "room="),
            link.replace("room=$room", "room=%72${room.drop(1)}"),
            link.replace("/watch-party#", "/watch-party/path#"),
            link.replace("/watch-party#", "/watch-party?x=1#"))) assertNull(bad, WatchPartyInvite.parse(bad))
    }
    @Test fun exactVideoIdAndEpisodeAreNeverCollapsedOrTruncated() {
        assertNotEquals(WatchPartyWire.titleToken("tt123:3:22"), WatchPartyWire.titleToken("tt123:3:23"))
        assertNotEquals(WatchPartyWire.titleToken("tt123"), WatchPartyWire.titleToken("TT123"))
        assertNull(WatchPartyWire.titleToken(""))
        assertNull(WatchPartyWire.titleToken("x".repeat(513)))
        assertNull(WatchPartyWire.titleToken("\uD800"))
        assertEquals(43, requireNotNull(WatchPartyWire.titleToken("tt123:3:23")).length)
    }
}
