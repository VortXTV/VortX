package com.vortx.android.player

import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayerLaunchPolicyTest {
    @Test
    fun `full exposes automatic VortX and Media3 while Play exposes Media3 only`() {
        val full = PlayerLaunchPolicy.choices(mpvAvailable = true).map { it.preference }
        val play = PlayerLaunchPolicy.choices(mpvAvailable = false).map { it.preference }

        assertEquals(
            listOf(
                PlayerEngineRouter.Override.AUTO,
                PlayerEngineRouter.Override.MPV,
                PlayerEngineRouter.Override.EXOPLAYER,
            ),
            full,
        )
        assertEquals(listOf(PlayerEngineRouter.Override.EXOPLAYER), play)
        assertFalse(PlayerEngineRouter.Override.MPV in play)
    }

    @Test
    fun `unavailable mpv and torrent compatibility fallbacks are deterministic`() {
        val direct = Playable("https://cdn.example/movie.mkv", "Movie")
        val torrent = direct.copy(url = "http://127.0.0.1/movie", isTorrent = true)

        assertEquals(
            PlayerEngineRouter.Override.EXOPLAYER,
            PlayerLaunchPolicy.effectivePreference(PlayerEngineRouter.Override.MPV, direct, mpvAvailable = false),
        )
        assertEquals(
            PlayerEngineRouter.Override.MPV,
            PlayerLaunchPolicy.effectivePreference(PlayerEngineRouter.Override.EXOPLAYER, torrent, mpvAvailable = true),
        )
        assertEquals(
            PlayerEngineRouter.Override.EXOPLAYER,
            PlayerLaunchPolicy.effectivePreference(PlayerEngineRouter.Override.EXOPLAYER, direct, mpvAvailable = true),
        )
        assertTrue(PlayerLaunchPolicy.choices(false).single().detail.contains("included in this edition"))
    }

    @Test
    fun `source menu exposes only explicit eligible engines`() {
        val direct = StreamSource(id = "direct", addon = "addon", title = "Direct", url = "https://cdn.example/movie.mkv")
        val torrent = direct.copy(id = "torrent", isTorrent = true)

        assertEquals(
            listOf(PlayerEngineRouter.Override.MPV, PlayerEngineRouter.Override.EXOPLAYER),
            PlayerLaunchPolicy.sourceChoices(direct, mpvAvailable = true).map { it.preference },
        )
        assertEquals(
            listOf(PlayerEngineRouter.Override.MPV),
            PlayerLaunchPolicy.sourceChoices(torrent, mpvAvailable = true).map { it.preference },
        )
        assertEquals(
            listOf(PlayerEngineRouter.Override.EXOPLAYER),
            PlayerLaunchPolicy.sourceChoices(torrent, mpvAvailable = false).map { it.preference },
        )
    }
}
