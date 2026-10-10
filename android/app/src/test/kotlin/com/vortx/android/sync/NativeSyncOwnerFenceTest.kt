package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.profile.UserProfile
import java.lang.reflect.Proxy
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Native-selected manager admission with synthetic gateway/transport; no JNI or backend proof. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class NativeSyncOwnerFenceTest {
    private class Fixture(dispatcher: kotlinx.coroutines.CoroutineDispatcher) {
        val context = MemoryContext()
        val manager = VortXSyncManager(context, CoroutineScope(SupervisorJob() + dispatcher))
        val key = ByteArray(32) { 17 }
        val account = VortXSyncManager.Account("00000000-0000-0000-0000-000000000456", "fixture@example.invalid", "Fixture", false)
        val session = VortXSyncManager.Session("fixture-token", account, key.copyOf())
        val providers = NativeProviderTestStore()
        val cloud = JSONObject().put("foreign", JSONObject().put("retain", true))
            .put("vortx", JSONObject().put("opaque", "retain"))
        var gets = 0
        var puts = 0
        var applies = 0
        var acknowledgements = 0
        var getEntered: CompletableDeferred<Unit>? = null
        var getRelease: CompletableDeferred<Unit>? = null
        var onExport: (() -> Unit)? = null
        var onPut: (() -> Unit)? = null
        val gateway = object : NativeAccountGateway {
            override fun retire() {}
            override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean {
                if (!isCurrent()) return false
                applies++
                return true
            }
            override fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport {
                val callback = onExport
                onExport = null
                callback?.invoke()
                return NativeAccountExport(JSONObject().put("scope", "account.${account.id}").put("fixture", true),
                    listOf(UserProfile(UserProfile.OWNER_ID, "Fixture", "star", isOwner = true)), 0.0,
                    hostPreferences = JSONObject().put("globals", JSONObject().put("fields", JSONObject())))
            }
            override fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean {
                acknowledgements++
                return true
            }
            override fun recordGlobalPreferences(account: SessionOwnerSnapshot.Account, changes: JSONObject) = true
        }

        init {
            check(com.vortx.android.BuildConfig.NATIVE_ENGINE_ENABLED)
            manager.installSyncTestSeam(session, 0, { method, _, body, token ->
                assertEquals("fixture-token", token)
                if (method == "GET") {
                    gets++
                    getEntered?.complete(Unit)
                    getRelease?.await()
                    200 to JSONObject().put("version", 10L).put("document",
                        requireNotNull(VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, 10L, true)))
                } else {
                    puts++
                    val request = requireNotNull(body)
                    val uploaded = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key,
                        request.getString("document"), account.id, request.getLong("version")))))
                    assertTrue(uploaded.getJSONObject("foreign").getBoolean("retain"))
                    assertEquals("retain", uploaded.getJSONObject("vortx").getString("opaque"))
                    onPut?.invoke()
                    200 to JSONObject().put("accepted", true)
                }
            })
            manager.installSessionRestoreTestSeam(session)
            manager.installNativeGatewayTestSeam(gateway, providers)
        }

        fun dirty() = context.getSharedPreferences("vortx_sync_dirty", 0)
        fun stampDirty() { dirty().edit().putString("vortx.sync.dirtySettings.${account.id}", "{\"stremiox.autoSkip\":123.25}").commit() }
        fun assertDirty() { assertTrue(dirty().contains("vortx.sync.dirtySettings.${account.id}")) }
        fun replace(next: VortXSyncManager.Session) {
            manager.replaceSyncSessionTestSeam(next)
            manager.installSessionRestoreTestSeam(next)
        }
        suspend fun close() { manager.cancelSyncTestWork(); NativeProviderAccess.unbindForTest() }
    }

    @Test fun `captured admission rejects an in place data key replacement`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val f = Fixture(StandardTestDispatcher(testScheduler))
        try {
            val admission = requireNotNull(f.manager.captureSyncLeaseAdmissionTestSeam())
            requireNotNull(f.manager.currentSession()).dataKey[0] = 99
            var writes = 0
            assertFalse(admission { writes++; true })
            assertEquals(0, writes)
        } finally { f.close(); Dispatchers.resetMain() }
    }

    @Test fun `current native fixture reaches encrypted PUT and exact acknowledgement`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val f = Fixture(StandardTestDispatcher(testScheduler))
        try {
            val synced = f.manager.syncUp()
            assertEquals(1, f.applies)
            assertEquals(1, f.puts)
            assertEquals(1, f.acknowledgements)
            assertEquals(11L, f.manager.lastAppliedVersion())
            assertTrue(synced)
        } finally { f.close(); Dispatchers.resetMain() }
    }

    @Test fun `native late export cannot publish under a changed data key`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val f = Fixture(StandardTestDispatcher(testScheduler))
        try {
            f.onExport = { requireNotNull(f.manager.currentSession()).dataKey[0] = 99 }
            assertFalse(f.manager.syncUp())
            assertEquals(1, f.applies)
            assertEquals(0, f.puts)
            assertEquals(0, f.acknowledgements)
            assertEquals(0L, f.manager.lastAppliedVersion())
        } finally { f.close(); Dispatchers.resetMain() }
    }

    @Test fun `recovered same owner epoch with a different key retires the captured admission`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val f = Fixture(StandardTestDispatcher(testScheduler))
        try {
            val admission = requireNotNull(f.manager.captureSyncLeaseAdmissionTestSeam())
            f.manager.installUnavailableSessionRestoreTestSeam()
            assertTrue(f.manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.UnknownOrUnavailable)
            val recovered = f.session.copy(dataKey = ByteArray(32) { 23 })
            f.manager.installSessionRestoreTestSeam(recovered)
            f.manager.retrySessionRestore()
            var writes = 0
            assertFalse(admission { writes++; true })
            assertEquals(0, writes)
            assertTrue(requireNotNull(f.manager.captureSyncLeaseAdmissionTestSeam()).invoke { true })
        } finally { f.close(); Dispatchers.resetMain() }
    }

    @Test fun `native export after same account session replacement never uploads or acknowledges`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        try {
            for (entry in listOf("syncUp", "pushThisDevice", "mergeBoth")) {
                val f = Fixture(StandardTestDispatcher(testScheduler))
                try {
                    f.onExport = { f.replace(f.session.copy(token = "replacement-token")) }
                    val result = when (entry) {
                        "pushThisDevice" -> f.manager.pushThisDevice()
                        "mergeBoth" -> f.manager.mergeBoth()
                        else -> f.manager.syncUp()
                    }
                    assertFalse(entry, result)
                    assertTrue("Export must actually execute", f.applies > 0)
                    assertEquals(0, f.puts)
                    assertEquals(0, f.acknowledgements)
                    assertEquals(0L, f.manager.lastAppliedVersion())
                } finally { f.close() }
            }
        } finally { Dispatchers.resetMain() }
    }

    @Test fun `native queued response rejects A B A even when account token and key return to A`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val f = Fixture(StandardTestDispatcher(testScheduler))
        try {
            f.getEntered = CompletableDeferred()
            f.getRelease = CompletableDeferred()
            val pending = async { f.manager.pushThisDevice() }
            f.getEntered!!.await()
            f.replace(f.session.copy(account = f.account.copy(id = "00000000-0000-0000-0000-000000000789")))
            f.replace(f.session)
            f.getRelease!!.complete(Unit)
            assertFalse(pending.await())
            assertEquals(0, f.applies)
            assertEquals(0, f.puts)
            assertEquals(0, f.acknowledgements)
            assertEquals(0L, f.manager.lastAppliedVersion())
        } finally { f.close(); Dispatchers.resetMain() }
    }

    @Test fun `late accepted native upload cannot clear replacement session dirty stamps`() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val f = Fixture(StandardTestDispatcher(testScheduler))
        try {
            f.stampDirty()
            f.onPut = { f.replace(f.session.copy(token = "replacement-token")) }
            assertFalse(f.manager.syncUp())
            assertEquals(1, f.puts)
            assertEquals(0, f.acknowledgements)
            assertEquals(0L, f.manager.lastAppliedVersion())
            f.assertDirty()
        } finally { f.close(); Dispatchers.resetMain() }
    }

    private class MemoryContext : ContextWrapper(null) {
        private val stores = mutableMapOf<String, SharedPreferences>()
        override fun getApplicationContext(): Context = this
        override fun getPackageName() = "com.vortx.android.native.owner.test"
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = stores.getOrPut(name) {
            val values = linkedMapOf<String, Any?>()
            fun editor(): SharedPreferences.Editor {
                val edits = linkedMapOf<String, Any?>()
                var clear = false
                return Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
                    when (method.name) {
                        "clear" -> { clear = true; proxy }
                        "remove" -> { edits[args!![0] as String] = null; proxy }
                        "commit", "apply" -> {
                            if (clear) values.clear()
                            edits.forEach { (k, v) -> if (v == null) values.remove(k) else values[k] = v }
                            if (method.name == "commit") true else null
                        }
                        else -> if (method.name.startsWith("put")) { edits[args!![0] as String] = args[1]; proxy } else null
                    }
                } as SharedPreferences.Editor
            }
            Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
                when (method.name) {
                    "getAll" -> values.toMap()
                    "contains" -> values.containsKey(args!![0])
                    "edit" -> editor()
                    "registerOnSharedPreferenceChangeListener", "unregisterOnSharedPreferenceChangeListener" -> null
                    else -> if (method.name.startsWith("get")) values[args!![0]] ?: args[1] else null
                }
            } as SharedPreferences
        }
        override fun deleteSharedPreferences(name: String) = stores.remove(name) != null
    }
}
