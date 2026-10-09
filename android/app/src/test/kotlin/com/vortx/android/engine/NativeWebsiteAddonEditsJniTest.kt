package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.SessionOwnerSnapshot
import java.io.File
import java.nio.file.Files
import javax.crypto.KeyGenerator
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Only the immutable schema-five JNI fixture. No application, media, provider or network run. */
class NativeWebsiteAddonEditsJniTest {
    private fun bindings(): VortxRuntimeBindings {
        val path = System.getenv("VORTX_JNI_LIBRARY")
        assumeTrue("Website add-on JNI fixture required", System.getenv("VORTX_JNI_SYNC") == "1" && !path.isNullOrBlank())
        System.load(requireNotNull(path))
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
    private fun noNetwork() = object : VortxResourceTransport {
        override fun makeCancellation() = error("No resource request permitted")
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network permitted")
    }
    private class Store : VortxCheckpointStore {
        var value: String? = null
        var installThenFail = false
        override fun read(scope: VortxAccountScope) = value
        override fun commit(scope: VortxAccountScope, snapshot: String) {
            value = snapshot
            if (installThenFail) error("Readback unavailable after durable install")
        }
    }
    private fun installed(session: VortxNativeSession): List<String> {
        val list = session.resolve(JSONObject().put("kind", "installed_addons").put("profileId", session.scope.ownerProfileID)).getJSONArray("addons")
        return (0 until list.length()).map { list.getJSONObject(it).getString("transportUrl") }
    }
    private fun scopedEvent(session: VortxNativeSession, id: String = "0".repeat(31) + "1"): JSONObject {
        val state = session.read().state
        return WebsiteAddonFixtures.event(id).put("scope", session.scope.accountID).put("ownerProfileId", session.scope.ownerProfileID)
            .put("profileId", session.scope.ownerProfileID).put("expectedBinding", NativeAccountBinding.read(state, session.scope.ownerProfileID).json())
            .put("observed", state.getJSONObject("nativeSync").getJSONObject("addons").optJSONObject(session.scope.ownerProfileID)
                ?: JSONObject().put("records", JSONObject()).put("order", JSONObject().put("updatedAt", 0).put("ids", JSONArray())))
    }

    @Test fun `golden raw event receipt survives sealed reopen and replay never revives native uninstall`() {
        val abi = bindings()
        val directory = Files.createTempDirectory(File("build").toPath(), "website-addon-").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = VortxEncryptedCheckpointStore(directory) { key }
        val scope = WebsiteAddonFixtures.scope
        try {
            val event = WebsiteAddonFixtures.event()
            VortxNativeSession.open(scope, "Owner", abi, store, noNetwork(), true).use { session ->
                val originalOwner = session.read().owner
                assertTrue(session.applyWebsiteAddonEdit(event))
                assertFalse(session.accepts(originalOwner))
                val state = session.read().state
                assertEquals(5, state.getJSONObject("nativeSync").getInt("schemaVersion"))
                assertEquals("4698bb16ec9581e729f9fd93e2f7922ae8ad2f07d409dca3ed08a38dc6190a6a", state.getJSONObject("nativeSync")
                    .getJSONObject("websiteAddonReceipts").getJSONObject(event.getString("eventId")).getString("fingerprint"))
                assertEquals(listOf(WebsiteAddonFixtures.url), installed(session))
                session.dispatch(listOf(JSONObject().put("type", "remove_addon").put("profileId", scope.ownerProfileID).put("transportUrl", WebsiteAddonFixtures.url)))
                val afterRemove = session.read().owner
                assertTrue(session.applyWebsiteAddonEdit(event)); assertEquals(afterRemove, session.read().owner)
                assertTrue(installed(session).isEmpty())
                val changed = NativeWebsiteAddonEdits.detached(event).put("counter", "2")
                assertFalse(session.applyWebsiteAddonEdit(changed))
                assertEquals(1, session.read().state.getJSONObject("websiteAddonEditPending").getJSONArray("events").length())
            }
            VortxNativeSession.open(scope, "Owner", abi, store, noNetwork()).use { cold ->
                // A divergent sealed source sharing the ID is never silently discarded in favor
                // of the incoming receipted source. Both stay pending for explicit resolution.
                assertFalse(cold.applyWebsiteAddonEdit(event)); assertTrue(installed(cold).isEmpty())
                assertEquals(2, cold.read().state.getJSONObject("websiteAddonEditPending").getJSONArray("events").length())
                assertEquals("profile_playback", cold.resolveCommitted(JSONObject().put("kind", "profile_playback").put("profileId", scope.ownerProfileID), cold.read().owner).getString("kind"))
            }
        } finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    @Test fun `coordinator queue applies independent event while binding conflict stays pending and baseline cannot revive`() = runBlocking {
        val abi = bindings(); val store = Store()
        val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 1)
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Owner", avatar = "🍿", isOwner = true)
        val oldURL = "https://fixture.invalid/legacy/manifest.json"
        val oldAddon = WebsiteAddonFixtures.descriptor().put("transportUrl", oldURL)
        val document = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode())).put("rosterModified", 1000)
            .put("library", JSONArray()).put("addons", JSONArray().put(oldAddon)))
        fun coordinator() = NativeAccountCoordinator(abi, store, { noNetwork() }, { it == account }, { it() }, {})
        var gateway = coordinator()
        try {
            assertTrue(gateway.applyDocument(account, document) { true })
            gateway.session().dispatch(listOf(JSONObject().put("type", "remove_addon").put("profileId", owner.id).put("transportUrl", oldURL)))
            assertTrue(installed(gateway.session()).isEmpty())
            val event = scopedEvent(gateway.session())
            val conflict = scopedEvent(gateway.session(), "0".repeat(31) + "2").also {
                it.getJSONObject("expectedBinding").put("account", JSONObject().put("kind", "shared").put("value", owner.id))
            }
            document.put("webAddonEdits", WebsiteAddonFixtures.document(conflict, event).getJSONObject("webAddonEdits"))
            assertTrue(gateway.applyDocument(account, document) { true })
            assertEquals(listOf(WebsiteAddonFixtures.url), installed(gateway.session()))
            assertEquals(1, gateway.session().read().state.getJSONObject("websiteAddonEditPending").getJSONArray("events").length())
            val native = gateway.exportDocument(account)!!.nativeSync
            document.put("nativeSync", native)
            gateway.retire(); gateway = coordinator()
            assertTrue(gateway.applyDocument(account, document) { true })
            assertEquals(listOf(WebsiteAddonFixtures.url), installed(gateway.session()))
            assertEquals(1, gateway.session().read().state.getJSONObject("websiteAddonEditPending").getJSONArray("events").length())
            val before = store.value
            val invalid = NativeWebsiteAddonEdits.detached(document).also { it.getJSONObject("webAddonEdits").put("unexpected", true) }
            assertTrue(runCatching { gateway.applyDocument(account, invalid) { true } }.isFailure)
            assertEquals(before, store.value)
        } finally { gateway.retire() }
    }

    @Test fun `cloud pruned queue plus peer receipt clears exact sealed pending warm and cold without revival`() = runBlocking {
        val abi = bindings()
        val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 1)
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Owner", avatar = "🍿", isOwner = true)
        fun document() = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode())).put("rosterModified", 1000)
            .put("library", JSONArray()).put("addons", JSONArray()))
        for (cold in listOf(false, true)) {
            val localStore = Store(); val peerStore = Store()
            var unavailable = true
            val rejecting = object : VortxRuntimeBindings by abi {
                override fun dispatch(handle: Long, action: String): String? = if (unavailable && JSONObject(action).optString("type") == "apply_website_addon_edits")
                    JSONObject().put("ok", false).put("error", "Simulated earlier action unavailable").toString() else abi.dispatch(handle, action)
            }
            fun local() = NativeAccountCoordinator(rejecting, localStore, { noNetwork() }, { it == account }, { it() }, {})
            var gateway = local()
            val peer = NativeAccountCoordinator(abi, peerStore, { noNetwork() }, { it == account }, { it() }, {})
            try {
                assertTrue(gateway.applyDocument(account, document()) { true })
                val event = scopedEvent(gateway.session())
                val queued = document().put("webAddonEdits", WebsiteAddonFixtures.document(event).getJSONObject("webAddonEdits"))
                assertTrue(gateway.applyDocument(account, queued) { true })
                assertEquals(1, gateway.session().read().state.getJSONObject("websiteAddonEditPending").getJSONArray("events").length())
                assertTrue(peer.applyDocument(account, queued) { true })
                peer.session().dispatch(listOf(JSONObject().put("type", "remove_addon").put("profileId", owner.id).put("transportUrl", WebsiteAddonFixtures.url)))
                val pruned = document().put("nativeSync", peer.exportDocument(account)!!.nativeSync)
                    .put("webAddonEdits", WebsiteAddonFixtures.document().getJSONObject("webAddonEdits"))
                if (cold) { gateway.retire(); gateway = local() }
                unavailable = false
                assertTrue(gateway.applyDocument(account, pruned) { true })
                assertEquals(0, gateway.session().read().state.getJSONObject("websiteAddonEditPending").getJSONArray("events").length())
                assertEquals(1, gateway.session().read().state.getJSONObject("nativeSync").getJSONObject("websiteAddonReceipts").length())
                assertTrue(installed(gateway.session()).isEmpty())
            } finally { gateway.retire(); peer.retire() }
        }
    }

    @Test fun `uncertain receipt checkpoint fails stop and cold reopen uses exact installed receipt`() {
        val abi = bindings(); val store = Store(); val scope = WebsiteAddonFixtures.scope
        VortxNativeSession.open(scope, "Owner", abi, store, noNetwork(), true).use { session ->
            val event = scopedEvent(session)
            store.installThenFail = true
            assertTrue(runCatching { session.applyWebsiteAddonEdit(event) }.isFailure)
            assertTrue(session.requiresRecovery())
            assertTrue(session.read().state.getJSONObject("nativeSync").optJSONObject("websiteAddonReceipts")?.length().let { it == null || it == 0 })
            assertTrue(runCatching { session.applyWebsiteAddonEdit(event) }.isFailure)
        }
        store.installThenFail = false
        VortxNativeSession.open(scope, "Owner", abi, store, noNetwork()).use { cold ->
            assertEquals(listOf(WebsiteAddonFixtures.url), installed(cold))
            assertEquals(1, cold.read().state.getJSONObject("nativeSync").getJSONObject("websiteAddonReceipts").length())
        }
    }

    @Test fun `stale captured owner and cancelled final admission cannot commit website receipt`() {
        val abi = bindings(); val store = Store(); val scope = WebsiteAddonFixtures.scope
        VortxNativeSession.open(scope, "Owner", abi, store, noNetwork(), true).use { session ->
            val event = scopedEvent(session); val captured = session.read().owner
            session.dispatch(listOf(JSONObject().put("type", "patch_profile").put("id", scope.ownerProfileID)
                .put("edits", JSONArray().put(JSONObject().put("field", "name").put("value", "New name")))))
            val before = store.value
            assertTrue(runCatching { session.applyWebsiteAddonEdit(event, captured) }.isFailure)
            assertTrue(runCatching { session.applyWebsiteAddonEdit(event, beforeCommit = { throw kotlinx.coroutines.CancellationException("Cancelled") }) }.isFailure)
            assertEquals(before, store.value); assertTrue(installed(session).isEmpty())
        }
    }

    @Test fun `legacy V3 initial import uses shared kernel state without host clock rewriting`() {
        val abi = bindings(); val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Owner", avatar = "🍿", isOwner = true)
        val scope = VortxAccountScope("account.v3", owner.id)
        val v3 = JSONObject().put("version", 3).put("counter", "2").put("eventId", "e9" + "0".repeat(30)).put("state", "removed")
            .put("wallTime", 1000.125).put("legacyRemovedSeen", 300).put("legacyAddedSeen", 200)
        val source = JSONObject().put("vortx", JSONObject().put("addons", JSONArray().put(WebsiteAddonFixtures.descriptor()))
            .put("deletedAddonsTs", JSONObject().put(WebsiteAddonFixtures.url, JSONObject().put("addedAt", 200).put("removedAt", 100).put("intentV3", v3))))
        val material = nativeLegacyMaterial(source, listOf(owner), 1000.0)
        val action = JSONObject().put("type", "import_legacy_sync").put("scope", scope.accountID).put("ownerProfileId", scope.ownerProfileID).put("material", material)
        VortxNativeSession.open(scope, "Owner", abi, Store(), noNetwork(), bootstrapActions = listOf(action)).use { session ->
            assertEquals(5, session.read().state.getJSONObject("nativeSync").getInt("schemaVersion"))
            assertTrue(installed(session).isEmpty())
            assertTrue(NativeHostPreferences.equal(v3, session.read().state.getJSONObject("nativeSync").getJSONObject("legacyImport").getJSONObject("baseline")
                .getJSONObject("addons").getJSONObject(owner.id).getJSONArray("intents").getJSONObject(0).getJSONObject("intentV3")))
        }
    }
}
