package com.vortx.android.engine

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import javax.crypto.KeyGenerator
import org.json.JSONArray
import org.json.JSONObject
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.SessionOwnerSnapshot
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Uses the immutable website-capable JNI fixture; no app, playback, provider, or network starts. */
class NativeWebsiteProfileEditsJniTest {
    private fun load() {
        val path = System.getenv("VORTX_JNI_LIBRARY")
        assumeTrue("Reviewed website JNI fixture required", System.getenv("VORTX_JNI_SYNC") == "1" && !path.isNullOrBlank())
        System.load(requireNotNull(path))
    }
    private fun bindings() = object : VortxRuntimeBindings {
        override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
        override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
        override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
        override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
        override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
        override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
        override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
    }
    private fun noNetwork() = object : VortxResourceTransport {
        override fun makeCancellation() = error("No resource request permitted")
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No network permitted")
    }
    private fun hash(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    @Test fun `real JNI admits exact host base exports kernel receipt and retains only conflict`() {
        load()
        val directory = Files.createTempDirectory(File("build").toPath(), "website-jni-").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = VortxEncryptedCheckpointStore(directory) { key }
        val scope = VortxAccountScope("account.website-fixture", "owner")
        val peerDirectory = Files.createTempDirectory(File("build").toPath(), "website-peer-jni-").toFile()
        val peerKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val peerStore = VortxEncryptedCheckpointStore(peerDirectory) { peerKey }
        try {
            VortxNativeSession.open(scope, "Owner", bindings(), store, noNetwork(), true).use { session ->
                val first = JSONObject().put("eventId", "00000000-0000-4000-8000-000000000001").put("editedAt", 1_000_001)
                    .put("observedNativeClock", 1000).put("observedHostClock", 0)
                    .put("hostBases", JSONObject().put("owner", JSONObject().put("avatar", JSONObject().put("absent", true).put("valueHash", hash("null")))))
                    .put("roster", JSONArray().put(JSONObject().put("id", "owner").put("settings", JSONObject().put("avatar", "🍿")))).put("libraryAdds", JSONObject())
                assertTrue(session.applyWebsiteProfileEdit(first))
                val sync = session.read().state.getJSONObject("nativeSync")
                assertEquals(2, sync.getInt("schemaVersion"))
                val receipts = sync.getJSONObject("legacyProfileEditReceipts")
                assertEquals(1, receipts.length())
                assertEquals("🍿", session.read().state.getJSONObject("hostProfilePreferences").getJSONObject("owner").getString("avatar"))
                val nativeSync = JSONObject(sync.toString())
                val hostPreferences = JSONObject(session.read().state.getJSONObject("nativeHostPreferenceState").getJSONObject("document").toString())
                VortxNativeSession.open(scope, "Owner", bindings(), peerStore, noNetwork(), true).use { peer ->
                    peer.dispatch(listOf(JSONObject().put("type", "merge_native_sync").put("document", nativeSync)), notifyMutation = false,
                        remoteHostPreferences = hostPreferences)
                    assertTrue(peer.applyWebsiteProfileEdit(first))
                    assertEquals(1, peer.read().state.getJSONObject("websiteProfileEditCertificates").length())
                }
                val missingDirectory = Files.createTempDirectory(File("build").toPath(), "website-missing-peer-jni-").toFile()
                val missingKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
                try {
                    VortxNativeSession.open(scope, "Owner", bindings(), VortxEncryptedCheckpointStore(missingDirectory) { missingKey }, noNetwork(), true).use { missing ->
                        missing.dispatch(listOf(JSONObject().put("type", "merge_native_sync").put("document", nativeSync)), notifyMutation = false)
                        assertFalse(missing.applyWebsiteProfileEdit(first))
                        assertEquals(1, missing.read().state.getJSONObject("websiteProfileEditPending").getJSONArray("events").length())
                    }
                } finally { missingDirectory.listFiles()?.forEach { it.delete() }; missingDirectory.delete() }
                val conflicting = JSONObject(first.toString()).put("eventId", "00000000-0000-4000-8000-000000000002").put("editedAt", 1_001_001)
                assertFalse(session.applyWebsiteProfileEdit(conflicting))
                assertEquals(1, session.read().state.getJSONObject("nativeSync").getJSONObject("legacyProfileEditReceipts").length())
                assertEquals(1, session.read().state.getJSONObject("websiteProfileEditPending").getJSONArray("events").length())
            }
        } finally { directory.listFiles()?.forEach { it.delete() }; directory.delete(); peerDirectory.listFiles()?.forEach { it.delete() }; peerDirectory.delete() }
    }

    @Test fun `original legacy aggregate cannot be replaced by a later pull warm or cold`() = kotlinx.coroutines.runBlocking {
        load()
        val directory = Files.createTempDirectory(File("build").toPath(), "website-legacy-jni-").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val checkpoints = VortxEncryptedCheckpointStore(directory) { key }
        val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 1)
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Owner", avatar = "🍿", isOwner = true)
        fun aggregate(name: String) = JSONObject().put("editedAt", 1_000_001).put("roster", JSONArray().put(JSONObject().put("id", owner.id).put("name", name))).put("libraryAdds", JSONObject())
        fun document(edit: JSONObject) = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode()))
            .put("rosterModified", 1000).put("library", JSONArray()).put("addons", JSONArray())).put("profileEdits", edit)
        fun coordinator() = NativeAccountCoordinator(bindings(), checkpoints, { noNetwork() }, { it == account }, { it() }, {})
        var gateway = coordinator()
        try {
            val original = document(aggregate("Original A"))
            assertTrue(gateway.applyDocument(account, original) { true })
            assertEquals("Original A", gateway.session().read().state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(owner.id).getString("name"))
            assertEquals(1, gateway.session().read().state.getJSONObject("nativeSync").getJSONObject("legacyProfileEditReceipts").length())
            val peerSync = JSONObject(gateway.session().read().state.getJSONObject("nativeSync").toString())
            val adoptionDirectory = Files.createTempDirectory(File("build").toPath(), "website-adopt-jni-").toFile()
            val adoptionKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
            val adopting = NativeAccountCoordinator(bindings(), VortxEncryptedCheckpointStore(adoptionDirectory) { adoptionKey }, { noNetwork() }, { it == account }, { it() }, {})
            try {
                val adoptedB = document(aggregate("Later B")).put("nativeSync", peerSync)
                assertTrue(adopting.applyDocument(account, adoptedB) { true })
                assertEquals("Original A", adopting.session().read().state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(owner.id).getString("name"))
                assertEquals(1, adopting.session().read().state.getJSONObject("nativeSync").getJSONObject("legacyProfileEditReceipts").length())
                assertEquals(1, adopting.session().read().state.getJSONObject("websiteProfileEditPending").getJSONArray("events").length())
            } finally { adopting.retire(); adoptionDirectory.listFiles()?.forEach { it.delete() }; adoptionDirectory.delete() }
            val later = document(aggregate("Later B"))
            assertTrue(gateway.applyDocument(account, later) { true })
            assertEquals("Original A", gateway.session().read().state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(owner.id).getString("name"))
            assertEquals(1, gateway.session().read().state.getJSONObject("nativeSync").getJSONObject("legacyProfileEditReceipts").length())
            assertEquals(1, gateway.session().read().state.getJSONObject("websiteProfileEditPending").getJSONArray("events").length())
            gateway.retire(); gateway = coordinator()
            assertTrue(gateway.applyDocument(account, later) { true })
            assertEquals("Original A", gateway.session().read().state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(owner.id).getString("name"))
            assertEquals(1, gateway.session().read().state.getJSONObject("nativeSync").getJSONObject("legacyProfileEditReceipts").length())
            assertEquals(1, gateway.session().read().state.getJSONObject("websiteProfileEditPending").getJSONArray("events").length())
        } finally { gateway.retire(); directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }
}
