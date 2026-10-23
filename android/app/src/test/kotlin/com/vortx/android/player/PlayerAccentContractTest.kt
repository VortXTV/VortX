package com.vortx.android.player

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The player paints with the accent chosen in Appearance, never a fixed brand orange. */
class PlayerAccentContractTest {
    private fun source(path: String) = File("src/main/kotlin/com/vortx/android/$path").readText()

    @Test fun `player accent defaults to the chosen theme accent`() {
        val player = source("player/PlayerScreen.kt")
        assertTrue(player.contains("emberAccent: Color = VortXTheme.colors.accent,"))
        assertFalse(player.contains("0xFFD97706"))
    }

    @Test fun `app shell playback prompts use the theme accent`() {
        assertFalse(source("ui/VortXApp.kt").contains("DefaultEmber"))
    }
}
