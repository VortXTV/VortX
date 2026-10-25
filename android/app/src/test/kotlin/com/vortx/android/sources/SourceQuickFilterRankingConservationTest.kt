package com.vortx.android.sources

import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import org.junit.Assert.assertEquals
import org.junit.Test

class SourceQuickFilterRankingConservationTest {
    @Test fun `confirmed evidence alone does not change score text IDs or ranked order`() {
        val input = listOf(StreamGroup("Provider", listOf(
            StreamSource("one", "Provider", "2160p HDR10 HEVC", infoHash = "abcd", isTorrent = true),
            StreamSource("two", "Provider", "1080p SDR H264", infoHash = "ef01", isTorrent = true),
        )))
        val marked = markAccountConfirmedCache(input, setOf("abcd"), 7L)
        input.single().streams.zip(marked.single().streams).forEach { (before, after) ->
            assertEquals(StreamRanking.score(before, SourcePrefsSnapshot.DEFAULT), StreamRanking.score(after, SourcePrefsSnapshot.DEFAULT))
            assertEquals(before, after.copy(accountConfirmedCacheRevision = null))
        }
        val originalOrder = StreamRanking.rankedGroups(input, SourcePrefsSnapshot.DEFAULT).flatMap { it.streams }.map { it.id }
        val markedOrder = StreamRanking.rankedGroups(marked, SourcePrefsSnapshot.DEFAULT).flatMap { it.streams }.map { it.id }
        assertEquals(originalOrder, markedOrder)
    }
}
