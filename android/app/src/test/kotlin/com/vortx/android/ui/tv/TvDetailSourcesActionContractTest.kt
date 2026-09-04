package com.vortx.android.ui.tv

import org.junit.Assert.assertTrue
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
        assertTrue(sourceList.contains("TrackPreferences.commonLanguages"))
    }

    @Test
    fun `metadata retry stays on detail instead of navigating back`() {
        val source = readSource()

        assertTrue(source.contains("TvError(meta.message, onRetry = viewModel::retryMeta)"))
        assertTrue(!source.contains("TvError(meta.message, onRetry = onBack)"))
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
