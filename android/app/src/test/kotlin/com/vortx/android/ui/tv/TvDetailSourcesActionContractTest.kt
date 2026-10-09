package com.vortx.android.ui.tv

import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.File

class TvDetailSourcesActionContractTest {
    @Test
    fun `Sources is adjacent to Watch and moves focus into the source pane`() {
        val source = readSource()

        assertTrue(source.contains("val sourcesFocus = remember { FocusRequester() }"))
        assertTrue(source.contains("label = \"Sources\""))
        assertTrue(source.contains("sourcesFocus.requestFocus()"))
        assertTrue(source.contains("Modifier.focusRequester(sourcesFocus)"))
    }

    @Test
    fun `TV source pane exposes session audio selection without a refetch action`() {
        val detail = readSource()
        val sourceList = readSourceList()

        assertTrue(detail.contains("sourceAudioLanguageHint"))
        assertTrue(detail.contains("onAudioLanguageHintChange = viewModel::setSourceAudioLanguageHint"))
        assertTrue(sourceList.contains("label = audioLanguageHint"))
        assertTrue(sourceList.contains("onAudioLanguageHintChange(null)"))
        assertTrue(sourceList.contains("detailAudioLanguageOptions(groups)"))
        assertTrue(sourceList.contains("audioLanguageOptions.forEach"))
        assertTrue(sourceList.contains("TrackPreferences.commonLanguages.firstOrNull"))
        assertFalse(sourceList.contains("TrackPreferences.commonLanguages.forEach"))
    }

    @Test
    fun `metadata retry stays on detail instead of navigating back`() {
        val source = readSource()

        assertTrue(source.contains("TvError(meta.message, onRetry = viewModel::retryMeta)"))
        assertTrue(!source.contains("TvError(meta.message, onRetry = onBack)"))
    }

    @Test
    fun `explicit QuickView Watch waits for a ranked source and consumes before dispatch`() {
        val source = readSource()
        assertTrue(source.contains("autoWatch: Boolean = false"))
        val begin = source.substringAfter("val beginPlayback: (() -> Unit) -> Unit = { action ->")
            .substringBefore("val beginPlaybackWithEngine")
        assertTrue(begin.indexOf("onAutoWatchConsumed()") in 0 until begin.indexOf("action()"))
        val automatic = source.substringAfter("LaunchedEffect(autoWatch, metaState, streamsState, playback)")
            .substringBefore("BackHandler")
        assertTrue(automatic.contains("!autoWatch"))
        assertTrue(automatic.contains("playback is Playback.Resolving"))
        assertTrue(automatic.contains("metaState !is UiState.Success"))
        assertTrue(automatic.contains("viewModel.bestSource() == null"))
        assertTrue(automatic.contains("beginPlayback { viewModel.playBest() }"))
    }

    @Test
    fun `manual source and engine choices also retire pending QuickView Watch`() {
        val source = readSource()
        val engine = source.substringAfter("val beginPlaybackWithEngine:")
            .substringBefore("LaunchedEffect(autoWatch")
        assertTrue(engine.indexOf("onAutoWatchConsumed()") in 0 until engine.indexOf("action()"))
    }

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate TvDetailScreen.kt from ${File(".").absolutePath}")
    }

    private fun readSourceList(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvSourceList.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvSourceList.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvSourceList.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate TvSourceList.kt from ${File(".").absolutePath}")
    }
}
