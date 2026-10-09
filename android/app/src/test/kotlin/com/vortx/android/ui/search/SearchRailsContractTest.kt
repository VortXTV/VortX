package com.vortx.android.ui.search

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** The bounded JVM gate verifies the shared layout composition; device focus remains a UI gate. */
class SearchRailsContractTest {
    @Test fun `touch and merged search use shared horizontal home rails`() {
        val touch = source("screens/OtherScreens.kt").substringAfter("fun SearchScreen(").substringBefore("internal fun SearchField(")
        val merged = source("screens/MergedDiscoverSearchScreen.kt")
        val rails = source("screens/SearchResultRails.kt")
        assertTrue(touch.contains("SearchResultRails(")); assertFalse(touch.contains("PosterGrid("))
        assertTrue(merged.contains("SearchResultRails(")); assertFalse(merged.contains("PosterGrid("))
        assertTrue(merged.contains("searchViewModel.suggestions.collectAsStateWithLifecycle()"))
        assertEquals(2, Regex("SearchSuggestionsRow\\(").findAll(merged).count())
        assertTrue(rails.contains("PosterRail(")); assertTrue(rails.contains("SearchCollectionsRail("))
        val poster = source("components/Poster.kt").substringAfter("fun PosterRail(").substringBefore("fun LoadingRail(")
        assertTrue(poster.contains("LazyRow("))
        assertTrue(rails.contains("searchResultSections(items)"))
        assertTrue(rails.contains("isLoading")); assertTrue(rails.contains("statusMessage"))
        assertTrue(touch.contains("errorMessage = (state as? UiState.Error)?.message"))
        assertTrue(merged.contains("errorMessage = (searchState.content as? UiState.Error)?.message"))
        assertTrue(rails.indexOf("if (collections != null && browse?.target != null)") < rails.indexOf("if (errorMessage != null)"))
    }

    @Test fun `TV retains quick actions query input and focusable cards in horizontal groups`() {
        val screen = source("tv/TvSearchScreen.kt")
        val rails = source("tv/TvSearchResultRails.kt")
        assertTrue(screen.contains("TvSearchQuickActions("))
        assertTrue(screen.contains("onValueChange = viewModel::onQueryChange"))
        assertTrue(screen.contains("TvSearchResultRails(")); assertFalse(screen.contains("TvCinemaGrid("))
        assertTrue(rails.contains("LazyRow(")); assertTrue(rails.contains("Modifier.focusGroup()"))
        assertTrue(rails.contains("TvPosterCard(")); assertTrue(rails.contains("PosterCardMenu.CATALOG"))
        assertTrue(rails.contains("TvSearchCollectionsRail("))
        assertTrue(screen.contains("errorMessage = (state as? UiState.Error)?.message"))
    }
    private fun source(path: String) = File("src/main/kotlin/com/vortx/android/ui/$path").readText()
}
