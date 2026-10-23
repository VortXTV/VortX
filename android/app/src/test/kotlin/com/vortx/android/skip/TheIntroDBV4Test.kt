package com.vortx.android.skip

import java.net.URI
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

// UNRUN source proposal. Calls the production helper; synthetic resources only, no transport/cache/player writes.
class TheIntroDBV4Test {
    private fun lookup(
        id: String = "tt1234567", season: Int? = null, episode: Int? = null, duration: Double = 3600.0,
    ) = TheIntroDBV4.lookup(id, season, episode, duration)

    private fun query(lookup: TheIntroDBV4.Lookup?): Map<String, String> =
        lookup?.let { URI(it.url).rawQuery.split('&').associate { item ->
            item.substringBefore('=') to item.substringAfter('=')
        } }.orEmpty()

    private fun fixtures(name: String): JSONArray {
        val stream = requireNotNull(javaClass.classLoader?.getResourceAsStream(name))
        return stream.bufferedReader(Charsets.UTF_8).use { JSONArray(it.readText()) }
    }

    @Test fun `v4 lookup preserves addressing and complete catalogue coordinates`() {
        val movie = requireNotNull(lookup())
        val uri = URI(movie.url)
        assertEquals("https", uri.scheme)
        assertEquals("api.theintrodb.org", uri.host)
        assertEquals("/v4/media", uri.path)
        assertEquals(mapOf("imdb_id" to "tt1234567", "duration_ms" to "3600000"), query(movie))
        assertEquals("123", query(lookup("tmdb:123"))["tmdb_id"])
        assertEquals("123", query(lookup("tvdb:123"))["tvdb_id"])
        assertEquals("0", query(lookup(season = 0, episode = 0))["season"])
        assertEquals("0", query(lookup(season = 0, episode = 0))["episode"])
        assertEquals("1000", query(lookup(season = 1000, episode = 10000))["season"])
        assertEquals("10000", query(lookup(season = 1000, episode = 10000))["episode"])
        assertFalse(query(lookup(season = 1, episode = 2)).containsKey("mapping"))
        assertNull(lookup(season = 1))
        assertNull(lookup(episode = 2))
        assertNull(lookup(season = -1, episode = 1))
        assertNull(lookup(season = 1001, episode = 1))
        assertNull(lookup(season = 1, episode = -1))
        assertNull(lookup(season = 1, episode = 10001))
    }

    @Test fun `duration uses positive finite Long milliseconds without saturation`() {
        assertEquals("3600250", query(lookup(duration = 3600.25))["duration_ms"])
        assertEquals("1", query(lookup(duration = 0.001))["duration_ms"])
        assertEquals("3000000125", query(lookup(duration = 3_000_000.125))["duration_ms"])
        assertEquals("9000000000000000000", query(lookup(duration = 9.0e15))["duration_ms"])
        for (duration in listOf(0.0, 0.0009, -1.0, Double.NaN, Double.POSITIVE_INFINITY,
                                Double.NEGATIVE_INFINITY, Double.MAX_VALUE, Long.MAX_VALUE.toDouble() / 1000.0)) {
            assertFalse("duration=$duration", query(lookup(duration = duration)).containsKey("duration_ms"))
        }
    }

    @Test fun `v4 cache separates legacy keys movie specials and selected release durations`() {
        assertEquals("introdb:v4:imdb_id=tt1234567:movie:3600000", lookup()?.cacheKey)
        assertNotEquals(lookup()?.cacheKey, lookup(season = 0, episode = 0)?.cacheKey)
        assertNotEquals(lookup(duration = 3600.1)?.cacheKey, lookup(duration = 3600.2)?.cacheKey)
        assertEquals(lookup("tmdb:00123")?.cacheKey, lookup("tmdb:123")?.cacheKey)
        assertTrue(requireNotNull(lookup(duration = Double.NaN)).cacheKey.endsWith(":unknown"))
        assertNotEquals("tt1234567:0:0:3600", lookup()?.cacheKey)
    }

    @Test fun `production supports and lookup agree on exact ASCII identities`() {
        val fixtures = fixtures("introdb-v4-identity.json")
        for (index in 0 until fixtures.length()) {
            val fixture = fixtures.getJSONObject(index)
            val name = fixture.getString("name")
            val id = fixture.getString("metaId")
            val expected = fixture.getBoolean("supported")
            assertEquals(name, expected, TheIntroDBV4.supports(id))
            val result = lookup(id)
            assertEquals(name, expected, result != null)
            if (expected) assertEquals(name, fixture.getString("queryValue"), query(result)[fixture.getString("queryName")])
        }
        for (id in listOf("", "tmdb:0", "tvdb:-1", "tmdb:+1", "tvdb:100000001", "tmdb:10000001", "tmdb:abc")) {
            assertFalse(id, TheIntroDBV4.supports(id))
            assertNull(id, lookup(id))
        }
        assertEquals("10000000", query(lookup("tmdb:10000000"))["tmdb_id"])
        assertEquals("100000000", query(lookup("tvdb:100000000"))["tvdb_id"])
    }

    @Test fun `synthetic v4 fixtures exercise production decoder and status decisions`() {
        val fixtures = fixtures("introdb-v4.json")
        for (index in 0 until fixtures.length()) {
            val fixture = fixtures.getJSONObject(index)
            val name = fixture.getString("name")
            val status = fixture.getInt("status")
            val expected = fixture.getString("expect")
            when (val result = TheIntroDBV4.read(status, fixture.getJSONObject("payload").toString())) {
                is TheIntroDBV4.ReadResult.Media -> {
                    assertEquals(name, "media", expected)
                    val spans = fixture.getJSONArray("spans")
                    assertEquals(name, spans.length(), result.spans.size)
                    for (spanIndex in result.spans.indices) {
                        val span = spans.getJSONObject(spanIndex)
                        assertEquals(name, span.getString("kind"), result.spans[spanIndex].kind)
                        assertEquals(name, if (span.isNull("startMs")) null else span.getInt("startMs"), result.spans[spanIndex].startMs)
                        assertEquals(name, if (span.isNull("endMs")) null else span.getInt("endMs"), result.spans[spanIndex].endMs)
                    }
                }
                TheIntroDBV4.ReadResult.EpisodeList -> assertEquals(name, "episodeList", expected)
                TheIntroDBV4.ReadResult.Versions -> assertEquals(name, "versions", expected)
                TheIntroDBV4.ReadResult.NotFound -> assertEquals(name, "notFound", expected)
                TheIntroDBV4.ReadResult.InvalidResponse -> assertEquals(name, "decodeFailure", expected)
                is TheIntroDBV4.ReadResult.HttpFailure -> {
                    assertEquals(name, "httpFailure", expected)
                    assertEquals(name, status, result.status)
                }
            }
        }
        assertSame(TheIntroDBV4.ReadResult.NotFound, TheIntroDBV4.read(404, "not JSON"))
        assertEquals(TheIntroDBV4.ReadResult.HttpFailure(0), TheIntroDBV4.read(0, ""))
        assertEquals(TheIntroDBV4.ReadResult.HttpFailure(503), TheIntroDBV4.read(503, "not JSON"))
    }

    @Test fun `raw NUL cannot masquerade as end of input but escaped NUL remains valid JSON`() {
        val media = """{"tvdb_id":123,"type":"movie"}"""
        val rawNul = '\u0000'
        for (body in listOf(
            media + rawNul,
            media + rawNul + "garbage",
            media + " " + rawNul + "{}",
            rawNul + media,
            """{"tvdb_id":123,"type":"movie","ignored":"raw""" + rawNul + """value"}""",
        )) assertSame(TheIntroDBV4.ReadResult.InvalidResponse, TheIntroDBV4.read(200, body))

        // Kotlin raw string retains the JSON escape spelling; no raw U+0000 exists in this body.
        val escapedNul = """{"tvdb_id":123,"type":"movie","ignored":"\u0000"}"""
        assertEquals(TheIntroDBV4.ReadResult.Media(emptyList()), TheIntroDBV4.read(200, escapedNul))
        assertSame(TheIntroDBV4.ReadResult.NotFound, TheIntroDBV4.read(404, rawNul.toString()))
        assertEquals(TheIntroDBV4.ReadResult.HttpFailure(503), TheIntroDBV4.read(503, rawNul.toString()))
    }

    @Test fun `required nullable millisecond bounds preserve data without coercion or overflow`() {
        val valid = """{"tvdb_id":123,"type":"movie","intro":[{"start_ms":null,"end_ms":null},{"start_ms":0,"end_ms":0},{"start_ms":90000,"end_ms":10000},{"start_ms":0,"end_ms":2147483647}]}"""
        assertEquals(TheIntroDBV4.ReadResult.Media(listOf(
            TheIntroDBV4.Span("intro", null, null), TheIntroDBV4.Span("intro", 0, 0),
            TheIntroDBV4.Span("intro", 90000, 10000), TheIntroDBV4.Span("intro", 0, Int.MAX_VALUE),
        )), TheIntroDBV4.read(200, valid))
        // Keep raw JSON lexemes here so the fixture reader does not canonicalize numeric types first.
        for (body in listOf(
            "not JSON", "[]", "{}",
            """{"tvdb_id":123,"type":"movie"}garbage""",
            """{"tvdb_id":123,"type":"movie"}{"tvdb_id":456,"type":"movie"}""",
            """{"tvdb_id":"123","type":"movie"}""",
            """{"tvdb_id":0,"type":"movie"}""",
            """{"tvdb_id":100000001,"type":"movie"}""",
            """{"tvdb_id":123.5,"type":"movie"}""",
            """{"tvdb_id":123,"type":null}""",
            """{"tvdb_id":123,"type":"movie","intro":[{"end_ms":90000}]}""",
            """{"tvdb_id":123,"type":"movie","intro":[{"start_ms":"0","end_ms":90000}]}""",
            """{"tvdb_id":123,"type":"movie","intro":[{"start_ms":true,"end_ms":90000}]}""",
            """{"tvdb_id":123,"type":"movie","intro":[{"start_ms":0.5,"end_ms":90000}]}""",
            """{"tvdb_id":123,"type":"movie","intro":[{"start_ms":0,"end_ms":2147483648}]}""",
            """{"tvdb_id":123,"type":"movie","intro":[null]}""",
            """{"tvdb_id":123,"type":"tv","episodes":null}""",
            """{"tvdb_id":123,"type":"tv","episodes":{},"versions":[]}""",
            """{"tvdb_id":123,"type":"tv","episodes":[],"versions":[]}""",
        )) assertSame(body, TheIntroDBV4.ReadResult.InvalidResponse, TheIntroDBV4.read(200, body))
    }
}
