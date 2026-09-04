package com.vortx.android.player

import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
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
        assertTrue(chrome.contains("Modifier.focusProperties { onExit = { cancelFocusChange() } }"))
        assertTrue(chrome.contains("if (isTvPlayer) tvOverlayFocusExitModifier(true).focusGroup() else Modifier"))
        assertTrue(!chrome.contains("Modifier.focusGroup().then(tvOverlayFocusExitModifier(true))"))
        assertTrue(chrome.contains("if (isTvPlayer && firstEnabledIndex < 0)"))
        assertTrue(chrome.contains("text = \"Close\""))
        assertTrue(chrome.contains("LaunchedEffect(title, firstEnabledIndex, options.size)"))
        assertTrue(chrome.contains(".focusRequester(muteFocus)"))
        assertTrue(chrome.contains(".focusRequester(recoveryFocus)"))
        assertTrue(chrome.contains("PlayerErrorOverlay(\n                emberAccent = emberAccent,\n                isTvPlayer = isTvPlayer,"))
    }

    @Test
    fun `TV scrubber is a real focus target and consumes directional seek keys`() {
        val chrome = source("src/main/kotlin/com/vortx/android/player/PlayerChrome.kt")
        val scrubber = source("src/main/kotlin/com/vortx/android/player/extras/SeekBarStyle.kt")
        val chromeScrubberCall = chrome.substringAfter("StyledScrubber(").substringBefore("            Text(\n                text = formatTime(duration)")
        val remoteFocusBlock = scrubber.substringAfter("val remoteFocus = if").substringBefore("    Canvas(")

        assertTrue(chromeScrubberCall.contains("tvSeekStepMs = seekStepMs"))
        assertTrue(chromeScrubberCall.contains("onTvSeekBy = if (isTvPlayer)"))
        assertTrue(chromeScrubberCall.contains("onInteraction()"))
        assertTrue(chromeScrubberCall.contains("onSeekBy(delta)"))
        assertTrue(chromeScrubberCall.contains("else {\n                    null"))
        assertTrue(chromeScrubberCall.contains(".then(tvTransportControlModifier(isTvPlayer, tvHeaderFocus))"))
        assertTrue(scrubber.contains("onTvSeekBy: ((Long) -> Unit)? = null"))
        assertTrue(remoteFocusBlock.contains(".focusable()"))
        assertTrue(remoteFocusBlock.contains("if (event.type != KeyEventType.KeyDown) return@onKeyEvent false"))
        assertTrue(remoteFocusBlock.contains("Holding Left/Right deliberately repeats relative seeks"))
        // A repeat KeyDown is intentionally another relative seek. Reject a future native repeat-count
        // suppression branch, which would make held remote presses silently stop after one tick.
        assertFalse(remoteFocusBlock.contains("repeatCount"))
        assertTrue(remoteFocusBlock.contains("Key.DirectionLeft -> {\n                        onTvSeekBy(-tvSeekStepMs)\n                        true"))
        assertTrue(remoteFocusBlock.contains("Key.DirectionRight -> {\n                        onTvSeekBy(tvSeekStepMs)\n                        true"))
        assertTrue(remoteFocusBlock.contains("else -> false"))
        assertTrue(scrubber.contains(".then(remoteFocus)"))
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
