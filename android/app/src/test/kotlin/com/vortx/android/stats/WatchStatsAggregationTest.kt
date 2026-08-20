package com.vortx.android.stats

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the PURE watch-stats aggregation (no engine / file / org.json), mirroring the intent of
 * Apple `Tests/WatchStatsAggregation`. Everything here is deterministic and dependency-free.
 */
class WatchStatsAggregationTest {

    private fun record(
        id: String,
        type: String,
        name: String = id,
        watchSeconds: Double = 0.0,
        plays: Int = 0,
        lastWatched: String? = null,
    ) = WatchRecord(
        id = id,
        type = type,
        name = name,
        poster = null,
        watchSeconds = watchSeconds,
        plays = plays,
        lastWatched = WatchStats.parseISODate(lastWatched),
    )

    @Test
    fun `compute counts movies series episodes and total time`() {
        val records = listOf(
            record("m1", "movie", watchSeconds = 3600.0, plays = 1),
            record("m2", "movie", watchSeconds = 1800.0, plays = 1),
            record("s1", "series", watchSeconds = 7200.0, plays = 6),
        )

        val stats = WatchStats.compute(records, emptyMap(), "All time", 8, 6)

        assertEquals(3, stats.titlesCount)
        assertEquals(2, stats.moviesCount)
        assertEquals(1, stats.seriesCount)
        assertEquals(6, stats.episodesCount)
        assertEquals(12_600.0, stats.totalWatchSeconds, 0.001)
        assertTrue(stats.hasData)
    }

    @Test
    fun `longest binge prefers the series with the most episodes over a longer movie`() {
        val records = listOf(
            record("m1", "movie", watchSeconds = 100_000.0, plays = 1),
            record("s1", "series", watchSeconds = 3600.0, plays = 10),
        )

        val binge = WatchStats.compute(records, emptyMap(), "All time", 8, 6).longestBinge

        assertEquals("s1", binge?.name)
        assertEquals("series", binge?.type)
        assertEquals(10, binge?.episodes)
    }

    @Test
    fun `binge falls back to the top movie when there are no watched series`() {
        val records = listOf(
            record("m1", "movie", watchSeconds = 5000.0, plays = 1),
            record("m2", "movie", watchSeconds = 9000.0, plays = 1),
        )

        val binge = WatchStats.compute(records, emptyMap(), "All time", 8, 6).longestBinge

        assertEquals("m2", binge?.name)
        assertEquals(0, binge?.episodes)
    }

    @Test
    fun `top genres are weighted by time and split evenly across a title's genres`() {
        val records = listOf(
            record("a", "movie", watchSeconds = 6000.0, plays = 1),
            record("b", "movie", watchSeconds = 3000.0, plays = 1),
        )
        val genres = mapOf(
            "a" to listOf("Drama", "Crime"), // 3000 each
            "b" to listOf("Drama"),           // 3000
        )

        val stats = WatchStats.compute(records, genres, "All time", 8, 6)

        assertEquals(2, stats.genreCoverage)
        assertEquals("Drama", stats.topGenres.first().name)
        assertEquals(6000.0, stats.topGenres.first().seconds, 0.001) // 3000 (from a) + 3000 (from b)
        assertEquals(3000.0, stats.topGenres[1].seconds, 0.001)      // Crime
    }

    @Test
    fun `most watched is ranked by time spent and capped at the limit`() {
        val records = (1..12).map { record("t$it", "movie", watchSeconds = it * 100.0, plays = 1) }

        val top = WatchStats.compute(records, emptyMap(), "All time", 8, 6).topTitles

        assertEquals(8, top.size)
        assertEquals("t12", top.first().id)
        assertEquals("t5", top.last().id)
    }

    @Test
    fun `clampSeconds drops non-finite or negative time and caps the ceiling`() {
        assertEquals(0.0, WatchStats.clampSeconds(Double.POSITIVE_INFINITY), 0.0)
        assertEquals(0.0, WatchStats.clampSeconds(Double.NaN), 0.0)
        assertEquals(0.0, WatchStats.clampSeconds(-5.0), 0.0)
        assertEquals(1234.0, WatchStats.clampSeconds(1234.0), 0.0)
        assertEquals(500_000.0 * 3600.0, WatchStats.clampSeconds(Double.MAX_VALUE), 0.0)
    }

    @Test
    fun `compute normalizes a hostile play count so the episode total cannot overflow`() {
        // watchSeconds is clamped by the record producers (model layer), not compute; here it is finite.
        val records = listOf(
            record("bad", "series", watchSeconds = 3600.0, plays = Int.MAX_VALUE),
        )

        val stats = WatchStats.compute(records, emptyMap(), "All time", 8, 6)

        assertEquals(WatchStats.MAXIMUM_PLAY_COUNT, stats.episodesCount)
    }

    @Test
    fun `parseISODate tolerates nanosecond fractional seconds and yields the UTC year`() {
        val instant = WatchStats.parseISODate("2026-05-13T05:50:02.786798226Z")
        assertTrue(instant != null)
        assertEquals(2026, WatchStats.yearOf(instant!!))

        assertEquals(2024, WatchStats.parseISODate("2024-01-01")?.let { WatchStats.yearOf(it) })
        assertNull(WatchStats.parseISODate(null))
        assertNull(WatchStats.parseISODate("not-a-date"))
    }

    @Test
    fun `non vod and internal ids are excluded by the type and id guards`() {
        assertTrue(WatchStats.isVODType("movie"))
        assertTrue(WatchStats.isVODType("series"))
        assertTrue(!WatchStats.isVODType("tv"))
        assertTrue(WatchStats.isInternalID("stremiox:profiles"))
        assertTrue(WatchStats.isInternalID("vortx:anything"))
        assertTrue(!WatchStats.isInternalID("tt12345"))
    }

    @Test
    fun `empty scope reports no data`() {
        val stats = WatchStats.compute(emptyList(), emptyMap(), "2020", 8, 6)
        assertTrue(!stats.hasData)
        assertNull(stats.longestBinge)
        assertTrue(stats.topTitles.isEmpty())
    }
}
