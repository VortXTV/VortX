package com.vortx.android.player.warm

import com.vortx.android.model.StreamSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Coverage for [SourceWarmer.warmTargetUrl], the direct/HTTP-only eligibility policy. The rule keeps the
 * warmer from ever touching a debrid, torrent, or usenet source on focus, so this pins that boundary.
 */
class SourceWarmerPolicyTest {

    private fun source(
        url: String? = null,
        isTorrent: Boolean = false,
        isMediaServer: Boolean = false,
        nzbUrl: String? = null,
        ytId: String? = null,
    ) = StreamSource(
        id = "s",
        addon = "a",
        title = "t",
        isTorrent = isTorrent,
        isMediaServer = isMediaServer,
        url = url,
        nzbUrl = nzbUrl,
        ytId = ytId,
    )

    @Test
    fun `a plain direct https source is warm-eligible`() {
        val url = "https://cdn.example.com/movie.mkv"
        assertEquals(url, SourceWarmer.warmTargetUrl(source(url = url)))
    }

    @Test
    fun `a torrent is never warmed`() {
        assertNull(SourceWarmer.warmTargetUrl(source(url = "https://cdn.example.com/x.mkv", isTorrent = true)))
    }

    @Test
    fun `a usenet source (nzb, no url) is never warmed`() {
        assertNull(SourceWarmer.warmTargetUrl(source(nzbUrl = "https://host/x.nzb")))
    }

    @Test
    fun `a known debrid host is never warmed`() {
        assertNull(SourceWarmer.warmTargetUrl(source(url = "https://real-debrid.com/d/ABC123")))
        assertNull(SourceWarmer.warmTargetUrl(source(url = "https://x.alldebrid.com/dl/abc")))
        assertNull(SourceWarmer.warmTargetUrl(source(url = "https://store.torbox.app/file")))
    }

    @Test
    fun `a media-server direct-play source is always eligible`() {
        val url = "https://real-debrid.com/looks-debrid-but-is-media-server"
        assertEquals(url, SourceWarmer.warmTargetUrl(source(url = url, isMediaServer = true)))
    }

    @Test
    fun `a non-http url (magnet) is never warmed`() {
        assertNull(SourceWarmer.warmTargetUrl(source(url = "magnet:?xt=urn:btih:deadbeef")))
    }

    @Test
    fun `a youtube-trailer source is never warmed`() {
        assertNull(SourceWarmer.warmTargetUrl(source(ytId = "abc123")))
    }
}
