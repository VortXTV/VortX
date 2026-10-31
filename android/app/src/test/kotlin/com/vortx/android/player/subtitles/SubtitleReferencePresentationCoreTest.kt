package com.vortx.android.player.subtitles

import org.junit.Assert.*
import org.junit.Test

/** Pure production parser/index tests: no Android spans, renderer, player or native/JNI execution. */
class SubtitleReferencePresentationCoreTest {
    private val plain = SubtitleReferencePresentationCore.Style()
    private fun cue(start: Long, end: Long, text: String = "cue") =
        SubtitleReferencePresentationCore.SourceCue(start, end, text)
    private fun parsed(vararg cues: SubtitleReferencePresentationCore.SourceCue) =
        requireNotNull(SubtitleReferencePresentationCore.prepare(100, cues.toList()))

    @Test fun whitespaceEntitiesAndEscapedTagsArePreservedExactlyOnce() {
        val source = "  A&amp;B &lt;b&gt; &#x1F642; &amp;lt;\n<br/>\tZ  "
        val runs = requireNotNull(SubtitleReferencePresentationCore.parseRuns(source))
        assertEquals(listOf(SubtitleReferencePresentationCore.Run("  A&B <b> 🙂 &lt;\n\n\tZ  ", plain)), runs)
        assertEquals("A&&&& &unfinished", requireNotNull(
            SubtitleReferencePresentationCore.parseRuns("A&&&& &unfinished")).joinToString("") { it.text })
        assertEquals("A", requireNotNull(SubtitleReferencePresentationCore.parseRuns(
            "&#" + "0".repeat(100) + "65;")).single().text)
    }

    @Test fun nestedStylesAndAuthoredColoursRestoreTheirParentStyle() {
        val runs = requireNotNull(SubtitleReferencePresentationCore.parseRuns(
            "<b>A<i>B<u>C</u></i><font color = '#12aBcF'>D</font>E</b>F"))
        assertEquals(listOf("A", "B", "C", "D", "E", "F"), runs.map { it.text })
        assertEquals(plain.copy(bold = true), runs[0].style)
        assertEquals(plain.copy(bold = true, italic = true), runs[1].style)
        assertEquals(plain.copy(bold = true, italic = true, underline = true), runs[2].style)
        assertEquals(plain.copy(bold = true, foregroundRgb = 0x12abcf), runs[3].style)
        assertEquals(plain.copy(bold = true), runs[4].style)
        assertEquals(plain, runs[5].style)
    }

    @Test fun unsupportedMarkupRejectsTheWholeFileInsteadOfReturningStrippedOrPartialText() {
        val unsupported = listOf("<b>unclosed", "<b><i>x</b></i>", "<ruby>x</ruby>",
            "<b class='x'>x</b>", "<font color='red'>x</font>", "<font color='#ffffff' size='2'>x</font>",
            "{\\an8}positioned", "x&unknown;", "&#0;", "&#xD800;", "&#1114112;", "x < unfinished")
        for (text in unsupported) {
            assertNull(text, SubtitleReferencePresentationCore.parseRuns(text))
            assertNull(text, SubtitleReferencePresentationCore.prepare(100,
                listOf(cue(0, 100, "valid prefix"), cue(100, 200, text))))
        }
    }

    @Test fun allCueAndCompleteFileBoundsAreEnforcedBeforePresentation() {
        val valid = listOf(cue(0, 100))
        assertNull(SubtitleReferencePresentationCore.prepare(0, valid))
        assertNull(SubtitleReferencePresentationCore.prepare(8 * 1024 * 1024 + 1, valid))
        assertNull(SubtitleReferencePresentationCore.prepare(1, emptyList()))
        assertNull(SubtitleReferencePresentationCore.prepare(1, List(12_001) { cue(0, 1) }))
        assertNotNull(SubtitleReferencePresentationCore.prepare(8 * 1024 * 1024, valid))
        val fullyOverlapping = requireNotNull(SubtitleReferencePresentationCore.prepare(1,
            List(12_000) { cue(0, 1) }))
        assertEquals((0 until 12_000).toList(), fullyOverlapping.index.lookup(0))
        for (bad in listOf(cue(-1, 1), cue(1, 1), cue(1, 91_000_001), cue(0, 1, ""),
            cue(0, 1, "\u0000"), cue(0, 1, "\ud800"), cue(0, 1, "a".repeat(16_385)),
            cue(0, 1, "é".repeat(8193)))) {
            assertNull(SubtitleReferencePresentationCore.prepare(1, listOf(bad)))
        }
        assertNull(SubtitleReferencePresentationCore.prepare(1, listOf(cue(2, 3), cue(1, 4))))
        assertNotNull(SubtitleReferencePresentationCore.prepare(1, listOf(cue(0, 1, "a".repeat(16_384)))))
        assertNotNull(SubtitleReferencePresentationCore.prepare(1, listOf(cue(0, 1, "é".repeat(8192)))))
    }

    @Test fun overlapTiesRepeatedTextAndHalfOpenBoundariesKeepEveryOriginalOccurrence() {
        val index = parsed(cue(0, 100, "same"), cue(10, 30, "same"), cue(10, 50, "third"),
            cue(30, 40, "fourth"), cue(100, 101, "last")).index
        assertEquals(emptyList<Int>(), index.lookup(-1))
        assertEquals(listOf(0), index.lookup(0))
        assertEquals(listOf(0, 1, 2), index.lookup(10))
        assertEquals(listOf(0, 2, 3), index.lookup(30))
        assertEquals(listOf(0, 2), index.lookup(40))
        assertEquals(listOf(0), index.lookup(50))
        assertEquals(listOf(4), index.lookup(100))
        assertEquals(emptyList<Int>(), index.lookup(101))
        assertEquals(listOf(0, 1, 2), index.lookup(10)) // backward seek
        assertEquals(emptyList<Int>(), index.lookup(Long.MAX_VALUE))
    }

    @Test fun longRunningCueIsNotLostBehindThousandsOfAlreadyEndedCues() {
        val cues = ArrayList<SubtitleReferencePresentationCore.SourceCue>()
        cues.add(cue(0, 90_000_000, "long"))
        repeat(11_999) { cues.add(cue(it.toLong(), it + 1L, "short")) }
        val index = requireNotNull(SubtitleReferencePresentationCore.prepare(100, cues)).index
        assertEquals(listOf(0), index.lookup(50_000_000))
        assertEquals(listOf(0, 10_001), index.lookup(10_000))
    }

    @Test fun immutableResultsAndBoundaryIdentityAllowRedrawOnlyWhenNecessary() {
        val index = parsed(cue(10, 20), cue(20, 30)).index
        val clock = SubtitleReferencePresentationCore.BoundaryClock()
        val owner = Any()
        assertTrue(clock.changed(owner, index.boundaryAt(10)))
        assertFalse(clock.changed(owner, index.boundaryAt(19)))
        assertTrue(clock.changed(owner, index.boundaryAt(20)))
        assertTrue(clock.changed(owner, index.boundaryAt(10))) // seek back
        assertTrue(clock.changed(Any(), index.boundaryAt(10))) // replacement prepared file
        clock.reset()
        assertTrue(clock.changed(owner, index.boundaryAt(10)))
        val result = index.lookup(10)
        try { (result as MutableList<Int>).clear(); fail("lookup must be immutable") }
        catch (_: UnsupportedOperationException) { }
        assertEquals(listOf(0), index.lookup(10))
    }
}
