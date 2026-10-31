package com.vortx.android.player.subtitles

import org.junit.Assert.*
import org.junit.Test

/** Pure admission framing only; actual Media3/Html parser execution requires Android. */
class Media3OwnedSubtitleSrtEnvelopeTest {
    private fun inspect(text: String) = Media3OwnedSubtitleSrtEnvelope.inspect(text.toByteArray(Charsets.UTF_8))

    @Test fun bomCrLfFinalTextAtEofAndMedia3OptionalTimeComponentsAreAccepted() {
        val rows = requireNotNull(inspect("\ufeff1\r\n00:00:01,000 --> 00:00:02,000\r\n{\\an8}<b>A</b>\r\n\r\n" +
            "2\r\n00:02 --> 00:03\r\nB"))
        assertEquals(listOf(Media3OwnedSubtitleSrtEnvelope.Timing(1000, 2000),
            Media3OwnedSubtitleSrtEnvelope.Timing(2000, 3000)), rows)
    }

    @Test fun incompleteHeadersInvalidBlocksAndTrailingJunkRefuseTheCompleteFile() {
        val prefix = "1\n00:00:00,000 --> 00:00:01,000\nvalid\n\n"
        for (bad in listOf("2", "2\n", "2\n00:00:01,000 -->", "2\n00:00:01,000 --> 00:00:02,000",
            "junk", "2\nbad timing\ntext", " 2\n00:00:01,000 --> 00:00:02,000\ntext")) {
            assertNull(bad, inspect(prefix + bad))
        }
        assertNull(inspect("1\n00:00:01,000 --> 00:00:01,000\nx"))
        assertNull(inspect("1\n00:00:00,000 --> 99:00:00,000\nx"))
        assertNull(inspect("1\n999999999999999999999:00:00 --> 99:00:00\nx"))
        assertNull(inspect("1\n00:00:01,000 --> 00:00:02,000\nx\n\n2\n00:00:00,000 --> 00:00:01,000\ny"))
    }

    @Test fun strictEncodingTextAndWholeFileBoundsAreEnforced() {
        assertNull(Media3OwnedSubtitleSrtEnvelope.inspect(byteArrayOf(0xc0.toByte(), 0xaf.toByte())))
        assertNull(Media3OwnedSubtitleSrtEnvelope.inspect(ByteArray(1024 * 1024 + 1)))
        assertNull(inspect("1\n00:00:00,000 --> 00:00:01,000\nx\u0000"))
        val prefix = "1\n00:00:00,000 --> 00:00:01,000\n"
        assertNotNull(inspect(prefix + "a".repeat(16_384)))
        assertNull(inspect(prefix + "a".repeat(16_385)))
        assertNull(inspect(prefix + "é".repeat(8193)))
        assertNull(inspect("\n\n"))
    }

    @Test fun equalStartsRepeatsAndNativeMarkupAreNotDeduplicatedOrInterpretedByFraming() {
        val rows = requireNotNull(inspect("1\n00:00:01,000 --> 00:00:03,000\n{\\an8}<ruby>A</ruby>\n\n" +
            "2\n00:00:01,000 --> 00:00:02,000\n{\\an8}<ruby>A</ruby>\n"))
        assertEquals(2, rows.size)
        assertEquals(1000L, rows[0].startMs)
        assertEquals(1000L, rows[1].startMs)
        try { (rows as MutableList<Media3OwnedSubtitleSrtEnvelope.Timing>).clear(); fail("immutable") }
        catch (_: UnsupportedOperationException) { }
    }
}
