package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.profile.UserProfile
import com.vortx.android.engine.NativeAccountCoordinator
import com.vortx.android.engine.NativeProfileAccess
import com.vortx.android.engine.VortxCore
import com.vortx.android.engine.VortxRuntimeBindings
import com.vortx.android.engine.VortxEncryptedCheckpointStore
import com.vortx.android.engine.VortxResourceTransport
import com.vortx.android.engine.VortxResourceCancellation
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Exercises the actual captured-lease crypto/pull/push path with local-only transport. */
@OptIn(ExperimentalCoroutinesApi::class)
class NativeAccountSyncTest {
    private val providerStore = com.vortx.android.integrations.NativeProviderTestStore()
    private fun installNative(manager: VortXSyncManager, gateway: NativeAccountGateway) {
        manager.installSessionRestoreTestSeam(manager.currentSession())
        manager.installNativeGatewayTestSeam(gateway, providerStore)
    }
    @org.junit.Before fun mainDispatcher() { Dispatchers.setMain(UnconfinedTestDispatcher()) }
    @org.junit.After fun resetDispatcher() { com.vortx.android.integrations.NativeProviderAccess.unbindForTest(); Dispatchers.resetMain() }
    private val key = ByteArray(32) { (it + 1).toByte() }
    private val account = VortXSyncManager.Account("00000000-0000-0000-0000-000000000123", "fixture@example.invalid", "Fixture", false)
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
        override fun makeCancellation(): VortxResourceCancellation = error("No provider request permitted")
        override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No provider request permitted")
    }
    private class Gateway : NativeAccountGateway {
        var applied = 0
        var retired = 0
        var reopened = 0
        var last: JSONObject? = null
        override fun retire() { retired++ }
        override suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): Boolean {
            check(isCurrent()); reopened++; return true
        }
        override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean {
            check(isCurrent()); applied++; last = JSONObject(document.toString()); return true
        }
        override fun exportDocument(account: SessionOwnerSnapshot.Account) = NativeAccountExport(
            JSONObject().put("scope", "account.${account.id}").put("fixture", true),
            listOf(UserProfile(id = UserProfile.OWNER_ID, name = "Owner", avatar = "star", isOwner = true)), 123.0)
    }
    @Test fun `missing failed malformed and undecryptable account pulls never seed or upload native state`() = runBlocking {
        for ((code, body) in listOf(404 to null, 500 to null, 200 to null, 200 to JSONObject(),
            200 to JSONObject().put("version", 100).put("document", "invalid-sealed-document"))) {
            val manager = VortXSyncManager(TestContext()); val gateway = Gateway(); var puts = 0
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, _, _ ->
                    if (method == "PUT") puts++
                    code to body
                })
                installNative(manager, gateway)
                assertFalse(manager.syncDown(true)); assertFalse(manager.syncUp())
                assertEquals(0, gateway.applied); assertEquals(0, puts)
                assertEquals(1, gateway.reopened)
            } finally { manager.cancelSyncTestWork() }
        }
    }
    @Test fun `native push preserves adjacent authenticated fields and excludes device selection`() = runBlocking {
        val manager = VortXSyncManager(TestContext()); val gateway = Gateway()
        val doc = JSONObject().put("foreign", JSONObject().put("keep", 1))
            .put("vortx", JSONObject().put("unknownPreference", "retained").put("rosterModified", 12.25)
                .put("roster", org.json.JSONArray().put(UserProfile(id = UserProfile.OWNER_ID, name = "Legacy baseline", avatar = "star", isOwner = true).encode())))
        val settings = requireNotNull(com.vortx.android.backup.SettingsBackup.encode(mapOf(
            "stremiox.profiles" to doc.getJSONObject("vortx").getJSONArray("roster").toString().toByteArray(),
            "stremiox.profiles.modified" to 12.25, "unknownFuturePreference" to "retained",
        ), "tv.vortx", "VortX"))
        doc.put("settings", java.util.Base64.getEncoder().encodeToString(settings))
        var uploaded: JSONObject? = null
        try {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, body, _ ->
                if (method == "GET") 200 to JSONObject().put("version", 100).put("document",
                    VortXCrypto.sealDocument(key, doc.toString().toByteArray(), account.id, 100, true))
                else {
                    val request = requireNotNull(body)
                    uploaded = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), account.id, request.getLong("version")))))
                    200 to JSONObject().put("accepted", true)
                }
            })
            installNative(manager, gateway)
            assertTrue(manager.syncDown(true)); assertTrue(manager.syncUp())
            val result = requireNotNull(uploaded)
            assertEquals(1, result.getJSONObject("foreign").getInt("keep"))
            assertEquals("retained", result.getJSONObject("vortx").getString("unknownPreference"))
            assertTrue(result.getJSONObject("nativeSync").getBoolean("fixture"))
            assertFalse(result.getJSONObject("nativeSync").has("activeProfileId"))
            assertEquals(doc.getString("settings"), result.getString("settings")); assertEquals(2, gateway.applied)
            // The projected export deliberately has a different name and clock. Neither may rewrite
            // the original legacy receipt input; the next native-native pull must see the same input.
            assertEquals(doc.getJSONObject("vortx").toString(), result.getJSONObject("vortx").toString())
        } finally { manager.cancelSyncTestWork() }
    }

    @Test fun `native pull preflights exact overlay number tokens before org json rounding`() = runBlocking {
        for ((literal, accepted) in listOf("9007199254740991.1" to false, "1e400" to false, "1.25" to true)) {
            val manager = VortXSyncManager(TestContext()); val gateway = Gateway(); var uploads = 0
            val raw = """{"vortx":{"byProfile":{"11111111-1111-1111-1111-111111111111":{"future":$literal}}}}"""
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                    transport = { method, _, _, _ ->
                        if (method == "PUT") uploads++
                        200 to JSONObject().put("version", 100).put("document", VortXCrypto.sealDocument(key, raw.toByteArray(), account.id, 100, true))
                    })
                installNative(manager, gateway)
                assertEquals(literal, accepted, manager.syncDown(true))
                assertEquals(literal, if (accepted) 1 else 0, gateway.applied)
                assertEquals(0, uploads)
                if (accepted) assertEquals(1.25, gateway.last!!.getJSONObject("vortx").getJSONObject("byProfile")
                    .getJSONObject("11111111-1111-1111-1111-111111111111").getDouble("future"), 0.0)
            } finally { manager.cancelSyncTestWork() }
        }
    }

    @Test fun `native push never claims pending host settings were uploaded or clears dirty intent`() = runBlocking {
        val context = TestContext(); val manager = VortXSyncManager(context); val gateway = Gateway()
        var requests = 0
        val storageKey = "vortx.sync.dirtySettings.${account.id}"
        try {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                transport = { _, _, _, _ -> requests++; 500 to null })
            installNative(manager, gateway)
            context.getSharedPreferences("vortx_sync_dirty", 0).edit().putString(storageKey, "{\"stremiox.audioLang\":123.25}").commit()
            assertFalse(manager.syncUp())
            assertEquals(0, requests)
            assertEquals("{\"stremiox.audioLang\":123.25}", context.getSharedPreferences("vortx_sync_dirty", 0).getString(storageKey, null))
        } finally { manager.cancelSyncTestWork() }
    }

    @Test fun `real JNI native and host fields sync separately with failed push cold persistence and exact event acknowledgement`() = runBlocking {
        org.junit.Assume.assumeTrue("Requires reviewed local JNI", System.getenv("VORTX_JNI_SYNC") == "1")
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        val bindings = object : VortxRuntimeBindings {
            override fun create(ownerId: String, ownerName: String) = VortxCore.nativeInitRuntime(JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString())
            override fun hydrate(snapshot: String) = VortxCore.nativeInitFromStateJson(snapshot)
            override fun dispatch(handle: Long, action: String) = VortxCore.nativeDispatchJson(handle, action)
            override fun resolve(handle: Long, request: String) = VortxCore.nativeResolveJson(handle, request)
            override fun state(handle: Long) = VortxCore.nativeGetStateJson(handle)
            override fun delta(handle: Long) = VortxCore.nativeGetStateDeltaJson(handle)
            override fun free(handle: Long) = VortxCore.nativeEngineFree(handle)
        }
        val noNetwork = object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No provider request permitted")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No provider request permitted")
        }
        val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-host-intent-").toFile()
        val checkpointKey = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val checkpoints = VortxEncryptedCheckpointStore(directory) { checkpointKey }
        val context = TestContext()
        val manager = VortXSyncManager(context)
        fun coordinator() = NativeAccountCoordinator(bindings, checkpoints, { noNetwork }, { true }, { it() }, {})
        var runtime = coordinator()
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Legacy owner", avatar = "star", isOwner = true)
        var cloud = JSONObject().put("vortx", JSONObject().put("roster", org.json.JSONArray().put(owner.encode()))
            .put("rosterModified", 123.5).put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
        var cloudVersion = 100L; var uploads = 0; var rejectPut = false; var failGet = false
        var whileUploading: (() -> Unit)? = null
        try {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, body, _ ->
                if (method == "GET") {
                    if (failGet) 500 to null else 200 to JSONObject().put("version", cloudVersion).put("document",
                        VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, cloudVersion, true))
                }
                else {
                    if (rejectPut) return@installSyncTestSeam 500 to null
                    val request = requireNotNull(body); cloudVersion = request.getLong("version")
                    cloud = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), account.id, cloudVersion))))
                    whileUploading?.invoke(); whileUploading = null
                    uploads++; 200 to JSONObject().put("accepted", true)
                }
            })
            installNative(manager, runtime)
            assertTrue(manager.syncDown(true))
            val profiles = NativeProfileAccess { runtime.session() }
            val pin = UserProfile.pinHash("1234", owner.id)
            profiles.save(profiles.read().profiles.single().copy(name = "Native name", pin = pin), false)
            assertFalse(runtime.session().read().state.getBoolean("hostProfileSyncPending"))
            assertTrue(manager.syncUp()); assertEquals(1, uploads)
            val nativeProfile = cloud.getJSONObject("nativeSync").getJSONObject("profiles").getJSONObject(owner.id).getJSONObject("profile")
            assertEquals("Native name", nativeProfile.getString("name")); assertEquals(pin, nativeProfile.getString("pin"))
            assertEquals("Legacy owner", cloud.getJSONObject("vortx").getJSONArray("roster").getJSONObject(0).getString("name"))
            profiles.save(profiles.read().profiles.single().copy(avatar = "moon"), false)
            val read = runtime.session().read()
            assertTrue(read.state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            assertTrue(JSONObject(checkpoints.read(read.owner.scope)!!).getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            rejectPut = true
            assertFalse(manager.syncUp()); assertEquals(1, uploads)
            assertTrue(runtime.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            runtime.retire(); runtime = coordinator(); installNative(manager, runtime)
            assertTrue(manager.syncDown(true))
            assertEquals("moon", NativeProfileAccess { runtime.session() }.read().profiles.single().avatar)
            assertTrue(runtime.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            rejectPut = false
            context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", true).commit()
            context.getSharedPreferences("vortx_sync_dirty", 0).edit().putString("vortx.sync.dirtySettings.${account.id}", "{\"stremiox.autoSkip\":123.25}").commit()
            whileUploading = { profiles.save(profiles.read().profiles.single().copy(avatar = "sun"), false) }
            assertTrue(manager.syncUp()); assertEquals(2, uploads)
            assertTrue(runtime.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            assertEquals("sun", profiles.read().profiles.single().avatar)
            val fields = cloud.getJSONObject("nativeHostPreferences").getJSONObject("profiles").getJSONObject(owner.id).getJSONObject("fields")
            assertEquals("moon", fields.getJSONObject("avatar").getString("value"))
            assertTrue(cloud.getJSONObject("nativeHostPreferences").getJSONObject("globals").getJSONObject("fields").getJSONObject("stremiox.autoSkip").getBoolean("value"))
            assertFalse(context.getSharedPreferences("vortx_sync_dirty", 0).contains("vortx.sync.dirtySettings.${account.id}"))
            assertTrue(manager.syncUp()); assertEquals(3, uploads)
            assertFalse(runtime.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            assertEquals("sun", cloud.getJSONObject("nativeHostPreferences").getJSONObject("profiles").getJSONObject(owner.id).getJSONObject("fields").getJSONObject("avatar").getString("value"))
            assertFalse(cloud.getJSONObject("nativeSync").has("hostProfileSyncPending"))
            assertFalse(cloud.has("nativeHostPreferenceState"))
            assertEquals("star", cloud.getJSONObject("vortx").getJSONArray("roster").getJSONObject(0).getString("avatar"))
            runtime.retire(); runtime = coordinator(); installNative(manager, runtime)
            // Another account/process may have left a different flat preference. A's sealed
            // account register must project before the failed network pull, without cloud access.
            context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", false).commit()
            failGet = true
            assertFalse(manager.syncDown(true))
            assertTrue(context.getSharedPreferences("vortx_settings", 0).getBoolean("stremiox.autoSkip", false))
            assertEquals("sun", profiles.read().profiles.single().avatar)
        } finally { runtime.retire(); manager.cancelSyncTestWork(); directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    @Test fun `real JNI first backup uses zero and collisions or unknown outcomes require authenticated repull`() = runBlocking {
        org.junit.Assume.assumeTrue("Requires reviewed local JNI", System.getenv("VORTX_JNI_SYNC") == "1")
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        for (mode in listOf("accepted", "collision-zero", "collision-positive", "collision-other-owner", "timeout-created", "missing-ack")) {
            val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-first-backup-").toFile()
            val checkpointKey = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
            val checkpoints = VortxEncryptedCheckpointStore(directory) { checkpointKey }
            val context = TestContext(); val manager = VortXSyncManager(context)
            val runtime = NativeAccountCoordinator(bindings(), checkpoints, { noNetwork() }, { true }, { it() }, {})
            var cloud: JSONObject? = null; var cloudVersion = 0L; val versions = mutableListOf<Long>(); var gets = 0
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, body, _ ->
                    if (method == "GET") {
                        gets++
                        cloud?.let { 200 to JSONObject().put("version", cloudVersion).put("document",
                            VortXCrypto.sealDocument(key, it.toString().toByteArray(), account.id, cloudVersion, true)) } ?: (404 to null)
                    } else {
                        val request = requireNotNull(body); val version = request.getLong("version"); versions += version
                        val candidate = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), account.id, version))))
                        if (versions.size == 1) {
                            assertEquals(0L, version)
                            assertTrue(directory.listFiles().orEmpty().isEmpty())
                            assertTrue(runCatching { runtime.session() }.isFailure)
                            cloud = candidate.put("peerUnknownPreference", "preserve")
                            if (mode == "collision-other-owner") {
                                val peer = UserProfile(id = "00000000-0000-0000-0000-000000001234", name = "Peer", avatar = "🍿", isOwner = true)
                                cloud = JSONObject().put("peerUnknownPreference", "preserve").put("vortx", JSONObject()
                                    .put("roster", org.json.JSONArray().put(peer.encode())).put("rosterModified", 7)
                                    .put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
                            }
                            cloudVersion = if (mode == "collision-positive") 123 else 0
                            when (mode) {
                                "collision-zero", "collision-positive", "collision-other-owner" -> 200 to JSONObject().put("accepted", false).put("version", cloudVersion)
                                "timeout-created" -> 0 to null
                                "missing-ack" -> 200 to JSONObject().put("ok", true)
                                else -> 200 to JSONObject().put("accepted", true)
                            }
                        } else {
                            assertTrue(gets >= 2); assertTrue(version > cloudVersion)
                            assertEquals("preserve", candidate.getString("peerUnknownPreference"))
                            cloud = candidate; cloudVersion = version
                            200 to JSONObject().put("accepted", true)
                        }
                    }
                })
                installNative(manager, runtime)
                val unknown = mode in setOf("timeout-created", "missing-ack")
                assertEquals(!unknown, manager.syncUp())
                if (unknown) {
                    assertEquals(listOf(0L), versions); assertTrue(directory.listFiles().orEmpty().isEmpty())
                    assertTrue(runCatching { runtime.session() }.isFailure); assertTrue(manager.syncUp())
                }
                val peerWon = mode == "collision-other-owner"
                assertEquals(if (peerWon) "Peer" else "Main", NativeProfileAccess { runtime.session() }.read().profiles.single().name)
                assertEquals(if (peerWon) "00000000-0000-0000-0000-000000001234" else UserProfile.OWNER_ID, runtime.session().scope.ownerProfileID)
                if (!peerWon) assertEquals("authenticated-empty-v1", cloud!!.getString("nativeAccountBootstrap"))
                assertTrue(context.getSharedPreferences("vortx_sync_state", 0).getBoolean("nativeBackupSeen.${account.id}", false))
                val before = runtime.session().read().state.toString(); val writes = versions.size
                cloud = null // A previously existing backup disappearing is not a new account.
                assertFalse(manager.syncDown(true)); assertFalse(manager.syncUp())
                assertEquals(before, runtime.session().read().state.toString()); assertEquals(writes, versions.size)
            } finally { runtime.retire(); manager.cancelSyncTestWork(); directory.listFiles()?.forEach { it.delete() }; directory.delete() }
        }
    }

    @Test fun `native provider clear is uploaded and acknowledged but edit during PUT remains pending`() = runBlocking {
        val manager = VortXSyncManager(TestContext()); val gateway = Gateway()
        val owner = SessionOwnerSnapshot.Account(account.id, 1)
        val vault = com.vortx.android.integrations.NativeProviderVault(providerStore)
        val credentials = vault.load(owner)
        credentials.edit(mapOf("tmdb" to null, "realDebrid" to null))
        vault.commit(owner, credentials)
        val original = JSONObject("""{"apiKeys":{"tmdb":"legacy","realDebrid":"legacy","unknown":"keep","metadata":{"tmdb":"legacy","unknown":"keep"}}}""")
        var cloud = original
        var cloudVersion = 100L
        var uploaded: JSONObject? = null
        var editDuringPut = false
        try {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, body, _ ->
                if (method == "GET") 200 to JSONObject().put("version", cloudVersion).put("document",
                    VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, cloudVersion, true))
                else {
                    val request = requireNotNull(body)
                    uploaded = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), account.id, request.getLong("version")))))
                    cloud = JSONObject(requireNotNull(uploaded).toString()); cloudVersion = request.getLong("version")
                    if (editDuringPut) assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "newer-local")))
                    200 to JSONObject().put("accepted", true)
                }
            })
            installNative(manager, gateway)
            assertTrue(manager.syncUp())
            val clear = requireNotNull(uploaded)
            assertFalse(clear.getJSONObject("apiKeys").has("realDebrid"))
            assertFalse(clear.getJSONObject("apiKeys").has("tmdb"))
            assertFalse(clear.getJSONObject("apiKeys").getJSONObject("metadata").has("tmdb"))
            assertEquals("keep", clear.getJSONObject("apiKeys").getString("unknown"))
            assertTrue(clear.getJSONObject("nativeProviderCredentials").getJSONObject("fields").getJSONObject("tmdb").isNull("value"))
            val actualOwner = manager.sessionOwnerSnapshot() as SessionOwnerSnapshot.Account
            assertFalse(com.vortx.android.integrations.NativeProviderAccess.hasPending(actualOwner)!!)
            editDuringPut = true
            assertTrue(manager.syncUp())
            assertTrue(com.vortx.android.integrations.NativeProviderAccess.hasPending(actualOwner)!!)
            assertEquals("newer-local", com.vortx.android.integrations.NativeProviderAccess.read(setOf("tmdb"))!!.values["tmdb"])
            installNative(manager, gateway)
            assertTrue(com.vortx.android.integrations.NativeProviderAccess.hasPending(actualOwner)!!)
        } finally { manager.cancelSyncTestWork() }
    }

    private class TestContext : ContextWrapper(null) {
        private val stores = mutableMapOf<String, SharedPreferences>()
        override fun getApplicationContext(): Context = this
        override fun getPackageName() = "com.vortx.android.native.test"
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = stores.getOrPut(name) { memoryPreferences() }
        override fun deleteSharedPreferences(name: String) = stores.remove(name) != null
    }
    companion object {
        private fun memoryPreferences(): SharedPreferences {
            val values = linkedMapOf<String, Any?>()
            fun editor(): SharedPreferences.Editor {
                val edits = linkedMapOf<String, Any?>(); var clear = false
                return Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
                    when (method.name) {
                        "clear" -> { clear = true; proxy }
                        "remove" -> { edits[args!![0] as String] = null; proxy }
                        "commit", "apply" -> { if (clear) values.clear(); edits.forEach { (k, v) -> if (v == null) values.remove(k) else values[k] = v }; if (method.name == "commit") true else null }
                        else -> if (method.name.startsWith("put")) { edits[args!![0] as String] = args[1]; proxy } else null
                    }
                } as SharedPreferences.Editor
            }
            return Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
                when (method.name) {
                    "getAll" -> values.toMap()
                    "contains" -> values.containsKey(args!![0])
                    "edit" -> editor()
                    "registerOnSharedPreferenceChangeListener", "unregisterOnSharedPreferenceChangeListener" -> null
                    else -> if (method.name.startsWith("get")) values[args!![0]] ?: args[1] else null
                }
            } as SharedPreferences
        }
    }
}
