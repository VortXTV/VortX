package com.vortx.android.library

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeWatchlistCodecTest {
    private val profile = "00000000-0000-0000-0000-00000000A11C"
    private val actor = "11111111-1111-1111-1111-111111111111"
    private val entry = WatchlistEntry("tt123", "movie", "🍿 / Revised", null, 123.5)

    @Test fun `shared Unicode slash fraction baseline actor matches Apple and Node`() {
        assertEquals("watchlist.movie.dHQxMjM", NativeWatchlistCodec.field(entry.id, entry.type))
        assertEquals("e2845c02-42cf-6e8c-1cc4-bef50778d4b4", NativeWatchlistCodec.baselineActor(profile, entry))
        assertTrue(NativeWatchlistCodec.baselineCanonicalJSON(profile, entry).contains("🍿 / Revised"))
        assertFalse(NativeWatchlistCodec.value(entry).has("poster"))
        assertNotEquals(NativeWatchlistCodec.baselineActor(profile, entry), NativeWatchlistCodec.baselineActor(profile, entry.copy(name = "Revised again")))
        assertNotEquals(NativeWatchlistCodec.baselineActor(profile, entry), NativeWatchlistCodec.baselineActor(profile.replace("A11C", "A11D"), entry))
    }

    @Test fun `binary64 canonical seconds use JS shortest and exponent boundaries`() {
        val cases = listOf(0.0 to "0", -0.0 to "0", 1.0 to "1", 123.5 to "123.5",
            1e-6 to "0.000001", 1e-7 to "1e-7", Double.MIN_VALUE to "5e-324",
            9_007_199_254_740_991.0 to "9007199254740991")
        cases.forEach { (number, expected) -> assertEquals(expected, NativeWatchlistCodec.canonicalSeconds(number)) }
    }

    @Test fun `typed identities remain distinct and tombstones are retained in input`() {
        val movie = NativeWatchlistCodec.field("tt123", "movie")
        val series = NativeWatchlistCodec.field("tt123", "series")
        assertNotEquals(movie, series)
        val registers = JSONObject().put(movie, register(NativeWatchlistCodec.value(entry)))
            .put(series, register(NativeWatchlistCodec.value(entry.copy(type = "series"))))
        assertEquals(2, NativeWatchlistCodec.entries(registers).size)
        registers.put(movie, register(JSONObject.NULL, 2))
        assertEquals(listOf("series"), NativeWatchlistCodec.entries(registers).map { it.type })
        assertTrue(registers.getJSONObject(movie).isNull("value"))
    }

    @Test fun `malformed and noncanonical identity cannot bypass validation through tombstone`() {
        listOf("watchlist.movie.dHQxMjM=", "watchlist.movie.dHQxMjN", "watchlist.channel.dHQxMjM",
            "watchlist.movie.", "watchlist.movie.Zm9yZWlnbg", "watchlist.movie._w", "watchlist.movie.dHQxMjM.extra")
            .forEach { field -> rejects { NativeWatchlistCodec.validate(field, JSONObject.NULL) } }
        rejects { NativeWatchlistCodec.field("tt123/unsafe", "movie") }
        rejects { NativeWatchlistCodec.field("tt" + "a".repeat(511), "movie") }
        val maximum = NativeWatchlistCodec.field("tt" + "a".repeat(510), "series")
        assertTrue(maximum.length > 512 && maximum.length <= NativeWatchlistCodec.MAX_FIELD_LENGTH)
        NativeWatchlistCodec.validate(maximum, JSONObject.NULL)
    }

    @Test fun `live values require exact known fields types limits and matching identity`() {
        val field = NativeWatchlistCodec.field(entry.id, entry.type)
        val valid = NativeWatchlistCodec.value(entry)
        NativeWatchlistCodec.validate(field, JSONObject(valid.toString()).put("name", JSONObject.NULL))
        listOf(
            JSONObject(valid.toString()).put("id", "tt-other"),
            JSONObject(valid.toString()).put("type", "series"),
            JSONObject(valid.toString()).put("addedAt", "123.5"),
            JSONObject(valid.toString()).put("addedAt", -1),
            JSONObject(valid.toString()).put("addedAt", 9_007_199_254_740_992L),
            JSONObject(valid.toString()).put("name", 7),
            JSONObject(valid.toString()).put("name", "a".repeat(4097)),
            JSONObject(valid.toString()).put("poster", "a".repeat(8193)),
            JSONObject(valid.toString()).put("unknown", true),
            JSONObject(valid.toString()).also { it.remove("addedAt") },
        ).forEach { invalid -> rejects { NativeWatchlistCodec.validate(field, invalid) } }
        rejects { NativeWatchlistCodec.value(entry.copy(name = "\uD800")) }
        rejects { NativeWatchlistCodec.value(entry.copy(addedAt = Double.POSITIVE_INFINITY)) }
        rejects { NativeWatchlistCodec.baselineActor(profile.lowercase(), entry) }
    }

    @Test fun `register validation does not silently skip corrupt clocks actors or values`() {
        val field = NativeWatchlistCodec.field(entry.id, entry.type)
        val valid = register(NativeWatchlistCodec.value(entry))
        listOf(
            JSONObject(valid.toString()).put("clock", 0.5),
            JSONObject(valid.toString()).put("clock", -1),
            JSONObject(valid.toString()).put("clock", 9_007_199_254_740_992L),
            JSONObject(valid.toString()).put("actor", actor.uppercase().replaceFirst('1', 'A')),
            JSONObject(valid.toString()).put("unexpected", true),
        ).forEach { invalid -> rejects { NativeWatchlistCodec.entries(JSONObject().put(field, invalid)) } }
        assertTrue(NativeWatchlistCodec.entries(JSONObject().put("avatar", register("person.fill"))).isEmpty())
    }

    @Test fun `merged entries above cap stay visible and new additions reject without eviction`() {
        val registers = JSONObject()
        (0..1000).forEach { index ->
            val item = entry.copy(id = "tt-$index", addedAt = index.toDouble())
            registers.put(NativeWatchlistCodec.field(item.id, item.type), register(NativeWatchlistCodec.value(item)))
        }
        val merged = NativeWatchlistCodec.entries(registers)
        assertEquals(1001, merged.size)
        assertTrue(merged.any { it.id == "tt-0" })
        rejects { NativeWatchlistCodec.requireAdditionCapacity(merged, "tt-new", "movie") }
        NativeWatchlistCodec.requireAdditionCapacity(merged, "tt-0", "movie")
        registers.put(NativeWatchlistCodec.field("tt-0", "movie"), register(JSONObject.NULL, 5))
        assertFalse(NativeWatchlistCodec.entries(registers).any { it.id == "tt-0" })
    }

    @Test fun `authenticated legacy array decoding is strict and normalized by typed identity`() {
        val movie = NativeWatchlistCodec.value(entry).put("poster", JSONObject.NULL)
        val series = NativeWatchlistCodec.value(entry.copy(type = "series"))
        assertEquals(2, NativeWatchlistCodec.legacyEntries(JSONArray().put(movie).put(series)).size)
        rejects { NativeWatchlistCodec.legacyEntries(JSONArray().put(movie).put(movie)) }
        rejects { NativeWatchlistCodec.legacyEntries(JSONArray().put("bad")) }
        assertFalse(NativeWatchlistCodec.value(NativeWatchlistCodec.legacyEntries(JSONArray().put(movie)).single()).has("poster"))
    }

    private fun register(value: Any, clock: Long = 1) = JSONObject().put("clock", clock).put("actor", actor).put("value", value)
    private fun rejects(block: () -> Unit) { assertTrue(runCatching(block).isFailure) }
}
