package com.vortx.android.nzb

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

class NzbIndexerClientTest {
    private val config = NzbIndexerConfig(id = "alpha", name = "Indexer", endpoint = "https://indexer.example/api")
    private val episode = NzbSearch(title = "Example Show", seriesImdbId = "tt1234567", season = 2, episode = 3)

    @Test fun typedTvRequestUsesNewznabFieldsAndNeverLeaksEndpointQuery() {
        val url = NzbIndexerClient().request(URI(config.endpoint), "secret key", episode, fallback = false)
        assertTrue(url.query!!.contains("t=tvsearch"))
        assertTrue(url.query!!.contains("imdbid=1234567"))
        assertTrue(url.query!!.contains("season=S02"))
        assertTrue(url.query!!.contains("ep=3"))
        assertTrue(url.rawQuery!!.contains("apikey=secret%20key"))
        assertTrue(NzbIndexerEndpointPolicy.validate("https://indexer.example/api?apikey=leak").isFailure)
        assertTrue(NzbIndexerEndpointPolicy.validate("https://user:pass@indexer.example/api").isFailure)
        assertTrue(NzbIndexerEndpointPolicy.validate("http://indexer.example/api").isFailure)
    }

    @Test fun parserRejectsDtdAndRetainsOnlySafeRows() {
        val client = NzbIndexerClient()
        val safe = """<rss><channel><item><title>Good</title><enclosure url="https://indexer.example/get?r=token" length="42"/></item><item><title>Bad</title><enclosure url="http://bad.example/get"/></item></channel></rss>""".toByteArray()
        val parsed = client.parse(safe) as NzbIndexerClient.Response.Releases
        assertEquals(1, parsed.releases.size)
        assertEquals("Good", parsed.releases.single().title)
        assertTrue(runCatching { client.parse("<!DOCTYPE rss [<!ENTITY x 'boom'>]><rss/>".toByteArray()) }.exceptionOrNull() is NzbFailure.Malformed)
    }

    @Test fun genericFallbackRunsOnlyForNewznab203() = runBlocking {
        val requests = mutableListOf<URI>()
        val client = NzbIndexerClient { url, _ ->
            requests += url
            if (requests.size == 1) NzbHttpResponse(200, "<error code=\"203\"/>".toByteArray())
            else NzbHttpResponse(200, "<rss><channel><item><title>Example.Show.S02E03</title><enclosure url=\"https://indexer.example/get?r=x\"/></item></channel></rss>".toByteArray())
        }
        assertEquals(1, client.search(config, "key", episode).getOrThrow().size)
        assertEquals(2, requests.size)
        assertTrue(requests.last().query!!.contains("t=search"))

        val noFallback = NzbIndexerClient { url, _ -> requests += url; NzbHttpResponse(200, "<error code=\"201\"/>".toByteArray()) }
        assertFalse(noFallback.search(config, "key", episode).isSuccess)
        assertEquals(3, requests.size)
    }
}
