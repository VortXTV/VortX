package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeLegacyMaterialTest {
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Owner", avatar = "🍿", isOwner = true)
    private val child = UserProfile(id = "10000000-0000-0000-0000-000000000001", name = "Child", avatar = "🎬")
    private fun material(document: JSONObject, roster: List<UserProfile> = listOf(owner, child)) = nativeLegacyMaterial(document, roster, 1720000000.1234, watchedMigration = null)
    private fun document(vortx: JSONObject = JSONObject()) = JSONObject().put("vortx", vortx)
    private fun movie(id: String = "tt123", time: Double = 0.0) = JSONObject().put("id", id).put("type", "movie").put("name", "Film")
        .put("t", time).put("d", 100.0).put("lastWatched", "2026-01-01T00:00:00.123456Z")
    private fun watchRows(material: JSONObject, profile: String = owner.id): List<JSONObject> = material.getJSONObject("watches").getJSONArray(profile).let { a ->
        (0 until a.length()).map(a::getJSONObject)
    }
    private fun failure(document: JSONObject, phrase: String) {
        val error = runCatching { material(document) }.exceptionOrNull()
        assertTrue("Expected '$phrase', got $error", error is IllegalArgumentException && error.message.orEmpty().contains(phrase))
    }

    @Test fun `pending or malformed website profile edits never bypass complete material validation`() {
        for (edits in listOf<Any>(JSONObject().put(owner.id, JSONObject().put("name", "Website name")), JSONArray(), "opaque")) {
            failure(document().put("profileEdits", edits), "Pending profile edits")
        }
        material(document().put("profileEdits", JSONObject()))
        material(document().put("profileEdits", JSONObject.NULL))
    }

    @Test fun `preserves exact profile ids salted PIN and fractional roster clock without credentials`() {
        val pin = UserProfile.pinHash("1234", child.id)
        val original = document().put("authKey", "must-not-copy").put("settings", "opaque encrypted-account-adjacent backup")
        val result = material(original, listOf(owner, child.copy(pin = pin, isKids = true, familyEdit = true, textScale = 1.15)))
        val p = result.getJSONArray("roster").getJSONObject(1)
        assertEquals(child.id, p.getString("id")); assertEquals(pin, p.getString("pin"))
        assertEquals(owner.id, p.getJSONObject("account").getString("value"))
        assertEquals(1150, p.getJSONObject("settings").getInt("textScale"))
        assertTrue(p.getJSONObject("parental").getBoolean("kids"))
        assertEquals(1720000000.1234, result.getDouble("rosterModifiedSeconds"), 0.0)
        assertFalse(result.toString().contains("must-not-copy")); assertEquals("must-not-copy", original.getString("authKey"))
    }

    @Test fun `membership-only owner row never becomes viewing history`() {
        val result = material(document(JSONObject().put("library", JSONArray().put(movie()))))
        assertEquals(1, result.getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("items").length())
        assertTrue(watchRows(result).isEmpty())
    }

    @Test fun `progress preserves millisecond position and fractional timestamp`() {
        val result = material(document(JSONObject().put("library", JSONArray().put(movie(time = 12.345)))))
        val row = watchRows(result).single()
        assertEquals(12345L, row.getLong("positionMs")); assertEquals(100000L, row.getLong("durationMs"))
        assertEquals(1767225600123.456, row.getDouble("lastPlayedAtMs"), 0.0)
        assertFalse(row.has("watched"))
        assertEquals(2001L, watchRows(material(document(JSONObject().put("library", JSONArray().put(movie(time = 2.001)))))).single().getLong("positionMs"))
    }

    @Test fun `durable watched carrier preserves opaque episodes beyond rail and explicit unmark clocks`() {
        val watched = JSONObject()
        repeat(125) { index -> watched.put("series-$index", JSONObject().put("w", JSONArray().put("opaque-episode-$index"))) }
        watched.put("tt456", JSONObject().put("w", JSONArray().put("opaque-final")).put("ma", JSONObject().put("opaque-final", 50.125))
            .put("ua", JSONObject().put("opaque-final", 50.875)))
        val doc = document(JSONObject().put("byProfile", JSONObject().put(child.id, JSONObject().put("watched", watched))))
        val rows = watchRows(material(doc), child.id)
        assertEquals(126, rows.size)
        assertTrue(rows.any { it.getString("metaId") == "series-124" && it.getString("videoId") == "opaque-episode-124" && it.getBoolean("watched") })
        val last = rows.single { it.getString("metaId") == "tt456" }
        assertEquals(50.125, last.getDouble("markedAtMs"), 0.0); assertEquals(50.875, last.getDouble("resetAtMs"), 0.0)
        assertFalse(last.has("watched")); assertFalse(last.has("lastPlayedAtMs")); assertFalse(last.has("type"))
    }

    @Test fun `addon legacy lowercase tombstone maps to exact configured path without rounding clocks`() {
        val url = "https://Example.com/Config%2FAbC/manifest.json"
        val addon = JSONObject().put("transportUrl", url).put("manifest", JSONObject().put("id", "test").put("name", "Test").put("version", "1.0.0"))
        val v = JSONObject().put("addons", JSONArray().put(addon)).put("deletedAddonsTs", JSONObject().put(url.lowercase(), JSONObject().put("addedAt", 1000.75).put("removedAt", 1000.5)))
        val result = material(document(v).put("addonOrder", JSONArray().put(url.lowercase())))
        val bucket = result.getJSONObject("addons").getJSONObject(owner.id)
        val actual = "https://example.com/Config%2FAbC/manifest.json"
        assertEquals(actual, bucket.getJSONArray("items").getJSONObject(0).getString("transportUrl"))
        assertEquals(actual, bucket.getJSONArray("order").getString(0))
        val intent = bucket.getJSONArray("intents").getJSONObject(0)
        assertEquals(actual, intent.getString("transportUrl")); assertEquals(1000.75, intent.getDouble("addedAtMs"), 0.0)
        assertEquals(1000.5, intent.getDouble("removedAtMs"), 0.0)
    }

    @Test fun `typed library tombstone retains exact fractional order and no fabricated type`() {
        val v = JSONObject().put("library", JSONArray().put(movie())).put("deletedLibraryTs", JSONObject().put("tt123", JSONObject().put("removedAt", 900.99).put("addedAt", 900.01)))
        val intent = material(document(v)).getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("intents").getJSONObject(0)
        assertEquals("movie:tt123", intent.getString("key")); assertEquals(900.99, intent.getDouble("removedAtMs"), 0.0)
        failure(document(JSONObject().put("deletedLibrary", JSONArray().put("tt999"))), "title-type reconciliation")
    }

    @Test fun `owner actor tie is resolved before timestamp-only kernel import`() {
        fun intent(watched: Boolean, actor: String) = JSONObject().put("t", "tt123").put("v", "tt123").put("w", watched).put("u", 100.25).put("a", actor)
        val v = JSONObject().put("library", JSONArray().put(movie())).put("ownerWatched", JSONObject().put("a", intent(true, "a")).put("b", intent(false, "z")))
        val rows = watchRows(material(document(v)))
        assertEquals(1, rows.size); assertEquals(100.25, rows.single().getDouble("resetAtMs"), 0.0)
        assertFalse(rows.single().has("markedAtMs"))
    }

    @Test fun `verified overlay removal maps exact title without inventing alias`() {
        val bucket = JSONObject().put("library", JSONArray().put(movie(time = 5.0)))
            .put("removed", JSONArray().put(JSONObject().put("keys", JSONArray().put("movie\u001fimdb:tt123")).put("removedAt", 1767225700000.75)))
        val result = material(document(JSONObject().put("byProfile", JSONObject().put(child.id, bucket))))
        val removal = watchRows(result, child.id).single { it.has("removedAtMs") }
        assertEquals("tt123", removal.getString("metaId")); assertEquals(1767225700000.75, removal.getDouble("removedAtMs"), 0.0)
        assertEquals(0, result.getJSONObject("identityLinks").getJSONArray(child.id).length())
    }

    @Test fun `rail progress and clocks share one unit while overlapping durable snapshot remains fallback`() {
        val progress = movie(time = 4.5).put("v", "opaque-video").put("w", JSONArray().put("opaque-video"))
            .put("ma", JSONObject().put("opaque-video", 20.25)).put("ua", JSONObject().put("opaque-video", 30.75))
        val durable = JSONObject().put("tt123", JSONObject().put("w", JSONArray().put("opaque-video"))
            .put("ua", JSONObject().put("opaque-video", 99.5)))
        val bucket = JSONObject().put("library", JSONArray().put(progress)).put("watched", durable)
        val rows = watchRows(material(document(JSONObject().put("byProfile", JSONObject().put(child.id, bucket)))), child.id)
        val row = rows.single()
        assertEquals("opaque-video", row.getString("videoId")); assertEquals(4500L, row.getLong("positionMs"))
        assertEquals(20.25, row.getDouble("markedAtMs"), 0.0); assertEquals(30.75, row.getDouble("resetAtMs"), 0.0)
        assertFalse(row.has("watched"))
    }

    @Test fun `actual owner history can carry rewind zero without manufacturing saved-row history`() {
        val history = movie(time = 0.0).put("v", "tt123").put("eventEpochMs", 1767225600123)
        val v = JSONObject().put("library", JSONArray().put(movie()))
            .put("byProfile", JSONObject().put(UserProfile.OWNER_ID, JSONObject().put("ownerHistory", JSONArray().put(history))))
        val row = watchRows(material(document(v))).single()
        assertEquals(0L, row.getLong("positionMs")); assertTrue(row.has("lastPlayedAtMs"))
    }

    @Test fun `durable unclocked duplicate cannot resurrect omission from authoritative rail snapshot`() {
        val bucket = JSONObject().put("library", JSONArray().put(movie(time = 1.0).put("w", JSONArray())))
            .put("watched", JSONObject().put("tt123", JSONObject().put("w", JSONArray().put("stale-episode"))))
        val rows = watchRows(material(document(JSONObject().put("byProfile", JSONObject().put(child.id, bucket)))), child.id)
        assertEquals(1, rows.size); assertFalse(rows.single().has("watched")); assertFalse(rows.single().has("videoId"))
    }

    @Test fun `unsupported evidence is explicit instead of a partial success`() {
        failure(document(JSONObject().put("library", JSONArray().put(movie(time = 1.0).put("watched", "opaque-bitfield")))), "bitfield")
        failure(document(JSONObject().put("byProfile", JSONObject().put(child.id, JSONObject().put("library", JSONArray().put(movie()))))), "Saved-only overlay")
        failure(document(JSONObject().put("addons", JSONArray().put(JSONObject().put("transportUrl", "https://example.com/manifest.json")))), "manifest reconciliation")
        failure(document(JSONObject().put("library", JSONArray().put(movie(time = 1.00001)))), "Sub-millisecond")
        assertTrue(runCatching { material(document(), listOf(owner, child.copy(usesOwnAccount = true))) }.exceptionOrNull()?.message.orEmpty().contains("authenticated streaming-account"))
    }

    @Test fun `credential-bearing addon material and malformed carriers fail closed`() {
        val addon = JSONObject().put("transportUrl", "https://example.com/manifest.json")
            .put("manifest", JSONObject().put("id", "test").put("name", "Test").put("accessToken", "secret"))
        failure(document(JSONObject().put("addons", JSONArray().put(addon))), "Credential-bearing")
        failure(document(JSONObject().put("library", "not-an-array")), "Malformed array")
        failure(document(JSONObject().put("byProfile", JSONObject().put("unknown", JSONObject().put("watched", JSONObject())))), "unknown profile")
    }

    @Test fun `empty intent cannot suppress shipping legacy deletion epoch or reconcile web removal`() {
        val url = "https://example.com/manifest.json"
        val v = JSONObject().put("library", JSONArray().put(movie())).put("deletedLibrary", JSONArray().put("tt123"))
            .put("deletedLibraryTs", JSONObject().put("tt123", JSONObject()))
            .put("deletedAddons", JSONArray().put(url)).put("deletedAddonsTs", JSONObject().put(url, JSONObject()))
        val result = material(document(v))
        assertEquals(1.0, result.getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("intents").getJSONObject(0).getDouble("removedAtMs"), 0.0)
        assertEquals(1.0, result.getJSONObject("addons").getJSONObject(owner.id).getJSONArray("intents").getJSONObject(0).getDouble("removedAtMs"), 0.0)
        failure(document(JSONObject().put("deletedAddonsTs", JSONObject().put(url, JSONObject()))).put("webAddonRemovals", JSONArray().put(url)), "Unclocked web")
    }

    @Test fun `legacy lowercase add-on identifier fails despite exact lowercased descriptor match`() {
        fun addon(path: String) = JSONObject().put("transportUrl", "https://example.com/$path/manifest.json")
            .put("manifest", JSONObject().put("id", path).put("name", path).put("version", "1.0.0"))
        failure(document(JSONObject().put("addons", JSONArray().put(addon("Config")).put(addon("config")))
            .put("deletedAddons", JSONArray().put("https://example.com/config/manifest.json"))), "Ambiguous legacy add-on")
    }

    @Test fun `removal group does not establish alias equivalence between distinct titles`() {
        val bucket = JSONObject().put("library", JSONArray().put(movie("tt123", 1.0)).put(movie("tt456", 1.0)))
            .put("removed", JSONArray().put(JSONObject().put("keys", JSONArray().put("movie\u001fimdb:tt123").put("movie\u001fimdb:tt456")).put("removedAt", 1000)))
        failure(document(JSONObject().put("byProfile", JSONObject().put(child.id, bucket))), "verified title reconciliation")
    }

    @Test fun `owner removed flag never converts viewing timestamp into deletion intent`() {
        val row = movie(time = 1.0).put("removed", true).put("eventEpochMs", 1767225600123)
        failure(document(JSONObject().put("library", JSONArray().put(row))), "explicit library removal intent")
        val result = material(document(JSONObject().put("library", JSONArray().put(row)).put("deletedLibrary", JSONArray().put("tt123"))))
        val intent = result.getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("intents").getJSONObject(0)
        assertEquals(1.0, intent.getDouble("removedAtMs"), 0.0)
    }

    @Test fun `mark-only and count-only owner membership do not manufacture viewing clocks`() {
        val marked = watchRows(material(document(JSONObject().put("library", JSONArray().put(movie().put("currentVideoWatched", true)))))).single()
        assertTrue(marked.getBoolean("watched")); assertFalse(marked.has("lastPlayedAtMs")); assertFalse(marked.has("positionMs"))
        val counted = watchRows(material(document(JSONObject().put("library", JSONArray().put(movie().put("timesWatched", 3)))))).single()
        assertEquals(3, counted.getInt("timesWatched")); assertFalse(counted.has("lastPlayedAtMs"))
    }

    @Test fun `newer sparse owner history keeps prior real duration and equal-clock offset conflict fails`() {
        val prior = movie(time = 5.0).put("v", "tt123")
        val newer = movie(time = 2.0).put("v", "tt123").put("lastWatched", "2026-01-02T00:00:00Z").also { it.remove("d") }
        val v = JSONObject().put("library", JSONArray().put(prior)).put("byProfile", JSONObject().put(owner.id, JSONObject().put("ownerHistory", JSONArray().put(newer))))
        val row = watchRows(material(document(v))).single()
        assertEquals(2000L, row.getLong("positionMs")); assertEquals(100000L, row.getLong("durationMs"))
        newer.put("lastWatched", prior.getString("lastWatched"))
        failure(document(v), "equal-clock progress")
    }

    @Test fun `contradictory owner watched operation at same clock and actor fails closed`() {
        fun intent(watched: Boolean) = JSONObject().put("t", "tt123").put("v", "tt123").put("w", watched).put("u", 100.25).put("a", "same")
        failure(document(JSONObject().put("library", JSONArray().put(movie())).put("ownerWatched", JSONObject().put("a", intent(true)).put("b", intent(false)))), "equal-clock owner intent")
    }

    @Test fun `zero overlay mark clocks are ingress absence and cannot suppress legacy watched ids`() {
        val durable = JSONObject().put("tt123", JSONObject().put("w", JSONArray().put("opaque-episode"))
            .put("ma", JSONObject().put("opaque-episode", 0.0)).put("ua", JSONObject().put("opaque-episode", 0.0)))
        val rows = watchRows(material(document(JSONObject().put("byProfile", JSONObject().put(child.id, JSONObject().put("watched", durable))))), child.id)
        val row = rows.single()
        assertTrue(row.getBoolean("watched")); assertFalse(row.has("markedAtMs")); assertFalse(row.has("resetAtMs"))
    }
}
