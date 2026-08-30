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

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate TvDetailScreen.kt from ${File(".").absolutePath}")
    }
}
