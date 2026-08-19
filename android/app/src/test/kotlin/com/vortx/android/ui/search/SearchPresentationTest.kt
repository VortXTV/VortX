package com.vortx.android.ui.search

import com.vortx.android.R
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.ui.UiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SearchPresentationTest {
    @Test
    fun `mixed results form ordered nonempty movie series and other sections`() {
        val movie = item("movie", MediaType.MOVIE)
        val series = item("series", MediaType.SERIES)
        val channel = item("channel", MediaType.CHANNEL)
        val television = item("tv", MediaType.TV)

        val sections = searchResultSections(listOf(channel, movie, television, series))

        assertEquals(
            listOf(
                SearchResultSectionKind.MOVIES,
                SearchResultSectionKind.SERIES,
                SearchResultSectionKind.OTHER,
            ),
            sections.map { it.kind },
        )
        assertEquals(listOf(movie), sections[0].items)
        assertEquals(listOf(series), sections[1].items)
        assertEquals(listOf(channel, television), sections[2].items)
    }

    @Test
    fun `empty result groups are omitted`() {
        val series = item("series", MediaType.SERIES)

        assertEquals(
            listOf(SearchResultSection(SearchResultSectionKind.SERIES, listOf(series))),
            searchResultSections(listOf(series)),
        )
        assertEquals(emptyList<SearchResultSection>(), searchResultSections(emptyList()))
    }

    @Test
    fun `same id movie and series survive as separate typed results`() {
        val movie = item("shared", MediaType.MOVIE)
        val series = item("shared", MediaType.SERIES)

        val sections = searchResultSections(listOf(movie, series))

        assertEquals(
            listOf(SearchResultSectionKind.MOVIES, SearchResultSectionKind.SERIES),
            sections.map { it.kind },
        )
        assertEquals(listOf(movie), sections[0].items)
        assertEquals(listOf(series), sections[1].items)
        assertNotEquals(searchResultItemKey(movie), searchResultItemKey(series))
        assertNotEquals(
            searchResultItemKey(movie),
            searchResultSectionHeaderKey(SearchResultSectionKind.MOVIES),
        )
        assertEquals(R.string.search_section_movies, SearchResultSectionKind.MOVIES.titleResourceId)
        assertEquals(R.string.search_section_series, SearchResultSectionKind.SERIES.titleResourceId)
    }

    @Test
    fun `no matches copy requires an eligible settled empty result`() {
        val empty = emptyList<MetaItem>()

        assertEquals(
            SearchEmptyMessage.IDLE_GUIDANCE,
            searchEmptyMessage(" x ", UiState.Success(empty)),
        )
        assertNull(searchEmptyMessage("xy", UiState.Loading))
        assertNull(searchEmptyMessage("xy", UiState.Error("offline")))
        assertEquals(SearchEmptyMessage.NO_MATCHES, searchEmptyMessage(" xy ", UiState.Success(empty)))
        assertNull(searchEmptyMessage("xy", UiState.Success(listOf(item("movie", MediaType.MOVIE)))))
        assertEquals(R.string.search_idle_guidance, SearchEmptyMessage.IDLE_GUIDANCE.textResourceId)
        assertEquals(R.string.search_no_matches, SearchEmptyMessage.NO_MATCHES.textResourceId)
    }

    private fun item(id: String, type: MediaType) = MetaItem(id = id, type = type, name = id)
}
