package com.vortx.android.player.queue

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackQueueCodecTest {
    private fun id(n: Int) = UUID(0L, n.toLong()).toString()
    private fun entry(n: Int) = PlaybackQueueEntry(id(n), MetaItem("tt$n", MediaType.MOVIE, "Movie $n"))
    private fun document(): JSONObject = JSONObject(PlaybackQueueCodec.encode(listOf(entry(1), entry(2))))
    private fun rejects(raw: String) = assertTrue("Expected complete queue refusal", runCatching { PlaybackQueueCodec.decode(raw) }.isFailure)

    @Test fun `empty missing storage and complete metadata round trip are distinct from malformed storage`() {
        assertEquals(emptyList<PlaybackQueueEntry>(), PlaybackQueueCodec.decode(null))
        assertEquals(emptyList<PlaybackQueueEntry>(), PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(emptyList())))
        val expected = listOf(entry(1), PlaybackQueueEntry(id(2), MetaItem("show", MediaType.SERIES, "你好 😀", "poster.jpg",
            preferredEpisode = PreferredEpisode(2, 7, "opaque-episode"))))
        assertEquals(expected, PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(expected)))
        rejects("")
        rejects("not-json")
        rejects("null")
        rejects("[]")
    }

    @Test fun `only queue and catalog fields are serialized`() {
        val meta = entry(1).item.copy(description = "unretained-stream-url", background = "unretained-background",
            progress = 0.5f, resumeSeconds = 12.0, continueWatchingPermit = "unretained-permit", watched = true)
        val encoded = PlaybackQueueCodec.encode(listOf(PlaybackQueueEntry(id(1), meta)))
        val root = JSONObject(encoded)
        assertEquals(setOf("schema", "entries"), root.keys().asSequence().toSet())
        assertEquals(setOf("entryId", "id", "type", "name"), root.getJSONArray("entries").getJSONObject(0).keys().asSequence().toSet())
        assertFalse(encoded.contains("unretained"))
        assertFalse(encoded.contains("headers"))
        assertFalse(encoded.contains("playbackLease"))
    }

    @Test fun `newer schema unknown document entry and episode fields reject whole saved document`() {
        rejects(document().put("schema", 2).toString())
        rejects(document().put("futureField", "preserve-me").toString())
        rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("streamUrl", "not-a-real-url") }.toString())
        rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("headers", JSONObject().put("Authorization", "not-a-real-token")) }.toString())
        val ep = JSONObject().put("season", 1).put("number", 1).put("future", true)
        rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("type", "series").put("episode", ep) }.toString())
    }

    @Test fun `malformed field types never coerce into an apparently valid queue`() {
        rejects(document().put("schema", "1").toString())
        rejects(document().put("schema", 1.5).toString())
        rejects(document().put("entries", "[]").toString())
        rejects(document().also { it.getJSONArray("entries").put(1, true) }.toString())
        for (field in listOf("entryId", "id", "type", "name", "poster")) {
            rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put(field, 7) }.toString())
        }
        val badSeason = JSONObject().put("season", "1").put("number", 1)
        rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("type", "series").put("episode", badSeason) }.toString())
    }

    @Test fun `duplicate UUID and invalid second entry reject all entries rather than keep a valid subset`() {
        rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("entryId", id(1)) }.toString())
        rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("name", "") }.toString())
        rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("type", "channel") }.toString())
        rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("entryId", "1-1-1-1-1") }.toString())
    }

    @Test fun `exact capacity round trips while over-capacity refuses without truncation`() {
        val hundred = (1..100).map(::entry)
        assertEquals(hundred, PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(hundred)))
        assertTrue(runCatching { PlaybackQueueCodec.encode((1..101).map(::entry)) }.isFailure)
        val oversized = JSONArray((1..101).map { n -> JSONObject().put("entryId", id(n)).put("id", "tt$n").put("type", "movie").put("name", "Movie $n") })
        rejects(JSONObject().put("schema", 1).put("entries", oversized).toString())
    }

    @Test fun `UTF8 byte budget is enforced independently of entry and UTF16 field limits`() {
        rejects(" ".repeat(768 * 1024 + 1))
        val heavy = (1..100).map { n -> entry(n).copy(item = entry(n).item.copy(
            name = "😀".repeat(256), poster = "https://example.invalid/" + "😀".repeat(2000))) }
        assertTrue(runCatching { PlaybackQueueCodec.encode(heavy) }.isFailure)
    }

    @Test fun `whole input must be consumed and literal NUL cannot hide a suffix`() {
        val complete = PlaybackQueueCodec.encode(listOf(entry(1)))
        assertEquals(listOf(entry(1)), PlaybackQueueCodec.decode(" \n$complete\t "))
        rejects("$complete trailing-data")
        rejects("$complete\u0000trailing-data")
        rejects("$complete {}")
    }

    @Test fun `episode shape is checked while specials and opaque genuine video IDs remain supported`() {
        val valid = PlaybackQueueEntry(id(1), MetaItem("show", MediaType.SERIES, "Show",
            preferredEpisode = PreferredEpisode(0, 1, "opaque-provider-video", upNext = true)))
        val roundTrip = PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(listOf(valid))).single()
        assertEquals(PreferredEpisode(0, 1, "opaque-provider-video", upNext = false), roundTrip.item.preferredEpisode)
        for (hint in listOf(JSONObject().put("season", -1).put("number", 1), JSONObject().put("season", 1).put("number", 0),
            JSONObject().put("season", 1).put("number", 1).put("videoId", false))) {
            rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("type", "series").put("episode", hint) }.toString())
        }
        rejects(document().also { it.getJSONArray("entries").getJSONObject(1).put("episode", JSONObject().put("season", 1).put("number", 1)) }.toString())
    }
}
