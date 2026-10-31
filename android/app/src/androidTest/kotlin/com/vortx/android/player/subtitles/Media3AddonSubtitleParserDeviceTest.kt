package com.vortx.android.player.subtitles

import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real pinned Media3 parsers and Android text objects; no network, media player or account fixture. */
@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
@OptIn(UnstableApi::class)
class Media3AddonSubtitleParserDeviceTest {
    private fun parse(text: String, format: Media3AddonSubtitleParser.Format) =
        Media3AddonSubtitleParser.parse(text.toByteArray(Charsets.UTF_8), format, { true }, { false })

    private fun visible(parsed: Media3AddonSubtitleParser.Parsed, at: Long): List<String> =
        parsed.presentation.lookup(at).map { it.text.toString() }

    @Test fun ordinarySrtKeepsTextAndQualifiedOriginalTiming() {
        val srt = "1\n00:00:01,000 --> 00:00:03,000\n<i>Hello</i> &amp; goodbye\n\n"
        val parsed = requireNotNull(parse(srt, Media3AddonSubtitleParser.Format.SRT))
        assertEquals(listOf("Hello & goodbye"), visible(parsed, 1500))
        assertTrue(visible(parsed, 3000).isEmpty())
        assertArrayEquals(srt.toByteArray(), parsed.alignmentSrtBytes())
        val changed = parsed.canonicalSrtBytes()
        changed.fill(0)
        assertFalse(parsed.canonicalSrtBytes().all { it == 0.toByte() })
        assertEquals(listOf("Hello & goodbye"), visible(parsed, 1500))
    }

    @Test fun webvttBlankHeaderAndOverlappingAuthoredCuesRemainVisible() {
        val vtt = "WEBVTT\n\nfirst\n00:00:01.000 --> 00:00:04.000\nFirst\n\nsecond\n00:00:02.000 --> 00:00:06.000\nSecond\n\n"
        val parsed = requireNotNull(parse(vtt, Media3AddonSubtitleParser.Format.VTT))
        assertEquals(listOf("First"), visible(parsed, 1500))
        assertEquals(setOf("First", "Second"), visible(parsed, 2500).toSet())
        assertEquals(listOf("Second"), visible(parsed, 5000))
        assertTrue(visible(parsed, 6000).isEmpty())
        assertNull(parsed.alignmentSrtBytes())
    }

    @Test fun webvttHeaderMetadataIsConsumedBeforeTheFirstCue() {
        val vtt = "WEBVTT - captions\nKind: captions\nLanguage: en\n\n00:00:01.000 --> 00:00:03.000\nHeader supported\n\n"
        val parsed = requireNotNull(parse(vtt, Media3AddonSubtitleParser.Format.VTT))
        assertEquals(listOf("Header supported"), visible(parsed, 1500))
    }

    @Test fun webvttRawControlLinesMatchTheActualParserGrammar() {
        val vtt = "WEBVTT\n\nNOTE123\n00:00:00.000 --> 00:00:09.000\nIgnored comment\n\n NOTE title\n00:00:01.000 --> 00:00:03.000\nLeading-space identifier\n\nREGION\n00:00:04.000 --> 00:00:06.000\nRegion identifier\n\n"
        val parsed = requireNotNull(parse(vtt, Media3AddonSubtitleParser.Format.VTT))
        assertEquals(listOf("Leading-space identifier"), visible(parsed, 1500))
        assertTrue(visible(parsed, 3500).isEmpty())
        assertEquals(listOf("Region identifier"), visible(parsed, 4500))
    }

    @Test fun ssaDialogueUsesActualParserAndKeepsOrdinaryOverlap() {
        val ass = """
            [Script Info]
            ScriptType: v4.00+
            PlayResX: 1920
            PlayResY: 1080
            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, Bold, Italic, Underline, StrikeOut, Alignment, MarginL, MarginR, MarginV
            Style: Default,Arial,20,&H00FFFFFF,0,0,0,0,2,10,10,10
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,First
            Dialogue: 0,0:00:02.00,0:00:06.00,Default,,0,0,0,,Second
        """.trimIndent()
        val parsed = requireNotNull(parse(ass, Media3AddonSubtitleParser.Format.ASS))
        assertEquals(listOf("First"), visible(parsed, 1500))
        assertEquals(setOf("First", "Second"), visible(parsed, 2500).toSet())
        assertEquals(listOf("Second"), visible(parsed, 5000))
        assertNull(parsed.alignmentSrtBytes())
    }

    @Test fun utf16AndLatin1KeepTheirOriginalTextWithoutForgingAlignmentEvidence() {
        val text = "1\n00:00:01,000 --> 00:00:03,000\nCafé\n\n"
        val utf16 = byteArrayOf(0xff.toByte(), 0xfe.toByte()) + text.toByteArray(Charsets.UTF_16LE)
        val latin1 = text.toByteArray(Charsets.ISO_8859_1)
        for (bytes in listOf(utf16, latin1)) {
            val parsed = requireNotNull(Media3AddonSubtitleParser.parse(bytes,
                Media3AddonSubtitleParser.Format.SRT, { true }, { false }))
            assertEquals(listOf("Café"), visible(parsed, 1500))
            assertNull(parsed.alignmentSrtBytes())
        }
    }

    @Test fun malformedTaggedUtf16DoesNotBecomeLatin1Text() {
        val bytes = byteArrayOf(0xff.toByte(), 0xfe.toByte(), 0x31)
        assertNull(Media3AddonSubtitleParser.parse(bytes, Media3AddonSubtitleParser.Format.SRT, { true }, { false }))
    }

    @Test fun signedOrOverflowingTimestampFieldsAreRefused() {
        for (stamp in listOf("-1:00:01.000", "9223372036854775807:00:01.000")) {
            assertNull(parse("WEBVTT\n\n$stamp --> 00:00:05.000\nNo\n\n", Media3AddonSubtitleParser.Format.VTT))
        }
        val positive = requireNotNull(parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nText\n\n", Media3AddonSubtitleParser.Format.VTT))
        assertEquals(listOf("Text"), visible(positive, 1500))
    }

    @Test fun sourceRetirementOrCancellationRefusesPreparation() {
        val bytes = "1\n00:00:01,000 --> 00:00:03,000\nHello\n\n".toByteArray()
        assertNull(Media3AddonSubtitleParser.parse(bytes, Media3AddonSubtitleParser.Format.SRT, { false }, { false }))
        assertNull(Media3AddonSubtitleParser.parse(bytes, Media3AddonSubtitleParser.Format.SRT, { true }, { true }))
    }

    @Test fun authoredOverlapAndDownloadedByteBudgetsAreEnforced() {
        val vtt = buildString {
            append("WEBVTT\n\n")
            repeat(129) { append("00:00:01.000 --> 00:00:03.000\nCue $it\n\n") }
        }
        assertNull(parse(vtt, Media3AddonSubtitleParser.Format.VTT))
        assertNull(Media3AddonSubtitleParser.parse(ByteArray(8 * 1024 * 1024 + 1),
            Media3AddonSubtitleParser.Format.SRT, { true }, { false }))
    }
}
