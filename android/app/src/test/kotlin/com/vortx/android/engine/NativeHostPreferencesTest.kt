package com.vortx.android.engine

import org.json.JSONObject
import com.vortx.android.library.NativeWatchlistCodec
import com.vortx.android.library.WatchlistEntry
import org.junit.Assert.*
import org.junit.Test

class NativeHostPreferencesTest {
    private val scope = VortxAccountScope("account.00000000-0000-0000-0000-000000000123", "00000000-0000-0000-0000-00000000A11C")
    private fun local(actor: Int) = NativeHostPreferences.local(scope).put("actor", "00000000-0000-0000-0000-00000000000$actor")
    private fun profile(value: String) = JSONObject().put(scope.ownerProfileID, JSONObject().put("avatar", value))
    private fun avatar(state: JSONObject) = state.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields").getJSONObject("avatar")

    @Test fun `shared fixture deterministic tie merge and deletion preserve independent unknown fields`() {
        val first = NativeHostPreferences.recordProfiles(scope, local(1).put("counter", 6), JSONObject(), profile("🍿"))
        val second = NativeHostPreferences.recordProfiles(scope, local(2).put("counter", 6), JSONObject(), profile("moon"))
        val a = NativeHostPreferences.merge(scope, first, second.getJSONObject("document"))
        val b = NativeHostPreferences.merge(scope, second, first.getJSONObject("document"))
        assertTrue(NativeHostPreferences.equal(a.getJSONObject("document"), b.getJSONObject("document")))
        assertEquals("moon", avatar(a).getString("value")); assertEquals(7L, a.getLong("counter"))
        val globals = NativeHostPreferences.recordGlobals(scope, first, JSONObject().put("stremiox.audioLang", "eng"))
        assertEquals(8L, globals.getJSONObject("document").getJSONObject("globals").getJSONObject("fields").getJSONObject("stremiox.audioLang").getLong("clock"))
        val deleted = NativeHostPreferences.recordProfiles(scope, a, profile("moon"), JSONObject().put(scope.ownerProfileID, JSONObject()))
        assertTrue(avatar(deleted).isNull("value")); assertEquals(8L, avatar(deleted).getLong("clock"))
        val again = NativeHostPreferences.merge(scope, deleted, first.getJSONObject("document"))
        assertTrue(avatar(again).isNull("value"))
    }
    @Test fun `equal event conflicting value scope actor counter overflow and credential injection reject`() {
        val state = NativeHostPreferences.recordProfiles(scope, local(1), JSONObject(), profile("star"))
        val conflict = JSONObject(state.getJSONObject("document").toString())
        conflict.getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields").getJSONObject("avatar").put("value", "moon")
        assertTrue(runCatching { NativeHostPreferences.merge(scope, state, conflict) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.merge(scope, state, JSONObject(conflict.toString()).put("scope", "foreign")) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.local(scope, local(1).put("actor", "not-uuid")) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.recordProfiles(scope, local(1).put("counter", NativeHostPreferences.MAX_CLOCK), JSONObject(), profile("star")) }.isFailure)
        for (invalid in listOf(-1, 1.5, "2", Double.NaN)) {
            assertTrue(runCatching { NativeHostPreferences.local(scope, local(1).put("counter", invalid)) }.isFailure)
        }
        assertTrue(runCatching { NativeHostPreferences.recordGlobals(scope, local(1), JSONObject().put("future", "{\"authKey\":\"never-copy\"}")) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.recordGlobals(scope, local(1), JSONObject().put("activeProfileId", "other")) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.recordGlobals(scope, local(1), JSONObject().put("stremiox.profiles.active", "other")) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.recordGlobals(scope, local(1), JSONObject().put("stremiox.theme.accent", "other")) }.isFailure)
    }
    @Test fun `native fields do not mint host events and unknown preference values survive projection`() {
        val before = profile("star").also { it.getJSONObject(scope.ownerProfileID).put("name", "Old") }
        val next = JSONObject(before.toString()).also { it.getJSONObject(scope.ownerProfileID).put("name", "New").put("future", JSONObject().put("nested", true)) }
        val state = NativeHostPreferences.recordProfiles(scope, local(1), before, next)
        val fields = state.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields")
        assertFalse(fields.has("name")); assertFalse(fields.has("avatar")); assertEquals(1L, state.getLong("counter"))
        val roster = JSONObject().put(scope.ownerProfileID, JSONObject().put("name", "Kernel name").put("deleted", false))
        assertTrue(NativeHostPreferences.projectProfiles(state, before, roster).getJSONObject(scope.ownerProfileID).getJSONObject("future").getBoolean("nested"))
        assertTrue(runCatching { NativeHostPreferences.projectProfiles(state, before, JSONObject()) }.isFailure)
    }
    @Test fun `applied DTO values and cross platform authority reject before merge`() {
        for ((field, value) in listOf("playback" to JSONObject().put("useAddonOrder", JSONObject()),
            "playback" to JSONObject().put("maxResolution", 1.5),
            "discovery" to JSONObject().put("selectedProviders", org.json.JSONArray().put("7")),
            "discovery" to JSONObject().put("hideLiveTab", "true"),
            "addonPreferences" to JSONObject().put("rankingOverride", JSONObject().put("useAddonOrder", 1)))) {
            assertTrue(runCatching { NativeHostPreferences.recordProfiles(scope, local(1), JSONObject(),
                JSONObject().put(scope.ownerProfileID, JSONObject().put(field, value))) }.isFailure)
        }
        for ((field, value) in listOf("stremiox.autoSkip" to "true", "stremiox.autoSkipDelaySeconds" to 1.5,
            "vortx.home.railOrder" to org.json.JSONArray().put(1))) {
            assertTrue(runCatching { NativeHostPreferences.recordGlobals(scope, local(1), JSONObject().put(field, value)) }.isFailure)
        }
        for (field in listOf("NAME", "ActiveProfileId", "Stremiox.Profiles.Active", "Vortx.Sync.future", "vortx.native.future")) {
            assertTrue(runCatching { NativeHostPreferences.recordGlobals(scope, local(1), JSONObject().put(field, "bad")) }.isFailure)
            assertTrue(runCatching { NativeHostPreferences.recordProfiles(scope, local(1), JSONObject(),
                JSONObject().put(scope.ownerProfileID, JSONObject().put(field, "bad"))) }.isFailure)
        }
        repeat(1000) { NativeHostDocument.requireCredentialFree(JSONObject().put("actor", java.util.UUID.randomUUID().toString())) }
    }

    @Test fun `CW discovery source and window persist merge and project within the native profile carrier`() {
        for (source in listOf("local", "trakt", "simkl")) for (window in listOf("last90Days", "20", "40", "60", "80", "100")) {
            val discovery = JSONObject().put("continueWatchingSource", source).put("continueWatchingWindow", window)
            val roster = JSONObject().put(scope.ownerProfileID, JSONObject().put("name", "Kernel viewer").put("deleted", false))
            val edited = JSONObject(roster.toString()).also { it.getJSONObject(scope.ownerProfileID).put("discovery", discovery) }
            val state = NativeHostPreferences.recordProfiles(scope, local(1), roster, edited)
            val merged = NativeHostPreferences.merge(scope, local(2), state.getJSONObject("document"))
            val projected = NativeHostPreferences.projectProfiles(merged, roster, roster)
            NativeHostPreferences.validateProjectedProfiles(projected)
            assertEquals(source, projected.getJSONObject(scope.ownerProfileID).getJSONObject("discovery").getString("continueWatchingSource"))
            assertEquals(window, projected.getJSONObject(scope.ownerProfileID).getJSONObject("discovery").getString("continueWatchingWindow"))
        }
        for (key in listOf("continueWatchingSource", "continueWatchingWindow")) {
            assertTrue(runCatching { NativeHostPreferences.recordProfiles(scope, local(1), JSONObject(),
                JSONObject().put(scope.ownerProfileID, JSONObject().put("discovery", JSONObject().put(key, true)))) }.isFailure)
        }
    }

    private val lowerID get() = scope.ownerProfileID.lowercase()
    private fun lowerGroups(state: JSONObject): JSONObject = JSONObject(state.toString()).also { changed ->
        val groups = changed.getJSONObject("document").getJSONObject("profiles")
        groups.put(lowerID, groups.remove(scope.ownerProfileID))
    }
    private fun roster() = JSONObject().put(scope.ownerProfileID, JSONObject().put("name", "Native owner").put("deleted", false))

    @Test fun `lowercase UUID incoming and JSON host record reload project under uppercase roster without rewriting events`() {
        val item = WatchlistEntry("tt123", "movie", "Fixture", null, 10.0)
        val original = NativeHostPreferences.seedWatchlists(scope,
            NativeHostPreferences.recordProfiles(scope, local(1).put("counter", 6), JSONObject(), profile("🍿")),
            mapOf(scope.ownerProfileID to listOf(item)))
        val raw = lowerGroups(original)
        val rawBytes = raw.toString()
        val reopened = NativeHostPreferences.local(scope, JSONObject(rawBytes))
        assertTrue(reopened.getJSONObject("document").getJSONObject("profiles").has(scope.ownerProfileID))
        assertFalse(reopened.getJSONObject("document").getJSONObject("profiles").has(lowerID))
        assertTrue(NativeHostPreferences.equal(avatar(original), avatar(reopened)))
        val merged = NativeHostPreferences.merge(scope, local(2), raw.getJSONObject("document"))
        assertEquals(rawBytes, raw.toString())
        val projected = NativeHostPreferences.projectProfiles(merged, profile("base"), roster())
        assertEquals("🍿", projected.getJSONObject(scope.ownerProfileID).getString("avatar"))
        val fields = merged.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID).getJSONObject("fields")
        assertEquals(listOf(item), NativeWatchlistCodec.entries(fields))
        assertTrue(NativeHostPreferences.equal(original.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID),
            merged.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID)))
    }

    @Test fun `UUID profile edit and watchlist seed normalize only keys and do not mint case-only edits`() {
        val before = JSONObject().put(lowerID, JSONObject().put("avatar", "🍿").put("future", JSONObject().put("nested", true)))
        val after = JSONObject().put(scope.ownerProfileID, JSONObject(before.getJSONObject(lowerID).toString()))
        val unchanged = NativeHostPreferences.recordProfiles(scope, local(1), before, after)
        assertEquals(0L, unchanged.getLong("counter")); assertEquals(0, unchanged.getJSONObject("document").getJSONObject("profiles").length())
        val edited = NativeHostPreferences.recordProfileFields(scope, local(1), lowerID, JSONObject().put("future", JSONObject().put("nested", true)))
        assertTrue(edited.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID)
            .getJSONObject("fields").getJSONObject("future").getJSONObject("value").getBoolean("nested"))
        val item = WatchlistEntry("tt123", "movie", null, null, 10.0)
        val seeded = NativeHostPreferences.seedWatchlists(scope, local(1), mapOf(lowerID to listOf(item)))
        val register = seeded.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID)
            .getJSONObject("fields").getJSONObject(NativeWatchlistCodec.field(item.id, item.type))
        assertEquals(0L, register.getLong("clock")); assertEquals(NativeWatchlistCodec.baselineActor(scope.ownerProfileID, item), register.getString("actor"))
    }

    @Test fun `canonical duplicate host groups and edits fail even with equal values without input mutation`() {
        val original = NativeHostPreferences.recordProfiles(scope, local(1), JSONObject(), profile("🍿"))
        val duplicate = JSONObject(original.toString()).also { state ->
            val groups = state.getJSONObject("document").getJSONObject("profiles")
            groups.put(lowerID, JSONObject(groups.getJSONObject(scope.ownerProfileID).toString()))
        }
        val bytes = duplicate.toString()
        assertTrue(runCatching { NativeHostPreferences.validate(scope, duplicate.getJSONObject("document")) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.local(scope, duplicate) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.merge(scope, original, duplicate.getJSONObject("document")) }.isFailure)
        val projectedDuplicate = profile("🍿").put(lowerID, JSONObject().put("avatar", "🍿"))
        assertTrue(runCatching { NativeHostPreferences.recordProfiles(scope, original, JSONObject(), projectedDuplicate) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.recordProfiles(scope, original, projectedDuplicate, profile("🍿")) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.projectProfiles(original, projectedDuplicate, roster()) }.isFailure)
        assertTrue(runCatching { NativeHostPreferences.projectProfiles(original, profile("🍿"), roster().put(lowerID, roster().getJSONObject(scope.ownerProfileID))) }.isFailure)
        val item = WatchlistEntry("tt123", "movie", null, null, 10.0)
        assertTrue(runCatching { NativeHostPreferences.seedWatchlists(scope, original, mapOf(lowerID to listOf(item), scope.ownerProfileID to listOf(item))) }.isFailure)
        assertEquals(bytes, duplicate.toString())
        assertEquals(1L, original.getLong("counter"))
    }

    @Test fun `case folded UUID merge retains newer null unknown siblings and nonUUID legacy spellings exactly`() {
        val older = NativeHostPreferences.recordProfiles(scope, local(1), JSONObject(), profile("🍿"))
        val newer = NativeHostPreferences.recordProfileFields(scope, older, scope.ownerProfileID,
            JSONObject().put("avatar", JSONObject.NULL).put("future", JSONObject().put("retained", true)))
        val merged = NativeHostPreferences.merge(scope, newer, lowerGroups(older).getJSONObject("document"))
        assertTrue(avatar(merged).isNull("value"))
        assertTrue(merged.getJSONObject("document").getJSONObject("profiles").getJSONObject(scope.ownerProfileID)
            .getJSONObject("fields").getJSONObject("future").getJSONObject("value").getBoolean("retained"))
        val legacy = JSONObject().put("LegacyName", JSONObject().put("avatar", "first"))
            .put("LEGACYNAME", JSONObject().put("avatar", "second"))
            .put("1-1-1-1-1", JSONObject().put("avatar", "short spelling"))
        val UUIDlike = listOf("ABCDEF1-0000-4000-8000-000000000001", "GBCDEF01-0000-4000-8000-000000000001",
            "gbcdef01-0000-4000-8000-000000000001", " ${scope.ownerProfileID}", "${scope.ownerProfileID} ", "{${scope.ownerProfileID}}")
        UUIDlike.forEach { legacy.put(it, JSONObject().put("avatar", "🍿")) }
        val state = NativeHostPreferences.recordProfiles(scope, local(1), JSONObject(), legacy)
        val groups = state.getJSONObject("document").getJSONObject("profiles")
        assertEquals(legacy.keys().asSequence().toSet(), groups.keys().asSequence().toSet())
        val sealed = NativeHostPreferences.local(scope, JSONObject(state.toString()))
        assertTrue(NativeHostPreferences.equal(state, sealed))
    }
}
