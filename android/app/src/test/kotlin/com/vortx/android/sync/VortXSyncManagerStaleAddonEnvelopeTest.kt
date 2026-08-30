package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.data.AddonTombstones
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class VortXSyncManagerStaleAddonEnvelopeTest {

    @Test
    fun `public sync down folds only add-on tombstones from an authenticated older envelope`() = runBlocking {
        val main = UnconfinedTestDispatcher()
        Dispatchers.setMain(main)
        try {
            val context = MemoryContext()
            val settings = context.getSharedPreferences("vortx_settings", Context.MODE_PRIVATE)
            settings.edit().putString("local.setting", "keep").commit()
            val addonTombstones = AddonTombstones(context)
            val libraryTombstones = LibraryTombstones(context)
            val account = VortXSyncManager.Account("account", "person@example.test", "person", false)
            val key = ByteArray(32) { (it + 1).toByte() }
            val manager = VortXSyncManager(context)
            var versionedPayloadApplied = false

            val removedAddon = "https://peer.example/manifest.json"
            val oldDocument = JSONObject()
                .put("settings", JSONObject().put("local.setting", "replace"))
                .put("apiKeys", JSONObject().put("realdebrid", "remote-value"))
                .put("foreignAccountField", JSONObject().put("keep", false))
                .put(
                    "vortx",
                    JSONObject()
                        .put("profiles", JSONArray().put(JSONObject().put("id", "PEER").put("name", "Peer")))
                        .put(
                            "byProfile",
                            JSONObject().put(
                                "PEER",
                                JSONObject().put("library", JSONArray().put(JSONObject().put("id", "peer-item"))),
                            ),
                        )
                        .put("deletedLibrary", JSONArray().put("library-entry"))
                        .put(
                            "deletedLibraryTs",
                            JSONObject().put("library-entry", JSONObject().put("removedAt", 200.0)),
                        )
                        .put(
                            "deletedAddonsTs",
                            JSONObject().put(removedAddon, JSONObject().put("removedAt", 200.0)),
                        ),
                )
            val envelope = requireNotNull(
                VortXCrypto.sealDocument(
                    dataKey = key,
                    plaintext = oldDocument.toString().toByteArray(),
                    accountId = account.id,
                    version = 9L,
                    writeV2 = true,
                ),
            )
            val response = JSONObject().put("version", 9L).put("document", envelope)
            manager.installSyncTestSeam(
                testSession = VortXSyncManager.Session("token", account, key),
                highWaterVersion = 10L,
                transport = { method, path, _, bearerToken ->
                    assertEquals("GET", method)
                    assertEquals("/v1/backup", path)
                    assertEquals("token", bearerToken)
                    200 to response
                },
                onVersionedPayloadApply = { versionedPayloadApplied = true },
            )

            assertTrue(manager.syncDown(force = true))
            assertTrue(removedAddon in addonTombstones.all())
            assertFalse("library-entry" in libraryTombstones.all())
            assertFalse(versionedPayloadApplied)
            assertEquals("keep", settings.getString("local.setting", null))
            assertEquals(10L, manager.lastAppliedVersion())

            // The ordinary account probe uses the strict H-2 pull and must reject the identical v9 envelope.
            assertEquals(VortXSyncManager.AccountDataProbe.UNREACHABLE, manager.accountHasSyncData())
            assertEquals(10L, manager.lastAppliedVersion())
        } finally {
            Dispatchers.resetMain()
        }
    }
}

private class MemoryContext : ContextWrapper(null) {
    private val preferences = mutableMapOf<String, MemoryPreferences>()

    override fun getApplicationContext(): Context = this

    override fun getPackageName(): String = "com.vortx.android.sync.test"

    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
        preferences.getOrPut(name, ::MemoryPreferences)

    override fun deleteSharedPreferences(name: String): Boolean = preferences.remove(name) != null
}

private class MemoryPreferences : SharedPreferences {
    private val values = linkedMapOf<String, Any?>()
    private val listeners = linkedSetOf<SharedPreferences.OnSharedPreferenceChangeListener>()

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()
    override fun getString(key: String, defValue: String?): String? = values[key] as? String ?: defValue
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? Set<*>)?.filterIsInstance<String>()?.toMutableSet() ?: defValues
    override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue
    override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue
    override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue
    override fun getBoolean(key: String, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
    override fun contains(key: String): Boolean = values.containsKey(key)
    override fun edit(): SharedPreferences.Editor = Editor()
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners += listener
    }
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) {
        listeners -= listener
    }

    private inner class Editor : SharedPreferences.Editor {
        private val changes = linkedMapOf<String, Any?>()
        private var clearAll = false

        override fun putString(key: String, value: String?): SharedPreferences.Editor = apply { changes[key] = value }
        override fun putStringSet(key: String, values: MutableSet<String>?): SharedPreferences.Editor =
            apply { changes[key] = values?.toSet() }
        override fun putInt(key: String, value: Int): SharedPreferences.Editor = apply { changes[key] = value }
        override fun putLong(key: String, value: Long): SharedPreferences.Editor = apply { changes[key] = value }
        override fun putFloat(key: String, value: Float): SharedPreferences.Editor = apply { changes[key] = value }
        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = apply { changes[key] = value }
        override fun remove(key: String): SharedPreferences.Editor = apply { changes[key] = null }
        override fun clear(): SharedPreferences.Editor = apply { clearAll = true }
        override fun commit(): Boolean {
            val changed = linkedSetOf<String>()
            if (clearAll) {
                changed += values.keys
                values.clear()
            }
            for ((key, value) in changes) {
                if (value == null) {
                    if (values.remove(key) != null) changed += key
                } else if (values[key] != value) {
                    values[key] = value
                    changed += key
                }
            }
            for (key in changed) listeners.forEach { it.onSharedPreferenceChanged(this@MemoryPreferences, key) }
            return true
        }
        override fun apply() { commit() }
    }
}
