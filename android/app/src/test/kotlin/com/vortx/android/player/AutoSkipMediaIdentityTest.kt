package com.vortx.android.player

import com.vortx.android.model.MediaRef
import com.vortx.android.model.Playable
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoSkipMediaIdentityTest {
    @Test
    fun `same episode keeps skip lifecycle across source failover`() {
        val ref = MediaRef(isSeries = true, imdb = "TT1234567", season = 2, episode = 4)
        val first = playable("https://one.example/file", ref)
        val failover = playable("https://two.example/file", ref)

        assertEquals("imdb:tt1234567:s2:e4", autoSkipMediaIdentity(first))
        assertEquals(autoSkipMediaIdentity(first), autoSkipMediaIdentity(failover))
    }

    @Test
    fun `different episodes and unmapped URLs never share skip lifecycle`() {
        val firstEpisode = playable(
            "https://one.example/file",
            MediaRef(isSeries = true, imdb = "tt1234567", season = 2, episode = 4),
        )
        val nextEpisode = playable(
            "https://two.example/file",
            MediaRef(isSeries = true, imdb = "tt1234567", season = 2, episode = 5),
        )
        val unmappedFirst = playable("https://one.example/file", null)
        val unmappedSecond = playable("https://two.example/file", null)

        assertNotEquals(autoSkipMediaIdentity(firstEpisode), autoSkipMediaIdentity(nextEpisode))
        assertEquals("url:https://one.example/file", autoSkipMediaIdentity(unmappedFirst))
        assertNotEquals(autoSkipMediaIdentity(unmappedFirst), autoSkipMediaIdentity(unmappedSecond))
    }

    @Test
    fun `player remembers automatic skip state by stable media identity`() {
        val source = readProjectFile("src/main/kotlin/com/vortx/android/player/PlayerScreen.kt")

        assertTrue(source.contains("val autoSkipIdentity = autoSkipMediaIdentity(playable)"))
        assertTrue(source.contains("val autoSkippedStarts = remember(autoSkipIdentity)"))
        assertTrue(source.contains("AutoSkipPolicy.target(skipSegments, latestState.positionMs, autoSkippedStarts)"))
    }

    private fun playable(url: String, ref: MediaRef?) = Playable(
        url = url,
        title = "Title",
        mediaRef = ref,
    )

    private fun readProjectFile(relativePath: String): String {
        val candidates = listOf(File(relativePath), File("app/$relativePath"), File("android/app/$relativePath"))
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relativePath from ${File(".").absolutePath}")
    }
}
