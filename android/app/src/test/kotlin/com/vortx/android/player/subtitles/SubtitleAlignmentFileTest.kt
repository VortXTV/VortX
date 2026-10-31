package com.vortx.android.player.subtitles

import java.io.ByteArrayInputStream
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class SubtitleAlignmentFileTest {
    @Test fun sizeCeilingRequiresActualEofAndNeverReturnsAnOversizedPrefix() {
        val exact = ByteArray(SubtitleAlignmentFile.MAX_BYTES) { 1 }
        assertArrayEquals(exact, SubtitleAlignmentFile.readBounded(ByteArrayInputStream(exact)))
        assertNull(SubtitleAlignmentFile.readBounded(ByteArrayInputStream(exact + byteArrayOf(2))))
    }

    @Test fun frozenRawFallbackUsesItsOwnedBytesAndUniqueFile() {
        val directory = Files.createTempDirectory("vortx-subtitle-owned-test").toFile()
        var first: SubtitleAlignmentFile? = null
        var second: SubtitleAlignmentFile? = null
        try {
            val bytes = "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n".toByteArray()
            first = SubtitleAlignmentFile.freeze(ByteArrayInputStream(bytes), directory)!!
            second = SubtitleAlignmentFile.freeze(ByteArrayInputStream(bytes), directory)!!
            bytes.fill(0)
            assertNotEquals(first.file, second.file)
            assertArrayEquals(first.bytes, first.file.readBytes())
            assertNotEquals(0, first.bytes[0].toInt())
        } finally {
            first?.file?.delete(); second?.file?.delete(); directory.delete()
        }
    }
}
