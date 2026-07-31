package com.vortx.android.player

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertTrue
import org.junit.Test

class ExoPlayerEngineSubtitleContractTest {

    @Test
    fun `load remembers playable before either media source branch`() {
        val sourcePath = sequenceOf(
            Path.of("src/main/kotlin/com/vortx/android/player/ExoPlayerEngine.kt"),
            Path.of("app/src/main/kotlin/com/vortx/android/player/ExoPlayerEngine.kt"),
        ).first(Files::exists)
        val source = String(
            Files.readAllBytes(sourcePath),
            StandardCharsets.UTF_8,
        )
        val loadStart = source.indexOf("override fun load(playable: Playable)")
        val rememberPlayable = source.indexOf("lastPlayable = playable", startIndex = loadStart)
        val adaptiveBranch = source.indexOf("if (playable.audioUrl != null)", startIndex = loadStart)

        assertTrue("load function must exist", loadStart >= 0)
        assertTrue("load must remember the playable", rememberPlayable >= 0)
        assertTrue(
            "the playable must be remembered before the adaptive branch can return",
            rememberPlayable in loadStart until adaptiveBranch,
        )
    }
}
