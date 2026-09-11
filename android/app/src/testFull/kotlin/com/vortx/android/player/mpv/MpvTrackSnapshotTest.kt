package com.vortx.android.player.mpv

import org.junit.Assert.*
import org.junit.Test

class MpvTrackSnapshotTest {
    @Test fun `invalid reads remain unknown rather than publishing empty tracks`() {
        for (json in listOf(null, "", "null", "{}", "[", "[null]", "[1]")) {
            assertNull("Unexpected authoritative snapshot for $json", parseMpvTrackSnapshot(json))
        }
        assertEquals(MpvTrackSnapshot(emptyList(), emptyList()), parseMpvTrackSnapshot("[]"))
    }

    @Test fun `malformed trailing entry never publishes a partial snapshot`() {
        assertNull(parseMpvTrackSnapshot("""[{"id":1,"type":"audio"},null]"""))
    }

    @Test fun `track metadata and forced subtitle disposition are retained`() {
        val result = requireNotNull(parseMpvTrackSnapshot("""[
          {"id":1,"type":"video"},
          {"id":2,"type":"audio","lang":"eng","selected":true,"demux-channel-count":6},
          {"id":3,"type":"sub","title":"Signs","forced":true}
        ]"""))
        assertEquals(1, result.audio.size)
        assertEquals("eng", result.audio.single().title)
        assertEquals(6, result.audio.single().channels)
        assertTrue(result.audio.single().selected)
        assertEquals("Signs", result.subtitles.single().title)
        assertTrue(result.subtitles.single().forced)
    }
}
