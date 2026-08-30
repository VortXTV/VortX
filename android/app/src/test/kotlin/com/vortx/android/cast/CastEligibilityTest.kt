package com.vortx.android.cast

import com.vortx.android.model.Playable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pure gating rules for the Cast lane. Mirrors the Apple `PlayerEngineRouter` loopback gate: only a
/// direct / HLS / debrid HTTP(S) stream a remote receiver can reach is castable; torrents (loopback
/// streaming-server URLs), trailers (UA-locked googlevideo), and non-HTTP URLs never are.
class CastEligibilityTest {

    private fun playable(
        url: String,
        isTorrent: Boolean = false,
        isTrailer: Boolean = false,
    ) = Playable(url = url, title = "Test", isTorrent = isTorrent, isTrailer = isTrailer)

    @Test
    fun `direct https stream is castable`() {
        assertTrue(CastEligibility.isCastable(playable("https://cdn.example.com/movie.mp4")))
    }

    @Test
    fun `remote http hls stream is castable`() {
        assertTrue(CastEligibility.isCastable(playable("http://debrid.example.com/stream/index.m3u8")))
    }

    @Test
    fun `loopback streaming-server url is not castable`() {
        assertFalse(CastEligibility.isCastable(playable("http://127.0.0.1:11470/hls/master.m3u8")))
        assertFalse(CastEligibility.isCastable(playable("http://localhost:8080/play.mp4")))
    }

    @Test
    fun `torrent is never castable even with a remote-looking url`() {
        assertFalse(CastEligibility.isCastable(playable("http://127.0.0.1:11470/stream", isTorrent = true)))
    }

    @Test
    fun `trailer is never castable`() {
        assertFalse(
            CastEligibility.isCastable(
                playable("https://rr3.googlevideo.com/videoplayback?x=1", isTrailer = true),
            ),
        )
    }

    @Test
    fun `header-gated stream is not castable because the receiver cannot replay headers`() {
        assertFalse(
            CastEligibility.isCastable(
                Playable(
                    url = "https://cdn.example.com/protected.m3u8",
                    title = "Protected",
                    headers = mapOf("Referer" to "https://addon.example/"),
                ),
            ),
        )
    }

    @Test
    fun `non-http urls are not castable`() {
        assertFalse(CastEligibility.isCastable(playable("magnet:?xt=urn:btih:abcdef")))
        assertFalse(CastEligibility.isCastable(playable("file:///data/local/clip.mp4")))
        assertFalse(CastEligibility.isCastable(playable("content://media/external/video/1")))
    }

    @Test
    fun `content type is guessed from the url extension`() {
        assertEquals("application/x-mpegURL", CastEligibility.contentType("https://x.example/a.m3u8"))
        assertEquals("application/dash+xml", CastEligibility.contentType("https://x.example/a.mpd"))
        assertEquals("video/webm", CastEligibility.contentType("https://x.example/a.webm"))
        assertEquals("video/mp4", CastEligibility.contentType("https://x.example/a.mp4"))
        assertEquals("video/mp4", CastEligibility.contentType("https://x.example/stream?id=7"))
    }

    @Test
    fun `subtitle content type is guessed from the url extension`() {
        assertEquals("application/x-subrip", CastEligibility.subtitleContentType("https://x.example/s.srt"))
        assertEquals("text/vtt", CastEligibility.subtitleContentType("https://x.example/s.vtt"))
        assertEquals("text/vtt", CastEligibility.subtitleContentType("https://x.example/subs?lang=en"))
    }
}
