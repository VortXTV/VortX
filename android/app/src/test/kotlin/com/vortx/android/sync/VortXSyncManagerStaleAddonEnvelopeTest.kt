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
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class VortXSyncManagerStaleAddonEnvelopeTest {
    private val managers = mutableListOf<VortXSyncManager>()
    private fun newManager(context: Context) = VortXSyncManager(context).also { managers.add(it) }
    @org.junit.After fun cleanupManagers() = runBlocking {
        managers.forEach { it.cancelSyncTestWork() }
        managers.clear()
    }
    @Test fun `B account publishes only authenticated configured addons until explicit import`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        try {
            for (uid in listOf(null, "shared")) {
                val context = MemoryContext()
                val manager = newManager(context)
                manager.attachSyncSeams(com.vortx.android.profile.ProfileStore::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(context))
                val disk = MemoryLibraryProofPersistence()
                manager.installAddonPublicationProofTestSeam(AddonPublicationProofs(disk))
                manager.installLibraryPublicationProofTestSeam(OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence()))
                val key = ByteArray(32) { (it + 1).toByte() }
                val account = VortXSyncManager.Account("B-addons", "b@example.test", "B", false)
                val aOnly = publicationAddon("https://addon.example/TokenA/manifest.json?Key=AA")
                val bOwned = publicationAddon("https://addon.example/tokena/manifest.json?key=aa")
                var resident = listOf(aOnly, bOwned.copy(raw = JSONObject(bOwned.raw.toString()).put("foreignExtra", "A-secret")))
                val peer = JSONObject().put("vortx", JSONObject().put("addons", JSONArray().put(bOwned.raw)))
                var version = 2L
                var uploaded: JSONObject? = null
                manager.installSyncTestSeam(VortXSyncManager.Session("b", account, key), 0, transport = { method, _, body, _ ->
                    if (method == "GET") 200 to JSONObject().put("version", version).put("document", requireNotNull(VortXCrypto.sealDocument(key, peer.toString().toByteArray(), account.id, version, true)))
                    else {
                        val request = requireNotNull(body)
                        version = request.getLong("version")
                        uploaded = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), account.id, version))))
                        200 to JSONObject().put("accepted", true)
                    }
                })
                manager.attachAccountAddonGateway(object : AccountAddonSyncGateway {
                    val lease = object : AccountAddonGatewayLease {}
                    override fun captureAccountAddonLease(): AccountAddonGatewayLease = lease
                    override fun nativeAddonOwner(nativeLease: AccountAddonGatewayLease) = NativeLibraryOwner(uid)
                    override suspend fun accountAddonSnapshot(nativeLease: AccountAddonGatewayLease) = resident
                    override suspend fun installAccountAddon(nativeLease: AccountAddonGatewayLease, descriptor: VortXSyncDoc.AddonDescriptor, admit: ((() -> Boolean) -> Boolean)) = admit { resident = resident + descriptor; true }
                    override suspend fun removeAccountAddon(nativeLease: AccountAddonGatewayLease, normalizedTransportUrl: String, admit: ((() -> Boolean) -> Boolean)) = false
                    override suspend fun applyRemoteAddonOrder(nativeLease: AccountAddonGatewayLease, order: List<String>, admit: ((() -> Boolean) -> Boolean)) = admit { true }
                })
                manager.attachAccountLibraryGateway(object : AccountLibrarySyncGateway {
                    val lease = object : AccountAddonGatewayLease {}
                    override fun captureAccountLibraryLease(): AccountAddonGatewayLease = lease
                    override fun nativeLibraryOwner(nativeLease: AccountAddonGatewayLease) = NativeLibraryOwner(uid)
                    override suspend fun accountLibrarySnapshot(nativeLease: AccountAddonGatewayLease, admit: ((() -> Boolean) -> Boolean)) = emptyList<VortXSyncDoc.OwnerLibraryItem>()
                    override suspend fun addAccountLibraryItems(nativeLease: AccountAddonGatewayLease, items: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean)) = true
                })
                fun output() = requireNotNull(uploaded).getJSONObject("vortx").getJSONArray("addons")
                manager.useAccountData()
                AddonPrefsStore(context).setAppliedOrder(listOf(aOnly.transportUrl, bOwned.transportUrl))
                assertTrue(manager.pushThisDevice())
                assertEquals(1, output().length())
                assertEquals(bOwned.raw.toString(), output().getJSONObject(0).toString())
                assertFalse(output().toString().contains("A-secret"))
                assertEquals(JSONArray().put(bOwned.transportUrl).toString(), requireNotNull(uploaded).getJSONArray("addonOrder").toString())
                assertTrue(manager.mergeBoth())
                assertEquals(1, output().length())
                // A local explicit B install owns only its authored outbound manifest.
                val local = publicationAddon("https://addon.example/B-local/manifest.json")
                requireNotNull(manager.captureAddonPublicationLease()).install(NativeLibraryOwner(uid), local, { resident }) { resident = resident + local }
                assertTrue(manager.pushThisDevice())
                assertEquals(2, output().length())
                assertFalse(output().toString().contains(aOnly.transportUrl))
                assertTrue(manager.importThisDeviceLibraryAndPush())
                assertEquals(3, output().length())
                resident = resident + publicationAddon("https://addon.example/later/manifest.json")
                manager.installAddonPublicationProofTestSeam(AddonPublicationProofs(disk))
                assertTrue(manager.pushThisDevice())
                assertEquals(3, output().length())
                manager.cancelSyncTestWork()
            }
        } finally { LibraryTombstones.activateAccount(null); cleanupManagers(); Dispatchers.resetMain() }
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
    fun `encrypted B sync with shared or null native owner never adopts resident A history implicitly`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        try {
            for (uid in listOf(null, "shared-native")) {
                val context = MemoryContext()
                val manager = newManager(context)
                val profileStore = com.vortx.android.profile.ProfileStore::class.java.getDeclaredConstructor(Context::class.java)
                    .apply { isAccessible = true }.newInstance(context)
                manager.attachSyncSeams(profileStore)
                val disk = MemoryLibraryProofPersistence()
                val proofs = OwnerLibraryPublicationProofs(disk)
                manager.installLibraryPublicationProofTestSeam(proofs)
                val key = ByteArray(32) { (it + 1).toByte() }
                val a = VortXSyncManager.Session("a", VortXSyncManager.Account("A-proof", "a@example.test", "A", false), key)
                val b = VortXSyncManager.Session("b", VortXSyncManager.Account("B-proof", "b@example.test", "B", false), key)
                val peer = JSONObject().put("id", "tt2").put("type", "movie").put("name", "B title")
                    .put("v", "tt2").put("t", 0).put("d", 10).put("lastWatched", "1970-01-01T00:00:01Z").put("eventEpochMs", 1000)
                val doc = JSONObject().put("vortx", JSONObject().put("library", JSONArray().put(peer)))
                var serverVersion = 2L
                var uploaded: JSONObject? = null
                manager.installSyncTestSeam(a, 0, transport = { method, _, body, token ->
                    assertEquals("b", token)
                    if (method == "GET") 200 to JSONObject().put("version", serverVersion).put("document", requireNotNull(VortXCrypto.sealDocument(key, doc.toString().toByteArray(), b.account.id, serverVersion, true)))
                    else {
                        val request = requireNotNull(body)
                        uploaded = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), b.account.id, request.getLong("version")))))
                        serverVersion = request.getLong("version")
                        200 to JSONObject().put("accepted", true)
                    }
                })
                var resident = listOf(publicationRow("tt1", 3000), publicationRow("tt2", 3000))
                fun projection(): String = JSONObject().put("uid", uid ?: JSONObject.NULL).put("events", JSONArray(resident.map { row ->
                    JSONObject().put("meta", JSONObject().put("id", row.metaId).put("type", row.type).put("name", row.name).put("poster", row.poster ?: JSONObject.NULL))
                        .put("currentVideoId", row.videoId ?: JSONObject.NULL).put("timeOffsetMs", row.timeOffsetMs).put("durationMs", row.durationMs)
                        .put("eventEpochMs", row.nativeEventEpochMs).put("lastWatchedEpochMs", OwnerLibraryHistoryPolicy.watchClock(row) ?: JSONObject.NULL)
                        .put("watched", row.watched ?: JSONObject.NULL).put("currentVideoWatched", row.currentVideoWatched ?: JSONObject.NULL)
                        .put("timesWatched", row.timesWatched ?: 0).put("removed", row.removed).put("wholeTitleWatched", row.wholeTitleWatched ?: JSONObject.NULL)
                })).toString()
                val native = com.vortx.android.engine.NativeOwnerLibraryGateway(read = { projection() }, restore = { error("Raw LWW must skip newer A rows") }, add = { error("No metadata add") })
                manager.attachAccountLibraryGateway(object : AccountLibrarySyncGateway {
                    val lease = object : AccountAddonGatewayLease {}
                    override fun captureAccountLibraryLease(): AccountAddonGatewayLease = lease
                    override fun nativeLibraryOwner(nativeLease: AccountAddonGatewayLease) = NativeLibraryOwner(uid)
                    override suspend fun accountLibrarySnapshot(nativeLease: AccountAddonGatewayLease, admit: ((() -> Boolean) -> Boolean)) = native.snapshot(uid, admit)
                    override suspend fun addAccountLibraryItems(nativeLease: AccountAddonGatewayLease, items: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean)) = native.apply(uid, items, admit)
                })
                val expired = requireNotNull(manager.captureLibraryPublicationLease())
                manager.replaceSyncSessionTestSeam(b)
                assertFalse(expired.mutate(NativeLibraryOwner(uid), "movie:tt9", { resident }, { _, _ -> true }) { error("Expired A cannot mutate B") })
                manager.useAccountData()
                assertTrue(manager.pushThisDevice())
                fun output() = requireNotNull(uploaded).getJSONObject("vortx").getJSONArray("library")
                assertEquals(1, output().length())
                assertEquals(peer.toString(), output().getJSONObject(0).toString())
                assertTrue(manager.mergeBoth())
                assertEquals(1, output().length())
                assertFalse(requireNotNull(uploaded).getJSONObject("vortx").has("deletedLibraryTs"))

                // A genuine operation on a positively absent B title proves only that exact target.
                val local = requireNotNull(manager.captureLibraryPublicationLease())
                val newRow = publicationRow("tt3", 4000)
                assertTrue(local.mutate(NativeLibraryOwner(uid), newRow.identity, { resident }, { before, after -> before == null && after == newRow }) { resident = resident + newRow })
                assertTrue(manager.syncUp())
                assertEquals(setOf("tt2", "tt3"), (0 until output().length()).map { output().getJSONObject(it).getString("id") }.toSet())
                // Same epoch with altered contents is not the previously granted event.
                resident = resident.map { if (it.metaId == "tt3") it.copy(timeOffsetMs = 5000) else it }
                assertTrue(manager.syncUp())
                assertEquals(1, output().length())
                disk.failWrites = true
                assertFalse(manager.importThisDeviceLibraryAndPush())
                disk.failWrites = false
                assertTrue(manager.importThisDeviceLibraryAndPush())
                assertEquals(setOf("tt1", "tt2", "tt3"), (0 until output().length()).map { output().getJSONObject(it).getString("id") }.toSet())
                resident = resident + publicationRow("tt99", 5000)
                manager.installLibraryPublicationProofTestSeam(OwnerLibraryPublicationProofs(disk))
                assertTrue(manager.pushThisDevice())
                assertEquals(3, output().length())
                manager.cancelSyncTestWork()
            }
        } finally { LibraryTombstones.activateAccount(null); cleanupManagers(); Dispatchers.resetMain() }
    }

    @Test fun `encrypted manager carries manual intents and unsaved progress without membership or deletion`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        try {
            val context = MemoryContext()
            val manager = newManager(context)
            val profiles = com.vortx.android.profile.ProfileStore::class.java.getDeclaredConstructor(Context::class.java)
                .apply { isAccessible = true }.newInstance(context)
            manager.attachSyncSeams(profiles)
            val proofs = OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence())
            manager.installLibraryPublicationProofTestSeam(proofs)
            manager.installOwnerWatchedIntentTestSeam(OwnerWatchedIntentStore(MemoryLibraryProofPersistence()) { 5000.0 })
            val key = ByteArray(32) { (it + 1).toByte() }
            val account = VortXSyncManager.Account("carrier-B", "b@example.test", "B", false)
            val priorOwner = JSONObject().put("opaque", JSONArray().put("retain"))
            val doc = JSONObject().put("vortx", JSONObject().put("library", JSONArray())
                .put("byProfile", JSONObject().put(com.vortx.android.profile.UserProfile.OWNER_ID, priorOwner)))
            var version = 1L
            var upload: JSONObject? = null
            manager.installSyncTestSeam(VortXSyncManager.Session("B", account, key), 0, transport = { method, _, body, _ ->
                if (method == "GET") 200 to JSONObject().put("version", version).put("document", requireNotNull(VortXCrypto.sealDocument(key, doc.toString().toByteArray(), account.id, version, true)))
                else {
                    val request = requireNotNull(body)
                    upload = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), account.id, request.getLong("version")))))
                    version = request.getLong("version")
                    200 to JSONObject().put("accepted", true)
                }
            })
            val raw = publicationRow().copy(removed = true, timeOffsetMs = 0)
            assertTrue(proofs.grantProjected(account.id, NativeLibraryOwner(null), listOf(raw to raw.copy(historyOnly = true))))
            assertTrue(requireNotNull(manager.captureOwnerWatchedIntentLease()).record("tt2", listOf("tt2:1:1"), false))
            manager.attachAccountLibraryGateway(object : AccountLibrarySyncGateway {
                val native = object : AccountAddonGatewayLease {}
                override fun captureAccountLibraryLease() = native
                override fun nativeLibraryOwner(nativeLease: AccountAddonGatewayLease) = NativeLibraryOwner(null)
                override suspend fun accountLibrarySnapshot(nativeLease: AccountAddonGatewayLease, admit: ((() -> Boolean) -> Boolean)) = listOf(raw, publicationRow("tt99"))
                override suspend fun addAccountLibraryItems(nativeLease: AccountAddonGatewayLease, items: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean)): Boolean = error("No membership import")
            })
            assertTrue(manager.syncUp())
            val vortx = requireNotNull(upload).getJSONObject("vortx")
            assertEquals(0, vortx.optJSONArray("library")?.length() ?: 0)
            assertFalse(vortx.has("deletedLibraryTs"))
            val owner = vortx.getJSONObject("byProfile").getJSONObject(com.vortx.android.profile.UserProfile.OWNER_ID)
            assertEquals("retain", owner.getJSONArray("opaque").getString(0))
            assertEquals("tt1", owner.getJSONArray("ownerHistory").getJSONObject(0).getString("id"))
            assertEquals(0L, owner.getJSONArray("ownerHistory").getJSONObject(0).getLong("t"))
            assertFalse(owner.getJSONArray("ownerHistory").getJSONObject(0).has("removed"))
            assertFalse(vortx.getJSONObject("ownerWatched").getJSONObject("tt2\u001ftt2:1:1").getBoolean("w"))
        } finally { LibraryTombstones.activateAccount(null); cleanupManagers(); Dispatchers.resetMain() }
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
    fun `real account switch isolates tombstones and sync upload preserves opaque peer entries`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        try {
            for (removeTypedRow in listOf(false, true)) {
                val context = MemoryContext()
                val manager = newManager(context)
                val store = com.vortx.android.profile.ProfileStore::class.java.getDeclaredConstructor(Context::class.java)
                    .apply { isAccessible = true }.newInstance(context)
                manager.attachSyncSeams(store)
                val key = ByteArray(32) { (it + 1).toByte() }
                val a = VortXSyncManager.Session("token-a", VortXSyncManager.Account("A-isolation", "a@example.test", "A", false), key)
                val b = VortXSyncManager.Session("token-b", VortXSyncManager.Account("B-isolation", "b@example.test", "B", false), key)
                fun row(id: String) = JSONObject().put("id", id).put("type", "movie").put("name", "Title")
                    .put("t", 1).put("d", 50).put("v", id).put("lastWatched", "1970-01-01T00:00:01Z")
                val opaqueObject = JSONObject().put("id", "tt2").put("type", "foreign").put("opaque", true)
                val opaqueArray = JSONArray().put("opaque").put(JSONObject().put("nested", 3))
                val rows = JSONArray().put(row("tt1")).put(opaqueObject).put("scalar").put(opaqueArray)
                    .put(JSONObject.NULL).put(row("tt2"))
                val doc = JSONObject().put("vortx", JSONObject().put("library", rows))
                val envelope = requireNotNull(VortXCrypto.sealDocument(key, doc.toString().toByteArray(), b.account.id, 2L, true))
                var uploaded: JSONObject? = null
                manager.installSyncTestSeam(a, 0L, transport = { method, _, body, token ->
                    assertEquals("token-b", token)
                    if (method == "GET") 200 to JSONObject().put("version", 2L).put("document", envelope)
                    else {
                        val request = requireNotNull(body)
                        uploaded = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, request.getString("document"), b.account.id, request.getLong("version")))))
                        200 to JSONObject().put("accepted", true)
                    }
                })
                val delayedA = LibraryTombstones(context)
                assertTrue(delayedA.merge(emptyList(), mapOf("tt1" to mapOf("removedAt" to 9000.0))))
                manager.replaceSyncSessionTestSeam(b)
                val bStore = LibraryTombstones(context)
                assertTrue(bStore.all().isEmpty())
                assertFalse(delayedA.tombstone("tt2"))
                var nativeMutations = 0
                manager.attachAccountLibraryGateway(object : AccountLibrarySyncGateway {
                    private val lease = object : AccountAddonGatewayLease {}
                    override fun captureAccountLibraryLease(): AccountAddonGatewayLease = lease
                    override suspend fun accountLibrarySnapshot(nativeLease: AccountAddonGatewayLease, admit: ((() -> Boolean) -> Boolean)): List<VortXSyncDoc.OwnerLibraryItem>? {
                        var result: List<VortXSyncDoc.OwnerLibraryItem>? = null
                        admit { result = listOf("tt1", "tt2").map { id -> requireNotNull(VortXSyncDoc.ownerLibraryItem(row(id))) }; true }
                        return result
                    }
                    override suspend fun addAccountLibraryItems(nativeLease: AccountAddonGatewayLease, items: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean)): Boolean = admit { nativeMutations++; true }
                })
                manager.syncDown(force = true)
                assertEquals("A tombstone must not remove B's same identity", 0, nativeMutations)
                assertEquals(2L, manager.lastAppliedVersion())
                if (removeTypedRow) bStore.merge(emptyList(), mapOf("tt2" to mapOf("removedAt" to 5000.0)))
                assertTrue(manager.syncUp())
                val vortx = requireNotNull(uploaded).getJSONObject("vortx")
                val output = vortx.getJSONArray("library")
                assertEquals(if (removeTypedRow) 5 else 6, output.length())
                assertEquals(opaqueObject.toString(), output.getJSONObject(1).toString())
                assertEquals("scalar", output.getString(2))
                assertEquals(opaqueArray.toString(), output.getJSONArray(3).toString())
                assertTrue(output.isNull(4))
                assertFalse(vortx.optJSONObject("deletedLibraryTs")?.has("tt1") == true)
                if (removeTypedRow) assertEquals(5000.0, vortx.getJSONObject("deletedLibraryTs").getJSONObject("tt2").getDouble("removedAt"), 0.0)
                else assertFalse(vortx.has("deletedLibraryTs"))
                manager.replaceSyncSessionTestSeam(a)
                assertEquals(setOf("tt1"), LibraryTombstones(context).all())
                assertFalse(delayedA.forget("tt1"))
                assertFalse(bStore.tombstone("tt3"))
            }
        } finally {
            LibraryTombstones.activateAccount(null)
            cleanupManagers(); Dispatchers.resetMain()
        }
    }

    @Test
    fun `public manager restores existing history and never advances a failed or expired receipt`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        try {
            for (mode in listOf("success", "unsavedHistory", "savedHistory", "sparseApple", "tombstoneOnly", "readded", "metadataReadd", "metadataOlderProgress", "metadataStaleReadd", "null", "wrongUid", "afterRead", "beforeDispatch", "afterResponse")) {
                val context = MemoryContext()
                val manager = newManager(context)
                val proofs = OwnerLibraryPublicationProofs(MemoryLibraryProofPersistence())
                manager.installLibraryPublicationProofTestSeam(proofs)
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
                if (mode in listOf("unsavedHistory", "savedHistory", "sparseApple")) {
                    if (mode == "sparseApple") for (field in listOf("watched", "timesWatched", "wholeTitleWatched", "currentVideoWatched")) row.remove(field)
                    doc.getJSONObject("vortx").put("library", JSONArray().apply {
                        if (mode == "savedHistory") put(JSONObject().put("id", "tt1").put("type", "movie").put("name", "Movie"))
                    }).put("byProfile", JSONObject().put(com.vortx.android.profile.UserProfile.OWNER_ID,
                        JSONObject().put("ownerHistory", JSONArray().put(row))))
                }
                if (mode == "tombstoneOnly") {
                    doc.getJSONObject("vortx").remove("library")
                    doc.getJSONObject("vortx").put("deletedLibraryTs", JSONObject().put("tt1", JSONObject().put("removedAt", 2000)))
                }
                if (mode == "readded") {
                    row.put("removed", true)
                    doc.getJSONObject("vortx").put("deletedLibraryTs", JSONObject().put("tt1", JSONObject().put("removedAt", 2000).put("addedAt", 3000)))
                }
                if (mode.startsWith("metadata")) {
                    if (mode == "metadataOlderProgress") row.put("eventEpochMs", 500).put("lastWatched", "1970-01-01T00:00:00.500Z")
                    else for (field in listOf("v", "t", "d", "eventEpochMs", "lastWatched", "watched", "currentVideoWatched", "wholeTitleWatched", "timesWatched")) row.remove(field)
                    doc.getJSONObject("vortx").put("deletedLibraryTs", JSONObject().put("tt1", JSONObject().put("removedAt", 500).put("addedAt", if (mode == "metadataStaleReadd") 1000 else 3000)))
                }
                val envelope = requireNotNull(VortXCrypto.sealDocument(key, doc.toString().toByteArray(), accountA.id, 2L, true))
                manager.installSyncTestSeam(VortXSyncManager.Session("A-token", accountA, key), 1L,
                    transport = { _, _, _, _ -> 200 to JSONObject().put("version", 2L).put("document", envelope) })
                fun replaceAccount() = manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("B-token", accountB, key))
                var nativeWrites = 0
                var metadataAdds = 0
                var attemptedApply = false
                var restoredProjection: String? = null
                val native = com.vortx.android.engine.NativeOwnerLibraryGateway(
                    read = {
                        if (mode == "afterRead") replaceAccount()
                        // Both VortX accounts deliberately share this same native UID.
                        restoredProjection ?: JSONObject("""{"uid":"same-native","events":[{"meta":{"id":"tt1","type":"movie","name":"Movie"},"currentVideoId":"tt1","timeOffsetMs":1000,"durationMs":50000,"eventEpochMs":1000,"lastWatchedEpochMs":1000,"watched":null,"currentVideoWatched":false,"wholeTitleWatched":false,"timesWatched":0,"removed":false}]}""").apply {
                            if (mode == "sparseApple") getJSONArray("events").getJSONObject(0).put("watched", "prior-opaque").put("timesWatched", 3).put("wholeTitleWatched", true).put("currentVideoWatched", true)
                            if (mode.startsWith("metadata")) getJSONArray("events").getJSONObject(0).put("removed", true)
                        }.toString()
                    },
                    restore = { request ->
                        nativeWrites++
                        val applied = JSONObject(request).getJSONArray("events").getJSONObject(0)
                        if (mode == "unsavedHistory" || mode == "savedHistory") assertEquals(mode == "unsavedHistory", applied.getBoolean("removed"))
                        if (mode == "sparseApple") {
                            assertEquals("prior-opaque", applied.getString("watched"))
                            assertEquals(3, applied.getInt("timesWatched"))
                            assertTrue(applied.getBoolean("wholeTitleWatched"))
                            assertTrue(applied.getBoolean("currentVideoWatched"))
                        }
                        applied.put("eventEpochMs", applied.get("genuineEventEpochMs"))
                        restoredProjection = JSONObject().put("uid", "same-native").put("events", JSONArray().put(applied)).toString()
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
                    add = {
                        assertTrue(mode in listOf("metadataReadd", "metadataOlderProgress"))
                        assertEquals(3000.0, it.membershipAddedAt!!, 0.0)
                        metadataAdds++
                    },
                )
                manager.attachAccountLibraryGateway(object : AccountLibrarySyncGateway {
                    private val lease = object : AccountAddonGatewayLease {}
                    override fun captureAccountLibraryLease(): AccountAddonGatewayLease = lease
                    override fun nativeLibraryOwner(nativeLease: AccountAddonGatewayLease) = NativeLibraryOwner("same-native")
                    override suspend fun accountLibrarySnapshot(nativeLease: AccountAddonGatewayLease, admit: ((() -> Boolean) -> Boolean)) = native.snapshot("same-native", admit)
                    override suspend fun addAccountLibraryItems(nativeLease: AccountAddonGatewayLease, items: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean)): Boolean {
                        attemptedApply = true
                        if (mode == "beforeDispatch") replaceAccount()
                        return native.apply("same-native", items, admit)
                    }
                    override suspend fun restoreAccountLibraryItems(nativeLease: AccountAddonGatewayLease, items: List<VortXSyncDoc.OwnerLibraryItem>, admit: ((() -> Boolean) -> Boolean)): AccountLibraryRestoreResult {
                        attemptedApply = true
                        if (mode == "beforeDispatch") replaceAccount()
                        var restored = emptyList<VortXSyncDoc.OwnerLibraryItem>()
                        val accepted = native.apply("same-native", items, admit) { restored = it }
                        return AccountLibraryRestoreResult(accepted, restored)
                    }
                })
                if (mode == "sparseApple") assertTrue(proofs.grant(accountA.id, NativeLibraryOwner("same-native"), requireNotNull(native.snapshot("same-native") { it() })))
                manager.syncDown(force = true)
                if (mode in listOf("success", "tombstoneOnly", "unsavedHistory", "savedHistory", "sparseApple")) {
                    assertTrue(attemptedApply)
                    assertEquals(1, nativeWrites)
                    assertEquals(2L, manager.lastAppliedVersion())
                    val actual = requireNotNull(native.snapshot("same-native") { it() }).single()
                    assertEquals("Synthetic removals cannot claim inherited history", mode != "tombstoneOnly", proofs.owns(accountA.id, NativeLibraryOwner("same-native"), actual))
                    if (mode == "unsavedHistory" || mode == "savedHistory") {
                        assertTrue(proofs.published(accountA.id, NativeLibraryOwner("same-native"), actual)!!.historyOnly)
                        assertTrue(LibraryTombstones(context).all().isEmpty())
                    }
                } else if (mode.startsWith("metadata")) {
                    assertEquals(0, nativeWrites)
                    assertEquals(if (mode == "metadataStaleReadd") 0 else 1, metadataAdds)
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
            cleanupManagers(); Dispatchers.resetMain()
        }
    }

    @Test
    fun `public sync up cannot publish a native snapshot returned after same uid account replacement`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        try {
            val context = MemoryContext()
            val manager = newManager(context)
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
            val manager = newManager(context)
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
            cleanupManagers(); Dispatchers.resetMain()
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
