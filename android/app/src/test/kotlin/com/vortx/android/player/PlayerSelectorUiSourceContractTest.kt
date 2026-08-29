package com.vortx.android.player

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerSelectorUiSourceContractTest {
    @Test
    fun `Sources orders Quality then audio hint then source header and keeps track selection separate`() {
        val chrome = source("src/main/kotlin/com/vortx/android/player/PlayerChrome.kt")
        val block = chrome.substringAfter("ControlSheet.SOURCES ->").substringBefore("ControlSheet.SOURCE_AUDIO ->")

        val quality = block.indexOf("label = qualityTitle")
        val audio = block.indexOf("label = \"Audio language\"")
        val sources = block.indexOf("add(SheetOption(sourcesTitle")
        val rows = block.indexOf("sourceChoices.forEach")
        assertTrue(quality >= 0 && quality < audio && audio < sources && sources < rows)
        assertTrue(chrome.contains("Release-name hint"))
        assertFalse(block.contains("onSelectAudio("))
    }

    @Test
    fun `phone and TV carry one launch-only choice into PlayerScreen`() {
        val detail = source("src/main/kotlin/com/vortx/android/ui/screens/DetailScreen.kt")
        val phone = source("src/main/kotlin/com/vortx/android/ui/VortXApp.kt")
        val tvDetail = source("src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt")
        val tv = source("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt")

        assertTrue(detail.contains("pendingLaunchEnginePreference = launchEnginePreference"))
        assertTrue(detail.contains("Applies to this launch only"))
        assertTrue(phone.contains("engineOverride = playingEngineOverride"))
        assertTrue(tvDetail.contains("pendingLaunchEnginePreference = launchEnginePreference"))
        assertTrue(tv.contains("engineOverride = playingEngineOverride"))
    }

    private fun source(relative: String): String {
        val candidates = listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relative from ${File(".").absolutePath}")
    }
}
