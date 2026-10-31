package com.vortx.android.cast

import com.vortx.android.model.Playable
import com.vortx.android.engine.StreamingServerPreparedFile
import com.vortx.android.engine.StreamingServerSelection
import com.vortx.android.engine.resolveSelectedStreamingServerTorrent
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CastReceiverURLPolicyTest {
    private val hash = "a".repeat(40)
    private val server = "http://192.168.1.20:11470"
    private fun selected(base: String): Playable = runBlocking {
        val selection = StreamingServerSelection(null) { true }
        check(selection.save(base))
        resolveSelectedStreamingServerTorrent(checkNotNull(selection.capture()), hash, 0, "movie",
            { true }, { true }, prepare = { _, _, _ -> StreamingServerPreparedFile("movie.mp4") })
    }
    @Test fun `chosen LAN torrent uses actual final server endpoint`() {
        val media = Playable("$server/$hash/0", "movie", isTorrent = true, viaStreamingServer = true)
        assertFalse(CastEligibility.isCastable(media))
        val owned = selected(server)
        assertTrue(CastEligibility.isCastable(owned))
        assertFalse(CastEligibility.isCastable(owned.copy(url = "http://192.168.1.21:11470/$hash/0")))
        assertFalse(CastEligibility.isCastable(owned.copy(url = "$server/settings")))
        assertFalse(CastEligibility.isCastable(owned.copy(headers = mapOf("Cookie" to "private"))))
        assertFalse(CastEligibility.isCastable(owned.copy(isTrailer = true)))
    }
    @Test fun `explicit Tailscale server is LAN authority but add-on URL alone is not`() {
        val tailServer = "http://100.89.1.2:11470"
        val media = Playable("$tailServer/$hash/0", "movie", isTorrent = true, viaStreamingServer = true)
        assertTrue(CastEligibility.isCastable(selected(tailServer)))
        assertFalse(CastEligibility.isCastable(media))
        assertFalse(CastEligibility.isCastable(selected(tailServer).copy(url = "http://100.89.1.3:11470/$hash/0")))
        assertFalse(CastEligibility.isRemoteHttpUrl("http://100.100.100.200/$hash/0"))
    }
    @Test fun `public resolved torrent still needs explicit selected server proof`() {
        val media = Playable("https://stream.example/$hash/0", "movie", isTorrent = true)
        assertFalse(CastEligibility.isCastable(media))
        assertTrue(CastEligibility.isCastable(selected("https://stream.example")))
    }
    @Test fun `local metadata and ambiguous numeric hosts remain forbidden even when selected`() {
        listOf("127.1", "127.2.3.4", "127.0.0.1", "2130706433", "0x7f000001", "0177.0.0.1", "0.0.0.0",
            "localhost", "foo.localhost", "169.254.169.254", "metadata.google.internal", "[::1]", "[::]",
            "[fe80::1]", "[::ffff:127.0.0.1]", "[fd00:ec2::254]", "168.63.129.16").forEach { host ->
            val base = "http://$host"
            assertFalse(host, CastEligibility.isRemoteHttpUrl("$base/$hash/0"))
            assertFalse(host, CastEligibility.isCastable(Playable("$base/movie.mp4", "movie")))
            assertFalse(host, StreamingServerSelection.normalizedBase(base) != null)
        }
    }
    @Test fun `ordinary self hosted LAN and Tailscale URLs need no streaming server selection`() {
        val urls = listOf(
            "http://192.168.1.20/private.mp4",
            "http://10.0.0.7/library/movie.mkv",
            "https://172.16.0.5/library/movie.mp4",
            "http://100.89.1.2:8080/media/episode.m3u8",
            "http://nas.local/movie.mp4",
            "http://nas/movie.mp4",
            "https://nas.example.ts.net/movie.mkv",
            "http://[fd7a:115c:a1e0::12]/movie.mp4",
        )
        for (url in urls) {
            val media = Playable(url, "movie")
            assertTrue(url, CastEligibility.isRemoteHttpUrl(url))
            assertTrue(url, CastEligibility.isCastable(media))
            // Ordinary streams require no torrent route receipt.
            assertTrue(url, CastEligibility.isCastable(media.copy(streamingServerRoute = null)))
        }
    }

    @Test fun `ordinary LAN and Tailscale routes still refuse receiver unavailable credentials and split media`() {
        for (url in listOf("$server/movie.mp4", "http://100.89.1.2:8080/movie.mp4")) {
            val media = Playable(url, "movie")
            assertFalse(CastEligibility.isCastable(media.copy(headers = mapOf("Authorization" to "Bearer test"))))
            assertFalse(CastEligibility.isCastable(media.copy(headers = mapOf("Cookie" to "test"))))
            assertFalse(CastEligibility.isCastable(media.copy(headers = mapOf("Referer" to "https://addon.example/"))))
            assertFalse(CastEligibility.isCastable(media.copy(audioUrl = "https://audio.example/leg.m4a")))
            assertFalse(CastEligibility.isCastable(media.copy(userAgent = "bound-client")))
            assertFalse(CastEligibility.isCastable(media.copy(isTrailer = true)))
        }
        assertFalse(CastEligibility.isRemoteHttpUrl("https://user:secret@cdn.example/movie.mp4"))
    }

    @Test fun `owned progressive Usenet transport gains no receiver lifetime from a LAN URL`() {
        var closed = false
        val originalLease = AutoCloseable { closed = true }
        val media = Playable("$server/movie.mkv", "movie", playbackLease = originalLease)
        assertFalse(CastEligibility.isCastable(media))
        assertFalse(CastEligibility.isCastable(media.copy(streamingServerRoute = selected(server).streamingServerRoute)))
        assertFalse(CastEligibility.isCastable(media.copy(url = "http://127.0.0.1:11470/movie.mkv")))
        assertFalse(closed) // Eligibility neither transfers nor retires a producer's original lifetime.
    }

    @Test fun `torrent authority still requires exact selected origin and media route`() {
        val selectedBase = "https://192.168.1.20:8443/stream"
        val media = Playable("$selectedBase/$hash/0", "movie", isTorrent = true, viaStreamingServer = true)
        assertFalse(CastEligibility.isCastable(media))
        val owned = selected(selectedBase)
        assertTrue(CastEligibility.isCastable(owned))
        for (other in listOf("http://192.168.1.20:8443/stream", "https://192.168.1.20:8444/stream",
                "https://192.168.1.21:8443/stream", "https://192.168.1.20:8443/other"))
            assertFalse(other, CastEligibility.isCastable(owned.copy(url = "$other/$hash/0")))
        for (path in listOf("/settings", "/${"a".repeat(39)}/0", "/$hash/-1", "/$hash/0/extra"))
            assertFalse(path, CastEligibility.isCastable(owned.copy(url = selectedBase + path)))
    }
}
