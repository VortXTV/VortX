package com.vortx.android.skip

import android.content.Context
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

// Full actual service/helper/models; synthetic collaborators are explicitly supplied by the runner.
class SkipTimestampServiceCompositionTest {
    private val intro = "https://api.theintrodb.org/v4/media?"
    private val vortx = "https://skip.vortx.tv/skip?"
    private val community = "https://api.skipdb.tv/api/segments?"
    private val custom = "https://mirror.example/api/segments?"
    private val cache: SkipTimestampStore get() = requireNotNull(SkipTimestampService.storeOrNull())
    private val media = """{"tvdb_id":101,"type":"movie","intro":[{"start_ms":null,"end_ms":90000}],"credits":[{"start_ms":3400000,"end_ms":null}]}"""

    @Before fun reset() {
        // Actual init owns the private singleton; reset only the synthetic cache it created.
        SkipTimestampService.init(Context())
        cache.reset()
        SkipHttp.reset()
        SkipConfig.reset()
        CustomSkipProvider.reset()
        AniSkipService.reset()
    }

    private fun count(prefix: String) = SkipHttp.requests.count { it.url.startsWith(prefix) }
    private fun candidate(kind: SkipSegment.Kind, start: Double, end: Double, confidence: Double = 0.9) =
        SegmentCandidate(kind, start, end, SegmentCandidate.Source.CROWD_API, confidence)

    @Test fun `media 200 maps nullable milliseconds and reuses its exact v4 cache entry`() = runBlocking {
        SkipHttp.reply(intro, 200, media)
        val expected = listOf(candidate(SkipSegment.Kind.INTRO, 0.0, 90.0),
                              candidate(SkipSegment.Kind.CREDITS, 3400.0, 3600.25))
        assertEquals(expected, SkipTimestampService.candidates("tvdb:101", null, null, 3600.25))
        val key = "introdb:v4:tvdb_id=101:movie:3600250"
        assertEquals(listOf(key), cache.writes.map { it.first })
        assertEquals(listOf(StoredSpan("intro", null, 90000), StoredSpan("credits", 3400000, null)),
                     cache.snapshot().getValue(key).spans)
        assertEquals(expected, SkipTimestampService.candidates("tvdb:101", null, null, 3600.25))
        assertEquals(1, count(intro))
        assertEquals(1, cache.writes.size)
        assertEquals(SkipHttp.Request("GET", intro + "tvdb_id=101&duration_ms=3600250", emptyMap()),
                     SkipHttp.requests.single())
    }

    @Test fun `404 writes one known miss and a second request uses that entry`() = runBlocking {
        SkipHttp.reply(intro, 404, "not JSON")
        repeat(2) { assertTrue(SkipTimestampService.candidates("tvdb:101", null, null, 3600.0).isEmpty()) }
        assertEquals(1, count(intro))
        assertEquals(listOf("introdb:v4:tvdb_id=101:movie:3600000"), cache.writes.map { it.first })
        assertTrue(cache.writes.single().second.spans.isEmpty())
    }

    @Test fun `genuine empty media 200 is cacheable separately from response variants`() = runBlocking {
        SkipHttp.reply(intro, 200, """{"tvdb_id":101,"type":"movie"}""")
        repeat(2) { assertTrue(SkipTimestampService.candidates("tvdb:101", null, null, 3600.0).isEmpty()) }
        assertEquals(1, count(intro))
        assertEquals(1, cache.writes.size)
        assertTrue(cache.writes.single().second.spans.isEmpty())
    }

    @Test fun `variants invalid bodies transport and HTTP failures never write an IntroDB cache row`() = runBlocking {
        val cases = listOf(
            200 to """{"tvdb_id":101,"type":"tv","episodes":[]}""",
            200 to """{"tvdb_id":101,"type":"movie","versions":[]}""",
            200 to """{"tvdb_id":101,"type":"movie","versions":[],"intro":[]}""",
            200 to "not JSON",
            200 to ("""{"tvdb_id":101,"type":"movie"}""" + '\u0000' + "garbage"),
            200 to """{"tvdb_id":101,"type":"movie"}garbage""",
            0 to "", 400 to "rejected", 422 to "rejected", 429 to "throttled", 500 to "unavailable",
        )
        for ((status, body) in cases) {
            reset()
            SkipHttp.reply(intro, status, body)
            repeat(2) { assertTrue("status=$status", SkipTimestampService.candidates("tvdb:101", null, null, 3600.0).isEmpty()) }
            assertEquals("status=$status", 2, count(intro))
            assertTrue("status=$status", cache.writes.isEmpty())
            assertTrue("status=$status", cache.snapshot().isEmpty())
        }
    }

    @Test fun `legacy rows coexist with distinct release durations and movie versus specials entries`() = runBlocking {
        val legacy = SkipTimestampStore.Entry(System.currentTimeMillis(), listOf(StoredSpan("intro", 1000, 2000)))
        val preserved = mapOf("tvdb:101:0:0:3600" to legacy, "skipdb:tt1234567:0:0:3600" to legacy,
                              "vortx:tt1234567:0:0:3600" to legacy)
        preserved.forEach { (key, entry) -> cache.seed(key, entry) }
        SkipHttp.reply(intro, 200, media)
        SkipTimestampService.candidates("tvdb:101", null, null, 3600.1)
        SkipTimestampService.candidates("tvdb:101", null, null, 3600.2)
        SkipHttp.reply(intro, 200, """{"tvdb_id":101,"type":"tv","season":0,"episode":0}""")
        SkipTimestampService.candidates("tvdb:101", 0, 0, 3600.1)
        val expected = setOf("introdb:v4:tvdb_id=101:movie:3600100", "introdb:v4:tvdb_id=101:movie:3600200",
                             "introdb:v4:tvdb_id=101:tv:0:0:3600100")
        assertEquals(expected, cache.writes.map { it.first }.toSet())
        preserved.forEach { (key, entry) -> assertEquals(entry, cache.snapshot()[key]) }
        assertEquals(preserved.keys + expected, cache.snapshot().keys)
        assertEquals(3, count(intro))
    }

    private fun otherProviders() {
        SkipConfig.provider = "both"
        SkipConfig.communityKey = "synthetic-community-key"
        SkipConfig.customKey = "synthetic-custom-key"
        CustomSkipProvider.base = "https://mirror.example"
        CustomSkipProvider.hostname = "mirror.example"
        SkipHttp.reply(vortx, 200, """{"segments":{"intro":{"start_ms":10000,"end_ms":20000}}}""")
        SkipHttp.reply(community, 200, """{"segments":{"outro":{"start_ms":3400000,"end_ms":3500000}},"intro_length_estimate_ms":12345}""")
        SkipHttp.reply(custom, 200, """{"segments":{"preview":{"start_ms":3500000,"end_ms":3550000}}}""")
        AniSkipService.result = listOf(candidate(SkipSegment.Kind.RECAP, 0.0, 8.0, 0.92))
    }

    @Test fun `both preserves VortX IntroDB SkipDB custom and AniSkip contributions in service order`() = runBlocking {
        otherProviders()
        SkipHttp.reply(intro, 200, """{"tvdb_id":101,"type":"tv","intro":[{"start_ms":30000,"end_ms":50000}]}""")
        val expected = listOf(candidate(SkipSegment.Kind.INTRO, 10.0, 20.0, 0.95),
            candidate(SkipSegment.Kind.INTRO, 30.0, 50.0), candidate(SkipSegment.Kind.CREDITS, 3400.0, 3500.0),
            candidate(SkipSegment.Kind.PREVIEW, 3500.0, 3550.0), candidate(SkipSegment.Kind.RECAP, 0.0, 8.0, 0.92))
        assertEquals(expected, SkipTimestampService.candidates("tt1234567", 1, 2, 3600.0))
        val expectedKeys = setOf("vortx:tt1234567:1:2:3600", "introdb:v4:imdb_id=tt1234567:tv:1:2:3600000",
                                 "skipdb:tt1234567:1:2:3600", "customskip:mirror.example:tt1234567:1:2:3600")
        assertEquals(expectedKeys, cache.snapshot().keys)
        assertEquals(12345, cache.snapshot().getValue("skipdb:tt1234567:1:2:3600").introEstimateMs)
        assertEquals(mapOf("Authorization" to "Bearer synthetic-community-key"),
                     SkipHttp.requests.single { it.url.startsWith(community) }.headers)
        assertEquals(mapOf("Authorization" to "Bearer synthetic-custom-key"),
                     SkipHttp.requests.single { it.url.startsWith(custom) }.headers)
        assertEquals(AniSkipService.Call("tt1234567", 2, 3600.0), AniSkipService.calls.single())
        assertEquals(setOf(vortx + "key=imdb:tt1234567:1:2",
            intro + "imdb_id=tt1234567&season=1&episode=2&duration_ms=3600000",
            community + "imdb_id=tt1234567&season=1&episode=2&duration=3600",
            custom + "imdb_id=tt1234567&season=1&episode=2&duration=3600"), SkipHttp.requests.map { it.url }.toSet())
        assertTrue(SkipHttp.requests.all { it.method == "GET" })
        assertEquals(4, SkipHttp.requests.size)
    }

    @Test fun `non timestamp IntroDB result cannot suppress successful selected sibling providers`() = runBlocking {
        otherProviders()
        SkipHttp.reply(intro, 200, """{"tvdb_id":101,"type":"tv","episodes":[]}""")
        val expected = listOf(candidate(SkipSegment.Kind.INTRO, 10.0, 20.0, 0.95),
            candidate(SkipSegment.Kind.CREDITS, 3400.0, 3500.0), candidate(SkipSegment.Kind.PREVIEW, 3500.0, 3550.0),
            candidate(SkipSegment.Kind.RECAP, 0.0, 8.0, 0.92))
        repeat(2) { assertEquals(expected, SkipTimestampService.candidates("tt1234567", 1, 2, 3600.0)) }
        assertFalse(cache.snapshot().keys.any { it.startsWith("introdb:") })
        assertEquals(2, count(intro))
        assertEquals(1, count(vortx))
        assertEquals(1, count(community))
        assertEquals(1, count(custom))
        assertEquals(2, AniSkipService.calls.size)
    }

    @Test fun `skipdb selection omits IntroDB while unknown legacy value uses the IntroDB fallback`() = runBlocking {
        SkipConfig.provider = "skipdb"
        SkipHttp.reply(community, 200, """{"segments":{"intro":{"start_ms":20000,"end_ms":30000}}}""")
        assertEquals(listOf(candidate(SkipSegment.Kind.INTRO, 20.0, 30.0)),
                     SkipTimestampService.candidates("tt1234567", null, null, 3600.0))
        assertEquals(0, count(intro))
        assertEquals(1, count(community))
        reset()
        SkipConfig.provider = "legacy-unknown"
        SkipHttp.reply(intro, 200, media)
        assertEquals(2, SkipTimestampService.candidates("tvdb:101", null, null, 3600.0).size)
        assertEquals(1, count(intro))
        assertEquals(0, count(community))
    }
}
