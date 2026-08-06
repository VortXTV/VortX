package com.vortx.android.ui.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class TvDetailInitialFocusTest {
    @Test
    fun `loading targets enabled secondary action and never steals focus when Watch enables`() {
        val focus = TvDetailInitialFocus()

        assertEquals(TvDetailFocusTarget.SECONDARY_ACTION, focus.next(watchEnabled = false))
        focus.record(requestSucceeded = true)

        assertNull(focus.next(watchEnabled = true))
    }

    @Test
    fun `failed loading request permits exactly one Watch retry`() {
        val focus = TvDetailInitialFocus()

        assertEquals(TvDetailFocusTarget.SECONDARY_ACTION, focus.next(watchEnabled = false))
        focus.record(requestSucceeded = false)
        assertNull(focus.next(watchEnabled = false))
        assertEquals(TvDetailFocusTarget.WATCH, focus.next(watchEnabled = true))
        focus.record(requestSucceeded = false)
        assertNull(focus.next(watchEnabled = true))
    }

    @Test
    fun `Compose wiring attaches fallback to first secondary action and keys retry to Watch state`() {
        val source = readSource()

        assertTrue(focusWiringIsConnected(source))

        val disconnected = source.replace(
            "modifier = saveModifier",
            "modifier = Modifier",
        )
        assertFalse(focusWiringIsConnected(disconnected))
    }

    private fun focusWiringIsConnected(source: String): Boolean =
        source.contains("val trailerModifier = if (hasTrailer) Modifier.focusRequester(secondaryFocus) else Modifier") &&
            source.contains("val saveModifier = if (hasTrailer) Modifier else Modifier.focusRequester(secondaryFocus)") &&
            source.contains("modifier = trailerModifier") &&
            source.contains("modifier = saveModifier") &&
            source.contains("LaunchedEffect(detail.id, watchEnabled)") &&
            source.contains("initialFocus.next(watchEnabled)")

    private fun readSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate TvDetailScreen.kt from ${File(".").absolutePath}")
    }
}
