package com.vortx.android.engine

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativePlaylistTest {
    private val id = "00000000-0000-0000-0000-000000000101"
    private val entryID = "00000000-0000-0000-0000-000000000102"
    private val field = "playlist.v1.$id"
    private val doc = NativePlaylist.Document(id, "Favorites", listOf(
        NativePlaylist.Entry(entryID, "tt123", "movie", "Example"),
    ))

    @Test fun `known v1 projects and null remains a tombstone`() {
        val value = NativePlaylist.encodedValue(doc)
        assertEquals(NativePlaylist.Projection.Supported(doc), NativePlaylist.projection(field, value))
        assertEquals(NativePlaylist.Projection.Deleted, NativePlaylist.projection(field, JSONObject.NULL))
        NativePlaylist.validateEnvelope(field, JSONObject.NULL, global = false)
        val supplementary = doc.copy(name = "Saved 🎬", entries = listOf(doc.entries.single().copy(title = "Example 🌍")))
        assertEquals(NativePlaylist.Projection.Supported(supplementary), NativePlaylist.projection(field, NativePlaylist.encodedValue(supplementary)))
        for (surrogate in listOf('\uD83D', '\uDE00')) {
            val malformed = String(charArrayOf(surrogate))
            assertThrows(IllegalArgumentException::class.java) { NativePlaylist.encodedValue(doc.copy(name = malformed)) }
            assertThrows(IllegalArgumentException::class.java) {
                NativePlaylist.encodedValue(doc.copy(entries = listOf(NativePlaylist.Entry(entryID, "id", "movie", malformed))))
            }
        }
        for (formatControl in listOf("\u00AD", "\u200B", "\u200D")) {
            assertThrows(IllegalArgumentException::class.java) {
                NativePlaylist.encodedValue(doc.copy(entries = listOf(NativePlaylist.Entry(entryID, "id", "movie", "bad${formatControl}title"))))
            }
            assertThrows(IllegalArgumentException::class.java) {
                NativePlaylist.validateEnvelope("playlist.v2.$formatControl", JSONObject(), global = false)
            }
        }
    }

    @Test fun `unknown future object is retained but read only`() {
        val value = JSONObject().put("schema", 2).put("future", JSONObject().put("enabled", true))
        NativePlaylist.validateEnvelope("playlist.v2.opaque", value, global = false)
        assertEquals(NativePlaylist.Projection.Unsupported, NativePlaylist.projection("playlist.v2.opaque", value))
        val malformed = JSONObject().put("future", JSONObject().put("text", String(charArrayOf('\uD83D'))))
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope("playlist.v2.opaque", malformed, global = false)
        }
        NativePlaylist.validateEnvelope("playlist.v2.opaque", JSONObject().put("text", "👩‍💻"), global = false)
    }

    @Test fun `global scope malformed v1 and oversized values reject`() {
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope(field, JSONObject(), global = true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope("playlist.v1.not-a-uuid", JSONObject(), global = false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope("playlist.v2.large", JSONObject().put("data", "x".repeat(NativePlaylist.MAX_VALUE_BYTES)), global = false)
        }
        val boundaryKey = "playlist.v2." + "a".repeat(500)
        NativePlaylist.validateEnvelope(boundaryKey, JSONObject().put("future", true), global = false)
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope(boundaryKey + "a", JSONObject().put("future", true), global = false)
        }
        val multibyteBoundary = "playlist.v2." + "🍿".repeat(125)
        NativePlaylist.validateEnvelope(multibyteBoundary, JSONObject().put("future", true), global = false)
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope(multibyteBoundary + "🍿", JSONObject().put("future", true), global = false)
        }
    }

    @Test fun `bounded JSON walk rejects depth cycles and excessive nodes before serialization`() {
        var deep = JSONObject().put("leaf", true)
        repeat(NativePlaylist.MAX_JSON_DEPTH + 1) { deep = JSONObject().put("child", deep) }
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope("playlist.v2.deep", deep, global = false)
        }
        val knownDeep = NativePlaylist.encodedValue(doc).put("future", deep)
        assertEquals(NativePlaylist.Projection.Unsupported, NativePlaylist.projection(field, knownDeep))
        val cycle = JSONObject()
        cycle.put("self", cycle)
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope("playlist.v2.cycle", cycle, global = false)
        }
        val arrayCycle = JSONArray()
        arrayCycle.put(arrayCycle)
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope("playlist.v2.array-cycle", JSONObject().put("items", arrayCycle), global = false)
        }
        assertEquals(NativePlaylist.Projection.Unsupported, NativePlaylist.projection(field, cycle))
        val many = JSONObject()
        repeat(32_768) { many.put("k$it", true) }
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope("playlist.v2.nodes", many, global = false)
        }
        val boundary = JSONObject().put("x", "🍿".repeat(43_690))
        NativePlaylist.validateEnvelope("playlist.v2.cost", boundary, global = false)
        val beyondBoundary = JSONObject().put("x", "🍿".repeat(43_691))
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope("playlist.v2.cost", beyondBoundary, global = false)
        }
    }

    @Test fun `false heavy bodies reject and Boolean boundaries agree with actual serializer`() {
        val falseHeavy = JSONObject().put("items", JSONArray().apply { repeat(50_000) { put(false) } })
            .put("pad", "x".repeat(250_000))
        assertTrue(falseHeavy.toString().toByteArray(Charsets.UTF_8).size > NativePlaylist.MAX_VALUE_BYTES)
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateEnvelope("playlist.v2.false-heavy", falseHeavy, global = false)
        }
        for (boolean in listOf(true, false)) {
            val overhead = if (boolean) 17 else 18 // Compact {"v":<bool>,"p":""}.
            val padding = "x".repeat(NativePlaylist.MAX_VALUE_BYTES - overhead)
            val boundary = JSONObject().put("v", boolean).put("p", padding)
            assertEquals(NativePlaylist.MAX_VALUE_BYTES, boundary.toString().toByteArray(Charsets.UTF_8).size)
            NativePlaylist.validateEnvelope("playlist.v2.bool-boundary", boundary, global = false)
            assertThrows(IllegalArgumentException::class.java) {
                NativePlaylist.validateEnvelope("playlist.v2.bool-boundary", JSONObject().put("v", boolean)
                    .put("p", padding + "x"), global = false)
            }
        }
    }

    @Test fun `strict projection binds ids and validates catalog text`() {
        val changedID = NativePlaylist.encodedValue(doc).put("id", "00000000-0000-0000-0000-000000000999")
        assertEquals(NativePlaylist.Projection.Unsupported, NativePlaylist.projection(field, changedID))
        val bad = NativePlaylist.encodedValue(doc)
        bad.getJSONArray("entries").getJSONObject(0).put("type", "channel")
        assertEquals(NativePlaylist.Projection.Unsupported, NativePlaylist.projection(field, bad))
    }

    @Test fun `generic profile projection and edits leave dedicated playlist register unchanged`() {
        val profileID = "00000000-0000-0000-0000-00000000A11C"
        val scope = VortxAccountScope("account.fixture", profileID)
        val local = NativeHostPreferences.local(scope)
        val playlist = NativePlaylist.encodedValue(doc)
        val raw = JSONObject().put("clock", 1L).put("actor", local.getString("actor")).put("value", playlist)
        local.put("counter", 1L)
        local.getJSONObject("document").getJSONObject("profiles")
            .put(profileID, JSONObject().put("fields", JSONObject().put(field, raw)))
        NativeHostPreferences.validate(scope, local.getJSONObject("document"))
        val before = JSONObject().put(profileID, JSONObject().put("id", profileID).put("name", "Owner").put(field, playlist))
        val after = JSONObject().put(profileID, JSONObject().put("id", profileID).put("name", "Owner"))
        // An unrelated profile save omits per-playlist DTO keys. It must not mint a null event.
        val recorded = NativeHostPreferences.recordProfiles(scope, local, before, after)
        assertEquals(1L, recorded.getLong("counter"))
        assertTrue(NativeHostPreferences.equal(raw, recorded.getJSONObject("document").getJSONObject("profiles")
            .getJSONObject(profileID).getJSONObject("fields").getJSONObject(field)))
        val roster = JSONObject().put(profileID, JSONObject().put("deleted", false).put("name", "Owner"))
        val projected = NativeHostPreferences.projectProfiles(local, after, roster)
        assertFalse(projected.getJSONObject(profileID).has(field))
        assertTrue(NativeHostPreferences.equal(raw, local.getJSONObject("document").getJSONObject("profiles")
            .getJSONObject(profileID).getJSONObject("fields").getJSONObject(field)))
    }

    @Test fun `host admits profile tombstone, rejects globals, and preserves over-cap incoming fields`() {
        val scope = VortxAccountScope("account.fixture", "00000000-0000-0000-0000-00000000A11C")
        val actor = "00000000-0000-0000-0000-000000000001"
        val document = NativeHostPreferences.empty(scope)
        val profileFields = JSONObject()
        document.getJSONObject("profiles").put(scope.ownerProfileID, JSONObject().put("fields", profileFields))
        profileFields.put(field, JSONObject().put("clock", 1).put("actor", actor).put("value", JSONObject.NULL))
        NativeHostPreferences.validate(scope, document)
        val globalDocument = NativeHostPreferences.empty(scope)
        globalDocument.getJSONObject("globals").getJSONObject("fields")
            .put(field, JSONObject().put("clock", 1).put("actor", actor).put("value", JSONObject.NULL))
        assertThrows(IllegalArgumentException::class.java) { NativeHostPreferences.validate(scope, globalDocument) }
        val many = NativeHostPreferences.empty(scope)
        val fields = JSONObject()
        many.getJSONObject("profiles").put(scope.ownerProfileID, JSONObject().put("fields", fields))
        repeat(33) { index ->
            fields.put("playlist.v2.opaque$index", JSONObject().put("clock", 1).put("actor", actor)
                .put("value", JSONObject().put("future", true)))
        }
        NativeHostPreferences.validate(scope, many) // Import must preserve remote/concurrent cardinality.
        val createFields = JSONObject()
        val createValue = NativePlaylist.encodedValue(doc)
        NativePlaylist.validateMutation(field, null, createValue, createFields)
        val raw = JSONObject().put("clock", 1).put("actor", actor).put("value", createValue)
        createFields.put(field, raw)
        NativePlaylist.validateMutation(field, raw, createValue, createFields)
        NativePlaylist.validateMutation(field, raw, JSONObject.NULL, createFields)
        var deepExtra = JSONObject().put("leaf", true)
        repeat(NativePlaylist.MAX_JSON_DEPTH + 1) { deepExtra = JSONObject().put("child", deepExtra) }
        val deepExtraRegister = JSONObject().put("clock", 1).put("actor", "00000000-0000-0000-0000-000000000001")
            .put("value", createValue).put("future", deepExtra)
        val deepExtraFields = JSONObject().put(field, deepExtraRegister)
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateMutation(field, deepExtraRegister, createValue, deepExtraFields)
        }
        val registerCycle = JSONObject().put("clock", 1).put("actor", "00000000-0000-0000-0000-000000000001")
            .put("value", createValue)
        registerCycle.put("future", registerCycle)
        assertThrows(IllegalArgumentException::class.java) {
            NativePlaylist.validateMutation(field, registerCycle, createValue, JSONObject().put(field, registerCycle))
        }
        NativePlaylist.validateEnvelope("playlist.v2.large-number", JSONObject().put("n", 1e100).put("i", Long.MAX_VALUE), global = false)
        val capped = JSONObject()
        repeat(32) { index -> capped.put("playlist.v2.future$index", JSONObject().put("clock", 1).put("actor", actor)
            .put("value", JSONObject().put("future", true))) }
        assertThrows(IllegalArgumentException::class.java) { NativePlaylist.validateMutation(field, null, createValue, capped) }
    }
}
