package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.data.AddonPrefsStore
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
    fun `public manager restores existing history and never advances a failed or expired receipt`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        try {
            for (mode in listOf("success", "tombstoneOnly", "readded", "null", "wrongUid", "afterRead", "beforeDispatch", "afterResponse")) {
                val context = MemoryContext()
                val manager = VortXSyncManager(context)
                // Construct an empty store without Android's device-language bootstrap in this JVM test.
                val store = com.vortx.android.profile.ProfileStore::class.java.getDeclaredConstructor(Context::class.java)
                    .apply { isAccessible = true }.newInstance(context)
                manager.attachSyncSeams(store)
                val key = ByteArray(32) { (it + 1).toByte() }
                val accountA = VortXSyncManager.Account("A-$mode", "a@example.test", "A", false)
                val accountB = VortXSyncManager.Account("B-$mode", "b@example.test", "B", false)
                val row = JSONObject().put("id", "tt1").put("type", "movie").put("name", "Movie")
                    .put("v", "tt1").put("t", 0).put("d", 50).put("eventEpochMs", 2000)
                    .put("lastWatched", "1970-01-01T00:00:02Z").put("watched", JSONObject.NULL)
                    .put("currentVideoWatched", true).put("wholeTitleWatched", true).put("timesWatched", 1)
                val doc = JSONObject().put("vortx", JSONObject().put("library", JSONArray().put(row)))
                if (mode == "tombstoneOnly") {
                    doc.getJSONObject("vortx").remove("library")
                    doc.getJSONObject("vortx").put("deletedLibraryTs", JSONObject().put("tt1", JSONObject().put("removedAt", 2000)))
                }
                if (mode == "readded") {
                    row.put("removed", true)
                    doc.getJSONObject("vortx").put("deletedLibraryTs", JSONObject().put("tt1", JSONObject().put("removedAt", 2000).put("addedAt", 3000)))
                }
                val envelope = requireNotNull(VortXCrypto.sealDocument(key, doc.toString().toByteArray(), accountA.id, 2L, true))
                manager.installSyncTestSeam(VortXSyncManager.Session("A-token", accountA, key), 1L,
                    transport = { _, _, _, _ -> 200 to JSONObject().put("version", 2L).put("document", envelope) })
                fun replaceAccount() = manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("B-token", accountB, key))
                var nativeWrites = 0
                var attemptedApply = false
                val native = com.vortx.android.engine.NativeOwnerLibraryGateway(
                    read = {
                        if (mode == "afterRead") replaceAccount()
                        // Both VortX accounts deliberately share this same native UID.
                        """{"uid":"same-native","events":[{"meta":{"id":"tt1","type":"movie","name":"Movie"},"currentVideoId":"tt1","timeOffsetMs":1000,"durationMs":50000,"eventEpochMs":1000,"lastWatchedEpochMs":1000,"watched":null,"currentVideoWatched":false,"wholeTitleWatched":false,"timesWatched":0,"removed":false}]}"""
                    },
                    restore = { request ->
                        nativeWrites++
                        if (mode == "tombstoneOnly") {
                            val event = JSONObject(request).getJSONArray("events").getJSONObject(0)
                            assertTrue(event.getBoolean("removed"))
                            assertEquals(2000L, event.getLong("genuineEventEpochMs"))
                            assertEquals(1000L, event.getLong("lastWatchedEpochMs"))
                        }
                        if (mode == "afterResponse") replaceAccount()
                        if (mode == "null") "null" else
                            """{"uid":"${if (mode == "wrongUid") "wrong" else "same-native"}","events":[{"id":"tt1","type":"movie","currentVideoId":"tt1","eventEpochMs":2000}]}"""
                    },
                    add = { error("Existing history must not use metadata add") },
                )
                manager.attachAccountLibraryGateway(object : AccountLibrarySyncGateway {
                    private val lease = object : AccountAddonGatewayLease {}
                    override fun captureAccountLibraryLease(): AccountAddonGatewayLease = lease
                    override suspend fun accountLibrarySnapshot(nativeLease: AccountAddonGatewayLease, admit: ((() -> Boolean) -> Boolean)) = native.snapshot("same-native", admit)
                    override suspend fun addAccountLibraryItems(nativeLease: AccountAddonGatewayLease, items: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean)): Boolean {
                        attemptedApply = true
                        if (mode == "beforeDispatch") replaceAccount()
                        return native.apply("same-native", items, admit)
                    }
                })
                manager.syncDown(force = true)
                if (mode == "success" || mode == "tombstoneOnly") {
                    assertTrue(attemptedApply)
                    assertEquals(1, nativeWrites)
                    assertEquals(2L, manager.lastAppliedVersion())
                } else if (mode == "readded") {
                    assertEquals(0, nativeWrites)
                    assertFalse("Newer explicit add wins", "tt1" in LibraryTombstones(context).all())
                    assertEquals(2L, manager.lastAppliedVersion())
                } else {
                    assertTrue(mode, manager.lastAppliedVersion() < 2L)
                    if (mode == "afterRead" || mode == "beforeDispatch") assertEquals(mode, 0, nativeWrites)
                }
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `public sync up cannot publish a native snapshot returned after same uid account replacement`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        try {
            val context = MemoryContext()
            val manager = VortXSyncManager(context)
            val store = com.vortx.android.profile.ProfileStore::class.java.getDeclaredConstructor(Context::class.java)
                .apply { isAccessible = true }.newInstance(context)
            manager.attachSyncSeams(store)
            val key = ByteArray(32) { (it + 1).toByte() }
            val a = VortXSyncManager.Session("token-a", VortXSyncManager.Account("A-export", "a@example.test", "A", false), key)
            val b = VortXSyncManager.Session("token-b", VortXSyncManager.Account("B-export", "b@example.test", "B", false), key)
            var uploads = 0
            manager.installSyncTestSeam(a, 0L, transport = { method, _, _, _ ->
                if (method != "GET") uploads++
                404 to JSONObject()
            })
            val native = com.vortx.android.engine.NativeOwnerLibraryGateway(
                read = { manager.replaceSyncSessionTestSeam(b); """{"uid":"same-native","events":[]}""" },
                restore = { error("Export cannot restore") }, add = { error("Export cannot add") },
            )
            manager.attachAccountLibraryGateway(object : AccountLibrarySyncGateway {
                private val lease = object : AccountAddonGatewayLease {}
                override fun captureAccountLibraryLease(): AccountAddonGatewayLease = lease
                override suspend fun accountLibrarySnapshot(nativeLease: AccountAddonGatewayLease, admit: ((() -> Boolean) -> Boolean)) = native.snapshot("same-native", admit)
                override suspend fun addAccountLibraryItems(nativeLease: AccountAddonGatewayLease, items: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean)): Boolean = error("Export cannot import")
            })
            assertFalse(manager.syncUp())
            assertEquals("B-export", manager.currentSession()?.account?.id)
            assertEquals(0, uploads)
            assertEquals(0L, manager.lastAppliedVersion())
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `account descriptors union app then web, skip shallow rows, and retain normalized order`() {
        val appUrl = "https://app.example/manifest.json"
        val webUrl = "https://web.example/manifest.json"
        fun descriptor(url: String, id: String, name: String) = JSONObject()
            .put("transportUrl", url)
            .put("manifest", JSONObject().put("id", id).put("name", name))

        val document = JSONObject()
            .put("addonOrder", JSONArray().put(" HTTPS://WEB.EXAMPLE/MANIFEST.JSON ").put(webUrl))
            .put(
                "vortx",
                JSONObject().put(
                    "addons",
                    JSONArray().put(descriptor(appUrl, "app", "App copy")).put(JSONObject().put("transportUrl", "https://shallow.example")),
                ),
            )
            .put(
                "addons",
                JSONArray()
                    .put(descriptor(appUrl, "app-web", "Web copy that must lose"))
                    .put(descriptor(webUrl, "web", "Website only")),
            )

        val parsed = VortXSyncDoc.parse(document)
        assertEquals(listOf(appUrl, webUrl), parsed.addons.map { it.transportUrl })
        assertEquals("app", parsed.addons.first().raw.getJSONObject("manifest").getString("id"))
        assertEquals(listOf(webUrl.lowercase()), parsed.addonOrder)
    }

    @Test
    fun `account order is isolated and an acknowledgement cannot clear a newer local drag`() {
        val context = MemoryContext()
        val prefs = AddonPrefsStore(context)
        val first = "https://one.example/manifest.json"
        val second = "https://two.example/manifest.json"

        AddonPrefsStore.activateAccount("account-a")
        assertTrue(prefs.setAppliedOrder(listOf(first)))
        val firstDirty = requireNotNull(prefs.orderDirtyAt())
        assertTrue(prefs.setAppliedOrder(listOf(second)))
        val secondDirty = requireNotNull(prefs.orderDirtyAt())
        assertTrue(secondDirty > firstDirty)
        prefs.clearPushedOrderDirty(firstDirty)
        assertEquals(secondDirty, prefs.orderDirtyAt())

        AddonPrefsStore.activateAccount("account-b")
        assertTrue(prefs.appliedOrder().isEmpty())
        assertTrue(prefs.setAppliedOrder(listOf(first), remote = true))
        assertEquals(listOf(first), prefs.appliedOrder())
        assertEquals(null, prefs.orderDirtyAt())

        AddonPrefsStore.activateAccount("account-a")
        assertEquals(listOf(second), prefs.appliedOrder())
        assertEquals(secondDirty, prefs.orderDirtyAt())
    }

    @Test
    fun `remote descriptor admission rejects userinfo private literals and malformed manifest fields`() {
        fun row(url: Any, id: Any, name: Any) = JSONObject()
            .put("transportUrl", url)
            .put("manifest", JSONObject().put("id", id).put("name", name))

        val document = JSONObject().put(
            "addons",
            JSONArray()
                .put(row("https://user:token@public.example/manifest.json", "one", "One"))
                .put(row("https://127.0.0.1/manifest.json", "two", "Two"))
                .put(row("https://[::1]/manifest.json", "three", "Three"))
                .put(row("https://good.example/manifest.json", 7, "Bad id type"))
                .put(row("https://also-good.example/manifest.json", "four", JSONObject()))
                .put(row("https://valid.example/manifest.json", "valid", "Valid")),
        )

        assertEquals(listOf("https://valid.example/manifest.json"), VortXSyncDoc.parse(document).addons.map { it.transportUrl })
    }

    @Test
    fun `owner library is app first typed zero safe and never treats omission as clear`() {
        fun row(id: Any, type: Any, seconds: Any = 0) = JSONObject()
            .put("id", id).put("type", type).put("name", "Title").put("t", seconds).put("d", 0).put("v", "tt1:1:1")
        val document = JSONObject()
            .put("library", JSONArray().put(row("tt999", "movie", 9)))
            .put("vortx", JSONObject().put("library", JSONArray()
                .put(row("tt123", "movie", 0))
                .put(row("bad", "movie", 7))
                .put(row("tmdb:5", "series", -3))))
        val parsed = VortXSyncDoc.parse(document).ownerLibrary
        assertEquals(2, parsed?.size)
        assertEquals("tt123", parsed?.first()?.metaId)
        assertEquals(0L, parsed?.first()?.timeOffsetMs)
        assertEquals(0L, parsed?.get(1)?.timeOffsetMs)
        assertEquals(null, VortXSyncDoc.parse(JSONObject()).ownerLibrary)

        val vortx = JSONObject().put("library", JSONArray().put(row("tt777", "movie", 4)))
        VortXSyncDoc.mergeLocalOwnerLibrary(vortx, emptyList(), emptySet())
        assertEquals("tt777", vortx.getJSONArray("library").getJSONObject(0).getString("id"))
        VortXSyncDoc.mergeLocalOwnerLibrary(vortx, listOf(parsed!!.first()), setOf("tt123"))
        assertEquals("tt777", vortx.getJSONArray("library").getJSONObject(0).getString("id"))

        val remote = row("tt123", "movie", 42).put("d", 99).put("v", "tt123:2:3")
            .put("lastWatched", "2026-10-01T10:00:00Z").put("watched", "opaque-native-bits")
        val preserved = JSONObject().put("library", JSONArray().put(remote))
        VortXSyncDoc.mergeLocalOwnerLibrary(preserved, listOf(parsed.first()), emptySet())
        val after = preserved.getJSONArray("library").getJSONObject(0)
        assertEquals(42, after.getInt("t")); assertEquals(99, after.getInt("d"))
        assertEquals("tt123:2:3", after.getString("v")); assertEquals("2026-10-01T10:00:00Z", after.getString("lastWatched"))
        assertEquals("opaque-native-bits", after.getString("watched"))
    }

    @Test
    fun `queued same native uid dispatch is rejected after vortx account replacement`() {
        val manager = VortXSyncManager(MemoryContext())
        fun session(id: String) = VortXSyncManager.Session(
            token = "token-$id",
            account = VortXSyncManager.Account(id, "same-native-uid@example.test", "same native uid", false),
            dataKey = ByteArray(32),
        )
        manager.installSyncTestSeam(session("A"), 0L, transport = { _, _, _, _ -> 404 to null })
        val queuedA = requireNotNull(manager.captureSyncLeaseAdmissionTestSeam())
        manager.replaceSyncSessionTestSeam(session("B"))
        var nativeDispatches = 0
        assertFalse(queuedA { nativeDispatches += 1; true })
        assertEquals(0, nativeDispatches)

        val currentB = requireNotNull(manager.captureSyncLeaseAdmissionTestSeam())
        assertTrue(currentB { nativeDispatches += 1; true })
        assertEquals(1, nativeDispatches)
    }

    @Test
    fun `unavailable session retry restores signed in add-on tombstone scope and sync payload`() {
        val context = MemoryContext()
        val manager = VortXSyncManager(context)
        val account = VortXSyncManager.Account("recovered-account", "person@example.test", "person", false)
        val session = VortXSyncManager.Session("token", account, ByteArray(32) { (it + 1).toByte() })
        val tombstones = AddonTombstones(context)
        val removed = "https://recovered.example/manifest.json"

        manager.installUnavailableSessionRestoreTestSeam()
        assertTrue(manager.sessionOwnerSnapshot() is SessionOwnerSnapshot.UnknownOrUnavailable)
        manager.installSessionRestoreTestSeam(session, ownerEpoch = 7L)
        manager.retrySessionRestore()

        assertEquals(SessionOwnerSnapshot.Account(account.id, 7L), manager.sessionOwnerSnapshot())
        assertTrue(tombstones.tombstone(removed))
        assertTrue(removed in tombstones.all())
        assertEquals(
            mapOf("removedAt" to tombstones.timestampsForSync().getValue(removed).getValue("removedAt")),
            tombstones.timestampsForSync()[removed],
        )
        val syncPayload = applyAddonTombstonesToVortx(JSONObject(), tombstones)
        assertEquals(removed, syncPayload.getJSONArray("deletedAddons").getString(0))
        assertTrue(syncPayload.getJSONObject("deletedAddonsTs").has(removed))
        assertTrue(
            context.getSharedPreferences("vortx_settings", Context.MODE_PRIVATE)
                .getString("stremiox.addons.deleted.account.recovered-account", null)
                ?.contains(removed) == true,
        )
    }

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
            val addonGateway = RecordingAddonGateway(removedAddon)
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
            manager.attachAccountAddonGateway(addonGateway)

            assertTrue(manager.syncDown(force = true))
            assertTrue(removedAddon in addonTombstones.all())
            assertEquals(listOf(removedAddon), addonGateway.removed)
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

private class RecordingAddonGateway(url: String) : AccountAddonSyncGateway {
    private data object Lease : AccountAddonGatewayLease
    private val descriptor = VortXSyncDoc.AddonDescriptor(
        transportUrl = url,
        raw = JSONObject()
            .put("transportUrl", url)
            .put("manifest", JSONObject().put("id", "peer").put("name", "Peer")),
    )
    val removed = mutableListOf<String>()

    override fun captureAccountAddonLease(): AccountAddonGatewayLease = Lease
    override suspend fun accountAddonSnapshot(nativeLease: AccountAddonGatewayLease): List<VortXSyncDoc.AddonDescriptor> = listOf(descriptor)
    override suspend fun installAccountAddon(nativeLease: AccountAddonGatewayLease, descriptor: VortXSyncDoc.AddonDescriptor, admit: ((() -> Boolean) -> Boolean)): Boolean = false
    override suspend fun removeAccountAddon(nativeLease: AccountAddonGatewayLease, normalizedTransportUrl: String, admit: ((() -> Boolean) -> Boolean)): Boolean {
        removed += normalizedTransportUrl
        return true
    }
    override suspend fun applyRemoteAddonOrder(nativeLease: AccountAddonGatewayLease, order: List<String>, admit: ((() -> Boolean) -> Boolean)): Boolean = false
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
