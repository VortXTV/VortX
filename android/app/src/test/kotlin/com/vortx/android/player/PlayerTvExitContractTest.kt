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
