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

    @Test fun `changed event identity conflict wrapper is idempotent and cannot starve later events`() {
        val first = JSONObject().put("eventId", "same").put("value", "A")
        val changed = JSONObject().put("eventId", "same").put("value", "B")
        var pending = NativeWebsiteProfileEdits.retain(scope, JSONObject().put("events", JSONArray()), first)
        pending = NativeWebsiteProfileEdits.retain(scope, pending, changed)
        pending = NativeWebsiteProfileEdits.retain(scope, pending, changed)
        NativeWebsiteProfileEdits.validateRetained(scope, pending, JSONObject())
        assertEquals(2, pending.getJSONArray("events").length())
        pending = NativeWebsiteProfileEdits.retain(scope, pending, JSONObject().put("eventId", "later").put("value", "C"))
        assertEquals(3, pending.getJSONArray("events").length())
    }

    private fun libraryEvent(account: JSONObject = JSONObject().put("kind", "own").put("value", "own-slot-fixture")): JSONObject =
        event().put("libraryAdds", JSONObject().put("owner", JSONArray().put(JSONObject().put("id", "tt123").put("name", "Fixture").put("type", "movie"))))
            .put("accountBindings", JSONObject().put("owner", JSONObject().put("account", account).put("revision", 3).put("transactionId", JSONObject.NULL)))

    private fun admitLibrary(source: JSONObject) = NativeWebsiteProfileEdits.admit(scope, source, response(),
        NativeHostPreferences.local(scope), JSONObject().put("owner", JSONObject().put("avatar", "moon")), JSONObject(), null)

    @Test fun `optional exact website account binding witnesses remain immutable and own attributed`() {
        val cases = listOf(JSONObject().put("kind", "own").put("value", "own-slot-fixture"),
            JSONObject().put("kind", "shared").put("value", "account.test"),
            JSONObject().put("kind", "pending_own"), JSONObject().put("kind", "local_only"))
        for (account in cases) {
            val source = libraryEvent(account)
            val original = source.toString()
            val binding = source.getJSONObject("accountBindings").getJSONObject("owner")
            binding.put("revision", NativeHostPreferences.MAX_CLOCK).put("transactionId", "transaction-fixture")
            val witnessed = source.toString()
            assertEquals("a".repeat(64), admitLibrary(source).certificates.getString(id))
            assertEquals(witnessed, source.toString())
            val retained = NativeWebsiteProfileEdits.retain(scope, JSONObject().put("events", JSONArray()), source)
            assertTrue(NativeHostPreferences.equal(source, retained.getJSONArray("events").getJSONObject(0)))
            assertNotEquals(original, witnessed)
        }
        // Historical events without a witness remain optional; the kernel decides eligibility.
        assertEquals("a".repeat(64), admitLibrary(libraryEvent().also { it.remove("accountBindings") }).certificates.getString(id))
    }

    @Test fun `website account binding malformed enum revision identities and extras fail closed`() {
        val invalidBindings = listOf(
            JSONObject().put("kind", "own"), JSONObject().put("kind", "own").put("value", ""),
            JSONObject().put("kind", "own").put("value", "x".repeat(257)),
            JSONObject().put("kind", "own").put("value", "🍿".repeat(65)),
            JSONObject().put("kind", "shared").put("value", "x".repeat(513)),
            JSONObject().put("kind", "shared").put("value", " padded "),
            JSONObject().put("kind", "shared").put("value", "control\u0085"),
            JSONObject().put("kind", "pending_own").put("value", "invented"),
            JSONObject().put("kind", "local_only").put("unknown", true), JSONObject().put("kind", "unknown"))
        for (binding in invalidBindings) assertTrue(runCatching { admitLibrary(libraryEvent(binding)) }.isFailure)
        for (revision in listOf<Any>(-1, 1.5, "3", NativeHostPreferences.MAX_CLOCK + 1)) {
            val source = libraryEvent()
            source.getJSONObject("accountBindings").getJSONObject("owner").put("revision", revision)
            assertTrue(runCatching { admitLibrary(source) }.isFailure)
        }
        for (transaction in listOf<Any>("", "x".repeat(129), "line\nbreak", 1)) {
            val source = libraryEvent()
            source.getJSONObject("accountBindings").getJSONObject("owner").put("transactionId", transaction)
            assertTrue(runCatching { admitLibrary(source) }.isFailure)
        }
        for (field in listOf("account", "revision", "transactionId")) {
            val source = libraryEvent(); source.getJSONObject("accountBindings").getJSONObject("owner").remove(field)
            assertTrue(runCatching { admitLibrary(source) }.isFailure)
        }
        val extra = libraryEvent(); extra.getJSONObject("accountBindings").getJSONObject("owner").put("unexpected", true)
        assertTrue(runCatching { admitLibrary(extra) }.isFailure)
        val credentials = libraryEvent(); credentials.getJSONObject("accountBindings").getJSONObject("owner").getJSONObject("account").put("token", "not-a-secret-fixture")
        assertTrue(runCatching { admitLibrary(credentials) }.isFailure)
    }

    @Test fun `website account bindings require exact nonempty targets and canonical duplicate rejection`() {
        val missing = libraryEvent().put("accountBindings", JSONObject())
        assertTrue(runCatching { admitLibrary(missing) }.isFailure)
        val unrelated = libraryEvent(); unrelated.getJSONObject("accountBindings").put("child", unrelated.getJSONObject("accountBindings").getJSONObject("owner"))
        assertTrue(runCatching { admitLibrary(unrelated) }.isFailure)
        val emptyTarget = libraryEvent().put("libraryAdds", JSONObject().put("owner", JSONArray()))
        assertTrue(runCatching { admitLibrary(emptyTarget) }.isFailure)
        val nonObject = libraryEvent().put("accountBindings", JSONArray())
        assertTrue(runCatching { admitLibrary(nonObject) }.isFailure)
        val upper = "ABCDEF01-0000-4000-8000-000000000001"
        val lower = upper.lowercase()
        val source = libraryEvent()
        val binding = source.getJSONObject("accountBindings").getJSONObject("owner")
        source.put("libraryAdds", JSONObject().put(upper, JSONArray().put(JSONObject().put("id", "tt123"))))
            .put("accountBindings", JSONObject().put(lower, binding))
        assertEquals("a".repeat(64), admitLibrary(source).certificates.getString(id))
        source.getJSONObject("accountBindings").put(upper, binding)
        assertTrue(runCatching { admitLibrary(source) }.isFailure)
    }

    private val upperProfile = "ABCDEF01-0000-4000-8000-000000000001"
    private val lowerProfile get() = upperProfile.lowercase()
    private fun uuidEvent(): JSONObject = event().also { source ->
        source.put("hostBases", JSONObject().put(lowerProfile, source.getJSONObject("hostBases").getJSONObject("owner")))
        source.getJSONArray("roster").getJSONObject(0).put("id", upperProfile)
    }
    private fun uuidResponse(): JSONObject = response().also { reply ->
        val applied = reply.getJSONArray("events").getJSONObject(0)
        applied.put("hostPatch", JSONObject().put(upperProfile, applied.getJSONObject("hostPatch").getJSONObject("owner")))
    }
    private fun uuidFallback() = JSONObject().put(upperProfile, JSONObject().put("avatar", "moon"))
    private fun uuidAdmit(source: JSONObject, reply: JSONObject = uuidResponse(), local: JSONObject = NativeHostPreferences.local(scope),
        certificates: JSONObject = JSONObject(), receipt: JSONObject? = null) =
        NativeWebsiteProfileEdits.admit(scope, source, reply, local, uuidFallback(), certificates, receipt)

    @Test fun `uppercase sparse patch admits lowercase absent base without changing immutable source or receipt`() {
        val source = uuidEvent(); val reply = uuidResponse()
        val sourceBytes = source.toString(); val replyBytes = reply.toString()
        val sourceHash = hash(NativeWebsiteProfileEdits.canonical(source))
        val basesHash = hash(NativeWebsiteProfileEdits.canonical(source.getJSONObject("hostBases")))
        val replyHash = hash(NativeWebsiteProfileEdits.canonical(reply))
        val applied = uuidAdmit(source, reply)
        val register = applied.host.getJSONObject("document").getJSONObject("profiles").getJSONObject(upperProfile).getJSONObject("fields").getJSONObject("avatar")
        assertEquals(8L, register.getLong("clock")); assertEquals(id, register.getString("actor")); assertEquals("🍿", register.getString("value"))
        assertEquals(sourceBytes, source.toString()); assertEquals(replyBytes, reply.toString())
        assertEquals(sourceHash, hash(NativeWebsiteProfileEdits.canonical(source)))
        assertEquals(basesHash, hash(NativeWebsiteProfileEdits.canonical(source.getJSONObject("hostBases"))))
        assertEquals(replyHash, hash(NativeWebsiteProfileEdits.canonical(reply)))
    }

    @Test fun `lowercase sealed current base admits uppercase patch and paired replay keeps newer null`() {
        val host = NativeHostPreferences.recordProfiles(scope, NativeHostPreferences.local(scope), JSONObject(),
            JSONObject().put(upperProfile, JSONObject().put("avatar", "moon")))
        val groups = host.getJSONObject("document").getJSONObject("profiles")
        groups.put(lowerProfile, groups.remove(upperProfile))
        val entry = groups.getJSONObject(lowerProfile).getJSONObject("fields").getJSONObject("avatar")
        val source = uuidEvent()
        source.getJSONObject("hostBases").getJSONObject(lowerProfile).put("avatar", JSONObject().put("clock", entry.getLong("clock"))
            .put("actor", entry.getString("actor")).put("valueHash", hash("\"moon\"")))
        val hostBytes = host.toString(); val sourceBytes = source.toString()
        val applied = uuidAdmit(source, local = host)
        assertEquals(hostBytes, host.toString()); assertEquals(sourceBytes, source.toString())
        val receipt = uuidResponse().getJSONArray("events").getJSONObject(0).getJSONObject("receipt")
        val paired = uuidAdmit(source, local = applied.host, receipt = receipt)
        assertTrue(NativeHostPreferences.equal(applied.host, paired.host))
        val replay = uuidAdmit(source, local = applied.host, certificates = applied.certificates)
        assertEquals(8L, replay.host.getJSONObject("document").getJSONObject("profiles").getJSONObject(upperProfile)
            .getJSONObject("fields").getJSONObject("avatar").getLong("clock"))
        val newer = JSONObject(applied.host.toString())
        newer.getJSONObject("document").getJSONObject("profiles").getJSONObject(upperProfile).getJSONObject("fields").put("avatar",
            JSONObject().put("clock", 9).put("actor", "00000000-0000-4000-8000-000000000009").put("value", JSONObject.NULL))
        newer.put("counter", 9)
        assertTrue(uuidAdmit(source, local = newer, receipt = receipt).host.getJSONObject("document").getJSONObject("profiles")
            .getJSONObject(upperProfile).getJSONObject("fields").getJSONObject("avatar").isNull("value"))
    }

    @Test fun `canonical duplicate bases patches and sparse rows reject even on replay without mutation`() {
        for (target in listOf("bases", "patch", "rows")) {
            val pairedHost = uuidAdmit(uuidEvent()).host
            val pairedHostBytes = pairedHost.toString()
            val pairedReceipt = uuidResponse().getJSONArray("events").getJSONObject(0).getJSONObject("receipt")
            val source = uuidEvent(); val reply = uuidResponse()
            when (target) {
                "bases" -> source.getJSONObject("hostBases").put(upperProfile, source.getJSONObject("hostBases").getJSONObject(lowerProfile))
                "patch" -> reply.getJSONArray("events").getJSONObject(0).getJSONObject("hostPatch").put(lowerProfile,
                    reply.getJSONArray("events").getJSONObject(0).getJSONObject("hostPatch").getJSONObject(upperProfile))
                else -> source.getJSONArray("roster").put(JSONObject(source.getJSONArray("roster").getJSONObject(0).toString()).put("id", lowerProfile))
            }
            val sourceBytes = source.toString(); val replyBytes = reply.toString()
            val local = NativeHostPreferences.local(scope); val localBytes = local.toString()
            val certificates = JSONObject().put(id, "a".repeat(64)); val certificateBytes = certificates.toString()
            assertTrue(runCatching { uuidAdmit(source, reply, local, certificates) }.isFailure)
            assertTrue(runCatching { uuidAdmit(source, reply, pairedHost, JSONObject(), pairedReceipt) }.isFailure)
            assertEquals(sourceBytes, source.toString()); assertEquals(replyBytes, reply.toString())
            assertEquals(localBytes, local.toString()); assertEquals(certificateBytes, certificates.toString())
            assertEquals(pairedHostBytes, pairedHost.toString())
        }
    }

    @Test fun `canonical base lookup still rejects absent and stale witnesses and nonUUID case differences`() {
        val missing = uuidEvent().put("hostBases", JSONObject())
        val missingLocal = NativeHostPreferences.local(scope); val certificates = JSONObject()
        val missingBytes = missing.toString(); val missingLocalBytes = missingLocal.toString()
        assertTrue(runCatching { uuidAdmit(missing, local = missingLocal, certificates = certificates) }.exceptionOrNull() is NativeWebsiteProfileEdits.Conflict)
        assertEquals(missingBytes, missing.toString()); assertEquals(missingLocalBytes, missingLocal.toString()); assertEquals(0, certificates.length())
        val stale = uuidEvent()
        val local = NativeHostPreferences.recordProfiles(scope, NativeHostPreferences.local(scope), JSONObject(), uuidFallback())
        val staleBytes = stale.toString(); val localBytes = local.toString()
        assertTrue(runCatching { uuidAdmit(stale, local = local, certificates = certificates) }.exceptionOrNull() is NativeWebsiteProfileEdits.Conflict)
        assertEquals(staleBytes, stale.toString()); assertEquals(localBytes, local.toString()); assertEquals(0, certificates.length())
        val exact = event(); exact.put("hostBases", JSONObject().put("OWNER", exact.getJSONObject("hostBases").getJSONObject("owner")))
        assertTrue(runCatching { NativeWebsiteProfileEdits.admit(scope, exact, response(), NativeHostPreferences.local(scope),
            JSONObject().put("owner", JSONObject().put("avatar", "moon")), JSONObject(), null) }.exceptionOrNull() is NativeWebsiteProfileEdits.Conflict)
    }
}
