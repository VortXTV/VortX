package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.profile.UserProfile
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
    @org.junit.Before fun mainDispatcher() { Dispatchers.setMain(UnconfinedTestDispatcher()) }
    @org.junit.After fun resetDispatcher() { Dispatchers.resetMain() }
    private val key = ByteArray(32) { (it + 1).toByte() }
    private val account = VortXSyncManager.Account("00000000-0000-0000-0000-000000000123", "fixture@example.invalid", "Fixture", false)
    private class Gateway : NativeAccountGateway {
        var applied = 0
        var retired = 0
        var last: JSONObject? = null
        override fun retire() { retired++ }
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
                manager.installNativeGatewayTestSeam(gateway)
                assertFalse(manager.syncDown(true)); assertFalse(manager.syncUp())
                assertEquals(0, gateway.applied); assertEquals(0, puts)
            } finally { manager.cancelSyncTestWork() }
        }
    }
    @Test fun `native push preserves adjacent authenticated fields and excludes device selection`() = runBlocking {
        val manager = VortXSyncManager(TestContext()); val gateway = Gateway()
        val doc = JSONObject().put("foreign", JSONObject().put("keep", 1)).put("vortx", JSONObject().put("unknownPreference", "retained"))
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
            manager.installNativeGatewayTestSeam(gateway)
            assertTrue(manager.syncDown(true)); assertTrue(manager.syncUp())
            val result = requireNotNull(uploaded)
            assertEquals(1, result.getJSONObject("foreign").getInt("keep"))
            assertEquals("retained", result.getJSONObject("vortx").getString("unknownPreference"))
            assertTrue(result.getJSONObject("nativeSync").getBoolean("fixture"))
            assertFalse(result.getJSONObject("nativeSync").has("activeProfileId"))
            assertTrue(result.has("settings")); assertEquals(2, gateway.applied)
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
