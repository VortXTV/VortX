package com.vortx.android.engine

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import javax.crypto.KeyGenerator
import org.json.JSONArray
import org.json.JSONObject
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
                val conflicting = JSONObject(first.toString()).put("eventId", "00000000-0000-4000-8000-000000000002").put("editedAt", 1_001_001)
                assertFalse(session.applyWebsiteProfileEdit(conflicting))
                assertEquals(1, session.read().state.getJSONObject("nativeSync").getJSONObject("legacyProfileEditReceipts").length())
                assertEquals(1, session.read().state.getJSONObject("websiteProfileEditPending").getJSONArray("events").length())
            }
        } finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }
}
