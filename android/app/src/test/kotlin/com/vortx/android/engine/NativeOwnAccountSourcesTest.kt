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
import java.security.MessageDigest
import java.util.Base64

/** Only fake HTTP bodies and opt-in local JNI. Never uses real credentials or providers. */
class NativeOwnAccountSourcesTest {
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
    private val child = UserProfile(id = "11111111-1111-1111-1111-111111111111", name = "Independent", avatar = "🍿", usesOwnAccount = true)
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 7)
    private val scope = VortxAccountScope("account.${account.id}", owner.id)
    private class Journal {
        val values = mutableMapOf<String, String?>(); var available = true; var writes = true
        val credentials = NativeOwnAccountCredentials({ key -> PersistentCredentialSnapshot(
            if (available) PersistentCredentialAvailability.AVAILABLE else PersistentCredentialAvailability.UNAVAILABLE, mapOf(key to values[key])) },
            { key, value -> if (writes) { values[key] = value; true } else false })
    }
    private fun root() = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode()).put(child.encode()))
        .put("library", JSONArray().put(JSONObject().put("id", "owner-title").put("type", "movie").put("name", "Owner only")))
        .put("addons", JSONArray()))
    private fun library(id: String = "own-title", temp: Boolean = false, removed: Boolean = false) = JSONObject().put("result", JSONArray().put(
        JSONObject().put("_id", id).put("type", "movie").put("name", "Independent title").put("temp", temp).put("removed", removed)
            .put("state", JSONObject().put("timeOffset", 20_001).put("duration", 100_000).put("lastWatched", "2026-10-08T10:00:00Z")
                .put("video_id", id).put("timesWatched", 0).put("flaggedWatched", 0)))).toString().toByteArray()
    private fun addons() = JSONObject().put("result", JSONObject().put("addons", JSONArray().put(JSONObject()
        .put("transportUrl", "https://own.example/Config/manifest.json")
        .put("manifest", JSONObject().put("id", "own-addon").put("name", "Own addon").put("version", "1.0.0")
            .put("types", JSONArray().put("movie")).put("resources", JSONArray().put("stream")).put("catalogs", JSONArray()))
        .put("flags", JSONObject().put("official", false).put("protected", false))))).toString().toByteArray()
    private fun producer(library: ByteArray = library(), addons: ByteArray = addons(),
                         after: (String) -> Unit = {}): NativeOwnAccountProducer = NativeOwnAccountProducer { path, body ->
        val response = when (path) {
            "login" -> """{"result":{"authKey":"fixture-token"}}""".toByteArray()
            "getUser" -> { assertEquals("fixture-token", body.getString("authKey")); """{"result":{"_id":"verified-stream-user"}}""".toByteArray() }
            "datastoreGet" -> { assertEquals("libraryItem", body.getString("collection")); assertEquals(true, body.get("all")); library }
            "addonCollectionGet" -> { assertEquals(false, body.get("update")); addons }
            else -> error("Unexpected endpoint")
        }; after(path); response
    }
    private suspend fun capture(journal: Journal, profile: UserProfile = child, admission: (() -> Boolean) -> Boolean = { it() }) =
        producer().signIn(journal.credentials, account, profile.id, "fixture@example.invalid", "fake-password", admission)

    @Test fun `producer hashes exact bodies plus only authenticated UUID overlay`() = runBlocking {
        val journal = Journal(); val capture = capture(journal)
        val raw = library(); val addonRaw = addons(); val document = root()
        document.getJSONObject("vortx").put("byProfile", JSONObject()
            .put(child.id, JSONObject().put("watched", JSONObject().put("own-title", JSONObject().put("w", JSONArray().put("own-title")))))
            .put(owner.id, JSONObject().put("private", "owner-only")))
        val source = producer(raw, addonRaw).fetch(capture, document)
        val bytes = Base64.getDecoder().decode(source.archiveBase64()); val envelope = JSONObject(String(bytes))
        assertEquals(2, envelope.getInt("schemaVersion"))
        assertArrayEquals(raw, Base64.getDecoder().decode(envelope.getString("libraryResponseBase64")))
        assertArrayEquals(addonRaw, Base64.getDecoder().decode(envelope.getString("addonsResponseBase64")))
        val slice = String(Base64.getDecoder().decode(envelope.getString("profileOverlayBase64")))
        assertFalse(slice.contains("owner-only")); assertFalse(slice.contains(owner.id)); assertTrue(slice.contains(child.id))
        assertEquals(MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }, source.digest)
        val material = nativeLegacyMaterial(document, listOf(owner, child), 1.0, listOf(source), accountScope = scope)
        assertEquals(2, material.getInt("schemaVersion"))
        assertEquals("own", material.getJSONArray("roster").getJSONObject(1).getJSONObject("account").getString("kind"))
        val own = material.getJSONObject("libraries").getJSONObject(child.id).getJSONArray("items")
        assertEquals(1, own.length()); assertEquals("own-title", own.getJSONObject(0).getString("id"))
        assertFalse(material.toString().contains("fixture-token")); assertFalse(material.toString().contains("fake-password"))
        assertEquals(20_001L, material.getJSONObject("watches").getJSONArray(child.id).getJSONObject(0).getLong("positionMs"))
    }

    @Test fun `same UID requires separate complete buckets for each exact UUID`() = runBlocking {
        val journal = Journal(); val second = child.copy(id = "22222222-2222-2222-2222-222222222222")
        val a = producer().fetch(capture(journal), root())
        val b = producer(library("second-title")).fetch(capture(journal, second), root())
        val material = nativeLegacyMaterial(root(), listOf(owner, child, second), 1.0, listOf(a, b), accountScope = scope)
        assertEquals(2, material.getJSONObject("ownAccountSources").length())
        assertEquals("own-title", material.getJSONObject("libraries").getJSONObject(child.id).getJSONArray("items").getJSONObject(0).getString("id"))
        assertEquals("second-title", material.getJSONObject("libraries").getJSONObject(second.id).getJSONArray("items").getJSONObject(0).getString("id"))
        assertTrue(runCatching { nativeLegacyMaterial(root(), listOf(owner, child, second), 1.0, listOf(a), accountScope = scope) }.isFailure)
        assertTrue(runCatching { nativeLegacyMaterial(root(), listOf(owner, child), 1.0, listOf(a, a), accountScope = scope) }.isFailure)
        assertTrue(runCatching { nativeLegacyMaterial(root(), listOf(owner, child), 1.0, listOf(a), accountScope = scope.copy(accountID = "foreign")) }.isFailure)
    }

    @Test fun `every async boundary and postfetch credential ABA revokes captured source`() = runBlocking {
        for (boundary in listOf("getUser", "datastoreGet", "addonCollectionGet")) {
            val journal = Journal(); val captured = capture(journal)
            assertTrue(runCatching { producer(after = { if (it == boundary) journal.credentials.invalidateContext() }).fetch(captured, root()) }.isFailure)
        }
        val journal = Journal(); val captured = capture(journal); val source = producer().fetch(captured, root())
        capture(journal) // Same exact token bytes, new login epoch and confirmed record revision.
        assertTrue(runCatching { source.withActive { error("stale commit must not run") } }.exceptionOrNull()?.message?.contains("capture changed") == true)
        assertTrue(runCatching { nativeLegacyMaterial(root(), listOf(owner, child), 1.0, listOf(source), accountScope = scope) }.isFailure)
    }

    @Test fun `failed secure writes and unavailable reads never produce a credential capture`() = runBlocking {
        val failed = Journal().apply { writes = false }
        assertTrue(runCatching { capture(failed) }.isFailure); assertTrue(failed.values.isEmpty())
        val missing = Journal().apply { available = false }
        assertTrue(runCatching { missing.credentials.capture(account, child.id, "verified-stream-user", null) { it() } }.isFailure)
        val journal = Journal(); var current = true; val captured = capture(journal, admission = { current && it() })
        current = false
        assertTrue(runCatching { producer().fetch(captured, root()) }.isFailure)
        assertNull(journal.credentials.capture(account.copy(id = "00000000-0000-0000-0000-000000000789"), child.id, "verified-stream-user", null) { it() })
    }

    @Test fun `malformed partial and credential bearing response cannot become empty authenticated sources`() = runBlocking {
        val journal = Journal(); val captured = capture(journal)
        for (raw in listOf("{}", "{\"result\":{}}", "{\"result\":[],\"next\":\"page\"}",
            "{\"result\":[{\"_id\":\"x\",\"type\":\"movie\",\"authKey\":\"secret\"}]}")) {
            assertTrue(runCatching { producer(raw.toByteArray()).fetch(captured, root()) }.isFailure)
        }
        assertTrue(runCatching { producer(addons = "{\"result\":{}}".toByteArray()).fetch(captured, root()) }.isFailure)
        val encodedCredential = Base64.getEncoder().encodeToString("{\"authKey\":\"fixture-secret\"}".toByteArray())
        val disguised = JSONObject(String(library())).also { it.getJSONArray("result").getJSONObject(0).put("name", encodedCredential) }
        assertTrue(runCatching { producer(disguised.toString().toByteArray()).fetch(captured, root()) }.isFailure)
        val empty = producer("{\"result\":[]}".toByteArray(), "{\"result\":{\"addons\":[]}}".toByteArray()).fetch(captured, root())
        val material = nativeLegacyMaterial(root(), listOf(owner, child), 1.0, listOf(empty), accountScope = scope)
        assertEquals(0, material.getJSONObject("libraries").getJSONObject(child.id).getJSONArray("items").length())
        assertEquals(0, material.getJSONObject("addons").getJSONObject(child.id).getJSONArray("items").length())
    }

    @Test fun `temporary and removed full-source rows preserve watches without manufacturing saved membership`() = runBlocking {
        for (removed in listOf(false, true)) {
            val journal = Journal(); val source = producer(library(temp = !removed, removed = removed)).fetch(capture(journal), root())
            val material = nativeLegacyMaterial(root(), listOf(owner, child), 1.0, listOf(source), accountScope = scope)
            val bucket = material.getJSONObject("libraries").getJSONObject(child.id)
            assertEquals(0, bucket.getJSONArray("items").length())
            assertEquals(1, material.getJSONObject("watches").getJSONArray(child.id).length())
            if (removed) assertEquals(1, bucket.getJSONArray("intents").getJSONObject(0).getInt("removedAtMs"))
            else assertEquals(0, bucket.getJSONArray("intents").length())
        }
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
    @Test fun `real kernel validates credentialless own buckets and source bound local replay`() = runBlocking {
        val bindings = bindings(); val journal = Journal(); val document = root()
        val source = producer().fetch(capture(journal), document)
        val sourceBytes = Base64.getDecoder().decode(source.archiveBase64())
        val material = nativeLegacyMaterial(document, listOf(owner, child), 1.0, listOf(source), accountScope = scope)
        VortxNativeRuntime.create(bindings, owner.id, owner.name).use { runtime ->
            withNativeOwnAccountSources(listOf(source)) {
                assertTrue(JSONObject(runtime.dispatch(JSONObject().put("type", "bind_sync_scope").put("scope", scope.accountID).toString())).getBoolean("ok"))
                assertTrue(JSONObject(runtime.dispatch(JSONObject().put("type", "import_legacy_sync").put("scope", scope.accountID)
                    .put("ownerProfileId", owner.id).put("material", material).toString())).getBoolean("ok"))
            }
            val state = JSONObject(runtime.stateJson()); val sync = state.getJSONObject("nativeSync")
            assertEquals(3, sync.getInt("schemaVersion")); assertEquals(2, sync.getJSONObject("legacyImport").getInt("schemaVersion"))
            assertTrue(NativeProfileAccess.projection(VortxNativeRead(VortxNativeOwner(scope, owner.id, 0), state)).profiles.single { it.id == child.id }.usesOwnAccount)
            val playback = JSONObject(runtime.resolve(JSONObject().put("kind", "profile_playback").put("profileId", child.id).toString()))
            assertEquals("own-title", playback.getJSONArray("continueWatching").getJSONObject(0).getString("metaId"))
            val addons = JSONObject(runtime.resolve(JSONObject().put("kind", "installed_addons").put("profileId", child.id).toString()))
            assertEquals("own-addon", addons.getJSONArray("addons").getJSONObject(0).getJSONObject("manifest").getString("id"))
            journal.credentials.invalidateContext()
            val peer = NativeOwnAccountBaseline.validate(bindings, scope, sync)
            val peerMaterial = nativeLegacyMaterial(document, listOf(owner, child), 1.0, retainedOwnAccounts = peer, accountScope = scope)
            assertTrue(NativeHostPreferences.equal(peer.proof(child.id), peerMaterial.getJSONObject("ownAccountSources").get(child.id)))
            assertEquals("verified-stream-user", peer.proof(child.id).getString("verifiedStreamingUid"))
            val retained = NativeOwnAccountBaseline.validate(bindings, scope, sync, mapOf(child.id to sourceBytes))
            val cold = nativeLegacyMaterial(document, listOf(owner, child), 1.0, retainedOwnAccounts = retained, accountScope = scope)
            // The kernel canonicalizes optional defaults. Reuse its exact typed own tuple, not
            // the pre-normalized host JSON spelling, and prove semantic replay with the kernel.
            for (kind in listOf("addons", "libraries", "watches", "identityLinks")) {
                assertTrue(NativeHostPreferences.equal(retained.bucket(kind, child.id), cold.getJSONObject(kind).get(child.id)))
            }
            assertTrue(NativeHostPreferences.equal(retained.proof(child.id), cold.getJSONObject("ownAccountSources").get(child.id)))
            val replay = JSONObject(runtime.dispatch(JSONObject().put("type", "import_legacy_sync").put("scope", scope.accountID)
                .put("ownerProfileId", owner.id).put("material", cold).toString()))
            assertTrue(replay.toString(), replay.getBoolean("ok"))
            assertTrue(runCatching { NativeOwnAccountBaseline.validate(bindings, scope.copy(accountID = "foreign"), sync) }.isFailure)
            val corrupt = JSONObject(sync.toString())
            corrupt.getJSONObject("legacyImport").getJSONObject("baseline").getJSONObject("ownAccountSources").getJSONObject(child.id).put("verifiedStreamingUid", "forged")
            assertTrue(runCatching { NativeOwnAccountBaseline.validate(bindings, scope, corrupt) }.isFailure)
            VortxNativeRuntime.hydrate(bindings, state.toString()).use { reopened ->
                assertEquals("verified-stream-user", JSONObject(reopened.stateJson()).getJSONObject("roster").getJSONObject("profiles").getJSONObject(child.id)
                    .getJSONObject("account").getString("value"))
            }
        }
    }

    @Test fun `unchanged archived own overlay reopens without credentials but unproven overlay cannot acknowledge edits`() = runBlocking {
        val bindings = bindings(); val journal = Journal(); val document = root()
        document.getJSONObject("vortx").put("byProfile", JSONObject().put(child.id, JSONObject()
            .put("library", JSONArray().put(JSONObject().put("id", "own-title").put("type", "movie")
                .put("t", 30).put("d", 100).put("v", "own-title").put("lastWatched", "2026-10-08T11:00:00Z")))))
        val source = producer().fetch(capture(journal), document)
        val bytes = Base64.getDecoder().decode(source.archiveBase64())
        val changed = JSONObject(document.toString()).also { it.getJSONObject("vortx").getJSONObject("byProfile")
            .getJSONObject(child.id).getJSONArray("library").getJSONObject(0).put("t", 45) }
        // Same credential generation does not prove that the authenticated overlay stayed current.
        assertTrue(runCatching { nativeLegacyMaterial(changed, listOf(owner, child), 1.0, listOf(source), accountScope = scope) }.isFailure)
        val material = nativeLegacyMaterial(document, listOf(owner, child), 1.0, listOf(source), accountScope = scope)
        VortxNativeRuntime.create(bindings, owner.id, owner.name).use { runtime ->
            assertTrue(JSONObject(runtime.dispatch(JSONObject().put("type", "bind_sync_scope").put("scope", scope.accountID).toString())).getBoolean("ok"))
            val imported = JSONObject(runtime.dispatch(JSONObject().put("type", "import_legacy_sync").put("scope", scope.accountID)
                .put("ownerProfileId", owner.id).put("material", material).toString()))
            assertTrue(imported.toString(), imported.getBoolean("ok"))
            val sync = JSONObject(runtime.stateJson()).getJSONObject("nativeSync")
            val query = JSONObject().put("kind", "profile_playback").put("profileId", child.id).toString()
            assertEquals(30_000L, JSONObject(runtime.resolve(query)).getJSONArray("continueWatching").getJSONObject(0).getLong("offsetMs"))
            journal.credentials.invalidateContext()
            val local = NativeOwnAccountBaseline.validate(bindings, scope, sync, mapOf(child.id to bytes))
            val unchanged = nativeLegacyMaterial(document, listOf(owner, child), 1.0, retainedOwnAccounts = local, accountScope = scope)
            assertTrue(NativeHostPreferences.equal(local.bucket("watches", child.id), unchanged.getJSONObject("watches").get(child.id)))
            val before = runtime.stateJson()
            assertTrue(runCatching { nativeLegacyMaterial(changed, listOf(owner, child), 1.0, retainedOwnAccounts = local, accountScope = scope) }.isFailure)
            val peer = NativeOwnAccountBaseline.validate(bindings, scope, sync)
            val peerMaterial = nativeLegacyMaterial(document, listOf(owner, child), 1.0, retainedOwnAccounts = peer, accountScope = scope)
            assertTrue(NativeHostPreferences.equal(peer.bucket("watches", child.id), peerMaterial.getJSONObject("watches").get(child.id)))
            assertTrue(runCatching { nativeLegacyMaterial(changed, listOf(owner, child), 1.0, retainedOwnAccounts = peer, accountScope = scope) }.isFailure)
            assertEquals(before, runtime.stateJson()) // Valid native account remains visible unchanged.
            assertEquals(30_000L, JSONObject(runtime.resolve(query)).getJSONArray("continueWatching").getJSONObject(0).getLong("offsetMs"))
            val bad = bytes.copyOf().also { it[it.lastIndex] = '!'.code.toByte() }
            assertTrue(runCatching { NativeOwnAccountBaseline.validate(bindings, scope, sync, mapOf(child.id to bad)) }.isFailure)
        }
    }
}
