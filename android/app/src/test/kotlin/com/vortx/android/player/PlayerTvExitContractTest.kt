package com.vortx.android.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking

class PlayerTvExitContractTest {
    @Test
    fun `player owns an idempotent system Back exit and restores the window before navigation`() {
        val screen = source("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")

        assertTrue(screen.contains("BackHandler(enabled = !playerExitRequested) { exitPlayer() }"))
        assertTrue(screen.contains("fun exitPlayer()"))
        assertTrue(screen.contains("if (playerExitRequested) return"))
        assertTrue(screen.contains("restorePlayerWindow()\n        currentOnBack()"))
        assertTrue(screen.contains("onBack = ::exitPlayer"))
        assertFalse(screen.contains("DisposableEffect(currentPlayable.isTrailer)"))
    }

    @Test
    fun `Connecting owns decoder lease and outer release before its early return`() {
        val screen = source("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")
        val connecting = screen.indexOf("if (engine == null)")
        assertTrue(connecting > 0)
        for (required in listOf(
            "PlayerEngineBuildOwner(",
            "DisposableEffect(engineHolder)",
            "PlayerPlaybackLeaseOwner(currentPlayable.playbackLease",
            "onDispose { resourceReleaseGate.sessionDisposed() }",
            "BackHandler(enabled = !playerExitRequested)",
        )) {
            assertTrue("$required must be mounted during Connecting", screen.indexOf(required) in 0 until connecting)
        }
        assertTrue(screen.contains("val engine = engineHolder.build("))
        assertTrue(screen.contains("bindForCommands = false"))
        assertTrue(screen.contains("reconcileAndPublishEngine("))
        assertFalse(screen.contains("engineHolder.set("))
        assertFalse(screen.contains("withContext(Dispatchers.Default + NonCancellable)"))
    }

    @Test
    fun `construction failure is terminal and keeps a Back action without a retry timer`() {
        val screen = source("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")
        assertTrue(screen.contains("catch (cancelled: CancellationException)"))
        assertTrue(screen.contains("throw cancelled"))
        assertTrue(screen.contains("engineBuildFailed = true"))
        assertTrue(screen.contains("if (!engineBuildFailed) CircularProgressIndicator"))
        assertTrue(screen.contains("if (engineBuildFailed) \"Unable to start playback\""))
        assertTrue(screen.contains("onClick = ::exitPlayer).focusable()"))
    }

    @Test
    fun `original orientation survives in-player retry and Up Next session replacement`() {
        val screen = source("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")

        assertTrue(screen.contains("var playerPreviousOrientation by remember { mutableStateOf<Int?>(null) }"))
        assertFalse(screen.contains("playerPreviousOrientation by remember(outerPlaybackSessionId)"))
        assertTrue(screen.contains("if (playerPreviousOrientation == null) playerPreviousOrientation = previousOrientation"))
    }

    @Test
    fun `TV player and failure overlay both request a reachable initial focus target`() {
        val chrome = source("src/main/kotlin/com/vortx/android/player/PlayerChrome.kt")

        assertTrue(chrome.contains("val tvChromeFocus = remember { FocusRequester() }"))
        assertTrue(chrome.contains("Modifier.focusRequester(tvChromeFocus)"))
        assertTrue(chrome.contains("val recoveryFocus = remember { FocusRequester() }"))
        assertTrue(chrome.contains(".focusRequester(recoveryFocus)"))
    }

    @Test
    fun `trickplay capture stops retrying after its first null or ordinary failure`() = runBlocking {
        val nullCircuit = TrickplayCaptureCircuitBreaker()
        var nullCalls = 0
        assertEquals(null, nullCircuit.attempt { nullCalls++; null })
        assertEquals(null, nullCircuit.attempt { nullCalls++; byteArrayOf(1) })
        assertEquals(1, nullCalls)
        assertTrue(nullCircuit.isDisabled())

        val failureCircuit = TrickplayCaptureCircuitBreaker()
        var failureCalls = 0
        assertEquals(null, failureCircuit.attempt { failureCalls++; error("capture failed") })
        assertEquals(null, failureCircuit.attempt { failureCalls++; byteArrayOf(1) })
        assertEquals(1, failureCalls)
        assertTrue(failureCircuit.isDisabled())
    }

    @Test
    fun `trickplay capture propagates cancellation and leaves the circuit available`() {
        val circuit = TrickplayCaptureCircuitBreaker()
        var cancelled = false

        try {
            runBlocking {
                circuit.attempt { throw CancellationException("player closed") }
            }
        } catch (_: CancellationException) {
            cancelled = true
        }
        assertTrue(cancelled)
        assertFalse(circuit.isDisabled())
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
