package com.vortx.android.player.subtitles

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for the pure half of [SubtitleEmbeddedExtractor] (serialization, ASS/tx3g parsing, local-input
 * gate). The [MediaExtractor] demux shell needs an Android runtime and is exercised on device.
 */
class SubtitleEmbeddedExtractorTest {

    @Test
    fun localInputGateMatchesApple() {
        assertTrue(SubtitleEmbeddedExtractor.isLocalFileInput("/data/user/0/x/movie.mkv"))
        assertTrue(SubtitleEmbeddedExtractor.isLocalFileInput("file:///sdcard/movie.mkv"))
        assertFalse(SubtitleEmbeddedExtractor.isLocalFileInput("https://cdn.example/movie.mkv"))
        assertFalse(SubtitleEmbeddedExtractor.isLocalFileInput("http://127.0.0.1:11470/x"))
        assertFalse(SubtitleEmbeddedExtractor.isLocalFileInput("content://media/external/x"))
    }

    @Test
    fun remoteInputYieldsEmpty() {
        assertEquals(emptyList<SubtitleEmbeddedExtractor.ExtractedTrack>(),
            SubtitleEmbeddedExtractor.extractTextSubtitles("https://cdn.example/movie.mkv"))
        assertEquals(emptyList<SubtitleEmbeddedExtractor.ExtractedTrack>(),
            SubtitleEmbeddedExtractor.extractTextSubtitles("http://127.0.0.1:11470/stream"))
    }

    @Test
    fun srtSerializationMatchesAppleShape() {
        val cues = listOf(
            SubtitleEmbeddedExtractor.Cue(startMs = 1500, endMs = 4500, text = "Hello"),
            SubtitleEmbeddedExtractor.Cue(startMs = 5000, endMs = 8000, text = "World"),
        )
        val srt = SubtitleEmbeddedExtractor.serializeSrt(cues)
        val expected = buildString {
            append("1\n00:00:01,500 --> 00:00:04,500\nHello\n\n")
            append("2\n00:00:05,000 --> 00:00:08,000\nWorld\n\n")
        }
        assertEquals(expected, srt)
    }

    @Test
    fun vttSerializationHasHeaderAndDotMillis() {
        val cues = listOf(SubtitleEmbeddedExtractor.Cue(startMs = 3_661_250, endMs = 3_665_000, text = "Late"))
        val vtt = SubtitleEmbeddedExtractor.serializeVtt(cues)
        assertEquals("WEBVTT\n\n01:01:01.250 --> 01:01:05.000\nLate\n\n", vtt)
    }

    @Test
    fun timestampFormatting() {
        assertEquals("00:00:00,000", SubtitleEmbeddedExtractor.srtTime(0))
        assertEquals("01:02:03,004", SubtitleEmbeddedExtractor.srtTime(3_723_004))
        assertEquals("01:02:03.004", SubtitleEmbeddedExtractor.vttTime(3_723_004))
    }

    @Test
    fun assStandardRowStripsMetadataAndTags() {
        // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text  (8 pre-Text commas)
        val row = "0,0,Default,,0,0,0,,{\\an8}Hello, there\\Nsecond line"
        val text = SubtitleEmbeddedExtractor.plainTextFromAss(row, preTextCommas = 8)
        assertEquals("Hello, there\nsecond line", text)
    }

    @Test
    fun assNonstandardFormatCountFromHeader() {
        // A Format line declaring an extra MarginB field: 10 fields -> preTextCommas = 8.
        val header = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, MarginB, Text\n"
        assertEquals(8, SubtitleEmbeddedExtractor.preTextCommaCount(header))
        // Standard header -> 8 as well (Layer..Effect + Start/End + Text = 10 fields).
        val std = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        assertEquals(8, SubtitleEmbeddedExtractor.preTextCommaCount(std))
        // Missing / malformed header falls back to standard 8.
        assertEquals(8, SubtitleEmbeddedExtractor.preTextCommaCount("no events here"))
    }

    @Test
    fun tx3gLengthPrefixedBody() {
        val body = "Hi".toByteArray(Charsets.UTF_8)
        val sample = byteArrayOf(0x00, body.size.toByte(), *body)
        assertEquals("Hi", SubtitleEmbeddedExtractor.movTextBody(sample))
        // A too-short sample yields empty.
        assertEquals("", SubtitleEmbeddedExtractor.movTextBody(byteArrayOf(0x05)))
        // An overrunning length yields empty.
        assertEquals("", SubtitleEmbeddedExtractor.movTextBody(byteArrayOf(0x00, 0x7F, 0x41)))
    }

    @Test
    fun decodeSampleTextRoutesByMime() {
        assertEquals("Plain", SubtitleEmbeddedExtractor.decodeSampleText(
            "Plain".toByteArray(), "application/x-subrip", 8))
        assertEquals("Ssa", SubtitleEmbeddedExtractor.decodeSampleText(
            "0,0,Default,,0,0,0,,Ssa".toByteArray(), "text/x-ssa", 8))
    }
}
