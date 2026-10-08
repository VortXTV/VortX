package com.vortx.android.engine

import java.io.File
import java.nio.file.Files
import javax.crypto.KeyGenerator
import kotlinx.coroutines.runBlocking
import com.vortx.android.model.MediaType
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Explicit local host artifact only. Never launches an app, player, provider or network request. */
class VortxNativeLiveJniTest {
    private fun load() {
        val path = System.getenv("VORTX_JNI_LIBRARY")
        assumeTrue("Set VORTX_JNI_LIBRARY to the reviewed host JNI artifact", !path.isNullOrBlank())
        System.load(requireNotNull(path))
    }
    @Test fun `host JNI exports hydrate full state and expose versioned resource host`() {
        load()
        assertEquals(1, VortxCore.nativeResourceHostAbiVersion())
        val host = VortxCore.nativeResourceHostNew(); assertTrue(host != 0L)
        VortxCore.nativeResourceHostFree(host)
        val handle = VortxCore.nativeInitRuntime("{\"ownerId\":\"jni-owner\",\"ownerName\":\"Fixture\"}")
        assertTrue(handle != 0L)
        try {
            assertTrue(JSONObject(VortxCore.nativeDispatchJson(handle, "{\"type\":\"add_profile\",\"id\":\"viewer\",\"name\":\"Viewer\"}")!!).getBoolean("ok"))
            val state = requireNotNull(VortxCore.nativeGetStateJson(handle))
            val restored = VortxCore.nativeInitFromStateJson(state); assertTrue(restored != 0L)
            try { assertEquals(state, VortxCore.nativeGetStateJson(restored)) } finally { VortxCore.nativeEngineFree(restored) }
            assertEquals(0L, VortxCore.nativeInitFromStateJson("{}"))
        } finally { VortxCore.nativeEngineFree(handle) }
    }

    @Test fun `native sync JNI session persists library profile and progress across encrypted restart`() = runBlocking {
        assumeTrue("Requires the separately reviewed native-sync JNI artifact", System.getenv("VORTX_JNI_SYNC") == "1")
        load()
        // Raw bindings deliberately avoid Android logging/library-loader stubs in the JVM runner.
        val bindings = object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
        val fixture = JSONObject(File("../../test/fixtures/native-resource-contract.json").readText())
        val noNetwork = object : VortxResourceTransport {
            override fun makeCancellation() = object : VortxResourceCancellation { override fun cancel() {}; override fun close() {} }
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String {
                val input = JSONObject(requestJson); val request = input.getJSONObject("request"); val addons = input.getJSONArray("addons")
                return JSONObject().put("kind", "resource_result").put("requestId", input.getString("requestId")).put("generation", input.getLong("generation"))
                    .put("request", request).put("cancelled", false).put("groups", JSONArray((0 until addons.length()).map {
                        JSONObject().put("addonId", addons.getJSONObject(it).getString("id")).put("status", "ready").put("content", fixture.getJSONObject(request.getString("resource")))
                    })).toString()
            }
        }
        val directory = Files.createTempDirectory(File("build").toPath(), "native-sync-jni-").toFile()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val store = VortxEncryptedCheckpointStore(directory) { key }
        val scope = VortxAccountScope("native-test-account", "native-owner")
        try {
            val captured = VortxNativeSession.open(scope, "Owner", bindings, store, noNetwork, true).use { session ->
                session.dispatch(listOf(JSONObject("""{"type":"add_profile","id":"guest","name":"Guest"}"""),
                    JSONObject("""{"type":"add_library_item","profileId":"native-owner","item":{"kind":"standard","id":"tt-local","type":"movie","name":"Local fixture"}}"""),
                    JSONObject("""{"type":"report_progress","metaId":"tt-local","videoId":"tt-local","name":"Local fixture","positionMs":15000,"durationMs":120000}""")))
                session.dispatch(listOf(JSONObject().put("type", "install_addon").put("profileId", "native-owner").put("addon",
                    JSONObject().put("transportUrl", "https://fixture.invalid/manifest.json").put("manifest", fixture.getJSONObject("manifest"))
                        .put("flags", JSONObject().put("official", false).put("protected", false)))))
                val repository = NativeCatalogRepository { session }
                assertEquals("Local fixture", repository.library().getOrThrow().items.single().name)
                assertEquals("Fixture Series", repository.home().getOrThrow().last().items.single().name)
                assertEquals("Fixture Series", repository.meta(MediaType.SERIES, "tt-fixture").getOrThrow().name)
                assertTrue(repository.streams(MediaType.SERIES, "tt-fixture", "tt-fixture:1:2").getOrThrow().isNotEmpty())
                assertEquals(1, JSONArray(repository.subtitles(MediaType.SERIES, "tt-fixture:1:2").getOrThrow()).length())
                val state = session.read().state
                assertEquals(1, state.getJSONObject("libraries").getJSONObject("native-owner").getJSONArray("items").length())
                assertEquals(15L, state.getJSONObject("libraries").getJSONObject("native-owner").getJSONObject("resume").getJSONObject("tt-local").getLong("offsetSecs"))
                val before = state.toString()
                val foreign = JSONObject(state.getJSONObject("nativeSync").toString()).put("scope", "foreign")
                assertTrue(runCatching { session.dispatch(listOf(JSONObject().put("type", "merge_native_sync").put("document", foreign))) }.isFailure)
                assertEquals(before, session.read().state.toString())
                before
            }
            VortxNativeSession.open(scope, "Owner", bindings, store, noNetwork).use { restored ->
                assertEquals(captured, restored.read().state.toString())
                restored.dispatch(listOf(JSONObject("""{"type":"switch_profile","id":"guest"}""")))
                assertEquals("guest", restored.read().owner.profileID)
                assertEquals(0, restored.read().state.getJSONObject("libraries").getJSONObject("guest").getJSONArray("items").length())
            }
        } finally { directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }
}
