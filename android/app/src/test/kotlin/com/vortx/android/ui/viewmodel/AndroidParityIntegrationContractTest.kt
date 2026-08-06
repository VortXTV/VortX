package com.vortx.android.ui.viewmodel

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidParityIntegrationContractTest {
    @Test
    fun `approved home and history features remain connected across the integration conflicts`() {
        val sources = IntegrationSources(
            media = readProjectFile("src/main/kotlin/com/vortx/android/model/Media.kt"),
            homeViewModel = readProjectFile("src/main/kotlin/com/vortx/android/ui/viewmodel/CatalogViewModels.kt"),
            phoneHome = readProjectFile("src/main/kotlin/com/vortx/android/ui/screens/HomeScreen.kt"),
            tvHome = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvHomeScreen.kt"),
            tvComponents = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvComponents.kt"),
            phoneApp = readProjectFile("src/main/kotlin/com/vortx/android/ui/VortXApp.kt"),
            tvApp = readProjectFile("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt"),
        )

        assertTrue(integrationContractIsComplete(sources))
        requirements.forEach { requirement ->
            val mutated = sources.mutate(requirement.source) { source ->
                source.replace(requirement.marker, "REMOVED_INTEGRATION_REQUIREMENT")
            }
            assertFalse(
                "contract must reject removal of ${requirement.marker}",
                integrationContractIsComplete(mutated),
            )
        }
    }

    private fun integrationContractIsComplete(sources: IntegrationSources): Boolean =
        requirements.all { requirement -> sources[requirement.source].contains(requirement.marker) }

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }

    private data class Requirement(val source: Source, val marker: String)

    private enum class Source {
        MEDIA,
        HOME_VIEW_MODEL,
        PHONE_HOME,
        TV_HOME,
        TV_COMPONENTS,
        PHONE_APP,
        TV_APP,
    }

    private data class IntegrationSources(
        val media: String,
        val homeViewModel: String,
        val phoneHome: String,
        val tvHome: String,
        val tvComponents: String,
        val phoneApp: String,
        val tvApp: String,
    ) {
        operator fun get(source: Source): String = when (source) {
            Source.MEDIA -> media
            Source.HOME_VIEW_MODEL -> homeViewModel
            Source.PHONE_HOME -> phoneHome
            Source.TV_HOME -> tvHome
            Source.TV_COMPONENTS -> tvComponents
            Source.PHONE_APP -> phoneApp
            Source.TV_APP -> tvApp
        }

        fun mutate(source: Source, transform: (String) -> String): IntegrationSources = when (source) {
            Source.MEDIA -> copy(media = transform(media))
            Source.HOME_VIEW_MODEL -> copy(homeViewModel = transform(homeViewModel))
            Source.PHONE_HOME -> copy(phoneHome = transform(phoneHome))
            Source.TV_HOME -> copy(tvHome = transform(tvHome))
            Source.TV_COMPONENTS -> copy(tvComponents = transform(tvComponents))
            Source.PHONE_APP -> copy(phoneApp = transform(phoneApp))
            Source.TV_APP -> copy(tvApp = transform(tvApp))
        }
    }

    private companion object {
        val requirements = listOf(
            Requirement(Source.MEDIA, "val caption: String? = null,"),
            Requirement(Source.MEDIA, "val watched: Boolean = false,"),
            Requirement(Source.HOME_VIEW_MODEL, "val reduced = reducer.reduce(update) ?: return@collect"),
            Requirement(Source.HOME_VIEW_MODEL, "clearOwnerPersonalizedRows()"),
            Requirement(Source.HOME_VIEW_MODEL, "baseRows = rows"),
            Requirement(Source.HOME_VIEW_MODEL, "refreshPersonalizedRails()"),
            Requirement(
                Source.HOME_VIEW_MODEL,
                "withoutContinueWatchingItems(rows, pendingContinueWatchingDismissals, owner)",
            ),
            Requirement(Source.HOME_VIEW_MODEL, "withTopPicksRail(baseRows, topPicksItems)"),
            Requirement(Source.HOME_VIEW_MODEL, "preferences.arrange(enriched, railSurface, preferences.state.value)"),
            Requirement(Source.HOME_VIEW_MODEL, "scope.launch { repo.loadHomeRowNextPage(catalog) }"),
            Requirement(Source.PHONE_HOME, "TOP_PICKS_CATALOG_ID -> \"Based on what you watch\""),
            Requirement(
                Source.PHONE_HOME,
                "onRemoveFromContinueWatching = viewModel::removeFromContinueWatching",
            ),
            Requirement(Source.PHONE_HOME, "{ viewModel.loadNextPage(catalog) }"),
            Requirement(Source.TV_HOME, "catalogLayout == HomeCatalogLayout.WALL"),
            Requirement(Source.TV_HOME, "remember(contentOwnerGeneration, catalogLayout)"),
            Requirement(Source.TV_HOME, "LaunchedEffect(contentOwnerGeneration, catalogLayout)"),
            Requirement(Source.TV_HOME, "onRemoveFromContinueWatching = onRemoveFromContinueWatching"),
            Requirement(Source.TV_HOME, "onLoadRowPage = onLoadRowPage"),
            Requirement(Source.TV_HOME, "reconcileTvHomeFocus(focusState, visibleCatalogs)"),
            Requirement(Source.TV_COMPONENTS, "if (item.watched)"),
            Requirement(Source.PHONE_APP, "playbackSessions.newHandle()"),
            Requirement(Source.PHONE_APP, "playbackSessions.report(playbackSession, pos, dur)"),
            Requirement(Source.TV_APP, "TvPlaybackHistorySession(playable, playbackSessions)"),
            Requirement(
                Source.TV_APP,
                "private val handle = if (playable.isTrailer) null else playbackSessions.newHandle()",
            ),
            Requirement(Source.TV_APP, "playbackHistory.report(pos, dur)"),
        )
    }
}
