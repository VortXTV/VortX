package com.vortx.android.player.mpv

import com.vortx.android.player.SubtitleSelectionAuthority
import org.junit.Assert.*
import org.junit.Test

class MpvAutomaticSubtitleIdentityTest {
    private val path = "/data/user/0/test/cache/vortx-sub-align-owned.srt"
    private fun track(id: String = "4", filename: String = path, external: String = "true") =
        """{"id":$id,"type":"sub","external":$external,"external-filename":"$filename"}"""

    @Test fun onlyTheUniqueActualSelectedExternalPathIsAVisiblePrimaryReceipt() {
        assertEquals(4, uniqueMpvExternalSubtitleId("[${track()}]", path, 4))
        assertNull(uniqueMpvExternalSubtitleId("[${track()}]", path, 5))
        assertNull(uniqueMpvExternalSubtitleId("[${track(filename = "/different/file.srt")}]", path, 4))
        assertNull(uniqueMpvExternalSubtitleId("[${track(external = "false")}]", path, 4))
        assertNull(uniqueMpvExternalSubtitleId("[${track()},${track(id = "5")}]", path, 4))
    }

    @Test fun malformedOrNarrowedIdsCannotNameTheMountedRawFallback() {
        for (id in listOf("0", "-1", "2147483648", "4.5", "\"4\"", "true"))
            assertNull(id, uniqueMpvExternalSubtitleId("[${track(id = id)}]", path, 4))
        assertNull(uniqueMpvExternalSubtitleId("not-json", path, 4))
        assertNull(uniqueMpvExternalSubtitleId(null, path, 4))
    }

    @Test fun longIdsCannotWrapIntoAValidNativeSelectorBeforeBoundsAreChecked() {
        // These JSON numbers are Long values. Their low bits used to narrow to positive selectors.
        for (id in listOf("-4294967292", "-9223372036854775804", "-2147483649")) {
            assertNull(id, uniqueMpvExternalSubtitleId("[${track(id = id)}]", path, 4))
            assertNull(id, uniqueMpvExternalSubtitleId("[${track(id = id)}]", path, Int.MAX_VALUE))
        }
        assertEquals(1, uniqueMpvExternalSubtitleId("[${track(id = "1")}]", path, 1))
        assertEquals(Int.MAX_VALUE, uniqueMpvExternalSubtitleId(
            "[${track(id = Int.MAX_VALUE.toString())}]", path, Int.MAX_VALUE))
    }

    @Test fun discardOfOlderAttemptCannotRetireItsSuccessor() {
        val selections = SubtitleSelectionAuthority()
        selections.beginSource(1L)
        val transport = MpvAutomaticSubtitleAlignment()
        val first = transport.begin(selections.beginChoice()!!)
        first.second()
        val second = transport.begin(selections.beginChoice()!!)
        second.second()
        assertFalse(transport.isCurrent(first.first))
        assertTrue(transport.isCurrent(second.first))
        transport.discard(first.first)
        assertTrue(transport.isCurrent(second.first))
        transport.takeRetirement().invoke()
        assertFalse(transport.isCurrent(second.first))
    }
}
