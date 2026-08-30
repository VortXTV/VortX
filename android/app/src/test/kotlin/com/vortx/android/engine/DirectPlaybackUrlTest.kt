package com.vortx.android.engine

import com.vortx.android.model.StreamSource
import org.junit.Assert.assertEquals
import org.junit.Test

class DirectPlaybackUrlTest {
    @Test
    fun `community-js synthetic id resolves through its structured header-gated url`() {
        val source = StreamSource(
            id = "community-js:fixture:0:12345",
            addon = "Fixture",
            title = "1080p",
            url = "https://cdn.example/protected.m3u8",
            requestHeaders = mapOf("Referer" to "https://fixture.example/"),
            externalSubtitles = listOf("https://cdn.example/subtitles.vtt"),
        )

        assertEquals("https://cdn.example/protected.m3u8", source.directPlaybackUrl(source.id))
        assertEquals("https://fixture.example/", source.requestHeaders["Referer"])
        assertEquals(listOf("https://cdn.example/subtitles.vtt"), source.externalSubtitles)
    }

    @Test
    fun `legacy direct id remains the fallback when source url is absent or invalid`() {
        val source = StreamSource(id = "https://cdn.example/legacy.mp4", addon = "Fixture", title = "Legacy", url = "magnet:?xt=urn:btih:bad")

        assertEquals("https://cdn.example/legacy.mp4", source.directPlaybackUrl(source.id))
    }
}
