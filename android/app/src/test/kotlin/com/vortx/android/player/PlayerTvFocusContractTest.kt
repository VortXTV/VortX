package com.vortx.android.player

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PlayerTvFocusContractTest {
    @Test
    fun `TV app scopes the early-return player branch in TV Material theme`() {
        val app = source("src/main/kotlin/com/vortx/android/ui/tv/TvApp.kt")
        val playerBranch = app.substringAfter("if (playable != null) {").substringBefore("return@VortXTheme")

        assertTrue(playerBranch.contains("TvMaterialTheme(colorScheme = tvDarkColorScheme())"))
        assertTrue(playerBranch.contains("PlayerScreen("))
        assertTrue(playerBranch.indexOf("TvMaterialTheme(colorScheme = tvDarkColorScheme())") < playerBranch.indexOf("PlayerScreen("))
    }

    @Test
    fun `TV chrome has bounded directional header to transport ownership`() {
        val chrome = source("src/main/kotlin/com/vortx/android/player/PlayerChrome.kt")

        assertTrue(chrome.contains("val tvTransportFocus = remember { FocusRequester() }"))
        assertTrue(chrome.contains("modifier = if (isTvPlayer) Modifier.focusGroup() else Modifier"))
        assertTrue(chrome.contains("fun tvHeaderControlModifier("))
        assertTrue(chrome.contains("this.down = down"))
        assertTrue(chrome.contains("fun tvTransportControlModifier("))
        assertTrue(chrome.contains("Every focusable transport descendant uses this modifier"))
        // Play, +/- seek, previous/next chapter, and scrubber all own the same explicit Up route.
        assertTrue(chrome.split("tvTransportControlModifier(").size - 1 >= 7)
        assertTrue(chrome.contains(".focusProperties { up = tvHeaderFocus }"))
    }

    @Test
    fun `TV overlays cancel focus exit and provide an all-disabled close target`() {
        val chrome = source("src/main/kotlin/com/vortx/android/player/PlayerChrome.kt")

        assertTrue(chrome.contains("private val LocalPlayerChromeIsTv = staticCompositionLocalOf { false }"))
        assertTrue(chrome.contains("CompositionLocalProvider(LocalPlayerChromeIsTv provides isTvPlayer)"))
        assertTrue(chrome.contains("private fun tvOverlayFocusExitModifier(isTvPlayer: Boolean)"))
        assertTrue(chrome.contains("@OptIn(ExperimentalComposeUiApi::class)"))
        assertTrue(chrome.contains("Modifier.focusProperties { exit = { FocusRequester.Cancel } }"))
        assertTrue(chrome.contains("if (isTvPlayer) Modifier.focusGroup().then(tvOverlayFocusExitModifier(true)) else Modifier"))
        assertTrue(chrome.contains("if (isTvPlayer && firstEnabledIndex < 0)"))
        assertTrue(chrome.contains("text = \"Close\""))
        assertTrue(chrome.contains("LaunchedEffect(title, firstEnabledIndex, options.size)"))
        assertTrue(chrome.contains(".focusRequester(muteFocus)"))
        assertTrue(chrome.contains(".focusRequester(recoveryFocus)"))
        assertTrue(chrome.contains("PlayerErrorOverlay(\n                emberAccent = emberAccent,\n                isTvPlayer = isTvPlayer,"))
    }

    private fun source(relativePath: String): String {
        val candidates = listOf(
            File(relativePath),
            File("app/$relativePath"),
            File("android/app/$relativePath"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
