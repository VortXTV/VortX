package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Test

class PlayerChapterTest {
    private val chapters = listOf(
        PlayerChapter("Opening", 0L),
        PlayerChapter("The plan", 60_000L),
        PlayerChapter("Finale", 120_000L),
    )

    @Test
    fun `current chapter follows the last marker at or before playback`() {
        assertEquals(0, currentChapterIndex(chapters, 0L))
        assertEquals(0, currentChapterIndex(chapters, 59_999L))
        assertEquals(1, currentChapterIndex(chapters, 60_000L))
        assertEquals(2, currentChapterIndex(chapters, 999_000L))
    }

    @Test
    fun `position before the first marker selects no chapter`() {
        assertEquals(-1, currentChapterIndex(listOf(PlayerChapter("Later", 10_000L)), 9_999L))
        assertEquals(-1, currentChapterIndex(emptyList(), 0L))
    }

    @Test
    fun `production normalization orders unsorted engine markers chronologically`() {
        val normalized = normalizePlayerChapters(
            listOf(
                PlayerChapter("Finale", 120_000L),
                PlayerChapter("Opening", 0L),
                PlayerChapter("The plan", 60_000L),
            ),
        )

        assertEquals(listOf("Opening", "The plan", "Finale"), normalized.map(PlayerChapter::title))
        assertEquals(1, currentChapterIndex(normalized, 90_000L))
    }
}
