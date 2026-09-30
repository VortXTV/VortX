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
