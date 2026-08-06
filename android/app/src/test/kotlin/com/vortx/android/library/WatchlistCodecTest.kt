package com.vortx.android.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WatchlistCodecTest {
    @Test
    fun `round trip keeps apple compatible fields newest first`() {
        val entries = listOf(
            WatchlistEntry("tt1", "series", "Show", "show.jpg", 10.0),
            WatchlistEntry("tmdb:2", "movie", null, null, 20.0),
        )

        val decoded = WatchlistCodec.decode(WatchlistCodec.encode(entries))

        assertEquals(listOf("tmdb:2", "tt1"), decoded.map { it.id })
        assertEquals("Show", decoded[1].name)
        assertEquals("show.jpg", decoded[1].poster)
    }

    @Test
    fun `garbled unsafe and duplicate entries fail soft`() {
        assertTrue(WatchlistCodec.decode("not-json").isEmpty())
        val decoded = WatchlistCodec.decode(
            """[
                {"id":"magnet:unsafe","type":"movie","addedAt":30},
                {"id":"tt1","type":"series","addedAt":20},
                {"id":"tt1","type":"movie","addedAt":10}
            ]""",
        )

        assertEquals(1, decoded.size)
        assertEquals("series", decoded.single().type)
    }
}
