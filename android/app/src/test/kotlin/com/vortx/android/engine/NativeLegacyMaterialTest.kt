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
    private val scope = VortxAccountScope("account.legacy-fixture", owner.id)
    private fun prepare(document: JSONObject) = prepareNativeLegacyMaterial(document, listOf(owner, child), 1720000000.1234, accountScope = scope)
    private fun movie(id: String = "tt123", time: Double = 0.0) = JSONObject().put("id", id).put("type", "movie").put("name", "Film")
        .put("t", time).put("d", 100.0).put("lastWatched", "2026-01-01T00:00:00.123456Z")
    private fun watchRows(material: JSONObject, profile: String = owner.id): List<JSONObject> = material.getJSONObject("watches").getJSONArray(profile).let { a ->
        (0 until a.length()).map(a::getJSONObject)
    }
    /** Issue #262: a unit the projection cannot represent is held, never fatal, and deterministically so. */
    private fun held(document: JSONObject, phrase: String, roster: List<UserProfile> = listOf(owner, child)): JSONObject {
        val holds = mutableListOf<NativeLegacyHeld>(); val again = mutableListOf<NativeLegacyHeld>()
        val first = nativeLegacyMaterial(document, roster, 1720000000.1234, watchedMigration = null, held = holds)
        val second = nativeLegacyMaterial(document, roster, 1720000000.1234, watchedMigration = null, held = again)
        assertTrue("Expected a hold for '$phrase', got $holds", holds.any { it.reason.contains(phrase) })
        assertEquals("Holding '$phrase' keeps the material deterministic", first.toString(), second.toString())
        assertTrue(nativeLegacyHeldSummary(holds).isNotEmpty())
        return first
    }
    private fun failure(document: JSONObject, phrase: String) {
        val error = runCatching { material(document) }.exceptionOrNull()
        assertTrue("Expected '$phrase', got $error", error is IllegalArgumentException && error.message.orEmpty().contains(phrase))
    }

    private fun addonV3(counter: String = "2", state: String = "removed") = JSONObject().put("version", 3).put("counter", counter)
        .put("eventId", "e9" + "0".repeat(30)).put("state", state).put("wallTime", 1000.125).put("legacyRemovedSeen", 300).put("legacyAddedSeen", 200)

    /** Issue #262: a 0.4 account carrying rows the native engine cannot represent still loads. */
    @Test fun `one unrepresentable unit never stops the account and a held unit leaves no trace`() {
        fun descriptor(url: String, id: String) = JSONObject().put("transportUrl", url).put("manifest", JSONObject().put("id", id).put("name", id))
        val urlOnly = JSONObject().put("transportUrl", "https://old.example.com/manifest.json").put("name", "Old")
        val stray = "30000000-0000-0000-0000-000000000003"
        val doc = document(JSONObject()
            .put("library", JSONArray().put(movie("tt-kept", 12.0)).put(movie("yt-channel").put("type", "channel"))
                .put(movie("iptv-one").put("type", "tv")).put(movie("tt-series", 42.0).put("type", "series").put("v", ""))
                .put(movie("tt-noclock", 30.0).put("lastWatched", "")))
            .put("addons", JSONArray().put(descriptor("https://example.com/manifest.json", "fixture")).put(urlOnly)
                .put(descriptor("https://frag.example.com/manifest.json#cfg", "frag"))
                .put(descriptor("http://192.168.1.20:7000/manifest.json", "lan")))
            .put("deletedProfiles", JSONArray().put("not-a-uuid"))
            .put("byProfile", JSONObject()
                .put(stray, JSONObject().put("watched", JSONObject().put("tt-stray", JSONObject().put("w", JSONArray().put("tt-stray:1:1")))))
                .put(child.id, JSONObject().put("watched", JSONObject().put("tt-child", JSONObject().put("ma", JSONObject().put("tt-child:1:1", 1500.5)))))))
        val holds = mutableListOf<NativeLegacyHeld>()
        val result = nativeLegacyMaterial(doc, listOf(owner, child), 1720000000.1234, watchedMigration = null, held = holds)
        val items = result.getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("items")
        assertEquals("Representable titles stay saved, including ones whose progress is held",
            setOf("tt-kept", "tt-series", "tt-noclock"), (0 until items.length()).map { items.getJSONObject(it).getString("id") }.toSet())
        val ownerWatches = watchRows(result)
        assertTrue(ownerWatches.any { it.getString("metaId") == "tt-kept" && it.getLong("positionMs") == 12_000L })
        assertTrue(ownerWatches.none { it.getString("metaId") in setOf("tt-series", "tt-noclock", "yt-channel", "iptv-one") })
        val addons = result.getJSONObject("addons").getJSONObject(owner.id).getJSONArray("items")
        assertEquals(listOf("https://example.com/manifest.json", "http://192.168.1.20:7000/manifest.json"),
            (0 until addons.length()).map { addons.getJSONObject(it).getString("transportUrl") })
        assertTrue(watchRows(result, child.id).any { it.optString("videoId") == "tt-child:1:1" })
        val reasons = holds.map { "${it.kind}:${it.reason}" }
        for (expected in listOf("library_row:Unsupported catalog content type", "library_progress:Series progress requires an exact video identity",
                "library_progress:Progress lacks a genuine viewing clock", "addon:URL-only add-on requires manifest reconciliation",
                "addon:Unsupported add-on transport URL", "deleted_profile:Invalid deleted profile identity",
                "profile_overlay:Watch carrier references an unknown profile"))
            assertTrue("Expected hold $expected; got $reasons", reasons.any { it.startsWith(expected) })
        assertEquals(2, reasons.count { it.startsWith("library_row:Unsupported catalog content type") })
        assertEquals("Only the fragment URL holds; the private add-on is retained", 1,
            reasons.count { it.startsWith("addon:Unsupported add-on transport URL") })
        val summary = nativeLegacyHeldSummary(holds)
        assertFalse(summary, summary.contains("tt-") || summary.contains(stray) || summary.contains("example.com"))
        assertEquals("malformed_clock_x", scrubbedLegacyReason("Malformed clock tt123:1:2"))
        assertEquals("malformed_object_carrier_x", scrubbedLegacyReason("Malformed object carrier $stray"))
        // A unit is atomic: progress that fails after appending a mark leaves nothing behind.
        val partial = movie("tt-partial", 5.0).put("type", "series").put("v", "").put("w", JSONArray().put("tt-partial:1:1"))
        val rolledBack = held(document(JSONObject().put("library", JSONArray().put(partial))), "Series progress requires an exact video identity")
        assertTrue(watchRows(rolledBack).none { it.getString("metaId") == "tt-partial" })
        assertEquals(1, rolledBack.getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("items").length())
    }

    @Test fun `known addon V3 is forwarded intact despite scalar intent disagreement`() {
        val url = "https://fixture.invalid/manifest.json"
        val intent = addonV3()
        val doc = document(JSONObject().put("deletedAddonsTs", JSONObject().put(url, JSONObject().put("addedAt", 200).put("removedAt", 100).put("intentV3", intent)))
            .put("deletedAddons", JSONArray().put(url)))
        val actual = material(doc).getJSONObject("addons").getJSONObject(owner.id).getJSONArray("intents").getJSONObject(0)
        assertTrue(NativeHostPreferences.equal(intent, actual.getJSONObject("intentV3")))
        assertEquals(200.0, actual.getDouble("addedAtMs"), 0.0)
        assertEquals(100.0, actual.getDouble("removedAtMs"), 0.0)
        NativeHostDocument.requireCredentialFree(actual)
    }

    @Test fun `addon V3 alias merge keeps winner and component seen maxima without flattening`() {
        val url = "https://fixture.invalid/Config/manifest.json"
        val descriptor = JSONObject().put("transportUrl", url).put("manifest", JSONObject().put("id", "fixture").put("name", "Fixture"))
        val older = addonV3("1", "present").put("legacyRemovedSeen", 500)
        val newer = addonV3("2", "removed").put("legacyAddedSeen", 600)
        val doc = document(JSONObject().put("addons", JSONArray().put(descriptor)).put("deletedAddonsTs", JSONObject()
            .put(url, JSONObject().put("addedAt", 200).put("intentV3", older))
            .put(url.lowercase(), JSONObject().put("removedAt", 100).put("intentV3", newer))))
        val v3 = material(doc).getJSONObject("addons").getJSONObject(owner.id).getJSONArray("intents").getJSONObject(0).getJSONObject("intentV3")
        assertEquals("2", v3.getString("counter")); assertEquals("removed", v3.getString("state"))
        assertEquals(500, v3.getInt("legacyRemovedSeen")); assertEquals(600, v3.getInt("legacyAddedSeen"))
    }

    @Test fun `unknown malformed or future addon intents are held rather than dropping causal metadata`() {
        val url = "https://fixture.invalid/manifest.json"
        fun intent(value: JSONObject) = document(JSONObject().put("deletedAddonsTs", JSONObject().put(url, value)))
        held(intent(JSONObject().put("future", true)), "Unsupported add-on intent fields")
        held(intent(JSONObject().put("intentV3", addonV3().put("future", true))), "Unsupported V3")
        held(intent(JSONObject().put("intentV3", addonV3("01"))), "counter")
        held(intent(JSONObject().put("intentV3", addonV3().put("wallTime", System.currentTimeMillis() + 49L * 60 * 60 * 1000))), "future")
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
        held(document(JSONObject().put("deletedLibrary", JSONArray().put("tt999"))), "title-type reconciliation")
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
        val history = movie(time = 0.0).put("v", "tt123").put("eventEpochMs", 1767225600999.875)
        val v = JSONObject().put("library", JSONArray().put(movie()))
            .put("byProfile", JSONObject().put(UserProfile.OWNER_ID, JSONObject().put("ownerHistory", JSONArray().put(history))))
        val row = watchRows(material(document(v))).single()
        assertEquals(0L, row.getLong("positionMs")); assertTrue(row.has("lastPlayedAtMs"))
        assertEquals(1767225600999.875, row.getDouble("lastPlayedAtMs"), 0.0)
        history.remove("eventEpochMs")
        held(document(v), "Malformed genuine owner history")
    }

    @Test fun `durable unclocked duplicate cannot resurrect omission from authoritative rail snapshot`() {
        val bucket = JSONObject().put("library", JSONArray().put(movie(time = 1.0).put("w", JSONArray())))
            .put("watched", JSONObject().put("tt123", JSONObject().put("w", JSONArray().put("stale-episode"))))
        val rows = watchRows(material(document(JSONObject().put("byProfile", JSONObject().put(child.id, bucket)))), child.id)
        assertEquals(1, rows.size); assertFalse(rows.single().has("watched")); assertFalse(rows.single().has("videoId"))
    }

    @Test fun `unsupported evidence is explicit instead of a partial success`() {
        held(document(JSONObject().put("library", JSONArray().put(movie(time = 1.0).put("watched", "opaque-bitfield")))), "bitfield")
        held(document(JSONObject().put("byProfile", JSONObject().put(child.id, JSONObject().put("library", JSONArray().put(movie()))))), "Saved-only overlay")
        held(document(JSONObject().put("addons", JSONArray().put(JSONObject().put("transportUrl", "https://example.com/manifest.json")))), "manifest reconciliation")
        assertTrue(runCatching { material(document(), listOf(owner, child.copy(usesOwnAccount = true))) }.exceptionOrNull()?.message.orEmpty().contains("authenticated streaming-account"))
    }

    @Test fun `float playback seconds normalize nearest milliseconds and source clocks stay exact`() {
        val raw = movie(time = 1.00001).put("d", 100.0006)
        val doc = document(JSONObject().put("library", JSONArray().put(raw)))
        val original = nativeWatchedDocumentSnapshot(doc)
        val row = watchRows(material(doc)).single()
        assertEquals(1000L, row.getLong("positionMs")); assertEquals(100001L, row.getLong("durationMs"))
        assertEquals(1767225600123.456, row.getDouble("lastPlayedAtMs"), 0.0)
        assertArrayEquals(original, nativeWatchedDocumentSnapshot(doc))
        val archived = NativeHostDocument.archive(doc).getJSONObject("document").getJSONObject("vortx").getJSONArray("library").getJSONObject(0)
        assertEquals(1.00001, archived.getDouble("t"), 0.0); assertEquals(100.0006, archived.getDouble("d"), 0.0)
        for ((seconds, expected) in listOf(2.001 to 2001L, 1.0005 to 1001L, 0.0001 to 0L)) {
            val result = material(document(JSONObject().put("library", JSONArray().put(movie(time = seconds)))))
            assertEquals(expected, watchRows(result).single().getLong("positionMs"))
        }
        val tiny = document(JSONObject().put("byProfile", JSONObject().put(child.id,
            JSONObject().put("library", JSONArray().put(movie(time = 0.0001))))))
        assertEquals(0L, watchRows(material(tiny), child.id).single().getLong("positionMs"))
        held(document(JSONObject().put("library", JSONArray().put(movie(time = -0.0001)))), "Invalid clock")
        held(document(JSONObject().put("library", JSONArray().put(movie().put("t", java.math.BigDecimal("9007199254740.9901"))))), "Excessive progress")
        held(document(JSONObject().put("library", JSONArray().put(movie().put("t", "1.01")))), "Malformed clock")
    }

    @Test fun `explicit preparation retains orphan historical installs and web removals without native membership`() {
        val live = "https://fixture.invalid/live/manifest.json"
        val descriptor = JSONObject().put("transportUrl", live).put("manifest", JSONObject().put("id", "live").put("name", "Live"))
        val stamps = JSONObject(); val removals = JSONArray()
        repeat(13) { index ->
            val url = "https://fixture.invalid/historical-$index/manifest.json"
            stamps.put(url, JSONObject().put("addedAt", 1000.75 + index).put("removedAt", 1000.5))
            if (index < 5) removals.put(url)
        }
        val doc = document(JSONObject().put("addons", JSONArray().put(descriptor)).put("deletedAddonsTs", stamps)
            .put("library", JSONArray().put(movie(time = 1.00001))))
            .put("addonOrder", JSONArray().put(live)).put("webAddonRemovals", removals)
        val original = nativeWatchedDocumentSnapshot(doc)
        held(doc, "installed descriptor")
        val prepared = prepare(doc)
        val bucket = prepared.material.getJSONObject("addons").getJSONObject(owner.id)
        assertEquals(1, bucket.getJSONArray("items").length()); assertEquals(live, bucket.getJSONArray("order").getString(0))
        assertEquals(0, bucket.getJSONArray("intents").length())
        assertEquals(18, prepared.pendingMembershipReceipts.length()); assertEquals(2, prepared.material.getJSONArray("roster").length())
        assertEquals(1000L, watchRows(prepared.material).single().getLong("positionMs"))
        assertArrayEquals(original, nativeWatchedDocumentSnapshot(doc))
        val retained = (0 until prepared.pendingMembershipReceipts.length()).map(prepared.pendingMembershipReceipts::getJSONObject)
            .single { it.getString("identity") == "https://fixture.invalid/historical-0/manifest.json" && it.getString("sourceField") == "/vortx/deletedAddonsTs" }
        assertEquals(1000.75, retained.getJSONObject("receipt").getDouble("addedAt"), 0.0)
        assertEquals(owner.id, retained.getString("profileId"))
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(original).joinToString("") { "%02x".format(it) }
        assertEquals(digest, retained.getString("sourceDocumentSha256"))
        // An orphan cannot be ordered and a present V3 cannot be deferred: each is held, never imported.
        val orphanURL = stamps.keys().next()
        val orderedOrphan = prepare(JSONObject(doc.toString()).put("addonOrder", JSONArray().put(orphanURL)))
        assertTrue(orderedOrphan.held.any { it.kind == "addon_order" && it.reason.contains("Ordered add-on requires descriptor reconciliation") })
        assertEquals(0, orderedOrphan.material.getJSONObject("addons").getJSONObject(owner.id).getJSONArray("order").length())
        val v3 = prepare(document(JSONObject().put("deletedAddonsTs", JSONObject().put(live, JSONObject().put("intentV3", addonV3(state = "present"))))))
        assertTrue(v3.held.any { it.reason.contains("installed descriptor") })
        assertEquals(0, v3.material.getJSONObject("addons").getJSONObject(owner.id).getJSONArray("intents").length())
        assertEquals(0, v3.pendingMembershipReceipts.length())
    }

    @Test fun `untyped library removal remains exact pending evidence and malformed evidence is held`() {
        val unknown = JSONObject().put("removedAt", 900.99).put("addedAt", 900.01)
        val doc = document(JSONObject().put("library", JSONArray().put(movie(time = 2.0)))
            .put("deletedLibraryTs", JSONObject().put("tt999", unknown)).put("deletedLibrary", JSONArray().put("tt999")))
        held(doc, "title-type reconciliation")
        val prepared = prepare(doc)
        assertEquals(2, prepared.pendingMembershipReceipts.length())
        assertEquals(0, prepared.material.getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("intents").length())
        assertTrue(NativeHostPreferences.equal(unknown, prepared.pendingMembershipReceipts.getJSONObject(0).getJSONObject("receipt")))
        // Pending is not a malformed-input escape hatch: malformed evidence is held, never deferred.
        for (malformed in listOf(
            document(JSONObject().put("deletedLibraryTs", JSONObject().put("tt999", JSONObject().put("removedAt", "900")))),
            document(JSONObject().put("deletedLibraryTs", JSONObject().put("tt999", JSONObject().put("future", true)))),
            document(JSONObject().put("library", JSONArray().put(movie("tt123")).put(movie("tt123").put("type", "series")))))) {
            val outcome = prepare(malformed)
            assertTrue(outcome.held.isNotEmpty() && outcome.pendingMembershipReceipts.length() == 0)
        }
    }

    @Test fun `saved-only shared overlay retains exact row and locator without invented viewing or owner membership`() {
        val saved = movie(time = 0.0).put("futurePreference", "kept")
        val doc = document(JSONObject().put("byProfile", JSONObject().put(child.id, JSONObject().put("library", JSONArray().put(saved)))))
        held(doc, "Saved-only overlay")
        val prepared = prepare(doc)
        assertTrue(watchRows(prepared.material, child.id).isEmpty())
        assertEquals(0, prepared.material.getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("items").length())
        val pending = prepared.pendingMembershipReceipts.getJSONObject(0)
        assertEquals(child.id, pending.getString("profileId")); assertEquals("profile_saved_overlay", pending.getString("kind"))
        assertEquals("/vortx/byProfile/${child.id}/library/0", pending.getString("sourceField"))
        assertTrue(NativeHostPreferences.equal(saved, pending.getJSONObject("receipt")))
        val validJournal = nativeLegacyMembershipJournal(scope, null, JSONArray().put(pending), setOf(owner.id, child.id))
        val foreignLocator = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(pending))
            .put("sourceField", "/vortx/byProfile/${owner.id}/library/0")
        assertTrue(runCatching { nativeLegacyMembershipJournal(scope, null, JSONArray().put(foreignLocator), setOf(owner.id, child.id)) }.isFailure)
        val historical = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(validJournal))
        historical.getJSONArray("receipts").getJSONObject(0).put("sourceField", foreignLocator.getString("sourceField"))
        assertTrue(runCatching { nativeLegacyMembershipJournal(scope, historical, JSONArray()) }.isFailure)
        for (invalidLocator in listOf("/vortx/byProfile/<captured-profile>/library/0", "/vortx/byProfile/${child.id}/library/foreign/0", "vortx.byProfile.${child.id}.library[0]")) {
            assertTrue(runCatching { nativeLegacyMembershipJournal(scope, null, JSONArray().put(
                NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(pending)).put("sourceField", invalidLocator)), setOf(owner.id, child.id)) }.isFailure)
        }
        saved.put("poster", 123)
        val malformed = prepare(doc)
        assertTrue(malformed.held.any { it.reason.contains("Malformed string poster") } && malformed.pendingMembershipReceipts.length() == 0)
    }

    @Test fun `independent own source unresolved evidence never enters shared root pending ledger`() {
        val account = com.vortx.android.sync.SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 7)
        val ownScope = VortxAccountScope("account.${account.id}", owner.id)
        val ownProfile = child.copy(usesOwnAccount = true)
        val stored = mutableMapOf<String, String?>()
        val credentials = NativeOwnAccountCredentials(
            { key -> com.vortx.android.security.PersistentCredentialSnapshot(
                com.vortx.android.security.PersistentCredentialAvailability.AVAILABLE, mapOf(key to stored[key])) },
            { key, value -> stored[key] = value; true },
        )
        val capture = credentials.storeVerified(credentials.begin(account, ownProfile.id, { it() }), "fixture-token", "verified-streaming-uid")
        fun source(root: JSONObject, library: JSONArray): NativeOwnAccountSource = NativeOwnAccountSource.fromFetched(capture, "verified-streaming-uid",
            nativeWatchedDocumentSnapshot(JSONObject().put("result", library)),
            nativeWatchedDocumentSnapshot(JSONObject().put("result", JSONObject().put("addons", JSONArray()))),
            nativeWatchedDocumentSnapshot(nativeOwnAccountOverlay(root, ownProfile.id)))
        fun prepareOwn(root: JSONObject, own: NativeOwnAccountSource) = prepareNativeLegacyMaterial(root, listOf(owner, ownProfile), null,
            ownAccountSources = listOf(own), accountScope = ownScope)
        val root = document(JSONObject().put("byProfile", JSONObject().put(ownProfile.id,
            JSONObject().put("library", JSONArray().put(movie("own-orphan", 0.0))))))
        val own = source(root, JSONArray())
        val savedOnly = prepareOwn(root, own)
        assertTrue(savedOnly.held.any { it.kind == "own_profile_overlay_row" && it.reason.contains("Saved-only overlay") })
        assertEquals(0, savedOnly.pendingMembershipReceipts.length())
        val carrier = nativeOwnAccountCarrier(own, ownProfile, root)
        assertFalse(carrier.getJSONArray("watches").toString().contains("own-orphan"))
        val conflictRoot = document()
        val rows = JSONArray()
        for ((id, offset) in listOf("tt111" to 20_001, "tmdb:222" to 30_001)) rows.put(JSONObject().put("_id", id).put("type", "movie")
            .put("state", JSONObject().put("timeOffset", offset).put("duration", 100_000).put("lastWatched", "2026-01-01T00:00:00.123456Z").put("video_id", "tt111")))
        val ownConflict = prepareOwn(conflictRoot, source(conflictRoot, rows))
        assertTrue(ownConflict.held.any { it.kind == "own_watch" && it.reason.contains("conflicting title identities") })
        assertEquals(0, ownConflict.pendingMembershipReceipts.length())
        assertFalse(ownConflict.material.getJSONObject("watches").getJSONArray(ownProfile.id).toString().contains("tt111"))
        val valid = prepareOwn(conflictRoot, source(conflictRoot, JSONArray()))
        assertEquals(0, valid.pendingMembershipReceipts.length())
    }

    @Test fun `saved overlay pointer preserves original UUID casing and binds same canonical profile`() {
        val alpha = child.copy(id = "ABCDEF01-ABCD-ABCD-ABCD-ABCDEF012345")
        val rawID = alpha.id.lowercase()
        val doc = document(JSONObject().put("byProfile", JSONObject().put(rawID,
            JSONObject().put("library", JSONArray().put(movie(time = 0.0))))))
        val prepared = prepareNativeLegacyMaterial(doc, listOf(owner, alpha), null, accountScope = scope)
        val receipt = prepared.pendingMembershipReceipts.getJSONObject(0)
        assertEquals(alpha.id, receipt.getString("profileId"))
        assertEquals("/vortx/byProfile/$rawID/library/0", receipt.getString("sourceField"))
        val journal = nativeLegacyMembershipJournal(scope, null, prepared.pendingMembershipReceipts, setOf(owner.id, alpha.id))
        assertTrue(NativeHostPreferences.equal(journal, nativeLegacyMembershipJournal(scope, journal, JSONArray())))
        val foreign = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(receipt))
            .put("sourceField", "/vortx/byProfile/abcdef01-abcd-abcd-abcd-abcdef012346/library/0")
        assertTrue(runCatching { nativeLegacyMembershipJournal(scope, null, JSONArray().put(foreign), setOf(owner.id, alpha.id)) }.isFailure)
        val first = movie("tt123", 1.0).put("v", "shared-video")
        val second = movie("tmdb:456", 2.0).put("v", "shared-video")
        doc.getJSONObject("vortx").getJSONObject("byProfile").getJSONObject(rawID).put("library", JSONArray().put(first).put(second))
        val conflict = prepareNativeLegacyMaterial(doc, listOf(owner, alpha), null, accountScope = scope).pendingMembershipReceipts.getJSONObject(0)
        assertEquals("/vortx/byProfile/${alpha.id}/watch_identity_conflicts", conflict.getString("sourceField"))
        val originals = conflict.getJSONObject("receipt").getJSONArray("sources")
        assertEquals("/vortx/byProfile/$rawID/library/0", originals.getJSONObject(0).getString("sourceField"))
        assertEquals("/vortx/byProfile/$rawID/library/1", originals.getJSONObject(1).getString("sourceField"))
        assertTrue(NativeHostPreferences.equal(first, originals.getJSONObject(0).getJSONObject("receipt")))
        assertTrue(NativeHostPreferences.equal(second, originals.getJSONObject(1).getJSONObject("receipt")))
    }

    @Test fun `sealed journal survives reopen and unrelated playback hash churn without duplicate receipts`() {
        val url = "https://fixture.invalid/historical/manifest.json"
        val doc = document(JSONObject().put("deletedAddonsTs", JSONObject().put(url, JSONObject().put("addedAt", 1000.75))))
        val first = prepare(doc)
        val journal = nativeLegacyMembershipJournal(scope, null, first.pendingMembershipReceipts)
        val reopened = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(journal))
        val changedDocument = JSONObject(doc.toString()).put("unrelatedProgress", 123.456)
        val replay = nativeLegacyMembershipJournal(scope, reopened, prepare(changedDocument).pendingMembershipReceipts)
        assertEquals(1, replay.getJSONArray("receipts").length())
        assertTrue(NativeHostPreferences.equal(journal, replay))
        assertTrue(NativeHostPreferences.equal(journal, nativeLegacyMembershipJournal(scope, reopened, JSONArray())))
        changedDocument.getJSONObject("vortx").getJSONObject("deletedAddonsTs").getJSONObject(url).put("addedAt", 1001.75)
        assertEquals(2, nativeLegacyMembershipJournal(scope, reopened, prepare(changedDocument).pendingMembershipReceipts).getJSONArray("receipts").length())
        assertTrue(runCatching { nativeLegacyMembershipJournal(VortxAccountScope("account.foreign", owner.id), reopened, JSONArray()) }.isFailure)
        val credential = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(first.pendingMembershipReceipts.getJSONObject(0)))
        credential.getJSONObject("receipt").put("authKey", "never-retain")
        assertTrue(runCatching { nativeLegacyMembershipJournal(scope, null, JSONArray().put(credential)) }.isFailure)
        val foreignProfile = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(first.pendingMembershipReceipts.getJSONObject(0))).put("profileId", child.id)
        assertTrue(runCatching { nativeLegacyMembershipJournal(scope, null, JSONArray().put(foreignProfile)) }.isFailure)
        val historical = nativeLegacyMembershipJournal(scope, null, JSONArray().put(foreignProfile), setOf(owner.id, child.id))
        assertTrue(NativeHostPreferences.equal(historical, nativeLegacyMembershipJournal(scope, historical, JSONArray(), setOf(owner.id))))
    }

    @Test fun `watch identity conflict retains all original sources including owner intent without guessing alias`() {
        val first = movie("tt123", 1.00001).put("v", "shared-video")
        val second = movie("tmdb:456", 2.00002).put("v", "shared-video")
        val unaffected = movie("tt789", 3.0).put("v", "tt789")
        val intent = JSONObject().put("t", "tmdb:456").put("v", "shared-video").put("w", false).put("u", 123.25).put("a", "actor")
        val doc = document(JSONObject().put("library", JSONArray().put(first).put(second).put(unaffected))
            .put("ownerWatched", JSONObject().put("original-intent", intent)))
        val original = nativeWatchedDocumentSnapshot(doc)
        held(doc, "conflicting title identities")
        val prepared = prepare(doc)
        assertEquals("tt789", watchRows(prepared.material).single().getString("metaId"))
        assertEquals(3, prepared.material.getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("items").length())
        assertEquals(0, prepared.material.getJSONObject("identityLinks").getJSONArray(owner.id).length())
        val pending = prepared.pendingMembershipReceipts.getJSONObject(0)
        assertEquals("watch_identity_conflict", pending.getString("kind")); assertEquals("shared-video", pending.getString("identity"))
        assertEquals("/vortx/byProfile/${owner.id}/watch_identity_conflicts", pending.getString("sourceField"))
        val sources = pending.getJSONObject("receipt").getJSONArray("sources")
        assertEquals(3, sources.length())
        val byPointer = (0 until sources.length()).map(sources::getJSONObject).associate { it.getString("sourceField") to it.getJSONObject("receipt") }
        assertTrue(NativeHostPreferences.equal(first, byPointer["/vortx/library/0"]))
        assertTrue(NativeHostPreferences.equal(second, byPointer["/vortx/library/1"]))
        assertTrue(NativeHostPreferences.equal(intent, byPointer["/vortx/ownerWatched/original-intent"]))
        assertFalse(sources.toString().contains("positionMs"))
        assertArrayEquals(original, nativeWatchedDocumentSnapshot(doc))
        assertEquals(1, nativeLegacyMembershipJournal(scope, nativeLegacyMembershipJournal(scope, null, prepared.pendingMembershipReceipts),
            prepare(JSONObject(doc.toString()).put("unrelated", 99)).pendingMembershipReceipts).getJSONArray("receipts").length())
        second.put("t", "malformed")
        val malformed = prepare(doc)
        assertTrue(malformed.held.any { it.kind == "library_progress" && it.reason.contains("Malformed clock") })
    }

    @Test fun `prepared full roster imports through real JNI and preserves pending receipts in sealed cold checkpoint`() = kotlinx.coroutines.runBlocking {
        val path = System.getenv("VORTX_JNI_LIBRARY")
        org.junit.Assume.assumeTrue("Reviewed local JNI fixture required", System.getenv("VORTX_JNI_SYNC") == "1" && !path.isNullOrBlank())
        System.load(requireNotNull(path))
        val bindings = object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
        fun noNetwork() = object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No network permitted")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network permitted")
        }
        val live = "https://fixture.invalid/live/manifest.json"
        val orphan = "https://fixture.invalid/historical/manifest.json"
        val descriptor = JSONObject().put("transportUrl", live).put("flags", JSONObject()).put("manifest", JSONObject()
            .put("id", "live").put("name", "Live").put("version", "1.0.0").put("catalogs", JSONArray()).put("resources", JSONArray()).put("types", JSONArray()))
        val doc = document(JSONObject().put("addons", JSONArray().put(descriptor))
            .put("deletedAddonsTs", JSONObject().put(orphan, JSONObject().put("addedAt", 1000.75).put("removedAt", 1000.5)))
            .put("deletedLibraryTs", JSONObject().put("tt999", JSONObject().put("removedAt", 900.99)))
            .put("byProfile", JSONObject().put(child.id, JSONObject().put("library", JSONArray().put(movie(time = 0.0)))))
            .put("library", JSONArray().put(movie(time = 1.00001).put("d", 100.0006))))
            .put("addonOrder", JSONArray().put(live)).put("webAddonRemovals", JSONArray().put(orphan))
        val prepared = prepare(doc)
        val journal = nativeLegacyMembershipJournal(scope, null, prepared.pendingMembershipReceipts, setOf(owner.id, child.id))
        val archive = NativeHostDocument.archive(doc).also { it.getJSONObject("document").put("nativeLegacyMembershipPending", journal) }
        val action = JSONObject().put("type", "import_legacy_sync").put("scope", scope.accountID)
            .put("ownerProfileId", owner.id).put("material", prepared.material)
        VortxNativeRuntime.create(bindings, owner.id, owner.name).use { runtime ->
            assertTrue(JSONObject(runtime.dispatch(JSONObject().put("type", "bind_sync_scope").put("scope", scope.accountID).toString())).getBoolean("ok"))
            val accepted = JSONObject(runtime.dispatch(action.toString()))
            assertTrue("Prepared native import rejected: $accepted", accepted.getBoolean("ok"))
        }
        val testRoot = java.nio.file.Files.createDirectories(java.io.File("build").toPath())
        val directory = java.nio.file.Files.createTempDirectory(testRoot, "legacy-membership-").toFile()
        val key = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = VortxEncryptedCheckpointStore(directory) { key }
        fun assertRestored(session: VortxNativeSession) {
            val state = session.read().state
            assertEquals(2, state.getJSONObject("roster").getJSONObject("profiles").length())
            val installed = session.resolve(JSONObject().put("kind", "installed_addons").put("profileId", owner.id)).getJSONArray("addons")
            assertEquals(1, installed.length()); assertEquals(live, installed.getJSONObject(0).getString("transportUrl"))
            assertTrue(NativeHostPreferences.equal(journal, state.getJSONObject("hostDocument").getJSONObject("nativeLegacyMembershipPending")))
            assertEquals(1.00001, state.getJSONObject("hostDocument").getJSONObject("vortx").getJSONArray("library").getJSONObject(0).getDouble("t"), 0.0)
        }
        VortxNativeSession.open(scope, owner.name, bindings, store, noNetwork(), bootstrapActions = listOf(action), initialHostArchive = archive).use { session ->
            assertRestored(session)
            session.dispatch(listOf(action), hostArchive = archive, notifyMutation = false)
            assertRestored(session)
        }
        assertFalse(directory.listFiles()!!.any { it.readBytes().toString(Charsets.UTF_8).contains(orphan) })
        VortxNativeSession.open(scope, owner.name, bindings, store, noNetwork()).use(::assertRestored)
        val account = com.vortx.android.sync.SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 1)
        val accountScope = VortxAccountScope("account.${account.id}", owner.id)
        val coordinatorDirectory = java.nio.file.Files.createTempDirectory(testRoot, "legacy-coordinator-").toFile()
        val coordinatorStore = VortxEncryptedCheckpointStore(coordinatorDirectory) { key }
        fun coordinator() = NativeAccountCoordinator(bindings, coordinatorStore, { noNetwork() }, { it == account }, { it() }, {})
        val accountDocument = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(doc)).also {
            it.getJSONObject("vortx").put("roster", JSONArray().put(owner.encode()).put(child.encode())).put("rosterModified", 1720000000.1234)
        }
        var gateway = coordinator()
        try {
            assertTrue(gateway.applyDocument(account, accountDocument) { true })
            val firstJournal = gateway.session().read().state.getJSONObject("hostDocument").getJSONObject("nativeLegacyMembershipPending")
            assertEquals(4, firstJournal.getJSONArray("receipts").length())
            accountDocument.put("unrelatedProgress", 99.123)
            assertTrue(gateway.applyDocument(account, accountDocument) { true })
            assertTrue(NativeHostPreferences.equal(firstJournal,
                gateway.session().read().state.getJSONObject("hostDocument").getJSONObject("nativeLegacyMembershipPending")))
            gateway.retire(); gateway = coordinator()
            assertTrue(gateway.reopenCheckpoint(account) { true })
            assertTrue(gateway.applyDocument(account, accountDocument) { true })
            val cold = gateway.session().read().state
            assertTrue(NativeHostPreferences.equal(firstJournal, cold.getJSONObject("hostDocument").getJSONObject("nativeLegacyMembershipPending")))
            val stored = accountScope.validateSnapshot(requireNotNull(coordinatorStore.read(accountScope)))
            assertTrue(NativeHostPreferences.equal(firstJournal, stored.getJSONObject("hostDocument").getJSONObject("nativeLegacyMembershipPending")))
            val installed = gateway.session().resolve(JSONObject().put("kind", "installed_addons").put("profileId", owner.id)).getJSONArray("addons")
            assertEquals(1, installed.length()); assertEquals(live, installed.getJSONObject(0).getString("transportUrl"))
            assertTrue(NativeHostPreferences.equal(accountDocument.getJSONObject("vortx"), cold.getJSONObject("hostDocument").getJSONObject("vortx")))
            assertTrue(runCatching { gateway.applyDocument(account, JSONObject(accountDocument.toString()).put("nativeLegacyMembershipPending", firstJournal)) { true } }.isFailure)
            gateway.retire(); gateway = coordinator()
            val wrongScope = NativeProfileOverlayWitness.parseDocument(nativeWatchedDocumentSnapshot(stored))
            wrongScope.getJSONObject("hostDocument").getJSONObject("nativeLegacyMembershipPending").put("scope", "account.foreign")
            coordinatorStore.commit(accountScope, wrongScope.toString())
            assertTrue(runCatching { gateway.reopenCheckpoint(account) { true } }.isFailure)
        } finally { gateway.retire() }
    }

    @Test fun `credential-bearing addon material and malformed carriers fail closed`() {
        val addon = JSONObject().put("transportUrl", "https://example.com/manifest.json")
            .put("manifest", JSONObject().put("id", "test").put("name", "Test").put("accessToken", "secret"))
        held(document(JSONObject().put("addons", JSONArray().put(addon))), "Credential-bearing")
        failure(document(JSONObject().put("library", "not-an-array")), "Malformed array")
        held(document(JSONObject().put("byProfile", JSONObject().put("unknown", JSONObject().put("watched", JSONObject())))), "unknown profile")
    }

    @Test fun `empty intent cannot suppress shipping legacy deletion epoch or reconcile web removal`() {
        val url = "https://example.com/manifest.json"
        val v = JSONObject().put("library", JSONArray().put(movie())).put("deletedLibrary", JSONArray().put("tt123"))
            .put("deletedLibraryTs", JSONObject().put("tt123", JSONObject()))
            .put("deletedAddons", JSONArray().put(url)).put("deletedAddonsTs", JSONObject().put(url, JSONObject()))
        val result = material(document(v))
        assertEquals(1.0, result.getJSONObject("libraries").getJSONObject(owner.id).getJSONArray("intents").getJSONObject(0).getDouble("removedAtMs"), 0.0)
        assertEquals(1.0, result.getJSONObject("addons").getJSONObject(owner.id).getJSONArray("intents").getJSONObject(0).getDouble("removedAtMs"), 0.0)
        held(document(JSONObject().put("deletedAddonsTs", JSONObject().put(url, JSONObject()))).put("webAddonRemovals", JSONArray().put(url)), "Unclocked web")
    }

    @Test fun `legacy lowercase add-on identifier fails despite exact lowercased descriptor match`() {
        fun addon(path: String) = JSONObject().put("transportUrl", "https://example.com/$path/manifest.json")
            .put("manifest", JSONObject().put("id", path).put("name", path).put("version", "1.0.0"))
        held(document(JSONObject().put("addons", JSONArray().put(addon("Config")).put(addon("config")))
            .put("deletedAddons", JSONArray().put("https://example.com/config/manifest.json"))), "Ambiguous legacy add-on")
    }

    @Test fun `removal group does not establish alias equivalence between distinct titles`() {
        val bucket = JSONObject().put("library", JSONArray().put(movie("tt123", 1.0)).put(movie("tt456", 1.0)))
            .put("removed", JSONArray().put(JSONObject().put("keys", JSONArray().put("movie\u001fimdb:tt123").put("movie\u001fimdb:tt456")).put("removedAt", 1000)))
        held(document(JSONObject().put("byProfile", JSONObject().put(child.id, bucket))), "verified title reconciliation")
    }

    @Test fun `owner removed flag never converts viewing timestamp into deletion intent`() {
        val row = movie(time = 1.0).put("removed", true).put("eventEpochMs", 1767225600123)
        held(document(JSONObject().put("library", JSONArray().put(row))), "explicit library removal intent")
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
        val newer = movie(time = 2.0).put("v", "tt123").put("lastWatched", "2026-01-02T00:00:00Z")
            .put("eventEpochMs", 1767312000000.0).also { it.remove("d") }
        val v = JSONObject().put("library", JSONArray().put(prior)).put("byProfile", JSONObject().put(owner.id, JSONObject().put("ownerHistory", JSONArray().put(newer))))
        val row = watchRows(material(document(v))).single()
        assertEquals(2000L, row.getLong("positionMs")); assertEquals(100000L, row.getLong("durationMs"))
        newer.put("lastWatched", prior.getString("lastWatched"))
        newer.put("eventEpochMs", 1767225600123.456)
        held(document(v), "equal-clock progress")
    }

    @Test fun `contradictory owner watched operation at same clock and actor fails closed`() {
        fun intent(watched: Boolean) = JSONObject().put("t", "tt123").put("v", "tt123").put("w", watched).put("u", 100.25).put("a", "same")
        held(document(JSONObject().put("library", JSONArray().put(movie())).put("ownerWatched", JSONObject().put("a", intent(true)).put("b", intent(false)))), "equal-clock owner intent")
    }

    @Test fun `zero overlay mark clocks are ingress absence and cannot suppress legacy watched ids`() {
        val durable = JSONObject().put("tt123", JSONObject().put("w", JSONArray().put("opaque-episode"))
            .put("ma", JSONObject().put("opaque-episode", 0.0)).put("ua", JSONObject().put("opaque-episode", 0.0)))
        val rows = watchRows(material(document(JSONObject().put("byProfile", JSONObject().put(child.id, JSONObject().put("watched", durable))))), child.id)
        val row = rows.single()
        assertTrue(row.getBoolean("watched")); assertFalse(row.has("markedAtMs")); assertFalse(row.has("resetAtMs"))
    }

    @Test fun `owner series mark maps cannot manufacture whole title episode identity`() {
        for (field in listOf("w", "ma", "ua")) {
            val series = JSONObject().put("id", "ttSeries").put("type", "series").put("name", "Series")
            series.put(field, if (field == "w") JSONArray().put("ttSeries") else JSONObject().put("ttSeries", 100.5))
            held(document(JSONObject().put("library", JSONArray().put(series))), "Whole-title mark")
        }
        val marked = watchRows(material(document(JSONObject().put("library", JSONArray().put(movie().put("w", JSONArray().put("tt123")))))))
        assertTrue(marked.single().getBoolean("watched"))
    }
}
