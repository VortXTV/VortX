package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Actual reviewed schema4 JNI + deterministic fake authenticated responses, no provider access. */
class NativeAccountRebindTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 7)
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
    private val child = UserProfile(id = "11111111-1111-1111-1111-111111111111", name = "Independent", avatar = "🍿", usesOwnAccount = true)
    private val scope = VortxAccountScope("account.${account.id}", owner.id)
    private class Store : VortxCheckpointStore {
        var value: String? = null; var fail = false; var failAfterInstall = false
        override fun read(scope: VortxAccountScope) = value
        override fun commit(scope: VortxAccountScope, snapshot: String) {
            check(!fail) { "Fixture checkpoint failure" }; scope.validateSnapshot(snapshot); value = snapshot
            check(!failAfterInstall) { "Fixture fsync failure after install" }
        }
    }
    private class Journal {
        val values = mutableMapOf<String, String?>()
        val credentials = NativeOwnAccountCredentials({ key -> PersistentCredentialSnapshot(PersistentCredentialAvailability.AVAILABLE, mapOf(key to values[key])) },
            { key, value -> values[key] = value; true })
    }
    private fun bindings(): VortxRuntimeBindings {
        assumeTrue(System.getenv("VORTX_JNI_SYNC") == "1" && !System.getenv("VORTX_JNI_LIBRARY").isNullOrBlank())
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        return object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
    }
    private fun transport() = object : VortxResourceTransport {
        override fun makeCancellation(): VortxResourceCancellation = error("No resource request")
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network")
    }
    private fun session(store: Store, bindings: VortxRuntimeBindings): VortxNativeSession {
        val root = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode()))
            .put("library", JSONArray()).put("addons", JSONArray()))
        val material = nativeLegacyMaterial(root, listOf(owner), 0.0)
        return VortxNativeSession.open(scope, owner.name, bindings, store, transport(),
            bootstrapActions = if (store.value == null) listOf(JSONObject().put("type", "import_legacy_sync").put("scope", scope.accountID)
                .put("ownerProfileId", owner.id).put("material", material)) else emptyList(),
            initialHostArchive = if (store.value == null) NativeHostDocument.archive(root) else null)
    }
    private fun producer(token: String = "fake-a", uid: String = "uid-a", empty: Boolean = false, after: (String) -> Unit = {}) = NativeOwnAccountProducer { path, body ->
        val response = when (path) {
            "login" -> JSONObject().put("result", JSONObject().put("authKey", token))
            "getUser" -> { assertEquals(token, body.getString("authKey")); JSONObject().put("result", JSONObject().put("_id", uid)) }
            "datastoreGet" -> JSONObject().put("result", if (empty) JSONArray() else JSONArray().put(JSONObject().put("_id", "title-$uid").put("type", "movie").put("name", "Title $uid")
                .put("state", JSONObject().put("timeOffset", 20_000).put("duration", 100_000).put("video_id", "title-$uid").put("lastWatched", "2026-10-08T10:00:00Z"))))
            "addonCollectionGet" -> JSONObject().put("result", JSONObject().put("addons", JSONArray()))
            else -> error("Unexpected request")
        }; after(path); response.toString().toByteArray()
    }
    private suspend fun link(session: VortxNativeSession, journal: Journal, producer: NativeOwnAccountProducer = producer()) =
        NativeStreamingAccountLink(journal.credentials, producer).signIn(session, account, child.id, "fake@example.invalid", "fake-password", { it() }, { it() })

    @Test fun `pending profile and verified native CAS commit together with proof and immutable selected credential`() = runBlocking {
        val bindings = bindings(); val store = Store(); val journal = Journal()
        session(store, bindings).use { session ->
            val access = NativeProfileAccess { session }; access.save(child, true)
            val pending = NativeAccountBinding.read(session.read().state, child.id)
            assertEquals("pending_own", pending.kind); assertNull(pending.streamingUID)
            assertTrue(access.read().profiles.single { it.id == child.id }.usesOwnAccount)
            val oldOwner = session.read().owner
            link(session, journal)
            val read = session.read(); val selected = NativeAccountBinding.read(read.state, child.id)
            assertEquals("own", selected.kind); assertEquals("uid-a", selected.streamingUID)
            assertEquals(pending.revision + 1, selected.revision)
            assertNotEquals(oldOwner, read.owner)
            val capture = journal.credentials.capture(account, child.id, "uid-a", selected.transactionID) { it() }!!
            assertEquals("fake-a", capture.request(JSONObject()).getString("authKey"))
            assertFalse(store.value!!.contains("fake-a")); assertFalse(store.value!!.contains("fake-password"))
            val baseline = NativeOwnAccountBaseline.validate(bindings, scope, read.state.getJSONObject("nativeSync"))
            assertEquals("uid-a", baseline.proof(child.id).getString("verifiedStreamingUid"))
            assertTrue(runCatching { baseline.requireOverlayUnchanged(JSONObject(), child.id) }.isFailure)
            assertFalse(baseline.proof(child.id).has("profileOverlaySha256"))
            assertEquals("title-uid-a", baseline.bucket("libraries", child.id).let { it as JSONObject }.getJSONArray("items").getJSONObject(0).getString("id"))
        }
        session(store, bindings).use { reopened ->
            assertEquals("uid-a", NativeAccountBinding.read(reopened.read().state, child.id).streamingUID)
            assertEquals("uid-a", reopened.read().state.getJSONObject("hostDocument").getJSONObject("authenticatedOwnAccountSources")
                .getJSONObject(child.id).getString("verifiedStreamingUid"))
        }
    }

    @Test fun `failed CAS checkpoint leaves old credential and native selection intact while candidate is inactive`() = runBlocking {
        val bindings = bindings(); val store = Store(); val journal = Journal()
        session(store, bindings).use { session ->
            NativeProfileAccess { session }.save(child, true); link(session, journal)
            val old = session.read(); val selected = NativeAccountBinding.read(old.state, child.id); val bytes = store.value
            store.fail = true
            assertTrue(runCatching { link(session, journal, producer("fake-b", "uid-a")) }.isFailure)
            assertEquals(bytes, store.value); assertEquals(old.owner, session.read().owner)
            assertTrue(selected.matches(NativeAccountBinding.read(session.read().state, child.id)))
            assertEquals("fake-a", journal.credentials.capture(account, child.id, "uid-a", selected.transactionID) { it() }!!.request(JSONObject()).getString("authKey"))
            assertEquals(2, journal.values.size) // Candidate remains sealed but has no selected pointer.
        }
    }

    @Test fun `same UID successful relink rotates owner and stale source cannot cross profile ABA`() = runBlocking {
        val bindings = bindings(); val store = Store(); val journal = Journal()
        session(store, bindings).use { session ->
            val access = NativeProfileAccess { session }; access.save(child, true); link(session, journal)
            val before = session.read().owner; val first = NativeAccountBinding.read(session.read().state, child.id)
            link(session, journal, producer("fake-b", "uid-a"))
            val second = NativeAccountBinding.read(session.read().state, child.id)
            assertNotEquals(first.transactionID, second.transactionID); assertNotEquals(before, session.read().owner)
            val bytes = store.value
            assertTrue(runCatching { link(session, journal, producer("fake-c", "uid-c") { path ->
                if (path == "addonCollectionGet") { access.select(child.id); access.select(owner.id) }
            }) }.isFailure)
            assertTrue(second.matches(NativeAccountBinding.read(session.read().state, child.id)))
            assertFalse(store.value!!.contains("uid-c"))
            assertNotNull(bytes)
        }
    }

    @Test fun `shared own A own B and A restore retain separate library slots`() = runBlocking {
        val bindings = bindings(); val store = Store(); val journal = Journal()
        session(store, bindings).use { session ->
            val access = NativeProfileAccess { session }; access.save(child, true); link(session, journal)
            // Legacy A remains in the authenticated UUID carrier after native account changes.
            // It must stay archived, never become B's progress or membership via UUID matching.
            val archive = session.read().state.getJSONObject("hostDocument")
            archive.getJSONObject("vortx").put("byProfile", JSONObject().put(child.id, JSONObject()
                .put("library", JSONArray().put(JSONObject().put("id", "a-only-overlay").put("type", "movie").put("t", 45).put("d", 100)))
                .put("watched", JSONObject().put("a-only-overlay", JSONObject().put("w", JSONArray().put("a-only-overlay"))))))
            session.dispatch(emptyList(), hostArchive = NativeHostDocument.archive(archive))
            link(session, journal, producer("fake-b", "uid-b"))
            assertEquals("uid-b", NativeAccountBinding.read(session.read().state, child.id).streamingUID)
            val selectedB = NativeOwnAccountBaseline.validate(bindings, scope, session.read().state.getJSONObject("nativeSync"))
            assertFalse(selectedB.bucket("watches", child.id).toString().contains("a-only-overlay"))
            assertFalse(selectedB.bucket("libraries", child.id).toString().contains("a-only-overlay"))
            assertTrue(session.read().state.getJSONObject("hostDocument").toString().contains("a-only-overlay"))
            assertTrue(runCatching { selectedB.requireOverlayUnchanged(archive, child.id) }.isFailure)
            access.save(access.read().profiles.single { it.id == child.id }.copy(usesOwnAccount = false), false)
            assertEquals("shared", NativeAccountBinding.read(session.read().state, child.id).kind)
            link(session, journal, producer("fake-a2", "uid-a"))
            val read = session.read(); assertEquals("uid-a", NativeAccountBinding.read(read.state, child.id).streamingUID)
            val active = NativeOwnAccountBaseline.validate(bindings, scope, read.state.getJSONObject("nativeSync"))
            assertEquals("uid-a", active.proof(child.id).getString("verifiedStreamingUid"))
            assertFalse(active.bucket("libraries", child.id).toString().contains("title-uid-b"))
        }
    }

    @Test fun `different verified UIDs may have identical exact empty response envelopes`() = runBlocking {
        val bindings = bindings(); val store = Store(); val journal = Journal()
        session(store, bindings).use { session ->
            NativeProfileAccess { session }.save(child, true)
            link(session, journal, producer("fake-b", "uid-b", empty = true))
            val b = NativeOwnAccountBaseline.validate(bindings, scope, session.read().state.getJSONObject("nativeSync")).proof(child.id)
            link(session, journal, producer("fake-c", "uid-c", empty = true))
            val c = NativeOwnAccountBaseline.validate(bindings, scope, session.read().state.getJSONObject("nativeSync")).proof(child.id)
            assertEquals(b.getString("sourceDocumentSha256"), c.getString("sourceDocumentSha256"))
            assertEquals("uid-c", NativeAccountBinding.read(session.read().state, child.id).streamingUID)
        }
    }

    @Test fun `typed profile names remain literal but encoded JSON credentials are still excluded`() {
        val record = child.encode()
        assertEquals("Independent", NativeHostDocument.archive(JSONObject().put("profile", record)).getJSONObject("document").getJSONObject("profile").getString("name"))
        record.put("name", java.util.Base64.getEncoder().encodeToString("{\"authKey\":\"fake-secret\"}".toByteArray()))
        assertTrue(NativeHostDocument.archive(JSONObject().put("profile", record)).getJSONArray("excludedCredentialPaths").length() > 0)
        val plist = requireNotNull(com.vortx.android.backup.BinaryPlist.encode(mapOf("authKey" to "fake-secret")))
        record.put("name", java.util.Base64.getEncoder().encodeToString(plist))
        assertTrue(NativeHostDocument.archive(JSONObject().put("profile", record)).getJSONArray("excludedCredentialPaths").length() > 0)
    }

    @Test fun `uncertain installed checkpoint prevents old runtime overwrite until cold native binding recovery`() = runBlocking {
        val bindings = bindings(); val store = Store(); val journal = Journal()
        var installed: NativeAccountBinding? = null
        session(store, bindings).use { session ->
            NativeProfileAccess { session }.save(child, true); link(session, journal)
            val old = NativeAccountBinding.read(session.read().state, child.id)
            store.failAfterInstall = true
            assertTrue(runCatching { link(session, journal, producer("fake-b", "uid-b")) }.isFailure)
            installed = NativeAccountBinding.read(JSONObject(store.value!!), child.id)
            assertEquals("uid-b", installed!!.streamingUID)
            assertEquals("uid-a", NativeAccountBinding.read(session.read().state, child.id).streamingUID)
            assertTrue(session.requiresRecovery()); assertFalse(session.accepts(session.read().owner))
            val sealed = store.value
            store.failAfterInstall = false
            assertTrue(runCatching { session.dispatch(listOf(JSONObject().put("type", "switch_profile").put("id", child.id))) }.isFailure)
            assertEquals(sealed, store.value); assertNotEquals(old.transactionID, installed!!.transactionID)
        }
        session(store, bindings).use { reopened ->
            val recovered = NativeAccountBinding.read(reopened.read().state, child.id)
            assertTrue(recovered.matches(installed!!)); assertFalse(reopened.requiresRecovery())
            assertEquals("fake-b", journal.credentials.capture(account, child.id, "uid-b", recovered.transactionID) { it() }!!.request(JSONObject()).getString("authKey"))
        }
    }

    @Test fun `canonical history hashes are evidence not accidental base64 structures`() {
        val hash = "e9" + "0".repeat(62)
        val sync = JSONObject().put("legacyImport", JSONObject().put("acceptedFingerprints", JSONArray().put(hash))
            .put("ownAccountSourceHistory", JSONObject().put(child.id, JSONObject().put(hash, hash))))
            .put("accountSlots", JSONObject().put(child.id, JSONObject().put("slots", JSONObject().put("opaque-slot", JSONObject()
                .put("sourceHistory", JSONObject().put(hash, hash))))))
        val source = JSONObject().put("nativeSync", sync)
        assertTrue(NativeHostPreferences.equal(source, NativeHostDocument.archive(source).getJSONObject("document")))
        assertTrue(runCatching { NativeHostDocument.archive(JSONObject().put("unqualified", hash)) }.isFailure)
    }
}
