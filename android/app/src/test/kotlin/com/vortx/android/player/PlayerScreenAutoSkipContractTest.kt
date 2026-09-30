package com.vortx.android.player

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source contracts for the production Compose glue around [AutoSkipCountdownPolicy]. */
class PlayerScreenAutoSkipContractTest {
    @Test
    fun `player advances only through the shared countdown and fences stale ownership`() {
        val screen = source("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")

        assertTrue(screen.contains("AutoSkipCountdownPolicy.advance("))
        assertTrue(screen.contains("AutoSkipCountdownPolicy.isCurrent("))
        assertTrue(screen.contains("builtEngine === expectedEngine"))
        assertTrue(screen.contains("playbackSessionKey == expectedSession"))
        assertTrue(screen.contains("!latestState.isPaused"))
        assertTrue(screen.contains("!latestState.isBuffering"))
        assertTrue(screen.contains("!latestState.hasEnded"))
        assertTrue(screen.contains("!effectiveError"))
        assertTrue(screen.contains("!sourceSwitchState.isSwitching"))
        assertTrue(screen.contains("!castState.isConnected"))
        assertTrue(screen.contains("!pip.isInPip"))
        assertTrue(screen.contains("!controlsLocked"))
        assertTrue(screen.contains("!playerExitRequested"))
        assertFalse(screen.contains("AutoSkipPolicy.target("))
    }

    @Test
    fun `all local viewer seek entry points use the countdown invalidation choke point`() {
        val screen = source("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")

        assertTrue(screen.contains("fun seekLocalTo(positionMs: Long)"))
        assertTrue(screen.contains("fun seekLocalBy(deltaMs: Long)"))
        assertTrue(screen.contains("fun invalidateAutoSkipPending"))
        assertTrue(screen.contains("onSeek = { showControls(); seekLocalTo(it) }"))
        assertTrue(screen.contains("onSeekBy = { showControls(); seekLocalBy(it) }"))
        assertTrue(screen.contains("onSeekCommit = { target ->"))
        assertTrue(screen.contains("seekLocalTo(target)"))
        assertTrue(screen.contains("if (resumeAt > 0L) seekLocalTo(resumeAt)"))
        assertTrue(screen.contains("SharedPreferences.OnSharedPreferenceChangeListener"))
        assertTrue(screen.contains("PlaybackBehaviorSettings.AUTO_SKIP_DELAY_SECONDS_KEY"))
    }

    @Test
    fun `skip pill exposes manual action and separate cancel semantics`() {
        val screen = source("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")

        assertTrue(screen.contains("AutoSkipCountdownPolicy.complete(autoSkipCountdown, segment)"))
        assertTrue(screen.contains("AutoSkipCountdownPolicy.cancel(autoSkipCountdown, segment)"))
        assertTrue(screen.contains("onCancel = ::cancelAutomaticSkip"))
        assertTrue(screen.contains("countdownState.isSuppressed(active)"))
        assertTrue(screen.contains(".size(48.dp)"))
        assertTrue(screen.contains("contentDescription = \"Cancel automatic \${active.label.lowercase()}\""))
        assertTrue(screen.contains("Key.DirectionLeft, Key.DirectionRight -> if (countdownPromptVisible)"))
        assertTrue(screen.contains("skipPillFocusedCancel = event.key == Key.DirectionRight"))
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
