package com.vortx.android.ui.screens

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DetailSourceAudioSelectorContractTest {
    @Test
    fun `detail sources expose a session audio selector with an Auto reset`() {
        val source = readSource()

        assertTrue(source.contains("label = audioLanguageHint"))
        assertTrue(source.contains("\"Auto\""))
        assertTrue(source.contains("onAudioLanguageHintChange(null)"))
        assertTrue(source.contains("TrackPreferences.commonLanguages"))
    }

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/screens/DetailScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/screens/DetailScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/screens/DetailScreen.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate DetailScreen.kt from ${File(".").absolutePath}")
    }
}
