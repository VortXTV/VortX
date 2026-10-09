package com.vortx.android.ui.components

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CinemaPresentationTest {
    private val movie = MetaItem("tt0133093", MediaType.MOVIE, "The Matrix")

    @Test fun `preview facts include only available positive metadata and episode target`() {
        val item = movie.copy(type = MediaType.SERIES, year = "2026", previewRuntimeMinutes = 42,
            previewSeasonCount = 2, preferredEpisode = PreferredEpisode(2, 5), imdbRating = "8.1")
        assertEquals("2026 · 42m · 2 seasons · S2 · E5 · ★ 8.1", cinemaCardFacts(item))
        assertEquals("1 season", cinemaCardFacts(movie.copy(previewSeasonCount = 1)))
        assertEquals("Movie", cinemaCardFacts(movie.copy(year = " ", previewRuntimeMinutes = -1, previewSeasonCount = 0, imdbRating = "")))
    }

    @Test fun `sparse preview never fabricates runtime seasons or episode count`() {
        assertEquals("Movie", cinemaCardFacts(movie))
        assertNull(cinemaLandscapeArtwork(movie))
    }

    @Test fun `remote resume caption keeps episode coordinates only once`() {
        val item = movie.copy(type = MediaType.SERIES, preferredEpisode = PreferredEpisode(2, 5), caption = "S2 E5 · Episode five")
        assertEquals("S2 E5 · Episode five", cinemaCardFacts(item))
        assertEquals("S2 · E5 · Episode five", cinemaCardFacts(item.copy(caption = "S2 · E5 · Episode five")))
        assertEquals("Series", cinemaCardFacts(item.copy(preferredEpisode = PreferredEpisode(-1, 0), caption = null)))
    }

    @Test fun `wide art prefers real backdrop and falls back to the preview poster`() {
        assertEquals("backdrop", cinemaLandscapeArtwork(movie.copy(background = "backdrop", poster = "poster")))
        assertEquals("poster", cinemaLandscapeArtwork(movie.copy(background = "  ", poster = "poster")))
        assertNull(cinemaLandscapeArtwork(movie.copy(background = "", poster = " ")))
    }

    @Test fun `quick view preference switches title taps while live keeps direct routing`() {
        assertTrue(cinemaCardOpensQuickView(movie, true))
        assertTrue(cinemaCardOpensQuickView(movie.copy(type = MediaType.SERIES), true))
        assertFalse(cinemaCardOpensQuickView(movie, false))
        assertFalse(cinemaCardOpensQuickView(movie.copy(type = MediaType.CHANNEL), true))
        assertFalse(cinemaCardOpensQuickView(movie.copy(type = MediaType.TV), true))
    }

    @Test fun `episode status preserves watched and valid resume without nonfinite percentages`() {
        assertEquals("Watched", cinemaEpisodeStatus(true, 0.3f))
        assertEquals("Resume · 30%", cinemaEpisodeStatus(false, 0.3f))
        assertEquals("Resume · 100%", cinemaEpisodeStatus(false, 1.5f))
        assertEquals("Unwatched", cinemaEpisodeStatus(false, null))
        assertEquals("Unwatched", cinemaEpisodeStatus(false, Float.NaN))
        assertEquals("Unwatched", cinemaEpisodeStatus(false, -0.5f))
    }
}
