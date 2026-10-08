package com.vortx.android.engine

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.math.BigDecimal

class NativeProfileOverlayWitnessTest {
    private fun vectors(): JSONObject = javaClass.getResourceAsStream("/native-profile-overlay-witness-vectors.json")!!.use {
        JSONObject(String(it.readBytes(), Charsets.UTF_8))
    }

    @Test fun `shared cross host golden bytes and digest match exactly`() {
        val vectors = vectors().getJSONArray("valid")
        for (index in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(index); val raw = vector.getString("inputJson").toByteArray(Charsets.UTF_8)
            val value = NativeProfileOverlayWitness.parse(raw)
            assertEquals(vector.getString("name"), vector.getString("encodedHex"),
                NativeProfileOverlayWitness.encode(value).joinToString("") { "%02x".format(it) })
            assertEquals(vector.getString("name"), vector.getString("sha256"), NativeProfileOverlayWitness.digestRaw(raw))
        }
    }

    @Test fun `raw invalid lexemes are rejected before platform number coercion`() {
        val invalid = vectors().getJSONArray("invalid")
        for (index in 0 until invalid.length()) {
            val vector = invalid.getJSONObject(index)
            assertTrue(vector.getString("name"), runCatching {
                NativeProfileOverlayWitness.digestRaw(vector.getString("inputJson").toByteArray(Charsets.UTF_8))
            }.isFailure)
        }
        for (json in listOf("[01]", "[1.]", "[+1]", "[1e]", "['x']", "{a:1}", "[1,]", "{}x")) {
            assertTrue(json, runCatching { NativeProfileOverlayWitness.digestRaw(json.toByteArray()) }.isFailure)
        }
        val document = NativeProfileOverlayWitness.parseDocument("{\"unsafe\":9007199254740991.1}".toByteArray())
        assertEquals(BigDecimal("9007199254740991.1"), document.get("unsafe"))
        assertTrue(runCatching { NativeProfileOverlayWitness.digest(document) }.isFailure)
        val number = document.get("unsafe")
        val profiles = JSONObject().put("profile", document)
        val slice = NativeProfileOverlayWitness.exactOverlay(profiles, null, "profile")
        // Reference identity proves extraction cannot serialize/reparse through platform org.json.
        assertSame(document, slice.getJSONObject("vortx").getJSONObject("byProfile").getJSONObject("profile"))
        assertSame(number, slice.getJSONObject("vortx").getJSONObject("byProfile").getJSONObject("profile").get("unsafe"))
        assertTrue(runCatching { NativeProfileOverlayWitness.digest(slice) }.isFailure)
        val removals = JSONArray().put(document)
        val removalSlice = NativeProfileOverlayWitness.exactOverlay(null, JSONObject().put("profile", removals), "profile")
        val retainedRemovals = removalSlice.getJSONObject("webProgress").getJSONObject("removed").getJSONObject("byProfile").getJSONArray("profile")
        assertSame(removals, retainedRemovals); assertSame(number, retainedRemovals.getJSONObject(0).get("unsafe"))
        assertTrue(runCatching { NativeProfileOverlayWitness.digest(removalSlice) }.isFailure)
        assertTrue(runCatching { NativeProfileOverlayWitness.digestRaw(byteArrayOf(0xc3.toByte(), 0x28)) }.isFailure)
    }

    @Test fun `codec enforces node depth and byte limits without dropping values`() {
        val tooDeep = "[".repeat(65) + "0" + "]".repeat(65)
        assertTrue(runCatching { NativeProfileOverlayWitness.digestRaw(tooDeep.toByteArray()) }.isFailure)
        val many = JSONArray(); repeat(100_000) { many.put(JSONObject.NULL) }
        assertTrue(runCatching { NativeProfileOverlayWitness.encode(many) }.isFailure)
        assertTrue(runCatching { NativeProfileOverlayWitness.encode("a".repeat(16_777_216)) }.isFailure)
        assertNotEquals(NativeProfileOverlayWitness.digest(JSONObject()), NativeProfileOverlayWitness.digest(JSONObject().put("vortx", JSONObject())))
        assertEquals(NativeProfileOverlayWitness.digestRaw("[1,1.0,1e0]".toByteArray()),
            NativeProfileOverlayWitness.digestRaw("[1.0,1,1.00]".toByteArray()))
    }
}
