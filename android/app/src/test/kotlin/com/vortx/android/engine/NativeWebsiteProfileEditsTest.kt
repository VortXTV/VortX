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
            JSONObject().put("owner", JSONObject().put("avatar", "moon")), JSONObject())
        val avatar = result.host.getJSONObject("document").getJSONObject("profiles").getJSONObject("owner").getJSONObject("fields").getJSONObject("avatar")
        assertEquals(8L, avatar.getLong("clock")); assertEquals(id, avatar.getString("actor")); assertEquals("🍿", avatar.getString("value"))
        assertEquals("a".repeat(64), result.certificates.getString(id))
    }

    @Test fun `changed host base conflicts without manufacturing certificate and raw source stays sealable`() {
        val local = NativeHostPreferences.recordProfiles(scope, NativeHostPreferences.local(scope), JSONObject(),
            JSONObject().put("owner", JSONObject().put("avatar", "later")))
        assertTrue(runCatching { NativeWebsiteProfileEdits.admit(scope, event(), response(), local,
            JSONObject().put("owner", JSONObject().put("avatar", "moon")), JSONObject()) }.exceptionOrNull() is NativeWebsiteProfileEdits.Conflict)
        val unsupportedButCredentialFree = JSONObject().put("eventId", "legacy-pending").put("unknownFuture", true)
        val retained = NativeWebsiteProfileEdits.retain(scope, JSONObject().put("events", JSONArray()), unsupportedButCredentialFree)
        assertEquals(1, retained.getJSONArray("events").length())
    }

    @Test fun `carrier requires version two and object events`() {
        assertEquals(1, NativeWebsiteProfileEdits.events(JSONObject().put("profileEditEvents", JSONObject().put("schemaVersion", 2).put("events", JSONArray().put(event())))).size)
        assertTrue(runCatching { NativeWebsiteProfileEdits.events(JSONObject().put("profileEditEvents", JSONObject().put("schemaVersion", 1).put("events", JSONArray()))) }.isFailure)
        assertTrue(runCatching { NativeWebsiteProfileEdits.events(JSONObject().put("profileEditEvents", JSONObject().put("schemaVersion", 2).put("events", JSONArray().put("bad")))) }.isFailure)
    }
}
