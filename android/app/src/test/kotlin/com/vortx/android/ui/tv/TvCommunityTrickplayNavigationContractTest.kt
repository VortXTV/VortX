package com.vortx.android.ui.tv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TvCommunityTrickplayNavigationContractTest {

    @Test
    fun `TV returns from the shared playback settings instead of keeping a second consent toggle`() {
        val source = projectFile("src/main/kotlin/com/vortx/android/ui/tv/TvSettingsScreen.kt")

        assertTrue(source.contains("if (route == TvSettingsRoute.PLAYBACK)"))
        assertTrue(source.contains("PlaybackSettingsScreen(onBack = { route = TvSettingsRoute.ROOT }, modifier = modifier)"))
        assertFalse(source.contains("var communityScrub"))
        assertFalse(source.contains("CommunityTrickplay.setEnabled"))
    }

    private fun projectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
