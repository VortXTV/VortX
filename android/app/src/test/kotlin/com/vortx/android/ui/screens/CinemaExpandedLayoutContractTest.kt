package com.vortx.android.ui.screens

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Shipping callsite/readback contracts, not viewport or physical D-pad evidence. */
class CinemaExpandedLayoutContractTest {
    @Test fun `TV episodes use real artwork fallback and selected accepted quality seam`() {
        val tv = source("ui/tv/TvDetailScreen.kt").substringAfter("TvSeasonEpisodeSection(")
        assertTrue(tv.contains("selectedEpisodeId?.let(viewModel::selectedEpisodeQualityLabels).orEmpty()"))
        val section = source("ui/tv/TvDetailSections.kt")
        assertTrue(section.contains("tvEpisodeFacts(episode.id, selectedEpisodeId, detail.runtime, acceptedSelectedQualityLabels)"))
        assertTrue(section.contains("FallbackArtwork(urls = artwork"))
        assertTrue(section.contains("onToggleWatched(episode, !watched)"))
    }
    @Test fun `Settings preserves supplied scroll and focus while applying width local spacious controls`() {
        val settings = source("ui/screens/OtherScreens.kt").substringAfter("fun SettingsScreen(")
        assertTrue(settings.contains("cinemaControlLayout(maxWidth.value)"))
        assertTrue(settings.contains("widthIn(max = layout.maxContentWidthDp.dp)"))
        assertTrue(settings.contains("verticalScroll(settingsScrollState)"))
        assertTrue(settings.contains("focusRequester(debridServicesFocusRequester)"))
        assertTrue(settings.contains("LocalCinemaControlLayout.current"))
        assertTrue(settings.contains("if (layout.spacious) 20.dp"))
    }
    @Test fun `Addons uses bounded width and spacious real cards without changing actions`() {
        val addons = source("ui/screens/AddonsScreen.kt")
        assertTrue(addons.contains("cinemaControlLayout(maxWidth.value)"))
        assertTrue(addons.contains("widthIn(max = layout.maxContentWidthDp.dp)"))
        assertTrue(addons.contains("spacious = layout.spacious"))
        assertTrue(addons.contains("if (spacious) 64.dp else 48.dp"))
        for (action in listOf("viewModel::install", "onInstallByQr", "viewModel.remove(addon)", "viewModel.toggleAddon(addon)", "viewModel::applyOrder")) {
            assertTrue("Retained add-on action: $action", addons.contains(action))
        }
    }
    @Test fun `TV cards mount ordinary catalog menu and preserve special CW actions`() {
        val cards = source("ui/tv/TvCinemaCards.kt")
        assertTrue(cards.contains("cinemaPosterMenu(item, continueWatching)"))
        assertTrue(cards.contains("onLongClick = if (menu != PosterCardMenu.NONE)"))
        assertTrue(cards.contains("menu = menu"))
        assertTrue(cards.contains("onRemoveFromContinueWatching = onRemoveFromContinueWatching"))
    }
    @Test fun `catalog Watchlist and watched actions capture before async and acknowledge before dismissal`() {
        val menu = source("ui/components/PosterCard.kt").substringAfter("internal fun PosterQuickActionMenu(")
        assertTrue(menu.contains("capturePosterAction({ checkNotNull(store).captureToggle(item) })"))
        assertTrue(menu.contains("checkNotNull(store).toggle(intent)"))
        assertTrue(menu.contains("capturePosterAction(capturedRepo::continueWatchingOwner)"))
        assertTrue(menu.contains("capturedRepo.setCatalogWatched(item, watched, owner).getOrThrow()"))
        val task = menu.substringAfter("posterActionScope.launch {")
        assertTrue(task.indexOf("action()") in 0 until task.indexOf("onDismiss()"))
        assertTrue(task.contains("actionMessage = \"Could not save this change. Try again.\""))
    }
    @Test fun `phone Sources action reveals actual below fold section through retained LazyColumn`() {
        val detail = source("ui/screens/DetailScreen.kt")
        assertTrue(detail.contains("onToggleSources = { sourcesOpen = !sourcesOpen; sourceJumpPending = sourcesOpen }"))
        assertTrue(detail.contains("detailListState.animateScrollToItem(sourceSectionIndex)"))
        assertTrue(detail.contains("state = detailListState"))
        assertTrue(detail.contains("item(key = \"detail-sources\")"))
    }
    @Test fun `Sources index includes each always mounted item including personal rating controls`() {
        val detail = source("ui/screens/DetailScreen.kt")
        val beforeSources = detail.substringAfter("is UiState.Success -> LazyColumn(")
            .substringBefore("item(key = \"detail-sources\")")
        for (key in listOf("detail-hero", "detail-actions", "detail-personal-rating")) {
            assertEquals("Exactly one mounted $key slot", 1,
                Regex(Regex.escape("item(key = \"$key\")")).findAll(beforeSources).count())
        }
        val personalRating = beforeSources.substringAfter("item(key = \"detail-personal-rating\")")
            .substringBefore("// DET financials")
        assertTrue(personalRating.contains("PersonalRatingActions("))
        assertTrue(source("ui/components/CinemaDetailLayoutPolicy.kt").contains(
            "3 + listOf(pickedReason, ratings, financials, releaseDates).count { it }"))
    }
    @Test fun `phone hero uses measured available viewport and real optional synopsis`() {
        val detail = source("ui/screens/DetailScreen.kt")
        assertTrue(detail.contains("val viewportHeight = maxHeight"))
        assertTrue(detail.contains("Backdrop(m.data, viewportHeight)"))
        assertTrue(detail.contains("cinemaDetailHeroHeightDp(maxWidth.value, viewportHeight.value).dp"))
        assertTrue(detail.substringAfter("private fun Backdrop(").contains("m.description?.takeIf(String::isNotBlank)"))
    }
    @Test fun `TV duplicate provider sections use unique list keys and only first focus anchor`() {
        val list = source("ui/tv/TvSourceList.kt")
        assertTrue(list.contains("val sourceTabs = tvSourceTabs(groups)"))
        assertTrue(list.contains("itemsIndexed(sourceTabs, key = { _, tab -> tab.key })"))
        assertTrue(list.contains("takeIf { entry.firstProviderSection }"))
        assertFalse(list.contains("\"h-\${item.key}\""))
    }
    private fun source(path: String): String {
        val relative = "src/main/kotlin/com/vortx/android/$path"
        return listOf(File(relative), File("android/app/$relative")).first { it.isFile }.readText()
    }
}
