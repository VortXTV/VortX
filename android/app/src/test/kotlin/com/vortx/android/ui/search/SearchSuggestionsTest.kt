package com.vortx.android.ui.search

import com.vortx.android.model.CoreSearchSuggestion
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// Locks in the SD-6 parity behavior of [searchSuggestionTitles]: the suggestion SURFACE opens from a
/// single non-empty character (Apple `CoreBridge.searchSuggestionTitles` guards only on non-empty), while
/// the engine dispatch stays gated at two characters in the repository layer.
class SearchSuggestionsTest {
    private fun movie(name: String) = MetaItem(id = name, type = MediaType.MOVIE, name = name)

    @Test
    fun `single character surfaces client-side completions`() {
        val result = searchSuggestionTitles(
            query = "d",
            continueWatching = listOf(movie("Dune"), movie("Arrival")),
            homeBoard = listOf(movie("Drive")),
        )
        assertTrue(result.contains("Dune"))
        assertTrue(result.contains("Drive"))
        assertTrue(!result.contains("Arrival"))
    }

    @Test
    fun `empty query yields no suggestions`() {
        assertEquals(emptyList<String>(), searchSuggestionTitles(query = "   ", continueWatching = listOf(movie("Dune"))))
    }

    @Test
    fun `engine suggestions interleave ahead of settled results and dedupe`() {
        val result = searchSuggestionTitles(
            query = "du",
            continueWatching = emptyList(),
            engineSuggestions = listOf(CoreSearchSuggestion(id = "1", name = "Dune", type = "movie")),
            currentResults = listOf(movie("Dune"), movie("Duna")),
        )
        // Engine "Dune" leads; the duplicate settled "Dune" is dropped; "Duna" still follows.
        assertEquals(listOf("Dune", "Duna"), result)
    }

    @Test
    fun `matching is diacritic insensitive`() {
        val result = searchSuggestionTitles(query = "amelie", continueWatching = listOf(movie("Amélie")))
        assertEquals(listOf("Amélie"), result)
    }
}
