package com.vortx.android.engine

import com.vortx.android.model.Episode
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import org.junit.Assert.*
import org.junit.Test

/** Source-only candidate tests of the production metadata-to-pool identity boundary; unrun. */
class NativeSourceIndexTargetTest {
    private val episode = Episode("provider-video-two", "Second", 1, 2)
    private fun series(videos: List<Episode> = listOf(episode)) =
        MetaDetail("tt123456", MediaType.SERIES, "Fixture", videos = videos)

    @Test fun canonicalMovieIdentityRequiresMatchingFreshMetadataAndMovieCoordinates() {
        for (id in listOf("tt123456", "tmdb:123")) {
            val detail = MetaDetail(id, MediaType.MOVIE, "Fixture")
            assertEquals(NativeSourceIndexTarget(MediaType.MOVIE, id, null, id),
                nativeSourceIndexTarget(detail, MediaType.MOVIE, id, null))
            assertEquals(id, nativeSourceIndexTarget(detail, MediaType.MOVIE, id, id)?.contentId)
            assertNull(nativeSourceIndexTarget(detail, MediaType.MOVIE, id, "$id:1:2"))
        }
        assertNull(nativeSourceIndexTarget(null, MediaType.MOVIE, "tt123456", null))
        assertNull(nativeSourceIndexTarget(MetaDetail("tt654321", MediaType.MOVIE, "Other"), MediaType.MOVIE, "tt123456", null))
        assertNull(nativeSourceIndexTarget(series(), MediaType.MOVIE, "tt123456", null))
    }

    @Test fun episodeQueryUsesApprovedMetadataCoordinatesInsteadOfParsingProviderVideoId() {
        val target = nativeSourceIndexTarget(series(), MediaType.SERIES, "tt123456", episode.id, episode)
        assertEquals(NativeSourceIndexTarget(MediaType.SERIES, "tt123456", episode.id, "tt123456:1:2", 1, 2), target)
        assertEquals("tmdb:123:1:2", nativeSourceIndexTarget(series().copy(id = "tmdb:123"),
            MediaType.SERIES, "tmdb:123", episode.id, episode)?.contentId)
        assertNull(nativeSourceIndexTarget(series(), MediaType.SERIES, "tt123456", "tt123456:1:2"))
        assertNull(nativeSourceIndexTarget(series(), MediaType.SERIES, "tt123456", null))
    }

    @Test fun preparationRequiresExactEpisodeIdSeasonAndEpisodeEvenWhenTitleWasCached() {
        for (expected in listOf(episode.copy(id = "other"), episode.copy(season = 9), episode.copy(episode = 9))) {
            assertNull(nativeSourceIndexTarget(series(), MediaType.SERIES, "tt123456", episode.id, expected))
        }
        assertNull(nativeSourceIndexTarget(null, MediaType.SERIES, "tt123456", episode.id, episode))
        assertNull(nativeSourceIndexTarget(series(emptyList()), MediaType.SERIES, "tt123456", episode.id, episode))
        assertNull(nativeSourceIndexTarget(series(listOf(episode, episode.copy(title = "Duplicate"))),
            MediaType.SERIES, "tt123456", episode.id, episode))
    }

    @Test fun aliasesMalformedTitlesAndOutOfContractCoordinatesCannotBecomeQueries() {
        for (id in listOf("Fixture", "imdb:tt123456", "tt12345", "tt123456?token=secret", "https://metadata.invalid/tt123456")) {
            assertNull(nativeSourceIndexTarget(series().copy(id = id), MediaType.SERIES, id, episode.id, episode))
        }
        for (invalid in listOf(episode.copy(season = -1), episode.copy(episode = -1), episode.copy(season = 10_000))) {
            assertNull(nativeSourceIndexTarget(series(listOf(invalid)), MediaType.SERIES, "tt123456", invalid.id, invalid))
        }
    }
}
