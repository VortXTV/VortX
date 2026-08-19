package com.vortx.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AdvancedDiscoverFiltersTest {
    @Test
    fun `genre chips cycle off include exclude off and count distinct groups`() {
        var filters = AdvancedDiscoverFilters()

        filters = filters.cycleGenre("Drama")
        assertEquals(GenreFilterState.INCLUDE, filters.genreState("Drama"))
        filters = filters.cycleGenre("Drama")
        assertEquals(GenreFilterState.EXCLUDE, filters.genreState("Drama"))
        filters = filters.copy(minYear = 2010, maxYear = 2019, upcomingOnly = true)
        assertEquals(3, filters.activeCount)
        filters = filters.cycleGenre("Drama")
        assertEquals(GenreFilterState.OFF, filters.genreState("Drama"))
        assertEquals(2, filters.activeCount)
    }

    @Test
    fun `known preview fields must match every active filter`() {
        val filters = AdvancedDiscoverFilters(
            includedGenres = setOf("Drama"),
            excludedGenres = setOf("Horror"),
            minYear = 2020,
            maxYear = 2029,
            ageRatings = setOf("PG-13"),
            minMinutes = 90,
            maxMinutes = 120,
            minSeasons = 2,
            maxSeasons = 3,
            upcomingOnly = true,
        )
        val matching = MetaItem(
            id = "tt1",
            type = MediaType.SERIES,
            name = "Matching",
            year = "2026-",
            genres = listOf("Crime", "drama"),
            certificationLabel = "pg-13",
            previewRuntimeMinutes = 100,
            previewSeasonCount = 3,
        )

        assertTrue(filters.matches(matching, currentYear = 2026))
        assertFalse(filters.matches(matching.copy(genres = listOf("Horror")), currentYear = 2026))
        assertFalse(filters.matches(matching.copy(year = "2019"), currentYear = 2026))
        assertFalse(filters.matches(matching.copy(certificationLabel = "R"), currentYear = 2026))
        assertFalse(filters.matches(matching.copy(previewRuntimeMinutes = 121), currentYear = 2026))
        assertFalse(filters.matches(matching.copy(previewSeasonCount = 1), currentYear = 2026))
    }

    @Test
    fun `missing preview fields remain visible under field present semantics`() {
        val filters = AdvancedDiscoverFilters(
            includedGenres = setOf("Drama"),
            excludedGenres = setOf("Horror"),
            minYear = 2020,
            maxYear = 2029,
            ageRatings = setOf("PG"),
            minMinutes = 60,
            maxMinutes = 90,
            minSeasons = 2,
            maxSeasons = 3,
            upcomingOnly = true,
        )

        assertTrue(filters.matches(MetaItem("tt2", MediaType.MOVIE, "Sparse"), currentYear = 2026))
    }

    @Test
    fun `genre options keep engine order then loaded genres and anime supplement`() {
        val result = DiscoverResult(
            items = listOf(
                MetaItem("kitsu:1", MediaType.SERIES, "Anime", genres = listOf("Drama", "Anime")),
            ),
            filters = DiscoverFilters(
                types = listOf(DiscoverTypeOption("Anime", true, "{}")),
                genres = listOf(
                    DiscoverGenreOption("Action", false, "{}"),
                    DiscoverGenreOption("drama", false, "{}"),
                ),
            ),
        )

        val options = advancedDiscoverGenreOptions(result)

        assertEquals(listOf("Action", "drama", "Anime"), options.take(3))
        assertTrue("Isekai" in options)
        assertEquals(options.size, options.map(String::lowercase).distinct().size)
        assertTrue(isAdvancedDiscoverSeriesContext(result))
    }
}
