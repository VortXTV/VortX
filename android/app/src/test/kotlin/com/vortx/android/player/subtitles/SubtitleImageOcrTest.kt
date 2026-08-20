package com.vortx.android.player.subtitles

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests for the pure OCR policy, bitmap conversion, recognizer hook, and SRT serialization. */
class SubtitleImageOcrTest {

    @After
    fun tearDown() {
        SubtitleImageOcr.recognizerProvider = null
    }

    @Test
    fun rectangleAndAppendCapsMatchApple() {
        assertFalse(SubtitleImageOcr.acceptsRectangleCount(0))
        assertTrue(SubtitleImageOcr.acceptsRectangleCount(1))
        assertTrue(SubtitleImageOcr.acceptsRectangleCount(SubtitleImageOcr.MAX_BITMAPS_PER_ITEM))
        assertFalse(SubtitleImageOcr.acceptsRectangleCount(SubtitleImageOcr.MAX_BITMAPS_PER_ITEM + 1))

        assertTrue(SubtitleImageOcr.canAppendBitmap(existingCount = 0, existingBytes = 0, nextBytes = 1024))
        assertFalse(SubtitleImageOcr.canAppendBitmap(existingCount = 0, existingBytes = 0, nextBytes = 0))
        // Exceeding the per-item byte cap is refused.
        assertFalse(
            SubtitleImageOcr.canAppendBitmap(
                existingCount = 1,
                existingBytes = SubtitleImageOcr.MAX_BITMAP_BYTES_PER_ITEM,
                nextBytes = 1,
            ),
        )
    }

    @Test
    fun cueTimingUsesDecoderEndThenFallsBackToPacketDuration() {
        // Explicit finite end wins.
        assertEquals(
            10.5 to 2.0,
            SubtitleImageOcr.cueTiming(
                packetStartSeconds = 10.0, packetDurationSeconds = 9.9,
                displayStartMs = 500, displayEndMs = 2500,
            ),
        )
        // The open-end sentinel falls back to the container packet duration.
        assertEquals(
            10.5 to 3.0,
            SubtitleImageOcr.cueTiming(
                packetStartSeconds = 10.0, packetDurationSeconds = 3.0,
                displayStartMs = 500, displayEndMs = SubtitleImageOcr.OPEN_END_SENTINEL_MS,
            ),
        )
        // A negative start is rejected.
        assertNull(
            SubtitleImageOcr.cueTiming(
                packetStartSeconds = -1.0, packetDurationSeconds = 3.0,
                displayStartMs = 0, displayEndMs = 1000,
            ),
        )
    }

    @Test
    fun toGrayscaleRejectsMalformedAndConvertsOpaqueWhite() {
        // A too-small bitmap is rejected.
        assertNull(
            SubtitleImageOcr.toGrayscale(
                SubtitleImageOcr.ImageBitmap(4, 4, ByteArray(16), ByteArray(SubtitleImageOcr.PALETTE_BYTES)),
            ),
        )
        // 8x8 all pointing at palette index 1 = opaque white -> Apple's formula drives every pixel to 0.
        val palette = ByteArray(SubtitleImageOcr.PALETTE_BYTES)
        val whiteEntry = 1 * 4
        palette[whiteEntry] = 0xFF.toByte()     // B
        palette[whiteEntry + 1] = 0xFF.toByte() // G
        palette[whiteEntry + 2] = 0xFF.toByte() // R
        palette[whiteEntry + 3] = 0xFF.toByte() // A (opaque)
        val indices = ByteArray(64) { 1 }
        val gray = SubtitleImageOcr.toGrayscale(SubtitleImageOcr.ImageBitmap(8, 8, indices, palette))!!
        assertEquals(64, gray.pixels.size)
        assertTrue(gray.pixels.all { (it.toInt() and 0xFF) == 0 })
    }

    @Test
    fun recognizeItemNoOpsWithoutRecognizer() = runBlocking {
        SubtitleImageOcr.recognizerProvider = null
        assertFalse(SubtitleImageOcr.isAvailable)
        val bitmap = SubtitleImageOcr.ImageBitmap(8, 8, ByteArray(64), ByteArray(SubtitleImageOcr.PALETTE_BYTES))
        assertNull(SubtitleImageOcr.recognizeItem(listOf(bitmap)))
    }

    @Test
    fun recognizeItemJoinsRecognizedLines() = runBlocking {
        SubtitleImageOcr.recognizerProvider = SubtitleImageOcr.Recognizer { "line" }
        assertTrue(SubtitleImageOcr.isAvailable)
        val bitmap = SubtitleImageOcr.ImageBitmap(8, 8, ByteArray(64), ByteArray(SubtitleImageOcr.PALETTE_BYTES))
        assertEquals("line\nline", SubtitleImageOcr.recognizeItem(listOf(bitmap, bitmap)))
    }

    @Test
    fun serializeSrtReusesExtractorShape() {
        val srt = SubtitleImageOcr.serializeSrt(
            listOf(SubtitleImageOcr.RecognizedCue(startMs = 1000, endMs = 4000, text = "Hi")),
        )
        assertEquals("1\n00:00:01,000 --> 00:00:04,000\nHi\n\n", srt)
        assertEquals("", SubtitleImageOcr.serializeSrt(emptyList()))
    }
}
