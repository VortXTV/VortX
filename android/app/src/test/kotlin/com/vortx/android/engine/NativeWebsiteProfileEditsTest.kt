package com.vortx.android.engine

import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeWebsiteProfileEditsTest {
    private val scope = VortxAccountScope("account.test", "owner")
    private val id = "00000000-0000-4000-8000-000000000001"
    private fun hash(canonical: String) = MessageDigest.getInstance("SHA-256").digest(canonical.toByteArray()).joinToString("") { "%02x".format(it) }
    private fun event() = JSONObject().put("eventId", id).put("editedAt", 1001).put("observedNativeClock", 1)
        .put("observedHostClock", 7).put("hostBases", JSONObject().put("owner", JSONObject().put("avatar", JSONObject().put("absent", true).put("valueHash", hash("\"moon\"")))))
        .put("roster", JSONArray().put(JSONObject().put("id", "owner").put("settings", JSONObject().put("avatar", "🍿"))))
        .put("libraryAdds", JSONObject())
    private fun response() = JSONObject().put("ok", true).put("events", JSONArray().put(JSONObject().put("event", "legacy_profile_edits_applied")
        .put("receipt", JSONObject().put("schemaVersion", 1).put("eventId", id).put("source", JSONObject().put("editedAtMs", 1001).put("observedNativeClock", 1)
            .put("fingerprint", "a".repeat(64))).put("acknowledgedPaths", JSONArray()).put("hostPaths", JSONArray()))
        .put("hostPatch", JSONObject().put("owner", JSONObject().put("settings.avatar", "🍿")))))

    @Test fun `exact absent host base admits immutable patch and records event actor`() {
        val result = NativeWebsiteProfileEdits.admit(scope, event(), response(), NativeHostPreferences.local(scope),
            JSONObject().put("owner", JSONObject().put("avatar", "moon")), JSONObject(), null)
        val avatar = result.host.getJSONObject("document").getJSONObject("profiles").getJSONObject("owner").getJSONObject("fields").getJSONObject("avatar")
        assertEquals(8L, avatar.getLong("clock")); assertEquals(id, avatar.getString("actor")); assertEquals("🍿", avatar.getString("value"))
        assertEquals("a".repeat(64), result.certificates.getString(id))
    }

    @Test fun `changed host base conflicts without manufacturing certificate and raw source stays sealable`() {
        val local = NativeHostPreferences.recordProfiles(scope, NativeHostPreferences.local(scope), JSONObject(),
            JSONObject().put("owner", JSONObject().put("avatar", "later")))
        assertTrue(runCatching { NativeWebsiteProfileEdits.admit(scope, event(), response(), local,
            JSONObject().put("owner", JSONObject().put("avatar", "moon")), JSONObject(), null) }.exceptionOrNull() is NativeWebsiteProfileEdits.Conflict)
        val unsupportedButCredentialFree = JSONObject().put("eventId", "legacy-pending").put("unknownFuture", true)
        val retained = NativeWebsiteProfileEdits.retain(scope, JSONObject().put("events", JSONArray()), unsupportedButCredentialFree)
        assertEquals(1, retained.getJSONArray("events").length())
    }

    @Test fun `carrier requires version two and object events`() {
        assertEquals(1, NativeWebsiteProfileEdits.events(JSONObject().put("profileEditEvents", JSONObject().put("schemaVersion", 2).put("events", JSONArray().put(event())))).size)
        assertTrue(runCatching { NativeWebsiteProfileEdits.events(JSONObject().put("profileEditEvents", JSONObject().put("schemaVersion", 1).put("events", JSONArray()))) }.isFailure)
        assertTrue(runCatching { NativeWebsiteProfileEdits.events(JSONObject().put("profileEditEvents", JSONObject().put("schemaVersion", 2).put("events", JSONArray().put("bad")))) }.isFailure)
    }

    @Test fun `legacy aggregate wrapper keeps exact raw source and deterministic migration identity`() {
        val aggregate = JSONObject().put("editedAt", 1001).put("roster", JSONArray().put(JSONObject().put("id", "owner").put("name", "Old dashboard")))
        val pending = NativeWebsiteProfileEdits.legacyPending(aggregate)
        val again = NativeWebsiteProfileEdits.legacyPending(JSONObject(aggregate.toString()))
        assertEquals(pending.getString("eventId"), again.getString("eventId"))
        assertTrue(NativeHostPreferences.equal(aggregate, pending.getJSONObject("legacyAggregate")))
        val migration = NativeWebsiteProfileEdits.legacyMigrationEvent(aggregate, "b".repeat(64))
        assertEquals(pending.getString("eventId"), migration.getString("eventId"))
        assertEquals("b".repeat(64), migration.getString("legacyBootstrapFingerprint"))
        assertFalse(migration.has("observedNativeClock"))
    }

    @Test fun `website hash evidence survives host archive inspection unchanged`() {
        val source = JSONObject().put("profileEditEvents", JSONObject().put("schemaVersion", 2).put("events", JSONArray().put(event())))
        val archived = NativeHostDocument.archive(source).getJSONObject("document")
        assertEquals(hash("\"moon\""), archived.getJSONObject("profileEditEvents").getJSONArray("events").getJSONObject(0)
            .getJSONObject("hostBases").getJSONObject("owner").getJSONObject("avatar").getString("valueHash"))
    }

    @Test fun `canonical JSON matches website commas numbers and unicode vectors`() {
        val vector = JSONObject().put("emoji", "🎬").put("exponent", 1e-7).put("integral", 100000000000000000000.0)
            .put("negativeZero", -0.0).put("nested", JSONObject().put("b", 1).put("a", 2))
            .put("array", JSONArray().put("x").put(1e-7)).put("slash", "https://vortx.tv/a/b")
        assertEquals("{\"array\":[\"x\",1e-7],\"emoji\":\"🎬\",\"exponent\":1e-7,\"integral\":100000000000000000000,\"negativeZero\":0,\"nested\":{\"a\":2,\"b\":1},\"slash\":\"https://vortx.tv/a/b\"}",
            NativeWebsiteProfileEdits.canonical(vector))
    }

    @Test fun `peer receipt needs exact paired host result or a newer host tuple`() {
        val fallback = JSONObject().put("owner", JSONObject().put("avatar", "moon"))
        val applied = NativeWebsiteProfileEdits.admit(scope, event(), response(), NativeHostPreferences.local(scope), fallback, JSONObject(), null)
        val receipt = response().getJSONArray("events").getJSONObject(0).getJSONObject("receipt")
        val replay = NativeWebsiteProfileEdits.admit(scope, event(), response(), applied.host, fallback, JSONObject(), receipt)
        assertEquals("a".repeat(64), replay.certificates.getString(id))
        assertTrue(runCatching { NativeWebsiteProfileEdits.admit(scope, event(), response(), NativeHostPreferences.local(scope), fallback, JSONObject(), receipt) }
            .exceptionOrNull() is NativeWebsiteProfileEdits.Conflict)
        val newer = JSONObject(applied.host.toString())
        newer.getJSONObject("document").getJSONObject("profiles").getJSONObject("owner").getJSONObject("fields").put("avatar",
            JSONObject().put("clock", 9).put("actor", "00000000-0000-4000-8000-000000000009").put("value", JSONObject.NULL))
        newer.put("counter", 9)
        val retainedNewer = NativeWebsiteProfileEdits.admit(scope, event(), response(), newer, fallback, JSONObject(), receipt)
        assertTrue(retainedNewer.host.getJSONObject("document").getJSONObject("profiles").getJSONObject("owner").getJSONObject("fields").getJSONObject("avatar").isNull("value"))
    }
}
