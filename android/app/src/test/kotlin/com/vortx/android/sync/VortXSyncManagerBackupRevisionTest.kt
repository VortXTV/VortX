package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.engine.*
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.integrations.NativeProviderCredentials
import com.vortx.android.profile.UserProfile
import java.lang.reflect.Proxy
import java.nio.file.Files
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Actual manager encryption, lease, native merge/checkpoint, and exact ACK against a strict-newer
 * CAS backup service. The peer uses a second real native runtime; no provider/user account calls. */
@OptIn(ExperimentalCoroutinesApi::class)
class VortXSyncManagerBackupRevisionTest {
    private val key = ByteArray(32) { 31 }
    private val account = VortXSyncManager.Account("00000000-0000-0000-0000-000000000123", "fixture@example.invalid", "Fixture", false)
    private val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Baseline", avatar = "star", isOwner = true)
    private val principal = SessionOwnerSnapshot.Account(account.id, 1)
    private fun bindings(): VortxRuntimeBindings {
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
    private fun initial() = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(owner.encode()))
        .put("rosterModified", 1).put("library", JSONArray()).put("addons", JSONArray()))
    private inner class Fixture : AutoCloseable {
        val directory = Files.createTempDirectory("native-backup-revision-").toFile()
        val abi = bindings()
        val disk = VortxEncryptedCheckpointStore(directory.resolve("local")) { SecretKeySpec(key, "AES") }
        fun coordinator(store: VortxCheckpointStore) = NativeAccountCoordinator(abi, store, { object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No provider network")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No provider network")
        } }, { it.id == account.id }, { it() }, {})
        var local = coordinator(disk)
        val peer = coordinator(VortxEncryptedCheckpointStore(directory.resolve("peer")) { SecretKeySpec(key, "AES") })
        val context = RevisionContext()
        val dispatcher = UnconfinedTestDispatcher()
        val manager = VortXSyncManager(context, CoroutineScope(SupervisorJob() + dispatcher))
        val providers = NativeProviderTestStore()
        var cloud = initial()
        var revision = 40L
        var cloudAbsent = false
        var loseAcceptedResponse = false
        var putFailure: Pair<Int, JSONObject?>? = null
        var injected: ((Int) -> Unit)? = null
        var echoed: Long? = null
        var getRevision: Any? = null
        var failGet = false
        var frozenGet: Pair<Long, JSONObject>? = null
        var onGet: (() -> Unit)? = null
        val attempts = mutableListOf<Long>()
        val bases = mutableListOf<Long?>()
        var gets = 0
        suspend fun start() {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, body, _ ->
                if (method == "GET") {
                    gets++
                    onGet?.invoke()
                    val (sourceVersion, source) = frozenGet ?: (revision to cloud)
                    if (failGet) 500 to null else if (cloudAbsent) 404 to null else 200 to JSONObject().put("version", getRevision ?: sourceVersion).put("document",
                        VortXCrypto.sealDocument(key, source.toString().toByteArray(), account.id, sourceVersion, true))
                } else {
                    val request = requireNotNull(body); val version = request.getLong("version")
                    check(request.has("baseRevision"))
                    val base = if (request.isNull("baseRevision")) null else request.getLong("baseRevision")
                    bases += base
                    attempts += version
                    injected?.invoke(attempts.size)
                    if (putFailure != null) requireNotNull(putFailure)
                    else if (base == revision.takeUnless { cloudAbsent } && version == BackupRevisionPolicy.next(base)) {
                        cloud = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), account.id, version))))
                        revision = version
                        cloudAbsent = false
                        if (loseAcceptedResponse) { loseAcceptedResponse = false; 0 to null }
                        else 200 to JSONObject().put("accepted", true)
                    } else 200 to JSONObject().put("accepted", false).put("version", echoed ?: revision)
                }
            })
            manager.installSessionRestoreTestSeam(manager.currentSession())
            manager.installNativeGatewayTestSeam(local, providers)
            assertTrue(peer.applyDocument(principal, initial()) { true })
            // The account already carries the first native publication, so mounting it leaves no
            // republish owning the pending state; each scenario's own edit is the only upload intent.
            val published = requireNotNull(peer.exportDocument(principal))
            cloud = initial().put("nativeSync", published.nativeSync).put("nativeHostPreferences", published.hostPreferences)
            assertTrue(manager.syncDown(true))
        }
        fun peerWins() {
            NativeProfileAccess { peer.session() }.let { profiles -> profiles.save(profiles.read().profiles.single().copy(name = "Peer A"), false) }
            val exported = requireNotNull(peer.exportDocument(principal))
            cloud = initial().put("nativeSync", exported.nativeSync).put("nativeHostPreferences", exported.hostPreferences)
            revision++
        }
        fun localEdit() = NativeProfileAccess { local.session() }.let { profiles ->
            profiles.save(profiles.read().profiles.single().copy(avatar = "moon"), false)
        }
        suspend fun cleanup() { manager.cancelSyncTestWork(); close() }
        override fun close() { local.retire(); peer.retire(); NativeProviderAccess.unbindForTest(); directory.deleteRecursively() }
    }

    @Test fun `stale prepared peer cannot overwrite winner and fresh merged base survives cold reopen`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit()
            fixture.injected = { attempt -> if (attempt == 1) fixture.peerWins() }
            assertTrue(fixture.manager.syncUp())
            assertEquals(listOf(41L, 42L), fixture.attempts)
            assertEquals(listOf(40L, 41L), fixture.bases)
            assertEquals(42L, fixture.manager.lastAppliedVersion())
            val live = NativeProfileAccess { fixture.local.session() }.read().profiles.single()
            assertEquals("Peer A", live.name); assertEquals("moon", live.avatar)
            assertEquals("Peer A", fixture.cloud.getJSONObject("nativeSync").getJSONObject("profiles").getJSONObject(owner.id).getJSONObject("profile").getString("name"))
            fixture.local.retire(); fixture.local = fixture.coordinator(fixture.disk)
            assertTrue(fixture.local.reopenCheckpoint(principal) { true })
            val cold = NativeProfileAccess { fixture.local.session() }.read().profiles.single()
            assertEquals("Peer A", cold.name); assertEquals("moon", cold.avatar)
            assertFalse(fixture.local.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `rejected winner echo cannot relabel a candidate derived from a different fresh base`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit(); fixture.echoed = 900_000L
            fixture.injected = { attempt ->
                if (attempt == 1) fixture.peerWins()
                if (attempt == 2) { fixture.cloud.put("secondPeer", "preserve"); fixture.revision++ }
            }
            assertTrue(fixture.manager.syncUp())
            assertEquals(listOf(41L, 42L, 43L), fixture.attempts)
            assertEquals(listOf(40L, 41L, 42L), fixture.bases)
            assertEquals("preserve", fixture.cloud.getString("secondPeer"))
            assertEquals("Peer A", NativeProfileAccess { fixture.local.session() }.read().profiles.single().name)
            assertEquals(43L, fixture.manager.lastAppliedVersion())
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `stale GET retries never promote stale payload and retain pending until fresh merge`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit()
            fixture.frozenGet = fixture.revision to JSONObject(fixture.cloud.toString())
            fixture.echoed = 900_000L
            fixture.injected = { if (it == 1) fixture.peerWins() }
            assertFalse(fixture.manager.syncUp())
            assertEquals(listOf(41L, 41L, 41L), fixture.attempts)
            assertEquals(listOf(40L, 40L, 40L), fixture.bases)
            assertEquals(40L, fixture.manager.lastAppliedVersion())
            assertTrue(fixture.local.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            assertEquals("Peer A", fixture.cloud.getJSONObject("nativeSync").getJSONObject("profiles").getJSONObject(owner.id).getJSONObject("profile").getString("name"))
            fixture.frozenGet = null
            assertTrue(fixture.manager.syncUp())
            assertEquals(listOf(41L, 41L, 41L, 42L), fixture.attempts)
            val result = NativeProfileAccess { fixture.local.session() }.read().profiles.single()
            assertEquals("Peer A", result.name); assertEquals("moon", result.avatar)
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `failed rebuild keeps pending intent and never blindly resends stale candidate`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit()
            fixture.injected = { fixture.peerWins(); fixture.failGet = true }
            assertFalse(fixture.manager.syncUp())
            assertEquals(listOf(41L), fixture.attempts)
            assertEquals(40L, fixture.manager.lastAppliedVersion())
            assertTrue(fixture.local.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `invalid pull revisions cannot apply upload or acknowledge local intent`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit()
            for (invalid in listOf("41", -1L, 40.5, JSONObject.NULL, java.math.BigDecimal("9007199254740991.1"), Long.MAX_VALUE)) {
                fixture.getRevision = invalid
                assertFalse("Rejected revision $invalid", fixture.manager.syncUp())
                assertTrue(fixture.attempts.isEmpty())
                assertEquals(40L, fixture.manager.lastAppliedVersion())
                assertTrue(fixture.local.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            }
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `largest safe base is readable but cannot overflow into a push or pending ACK`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.revision = BackupRevisionPolicy.MAX_VERSION
            fixture.start(); fixture.localEdit()
            assertFalse(fixture.manager.syncUp())
            assertTrue(fixture.attempts.isEmpty())
            assertEquals(BackupRevisionPolicy.MAX_VERSION, fixture.manager.lastAppliedVersion())
            assertTrue(fixture.local.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `account replacement during recovery cannot send or acknowledge under new lease`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit()
            val oldSession = fixture.local.session()
            val oldRead = oldSession.read()
            val checkpoint = requireNotNull(fixture.disk.read(oldRead.owner.scope))
            assertTrue(oldRead.state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            fixture.injected = { fixture.peerWins(); fixture.onGet = {
                fixture.manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("other-fixture", account.copy(id = "00000000-0000-0000-0000-000000000456"), key))
            } }
            assertFalse(fixture.manager.syncUp())
            assertEquals(listOf(41L), fixture.attempts)
            assertEquals(0L, fixture.manager.lastAppliedVersion())
            assertTrue(runCatching { oldSession.read() }.isFailure)
            assertEquals(checkpoint, fixture.disk.read(oldRead.owner.scope))
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `native authenticated absence creates at zero with null witness`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.cloudAbsent = true
            fixture.start()
            assertEquals(listOf(0L), fixture.attempts)
            assertEquals(listOf<Long?>(null), fixture.bases)
            assertFalse(fixture.cloudAbsent)
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `native absent row race remerges the winning seed before next proposal`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.cloudAbsent = true
            fixture.injected = { if (it == 1) {
                fixture.cloudAbsent = false; fixture.revision = 0
                fixture.cloud.put("seedWinner", "preserve")
            } }
            fixture.start()
            assertEquals(listOf(0L, 1L), fixture.attempts)
            assertEquals(listOf(null, 0L), fixture.bases)
            assertEquals("preserve", fixture.cloud.getString("seedWinner"))
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `lost accepted native response preserves intent and fresh retry merges intervening winner`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit(); fixture.loseAcceptedResponse = true
            assertFalse(fixture.manager.syncUp())
            assertEquals(41L, fixture.revision); assertEquals(40L, fixture.manager.lastAppliedVersion())
            assertTrue(fixture.local.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            fixture.cloud.put("afterLostResponse", "keep"); fixture.revision++
            assertTrue(fixture.manager.syncUp())
            assertEquals(listOf(41L, 43L), fixture.attempts)
            assertEquals(listOf(40L, 42L), fixture.bases)
            assertEquals("keep", fixture.cloud.getString("afterLostResponse"))
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `native upgrade required stops retries without acknowledging or stamping success`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit()
            fixture.putFailure = 426 to JSONObject().put("error", "upgrade_required").put("accepted", false)
            assertFalse(fixture.manager.syncUp())
            assertEquals(listOf(41L), fixture.attempts)
            assertEquals(40L, fixture.manager.lastAppliedVersion())
            assertEquals("Update VortX to keep syncing. Your changes are still on this device.", fixture.manager.syncProblem.value)
            assertTrue(fixture.local.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            assertFalse(fixture.manager.syncUp()); assertEquals(1, fixture.attempts.size)
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `same account reauthentication while PUT waits cannot acknowledge retired lease`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit()
            val oldSession = fixture.local.session()
            val oldRead = oldSession.read()
            assertTrue(oldRead.state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            fixture.injected = { fixture.manager.replaceSyncSessionTestSeam(
                VortXSyncManager.Session("replacement-fixture-token", account, key)) }
            assertFalse(fixture.manager.syncUp())
            assertEquals(listOf(40L), fixture.bases)
            assertEquals(40L, fixture.manager.lastAppliedVersion())
            // Reauthentication retires the mount: it can neither be read nor acknowledge the pending
            // intent, which stays in the durable checkpoint for the new lease's own mount.
            assertTrue(runCatching { oldSession.read() }.isFailure)
            val checkpoint = JSONObject(requireNotNull(fixture.disk.read(oldRead.owner.scope)))
            assertTrue(checkpoint.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `retired native installation cannot acknowledge a candidate accepted during remount`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start(); fixture.localEdit()
            fixture.injected = {
                fixture.local.retire(); fixture.local = fixture.coordinator(fixture.disk)
                fixture.manager.installNativeGatewayTestSeam(fixture.local, fixture.providers)
            }
            assertFalse(fixture.manager.syncUp())
            assertEquals(40L, fixture.manager.lastAppliedVersion())
            assertTrue(fixture.local.reopenCheckpoint(principal) { true })
            assertTrue(fixture.local.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }

    @Test fun `ACKed provider-only rollback arms durable repair and restores cold peer without native differences`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try {
            fixture.start()
            // Seed an ACKed secure register directly: no local edit callback or pending provider intent.
            val credential = NativeProviderCredentials("account.${account.id}")
            credential.edit(mapOf("tmdb" to "synthetic-older"))
            val older = credential.mirror(JSONObject())
            credential.edit(mapOf("tmdb" to "synthetic-newer"))
            credential.acknowledge(credential.document())
            fixture.providers.values["native.providers.account.${account.id}"] = credential.encoded()
            val native = requireNotNull(fixture.local.exportDocument(principal))
            fixture.cloud.put("nativeSync", native.nativeSync).put("nativeHostPreferences", native.hostPreferences)
                .put("nativeProviderCredentials", older.getJSONObject("nativeProviderCredentials")).put("apiKeys", older.getJSONObject("apiKeys"))
            fixture.revision++
            assertTrue(fixture.manager.syncDown(true))
            assertFalse(NativeProviderAccess.hasPending(principal)!!)
            assertEquals("synthetic-newer", NativeProviderAccess.read(setOf("tmdb"))!!.values["tmdb"])
            assertTrue(fixture.context.getSharedPreferences("vortx_sync_state", android.content.Context.MODE_PRIVATE)
                .getBoolean("pendingPush.${account.id}", false))
            fixture.dispatcher.scheduler.advanceTimeBy(2_501)
            fixture.dispatcher.scheduler.runCurrent()
            assertEquals(listOf(42L), fixture.attempts)
            assertEquals("synthetic-newer", fixture.cloud.getJSONObject("apiKeys").getString("tmdb"))
            val cold = NativeProviderCredentials("account.${account.id}")
            cold.merge(fixture.cloud)
            assertEquals("synthetic-newer", cold.value("tmdb"))
        } finally { fixture.cleanup(); Dispatchers.resetMain() }
    }
}

internal class RevisionContext : ContextWrapper(null) {
    private val prefs = mutableMapOf<String, SharedPreferences>()
    override fun getApplicationContext(): Context = this
    override fun getPackageName() = "com.vortx.revision.test"
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = prefs.getOrPut(name) { revisionPreferences() }
}

private fun revisionPreferences(): SharedPreferences {
    val values = linkedMapOf<String, Any?>()
    val listeners = mutableSetOf<SharedPreferences.OnSharedPreferenceChangeListener>()
    lateinit var prefs: SharedPreferences
    fun editor(): SharedPreferences.Editor {
        val writes = linkedMapOf<String, Any?>(); var clear = false
        return Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
            when (method.name) {
                "clear" -> { clear = true; proxy }
                "remove" -> { writes[args!![0] as String] = null; proxy }
                "commit", "apply" -> {
                    if (clear) values.clear()
                    writes.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
                    writes.keys.forEach { key -> listeners.toList().forEach { it.onSharedPreferenceChanged(prefs, key) } }
                    if (method.name == "commit") true else null
                }
                else -> if (method.name.startsWith("put")) { writes[args!![0] as String] = args[1]; proxy } else null
            }
        } as SharedPreferences.Editor
    }
    prefs = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
        when (method.name) {
            "getAll" -> values.toMap()
            "contains" -> values.containsKey(args!![0])
            "edit" -> editor()
            "registerOnSharedPreferenceChangeListener" -> { listeners += args!![0] as SharedPreferences.OnSharedPreferenceChangeListener; null }
            "unregisterOnSharedPreferenceChangeListener" -> { listeners -= args!![0] as SharedPreferences.OnSharedPreferenceChangeListener; null }
            else -> if (method.name.startsWith("get")) values[args!![0]] ?: args[1] else null
        }
    } as SharedPreferences
    return prefs
}
