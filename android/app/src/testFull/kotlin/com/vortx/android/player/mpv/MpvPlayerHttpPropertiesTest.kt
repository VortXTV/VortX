package com.vortx.android.player.mpv

import com.vortx.android.model.Playable
import org.junit.Assert.assertEquals
import org.junit.Test

class MpvPlayerHttpPropertiesTest {
    @Test
    fun `plain source after custom source resets both header fields and user agent`() {
        val custom = Playable(
            url = "https://video.example/trailer",
            title = "Trailer",
            headers = linkedMapOf("Referer" to "https://private.example"),
            userAgent = "Bound-Trailer-UA",
            isTrailer = true,
        )
        val plain = Playable(
            url = "https://cdn.example/movie",
            title = "Movie",
        )

        assertEquals(
            listOf(
                "http-header-fields" to "",
                "user-agent" to MpvConfig.USER_AGENT,
                "http-header-fields" to "Referer: https://private.example",
                "user-agent" to "Bound-Trailer-UA",
                "http-header-fields" to "",
            ),
            MpvPlayer.streamHttpPropertyWrites(custom),
        )
        assertEquals(
            listOf(
                "http-header-fields" to "",
                "user-agent" to MpvConfig.USER_AGENT,
            ),
            MpvPlayer.streamHttpPropertyWrites(plain),
        )
    }

    @Test
    fun `headers-only source restores base user agent before applying its own headers`() {
        val source = Playable(
            url = "https://cdn.example/movie",
            title = "Movie",
            headers = linkedMapOf(
                "Referer" to "https://addon.example",
                "X-Playback-Token" to "token",
            ),
        )

        assertEquals(
            listOf(
                "http-header-fields" to "",
                "user-agent" to MpvConfig.USER_AGENT,
                "http-header-fields" to
                    "Referer: https://addon.example,X-Playback-Token: token",
            ),
            MpvPlayer.streamHttpPropertyWrites(source),
        )
    }
}
