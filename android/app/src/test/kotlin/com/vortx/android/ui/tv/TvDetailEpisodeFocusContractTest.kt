package com.vortx.android.ui.tv

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class TvDetailEpisodeFocusContractTest {
    @Test
    fun `episode rail wires previous episode and first episode to season focus`() {
        val source = readSource()

        assertTrue(source.contains(".focusProperties { up = upFocusRequester }"))
        assertTrue(source.contains("if (index == 0) seasonFocus else episodeFocusRequesters[index - 1]"))
        assertTrue(source.contains("focusRestoreEpisodeId"))
        assertTrue(source.contains("focusRestoreRevision"))
    }

    @Test
    fun `whole series watched action uses complete inventory rather than active season`() {
        val source = readSource()
        assertTrue(source.contains("detail.videos.isNotEmpty() && detail.videos.all { it.id in detail.watchedVideoIds }"))
        assertTrue(source.contains("onMarkSeriesWatched(!seriesAllWatched)"))
        assertTrue(source.contains("\"Mark series unwatched\" else \"Mark series watched\""))
        val detail = listOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
        ).first(File::isFile).readText()
        assertTrue(detail.contains("onMarkSeriesWatched = viewModel::setWatched"))
    }

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvDetailSections.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailSections.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailSections.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate TvDetailSections.kt from ${File(".").absolutePath}")
    }
}
