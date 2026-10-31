package com.vortx.android.player.subtitles

import android.graphics.Typeface
import android.text.Spanned
import android.text.style.StyleSpan
import androidx.media3.common.text.Cue
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real Media3 SubripParser plus Android Html; written but requires an Android test runtime. */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class Media3OwnedSubtitlePresentationTest {
    @Test fun ordinaryParserStylingPositioningOverlapAndBackwardSeekArePreserved() {
        val raw = "1\n00:00:01,000 --> 00:00:03,000\n{\\an8}<b>A</b> &amp; B\n\n" +
            "2\n00:00:01,000 --> 00:00:02,000\nrepeat\n"
        val prepared = requireNotNull(Media3OwnedSubtitlePresentation.prepareSrt(raw.toByteArray()))
        assertTrue(prepared.lookup(999).isEmpty())
        val cues = prepared.lookup(1000)
        assertEquals(2, cues.size)
        assertEquals("A & B", cues[0].text.toString())
        val text = cues[0].text as Spanned
        assertTrue(text.getSpans(0, text.length, StyleSpan::class.java).any { it.style == Typeface.BOLD })
        assertEquals(Cue.ANCHOR_TYPE_START, cues[0].lineAnchor)
        assertEquals(listOf(cues[0]), prepared.lookup(2000))
        assertTrue(prepared.lookup(3000).isEmpty())
        assertEquals(cues, prepared.lookup(1000))
        val clock = SubtitleReferencePresentation.Clock()
        assertTrue(clock.sample(prepared, 1000).changed)
        val same = clock.sample(prepared, 1001)
        assertFalse(same.changed)
        assertSame(same.cues, clock.sample(prepared, 1999).cues)
    }

    @Test fun completeInputIsRequiredEvenWhenMedia3CouldReturnAPrefix() {
        val incomplete = "1\n00:00:00,000 --> 00:00:01,000\nvalid\n\n2\n"
        assertNull(Media3OwnedSubtitlePresentation.prepareSrt(incomplete.toByteArray()))
    }
}
