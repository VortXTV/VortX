package com.vortx.android.trickplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrickplayTimelineTest {

    @Test
    fun `parser accepts bom crlf short and hour times with exact row-major geometry`() {
        val raw = "\uFEFFWEBVTT metadata\r\n\r\n" +
            "00:01.250 --> 00:03.500 align:start\r\n" +
            "sprite.jpg#xywh=0,0,320,180\r\n\r\n" +
            "01:02:03.500 --> 01:02:05.000\r\n" +
            "sprite.jpg#xywh=320,0,320,180\r\n"

        val cues = TrickplayTimeline.parseVtt(raw, frameCount = 2, cols = 2, tileW = 320, tileH = 180)

        assertEquals(2, cues?.size)
        assertEquals(1.25, cues?.get(0)?.start ?: -1.0, 0.0001)
        assertEquals(3.5, cues?.get(0)?.end ?: -1.0, 0.0001)
        assertEquals(1, cues?.get(1)?.tileIndex)
        assertEquals(3_723.5, cues?.get(1)?.start ?: -1.0, 0.0001)
    }

    @Test
    fun `parser rejects partial overlapping or mismatched geometry indexes`() {
        val oneCue = "WEBVTT\n\n00:00.000 --> 00:10.000\nsprite#xywh=0,0,320,180\n"
        val overlap = "WEBVTT\n\n" +
            "00:00.000 --> 00:10.000\nsprite#xywh=0,0,320,180\n\n" +
            "00:09.999 --> 00:20.000\nsprite#xywh=320,0,320,180\n"
        val wrongTile = "WEBVTT\n\n" +
            "00:00.000 --> 00:10.000\nsprite#xywh=1,0,320,180\n"

        assertNull(TrickplayTimeline.parseVtt(oneCue, frameCount = 2, cols = 2, tileW = 320, tileH = 180))
        assertNull(TrickplayTimeline.parseVtt(overlap, frameCount = 2, cols = 2, tileW = 320, tileH = 180))
        assertNull(TrickplayTimeline.parseVtt(wrongTile, frameCount = 1, cols = 2, tileW = 320, tileH = 180))
        assertNull(TrickplayTimeline.parseVtt("not-vtt", 1, 1, 320, 180))
    }

    @Test
    fun `parser fails soft on hostile coordinates without integer overflow`() {
        val extremeY = "WEBVTT\n\n00:00:00.000 --> 00:00:10.000\n" +
            "sprite#xywh=0,${Int.MAX_VALUE},1,1\n"
        val extremeX = "WEBVTT\n\n00:00:00.000 --> 00:00:10.000\n" +
            "sprite#xywh=${Int.MAX_VALUE},0,1,1\n"

        assertNull(TrickplayTimeline.parseVtt(extremeY, 2, 2, 1, 1))
        assertNull(TrickplayTimeline.parseVtt(extremeX, 2, 2, 1, 1))
    }

    @Test
    fun `parsed cue lookup returns null before after and inside gaps`() {
        val cues = listOf(
            cue(10.0, 20.0, 0),
            cue(40.0, 50.0, 1),
        )

        assertNull(TrickplayTimeline.cue(9.999, cues, 2, 10.0, 2, 320, 180))
        assertEquals(0, TrickplayTimeline.cue(10.0, cues, 2, 10.0, 2, 320, 180)?.tileIndex)
        assertNull(TrickplayTimeline.cue(20.0, cues, 2, 10.0, 2, 320, 180))
        assertNull(TrickplayTimeline.cue(30.0, cues, 2, 10.0, 2, 320, 180))
        assertEquals(1, TrickplayTimeline.cue(49.999, cues, 2, 10.0, 2, 320, 180)?.tileIndex)
        assertNull(TrickplayTimeline.cue(50.0, cues, 2, 10.0, 2, 320, 180))
    }

    @Test
    fun `legacy lookup remains finite and half open only when cues are absent`() {
        val legacy = TrickplayTimeline.cue(29.999, null, 3, 10.0, 2, 320, 180)
        assertEquals(2, legacy?.tileIndex)
        assertEquals(0, legacy?.x)
        assertEquals(180, legacy?.y)
        assertNull(TrickplayTimeline.cue(30.0, null, 3, 10.0, 2, 320, 180))
        assertNull(TrickplayTimeline.cue(5.0, emptyList(), 3, 10.0, 2, 320, 180))
    }

    @Test
    fun `generated vtt uses actual times and preserves explicit gap fence`() {
        val times = listOf(0.0, 10.0, 100.0, 110.0)
        val fences = TrickplayTimeline.selectedCueEndFences(
            retainedCaptureTimes = times,
            selectedIndices = listOf(0, 1, 2, 3),
            retainedCadence = 10.0,
        )
        assertEquals(listOf(null, 20.0, null, null), fences)

        val vtt = TrickplayTimeline.makeVtt(
            captureTimes = times,
            nominalInterval = 10.0,
            gapFenceInterval = 10.0,
            cueEndFences = fences,
            cols = 2,
            tileW = 320,
            tileH = 180,
        )
        assertTrue(vtt?.contains("00:00:10.000 --> 00:00:20.000") == true)
        assertFalse(vtt?.contains("00:00:10.000 --> 00:01:40.000") == true)

        val parsed = TrickplayTimeline.parseVtt(vtt.orEmpty(), 4, 2, 320, 180)
        assertEquals(4, parsed?.size)
        assertNull(TrickplayTimeline.cue(50.0, parsed, 4, 10.0, 2, 320, 180))
        assertEquals(2, TrickplayTimeline.cue(100.0, parsed, 4, 10.0, 2, 320, 180)?.tileIndex)
    }

    @Test
    fun `gap fences survive sheet sampling across skipped retained captures`() {
        val retained = listOf(0.0, 10.0, 20.0, 200.0, 210.0, 220.0)
        val selected = listOf(0, 2, 5)

        assertEquals(
            listOf(null, 30.0, null),
            TrickplayTimeline.selectedCueEndFences(retained, selected, retainedCadence = 10.0),
        )
    }

    @Test
    fun `nominal cadence uses lower median only with enough adjacent evidence`() {
        assertEquals(10.0, TrickplayTimeline.nominalCadence(listOf(0.0, 100.0, 200.0), 10.0), 0.0001)
        assertEquals(
            20.0,
            TrickplayTimeline.nominalCadence((0..9).map { it * 20.0 } + 1_000.0, 10.0),
            0.0001,
        )
        assertEquals(10.0, TrickplayTimeline.nominalCadence(listOf(Double.NaN, -1.0, 0.0), 10.0), 0.0001)
        assertEquals(0.0, TrickplayTimeline.nominalCadence(listOf(0.0, 10.0), Double.NaN), 0.0001)
    }

    @Test
    fun `retention preserves endpoints removes redundant interior and keeps newest duplicate`() {
        val times = listOf(0.0, 10.0, 11.0, 12.0, 100.0)
        val retained = TrickplayTimeline.retainedIndices(times, limit = 4)
        assertEquals(listOf(0, 1, 3, 4), retained)
        assertEquals(0, retained.first())
        assertEquals(4, retained.last())

        assertEquals(
            listOf(0, 2, 3),
            TrickplayTimeline.retainedIndices(listOf(0.0, 10.0, 10.0, 20.0), limit = 4),
        )
        assertEquals(listOf(4), TrickplayTimeline.retainedIndices(times, limit = 1))
    }

    @Test
    fun `bounded retention keeps admitting captures across a long session`() {
        var retainedTimes = emptyList<Double>()
        for (capture in 0..200) {
            val candidates = retainedTimes + capture * 10.0
            val retained = TrickplayTimeline.retainedIndices(candidates, limit = 37)
            retainedTimes = retained.map { candidates[it] }
        }

        assertEquals(37, retainedTimes.size)
        assertEquals(0.0, retainedTimes.first(), 0.0001)
        assertEquals(2_000.0, retainedTimes.last(), 0.0001)
        assertTrue(retainedTimes.zipWithNext().all { (first, second) -> first < second })
        assertTrue(retainedTimes.any { kotlin.math.abs(it - 1_000.0) <= 80.0 })
    }

    @Test
    fun `pre-stride gap evidence survives adversarial sheet strides`() {
        listOf(8, 15, 30).forEach { sheetStride ->
            val retainedCadence = 20.0
            val deltas = listOf(10.0) + List(sheetStride - 2) { retainedCadence } + listOf(50.0) +
                List(sheetStride) { retainedCadence }
            val retainedTimes = buildList {
                add(120.0)
                deltas.forEach { add(last() + it) }
            }
            val selectedIndices = listOf(0, sheetStride, sheetStride * 2)
            val selectedTimes = selectedIndices.map { retainedTimes[it] }
            val effectiveInterval = retainedCadence * sheetStride
            val fences = TrickplayTimeline.selectedCueEndFences(
                retainedCaptureTimes = retainedTimes,
                selectedIndices = selectedIndices,
                retainedCadence = retainedCadence,
            )
            val preGapTime = retainedTimes[sheetStride - 1]
            assertEquals(preGapTime + retainedCadence, fences?.get(0) ?: -1.0, 0.0001)

            val cues = TrickplayTimeline.makeCues(
                captureTimes = selectedTimes,
                nominalInterval = effectiveInterval,
                gapFenceInterval = retainedCadence,
                cueEndFences = fences,
                cols = 2,
                tileW = 1,
                tileH = 1,
            )
            assertNull(
                TrickplayTimeline.cue(
                    preGapTime + retainedCadence + 1.0,
                    cues,
                    cues?.size ?: 0,
                    effectiveInterval,
                    2,
                    1,
                    1,
                ),
            )
        }
    }

    @Test
    fun `even spacing returns exact count and both endpoints`() {
        assertEquals(listOf(0, 3, 6, 9), TrickplayTimeline.evenlySpacedIndices(10, 4))
        assertEquals(listOf(9), TrickplayTimeline.evenlySpacedIndices(10, 1))
        assertEquals((0 until 4).toList(), TrickplayTimeline.evenlySpacedIndices(4, 8))
        assertEquals(emptyList<Int>(), TrickplayTimeline.evenlySpacedIndices(0, 4))
    }

    @Test
    fun `cue generation rejects unordered timestamps and invalid fences`() {
        assertNull(
            TrickplayTimeline.makeCues(
                captureTimes = listOf(0.0, 0.0),
                nominalInterval = 10.0,
                cols = 2,
                tileW = 320,
                tileH = 180,
            ),
        )
        assertNull(
            TrickplayTimeline.makeCues(
                captureTimes = listOf(0.0, 10.0),
                nominalInterval = 10.0,
                cueEndFences = listOf(11.0, null),
                cols = 2,
                tileW = 320,
                tileH = 180,
            ),
        )
    }

    private fun cue(start: Double, end: Double, index: Int) = TrickplayTimelineCue(
        start = start,
        end = end,
        x = index * 320,
        y = 0,
        width = 320,
        height = 180,
        tileIndex = index,
    )
}
