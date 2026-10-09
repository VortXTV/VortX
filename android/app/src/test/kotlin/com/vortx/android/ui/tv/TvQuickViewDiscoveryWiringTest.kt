package com.vortx.android.ui.tv

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Callsite checks supplement the executable selection, navigation and real-store action tests. */
class TvQuickViewDiscoveryWiringTest {
    @Test fun `only catalog destinations dispatch through QuickView while history and local play retain existing owners`() {
        val shell = source("TvShell.kt")
        assertTrue(shell.contains("tvCatalogOpensQuickView(item, cinemaQuickView)"))
        assertTrue(shell.contains("TvHomeScreen(viewModel<HomeViewModel>(factory = factory), onCatalogItem"))
        assertTrue(shell.contains("TvDiscoverScreen(discoverViewModel, onCatalogItem"))
        assertTrue(shell.contains("viewModel = viewModel<SearchViewModel>(factory = factory), onItem = onCatalogItem"))
        assertTrue(shell.substringAfter("TvLibraryRoute.HISTORY ->").substringBefore("TvDestination.DOWNLOADS").contains("onItem = onItem"))
        assertTrue(shell.contains("TvDownloadsScreen(onPlay = onPlayLocal)"))
        assertTrue(shell.contains("TvLiveScreen(viewModel<LiveViewModel>(factory = factory), onItem)"))
    }

    @Test fun `live preference observer feeds both merged navigation and actual Discover search consumer`() {
        val shell = source("TvShell.kt")
        assertTrue(shell.contains("mergeDiscoverSearch = homePreferences.mergeDiscoverSearch"))
        assertTrue(shell.contains("cinemaQuickView = homePreferences.cinemaQuickView"))
        assertTrue(shell.contains("val currentDestination by rememberUpdatedState(destination)"))
        assertTrue(shell.contains("TvCinemaRoute(currentDestination, currentHomeBrowseSelected)"))
        assertTrue(shell.contains("tvCinemaDestinations(hiddenTabs, mergeHomeDiscover, mergeDiscoverSearch)"))
        assertTrue(shell.contains("if (mergeDiscoverSearch) {"))
        assertTrue(shell.contains("browseContent = { browseModifier ->"))
        val search = source("TvSearchScreen.kt")
        assertTrue(search.contains("browseContent != null && !isSearchQueryEligible(query)"))
        assertTrue(search.contains("BackHandler(enabled = signedIn && browseContent != null && query.isNotBlank())"))
        assertTrue(search.contains("viewModel.submitQuery()"))
        assertTrue(search.contains("viewModel.history.collectAsStateWithLifecycle()"))
        assertTrue(search.contains("viewModel.recordHistory()"))
    }

    @Test fun `TV modal captures real Watchlist intent before task and uses separate owner-fenced navigation actions`() {
        val modal = source("TvQuickViewDialog.kt")
        val click = modal.substringAfter("val intent = try")
        assertTrue(click.indexOf("actions.captureWatchlistToggle()") < click.indexOf("scope.launch"))
        assertTrue(click.indexOf("actions.toggleWatchlist(intent)") < click.indexOf("message = if (added)"))
        assertTrue(modal.contains("actions.watch()"))
        assertTrue(modal.contains("actions.details()"))
        assertTrue(modal.contains("Dialog(onDismissRequest = onClose"))
        assertTrue(modal.contains("focusProperties { exit = { FocusRequester.Cancel } }"))
        val app = source("TvApp.kt")
        assertTrue(app.contains("autoWatch = tvQuickWatchMatchesDetail(quickWatchSelection, current, repo.continueWatchingOwner())"))
        assertTrue(app.contains("onAutoWatchConsumed = { quickWatchSelection = null }"))
        assertTrue(app.contains("if (owner == repo.continueWatchingOwner())"))
    }

    @Test fun `Home Browse owner survives actual player and detail branches above TvShell`() {
        val app = source("TvApp.kt")
        val declaration = app.indexOf("var shellHomeBrowseSelected by remember")
        val player = app.indexOf("if (playable != null) {")
        assertTrue(declaration in 0 until player)
        assertTrue(app.contains("homeBrowseSelected = shellHomeBrowseSelected"))
        assertTrue(app.contains("onHomeBrowseSelectedChange = { shellHomeBrowseSelected = it }"))
        assertFalse(source("TvShell.kt").contains("var homeBrowseSelected by remember"))
    }

    private fun source(name: String): String {
        val relative = "src/main/kotlin/com/vortx/android/ui/tv/$name"
        return listOf(File(relative), File("android/app/$relative")).first { it.isFile }.readText()
    }
}
