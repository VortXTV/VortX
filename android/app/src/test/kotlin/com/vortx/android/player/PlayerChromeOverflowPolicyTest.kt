package com.vortx.android.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PlayerChromeOverflowPolicyTest {
    @Test
    fun `narrow phone placement keeps only source and track actions plus More in the header`() {
        val placement = fullyPopulatedPlacement()

        assertEquals(
            listOf(
                PlayerChromeHeaderAction.SOURCES,
                PlayerChromeHeaderAction.AUDIO,
                PlayerChromeHeaderAction.SUBTITLES,
                PlayerChromeHeaderAction.MORE,
            ),
            placement.header,
        )
        assertTrue(PlayerChromeOverflowAction.QUALITY in placement.overflow)
        assertTrue(PlayerChromeOverflowAction.EPISODES in placement.overflow)
        assertTrue(PlayerChromeOverflowAction.VOLUME in placement.overflow)
        assertTrue(PlayerChromeOverflowAction.CAST in placement.overflow)
    }

    @Test
    fun `TV placement uses the same fixed header so remote focus never depends on width`() {
        val placement = fullyPopulatedPlacement()

        assertEquals(PlayerChromeHeaderAction.entries, placement.header)
        assertTrue(PlayerChromeOverflowAction.PIP in placement.overflow)
        assertTrue(PlayerChromeOverflowAction.LOCK in placement.overflow)
        assertTrue(PlayerChromeOverflowAction.SETTINGS in placement.overflow)
    }

    @Test
    fun `unavailable secondary actions are absent while core More actions remain reachable`() {
        val placement = playerChromeActionPlacement(
            hasQualityChoices = false,
            hasEpisodes = false,
            hasChapters = false,
            canShare = false,
            hasPip = false,
            hasLock = false,
            hasCastSlot = false,
        )

        assertFalse(PlayerChromeOverflowAction.QUALITY in placement.overflow)
        assertFalse(PlayerChromeOverflowAction.EPISODES in placement.overflow)
        assertFalse(PlayerChromeOverflowAction.CHAPTERS in placement.overflow)
        assertFalse(PlayerChromeOverflowAction.SHARE in placement.overflow)
        assertTrue(PlayerChromeOverflowAction.VOLUME in placement.overflow)
        assertTrue(PlayerChromeOverflowAction.SPEED in placement.overflow)
        assertTrue(PlayerChromeOverflowAction.ASPECT_RATIO in placement.overflow)
        assertTrue(PlayerChromeOverflowAction.SETTINGS in placement.overflow)
    }

    @Test
    fun `dismissing a More drill-in restores TV focus to More`() {
        val chrome = source("src/main/kotlin/com/vortx/android/player/PlayerChrome.kt")

        assertTrue(chrome.contains("fun openMoreSubsheet(sheet: ControlSheet)"))
        assertTrue(chrome.contains("restoreMoreFocus = true\n        openSheet = sheet"))
        assertTrue(chrome.contains("if (restoreMoreFocus) tvMoreFocus.requestFocus()"))
        val more = chrome.substringAfter("ControlSheet.MORE ->").substringBefore("ControlSheet.PLAYER_SETTINGS ->")
        assertTrue(more.contains("openMoreSubsheet(ControlSheet.VOLUME)"))
        assertTrue(more.contains("openMoreSubsheet(ControlSheet.PLAYER_SETTINGS)"))
    }

    @Test
    fun `compact header keeps spoken labels for every remote action`() {
        val chrome = source("src/main/kotlin/com/vortx/android/player/PlayerChrome.kt")
        val header = chrome.substringAfter("Row(verticalAlignment = Alignment.CenterVertically) {")
            .substringBefore("Row(horizontalArrangement")

        assertTrue(header.contains("contentDescription = \"Back\""))
        assertTrue(header.contains("sourcesDescription"))
        assertTrue(header.contains("\"Audio and output settings\""))
        assertTrue(header.contains("\"Subtitles\""))
        assertTrue(header.contains("\"More player controls\""))
    }

    private fun fullyPopulatedPlacement() = playerChromeActionPlacement(
        hasQualityChoices = true,
        hasEpisodes = true,
        hasChapters = true,
        canShare = true,
        hasPip = true,
        hasLock = true,
        hasCastSlot = true,
    )

    private fun source(relative: String): String {
        val candidates = listOf(File(relative), File("app/$relative"), File("android/app/$relative"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relative from ${File(".").absolutePath}")
    }
}
