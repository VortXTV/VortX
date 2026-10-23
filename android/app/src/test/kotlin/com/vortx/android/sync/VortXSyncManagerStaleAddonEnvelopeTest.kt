package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.data.AddonPrefsStore
import com.vortx.android.data.AddonTombstones
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
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
import org.junit.Assume
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class VortXSyncManagerStaleAddonEnvelopeTest {
    private val managers = mutableListOf<VortXSyncManager>()
    private fun newManager(context: Context) = VortXSyncManager(context).also { managers.add(it) }
    @org.junit.After fun cleanupManagers() = runBlocking {
        managers.forEach { it.cancelSyncTestWork() }
        managers.clear()
    }

    @Test fun `addon invocation captures before queued work and manifest completion across account switch`() = kotlinx.coroutines.test.runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        try {
            for (mode in listOf("manifest", "order", "disabled", "remove")) for (uid in listOf("signed-out", "shared")) {
                val manager = newManager(MemoryContext())
                val key = ByteArray(32)
                val a = VortXSyncManager.Session("a", VortXSyncManager.Account("A", "a@example.test", "A", false), key)
                val b = VortXSyncManager.Session("b", VortXSyncManager.Account("B", "b@example.test", "B", false), key)
                manager.installSyncTestSeam(a, 0, { _, _, _, _ -> 404 to JSONObject() })
                val fence = com.vortx.android.engine.HistoryOwnerFence(
                    captureOwner = { revision -> com.vortx.android.data.ContinueWatchingOwner(com.vortx.android.profile.UserProfile.OWNER_ID, "primary", uid, true, revision) },
                    ownerRouteMatches = { it.principal == uid }, transitionInProgress = { false },
                )
                var captures = 0
                var writes = 0
                fun capture(): com.vortx.android.engine.OwnerAddonMutationAdmission {
                    captures++
                    return com.vortx.android.engine.OwnerAddonMutationAdmission.capture(fence, manager.captureLocalLibraryMutationAdmission(), manager.captureAddonPublicationLease())
                }
                val response = kotlinx.coroutines.CompletableDeferred<String>()
                val work = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { runCatching {
                    if (mode == "manifest") com.vortx.android.engine.performOwnedAddonInstall(::capture, { response.await() }) { admission, _ -> admission.mutate { writes++ } }
                    else com.vortx.android.engine.withOwnerAddonMutationAdmission(kotlinx.coroutines.test.StandardTestDispatcher(testScheduler), ::capture) { admission -> admission.mutate { writes++ } }
                } }
                assertEquals(1, captures)
                manager.replaceSyncSessionTestSeam(b)
                response.complete("manifest")
                testScheduler.runCurrent()
                assertTrue(work.await().isFailure)
                assertEquals("$mode must not mutate native state, tombstones, or prefs under B", 0, writes)
            }
        } finally { cleanupManagers(); Dispatchers.resetMain() }
    }

    @Test fun `addon account identifiers retain exact case without claiming a legacy namespace`() {
        val context = MemoryContext()
        val tombstones = AddonTombstones(context)
        val prefs = AddonPrefsStore(context)
        val endpoint = "https://addon.example/Secret/manifest.json"
        try {
            context.getSharedPreferences("vortx_settings", Context.MODE_PRIVATE).edit()
                .putString("stremiox.addons.deleted.account.owner", JSONArray().put(endpoint).toString()).commit()
            context.getSharedPreferences("vortx.addon.prefs", Context.MODE_PRIVATE).edit()
                .putString("vortx.sync.appliedAddonOrder.account.owner", JSONArray().put(endpoint).toString()).commit()
            AddonTombstones.activateAccount("owner")
            AddonPrefsStore.activateAccount("owner")
            assertTrue("Legacy normalized owner has no exact account attribution", tombstones.all().isEmpty())
            assertTrue(prefs.appliedOrder().isEmpty())
            tombstones.tombstone(endpoint)
            prefs.setAppliedOrder(listOf(endpoint))
            AddonTombstones.activateAccount("Owner")
            AddonPrefsStore.activateAccount("Owner")
            assertTrue(tombstones.all().isEmpty())
            assertTrue(prefs.appliedOrder().isEmpty())
            AddonTombstones.activateAccount("owner")
            AddonPrefsStore.activateAccount("owner")
            assertEquals(setOf(endpoint), tombstones.all())
            assertEquals(listOf(endpoint), prefs.appliedOrder())
        } finally { AddonTombstones.activateAccount(null); AddonPrefsStore.activateAccount(null) }
    }

    @Test
    fun `queued typed add and remove capture invocation owner before dispatcher can adopt B`() = kotlinx.coroutines.test.runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        try {
            for (action in listOf("add", "remove", "manual")) for (transition in listOf("account", "session", "native")) {
                val context = MemoryContext()
                val manager = newManager(context)
                val watched = OwnerWatchedIntentStore(MemoryLibraryProofPersistence())
                manager.installOwnerWatchedIntentTestSeam(watched)
                val key = ByteArray(32) { (it + 1).toByte() }
                val a = VortXSyncManager.Session("token-a", VortXSyncManager.Account("A-queued", "a@example.test", "A", false), key)
                val b = VortXSyncManager.Session("token-b", VortXSyncManager.Account("B-queued", "b@example.test", "B", false), key)
                manager.installSyncTestSeam(a, 0L, transport = { _, _, _, _ -> 404 to JSONObject() })
                val aStore = LibraryTombstones(context)
                aStore.merge(emptyList(), mapOf("tt1" to mapOf("removedAt" to 1000.0)))
                var nativePrincipal = "same-native"
                val fence = com.vortx.android.engine.HistoryOwnerFence(
                    captureOwner = { revision -> com.vortx.android.data.ContinueWatchingOwner(
                        profileId = com.vortx.android.profile.UserProfile.OWNER_ID,
                        accountSlot = "primary", principal = nativePrincipal, usesEngineHistory = true, revision = revision,
                    ) },
                    ownerRouteMatches = { owner -> owner.principal == nativePrincipal },
                    transitionInProgress = { false },
                )
                var captures = 0
                val writes = mutableListOf<String>()
                val queuedDispatcher = kotlinx.coroutines.test.StandardTestDispatcher(testScheduler)
                suspend fun invokeMutation(): Result<Unit> = runCatching {
                    com.vortx.android.engine.withOwnerLibraryMutationAdmission(
                        queuedDispatcher,
                        capture = {
                            captures++
                            com.vortx.android.engine.OwnerLibraryMutationAdmission.capture(
                                fence, manager.captureLocalLibraryMutationAdmission(), { LibraryTombstones(context) },
                                watchedIntents = manager.captureOwnerWatchedIntentLease(),
                            )
                        },
                    ) { admitted ->
                        admitted.mutate { _, tombstones ->
                            writes += "${manager.currentSession()?.account?.id}:$action"
                            when (action) {
                                "add" -> tombstones.forget("tt1")
                                "remove" -> tombstones.tombstone("tt1")
                                "manual" -> assertTrue(requireNotNull(admitted.watchedIntents).record("tt1", listOf("tt1:1:1"), true))
                            }
                            Unit
                        }
                    }
                }
                // UNDISPATCHED enters the production wrapper immediately, but its withContext(Default)
                // equivalent remains queued. Moving capture inside that hop makes this assertion fail.
                val queued = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { invokeMutation() }
                assertEquals(1, captures)
                assertTrue(writes.isEmpty())
                when (transition) {
                    "account" -> manager.replaceSyncSessionTestSeam(b)
                    "session" -> manager.replaceSyncSessionTestSeam(a.copy(token = "replacement-token"))
                    "native" -> nativePrincipal = "other-native"
                }
                testScheduler.runCurrent()
                assertTrue("$action/$transition must fail closed", queued.await().isFailure)
                assertTrue("No native action against replacement owner", writes.isEmpty())
                assertTrue(watched.entries("A-queued").isEmpty())
                assertTrue(watched.entries("B-queued").isEmpty())
                if (transition == "account") assertTrue(LibraryTombstones(context).all().isEmpty())
                manager.replaceSyncSessionTestSeam(a)
                assertEquals(setOf("tt1"), LibraryTombstones(context).all())
                // A fresh invocation still succeeds under its own captured account and native owner.
                val fresh = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { invokeMutation() }
                testScheduler.runCurrent()
                assertTrue(fresh.await().isSuccess)
                assertEquals(listOf("A-queued:$action"), writes)
            }
        } finally {
            LibraryTombstones.activateAccount(null)
            cleanupManagers(); Dispatchers.resetMain()
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
        assertEquals(listOf("https://web.example/MANIFEST.JSON", webUrl), parsed.addonOrder)
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
    fun `remote descriptor admission keeps self hosted endpoints and rejects unsafe descriptors`() {
        fun row(url: Any, id: Any, name: Any) = JSONObject()
            .put("transportUrl", url)
            .put("manifest", JSONObject().put("id", id).put("name", name))

        val document = JSONObject().put(
            "addons",
            JSONArray()
                .put(row("https://user:token@public.example/manifest.json", "one", "One"))
                .put(row("https://127.0.0.1/manifest.json", "two", "Two"))
                .put(row("https://[::1]/manifest.json", "three", "Three"))
                .put(row("https://169.254.169.254/manifest.json", "metadata-v4", "Metadata"))
                .put(row("https://100.100.100.200/manifest.json", "metadata-alibaba", "Metadata"))
                .put(row("https://[fd00:ec2::254]/manifest.json", "metadata-v6", "Metadata"))
                .put(row("https://good.example/manifest.json", 7, "Bad id type"))
                .put(row("https://also-good.example/manifest.json", "four", JSONObject()))
                .put(row("https://valid.example/manifest.json", "valid", "Valid")),
        )

        assertEquals(
            listOf("https://127.0.0.1/manifest.json", "https://[::1]/manifest.json", "https://valid.example/manifest.json"),
            VortXSyncDoc.parse(document).addons.map { it.transportUrl },
        )
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
        val manager = newManager(MemoryContext())
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
        val manager = newManager(context)
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
                    .getString("stremiox.addons.deleted.account.v2.recovered-account", null)
                ?.contains(removed) == true,
        )
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
