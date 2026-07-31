package com.vortx.android.debrid

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DebridFileSelectionTest {

    @Test
    fun providerArrayOrderAndRawFileIndexCannotOverrideTheEpisodeMatch() {
        val files = listOf(
            video(id = 901, name = "Pack/Show.S01E04.mkv", size = 900),
            video(id = 17, name = "Pack/Show.S01E02.mkv", size = 700),
            video(id = 4402, name = "Pack/Show.S01E03.mkv", size = 800),
        )

        assertEquals(
            17,
            DebridFileSelection.pick(files, DebridResolver.Episode(1, 2), providerFileIdx = 0)?.id,
        )
        assertEquals(
            17,
            DebridFileSelection.pick(
                listOf(files[2], files[0], files[1]),
                DebridResolver.Episode(1, 2),
                providerFileIdx = 1,
            )?.id,
        )
    }

    @Test
    fun episodeTokensAreDigitBounded() {
        val prefixCollisions = listOf(
            video(id = 1, name = "Show.S01E020.mkv", size = 900),
            video(id = 2, name = "Show.1x020.mkv", size = 800),
            video(id = 3, name = "Show.Season.1.Episode.20.mkv", size = 700),
        )

        assertNull(
            DebridFileSelection.pick(
                prefixCollisions,
                DebridResolver.Episode(1, 2),
                providerFileIdx = null,
            ),
        )
        assertEquals(
            4,
            DebridFileSelection.pick(
                prefixCollisions + video(id = 4, name = "Show.1x02.mkv", size = 600),
                DebridResolver.Episode(1, 2),
                providerFileIdx = null,
            )?.id,
        )
    }

    @Test
    fun ambiguousOrUnmatchedEpisodePackFailsClosed() {
        val ambiguous = listOf(
            video(id = 1, name = "Show.S01E02.mkv", size = 700),
            video(id = 2, name = "Show.1x02.mkv", size = 650),
        )
        val unmatched = listOf(
            video(id = 3, name = "Show.S01E03.mkv", size = 1_400),
            video(id = 4, name = "Show.S01E04.mkv", size = 1_300),
        )

        assertNull(
            DebridFileSelection.pick(
                ambiguous,
                DebridResolver.Episode(1, 2),
                providerFileIdx = null,
            ),
        )
        assertNull(
            DebridFileSelection.pick(
                unmatched,
                DebridResolver.Episode(1, 2),
                providerFileIdx = null,
            ),
        )
    }

    @Test
    fun oneEffectiveProviderFileIsUnambiguousForAnEpisode() {
        val sole = listOf(
            DebridResolver.DebridFile(
                id = 77,
                name = "provider-opaque",
                shortName = "provider-opaque",
                size = 500,
            ),
        )

        assertEquals(
            77,
            DebridFileSelection.pick(
                sole,
                DebridResolver.Episode(1, 2),
                providerFileIdx = 9,
            )?.id,
        )
        assertEquals(
            77,
            DebridFileSelection.pick(
                sole,
                DebridResolver.Episode(-1, 0),
                providerFileIdx = 9,
            )?.id,
        )
    }

    @Test
    fun movieSelectionStillUsesTheLargestVideo() {
        val files = listOf(
            video(id = 1, name = "feature-1080p.mkv", size = 700),
            DebridResolver.DebridFile(
                id = 2,
                name = "feature-archive.rar",
                shortName = "feature-archive.rar",
                size = 2_000,
            ),
            video(id = 3, name = "feature-4k.mkv", size = 1_400),
        )

        assertEquals(
            3,
            DebridFileSelection.pick(files, episode = null, providerFileIdx = 0)?.id,
        )
    }

    private fun video(id: Int, name: String, size: Long) =
        DebridResolver.DebridFile(id = id, name = name, shortName = name.substringAfterLast('/'), size = size)
}
