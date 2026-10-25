package com.vortx.android.engine

import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.singularity.SourceIndexClient
import com.vortx.android.singularity.SourceIndexServeSource
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

/** Pooled descriptors are not fetch authorization, even when they look publicly routable.
 * No URL in these tests is resolved, fetched, or handed to a player. */
class SourceIndexPooledAdmissionBoundaryTest {
    private val hash = "abcdef0123456789abcdef0123456789abcdef01"

    @Test fun `pooled URL kinds stay withheld for public looking and private targets`() {
        val urls = listOf(
            "https://media.example.com/movie.mp4",
            "https://8.8.8.8/release.nzb",
            "http://192.168.1.12/movie.mp4",
            "http://127.0.0.1/admin",
        )
        val rows = JSONArray()
        for (kind in listOf("http", "usenet", "directurl", "nzbUrl")) for (url in urls) {
            rows.put(JSONObject().put("kind", kind).put("id", url).put("corroboration", 99))
        }
        // A canonical-looking hash does not turn a non-torrent kind into an admitted torrent.
        rows.put(JSONObject().put("kind", "http").put("id", hash).put("corroboration", 99))
        rows.put(JSONObject().put("kind", "usenet").put("id", hash).put("corroboration", 99))
        // Conversely, a torrent label cannot promote a URL into a canonical infohash.
        rows.put(JSONObject().put("kind", "torrent").put("id", urls.first()).put("corroboration", 99))
        val parsed = SourceIndexClient.parsePooled(JSONObject().put("sources", rows).toString())
        assertEquals(19, parsed.size)
        assertTrue(SourceIndexClient.streams(parsed).isEmpty())
    }

    @Test fun `unknown wire URL fields cannot hitchhike on an admitted pooled torrent`() {
        val row = JSONObject().put("kind", "torrent").put("id", hash).put("corroboration", 2)
            .put("url", "http://127.0.0.1/private")
            .put("nzbUrl", "https://media.example.com/release.nzb")
        val built = SourceIndexClient.streams(SourceIndexClient.parsePooled(
            JSONObject().put("sources", JSONArray().put(row)).toString(),
        ))
        assertEquals(1, built.size)
        assertEquals(hash, built.single().infoHash)
        assertEquals(null, built.single().url)
        assertEquals(null, built.single().nzbUrl)
    }

    @Test fun `pooled withholding and torrent append leave own LAN and addon groups untouched`() {
        val lan = StreamSource(id = "own-lan", addon = "Own add-on", title = "LAN video",
            url = "http://192.168.1.12/video.mp4")
        val ownNzb = StreamSource(id = "own-indexer", addon = "Own add-on", title = "Own NZB",
            nzbUrl = "https://indexer.example/release.nzb?apikey=fixture-own-key")
        val ownGroup = StreamGroup("Own add-on", listOf(lan, ownNzb))
        val groups = listOf(ownGroup)
        val withheld = SourceIndexClient.streams(listOf(pooled("http", "https://media.example.com/movie.mp4")))
        assertSame(groups, SourceIndexServeSource.merge(withheld, groups))
        val merged = SourceIndexServeSource.merge(SourceIndexClient.streams(listOf(pooled("torrent", hash))), groups)
        assertEquals(2, merged.size)
        assertSame(ownGroup, merged.first())
        assertSame(lan, merged.first().streams[0])
        assertSame(ownNzb, merged.first().streams[1])
        assertEquals("Singularity", merged.last().addon)
        assertEquals(hash, merged.last().streams.single().infoHash)
    }

    @Test fun `serve query selects torrents before the server result limit`() {
        val url = URI(requireNotNull(SourceIndexClient.serveUrl("tt1234567")))
        assertEquals("https", url.scheme)
        assertEquals("sources.vortx.tv", url.host)
        assertEquals("/sources", url.path)
        assertEquals(listOf("content_id=tt1234567", "kind=torrent", "paged=1"), url.rawQuery.split('&'))
    }

    private fun pooled(kind: String, id: String) = SourceIndexClient.PooledSource(kind, id, "Other", 0L, null, 9)
}
