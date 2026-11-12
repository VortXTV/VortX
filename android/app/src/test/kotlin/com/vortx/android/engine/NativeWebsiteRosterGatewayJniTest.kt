package com.vortx.android.engine

import android.content.Context
import com.vortx.android.data.AddonPrefsStore
import com.vortx.android.data.AddonTombstones
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.LibraryTombstones
import com.vortx.android.sync.NativeAccountReadCapture
import com.vortx.android.sync.NativeSettingsFence
import com.vortx.android.sync.NativeWebsiteRosterCandidate
import com.vortx.android.sync.NativeWebsiteRosterDenialReceipt
import com.vortx.android.sync.NativeWebsiteRosterReceiptStore
import com.vortx.android.sync.RevisionContext
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.sync.SyncRequestTestSeam
import com.vortx.android.sync.VortXCrypto
import com.vortx.android.sync.VortXSyncDoc
import com.vortx.android.sync.VortXSyncManager
import java.io.File
import java.lang.management.ManagementFactory
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.SecretKey
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Real JNI and coordinator/exclusion/Session.open with synthetic accounts and stores.
 * The direct gateway fixtures supply read/auth/local-presence evidence. The two-manager case
 * uses real manager admission with the in-process encrypted backup seam. Once this opt-in gate
 * is enabled, a missing or mismatched JNI artifact fails the fixture. */
class NativeWebsiteRosterGatewayJniTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 7)
    private fun b(value: String) = value.toByteArray(Charsets.UTF_8)
    private fun source() = b("""{"addons":[],"apiKeys":{"tmdb":"synthetic-value"},"future":{"n":9007199254740993,"fraction":1.2300e+2,"text":"\u0061"}}""")
    private class Bindings : VortxRuntimeBindings {
        init {
            assumeTrue("Explicit reviewed website roster JNI gate required", System.getenv("VORTX_JNI_WEBSITE_ROSTER_ADMISSION") == "1")
            val file = File(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")) { "Actual JNI fixture required" })
            val expected = requireNotNull(System.getenv("VORTX_JNI_SHA256"))
            require(Regex("[0-9a-f]{64}").matches(expected) && file.isAbsolute && file.isFile)
            assertEquals("Reviewed native artifact hash", expected, OHJson.sha(file.readBytes()))
            System.load(file.absolutePath)
        }
        val live = Collections.synchronizedSet(mutableSetOf<Long>())
        var created = 0
        var freed = 0
        var afterImport: (() -> Unit)? = null
        override fun create(ownerId: String, ownerName: String): Long = VortxCore.nativeInitRuntime(
            JSONObject().put("ownerId", ownerId).put("ownerName", ownerName).toString()).also { created++; live.add(it) }
        override fun hydrate(snapshot: String): Long = VortxCore.nativeInitFromStateJson(snapshot).also { created++; live.add(it) }
        override fun dispatch(handle: Long, action: String): String? = VortxCore.nativeDispatchJson(handle, action).also {
            if (JSONObject(action).getString("type") == "import_legacy_sync") afterImport?.invoke()
        }
        override fun resolve(handle: Long, request: String): String? = error("No native resource resolution allowed")
        override fun state(handle: Long): String? = VortxCore.nativeGetStateJson(handle)
        override fun delta(handle: Long): String? = error("No native delta drain allowed")
        override fun free(handle: Long) { VortxCore.nativeEngineFree(handle); live.remove(handle); freed++ }
    }
    // Observe the real monitor being contended; no field replacement or production seam.
    private fun monitor(instance: Any, field: String): Any =
        instance.javaClass.getDeclaredField(field).also { it.isAccessible = true }.get(instance)
    private fun waitsFor(thread: Thread, lock: Any): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        val threads = ManagementFactory.getThreadMXBean()
        while (System.nanoTime() < deadline) {
            val info = threads.getThreadInfo(thread.id)
            if (info?.threadState == Thread.State.BLOCKED &&
                info.lockInfo?.identityHashCode == System.identityHashCode(lock)) return true
            if (!thread.isAlive) return false
            Thread.sleep(1)
        }
        return false
    }
    private fun joinBounded(thread: Thread) {
        thread.join(10_000)
        check(!thread.isAlive) { "Fixture worker did not drain" }
    }

    private inner class Fixture : AutoCloseable {
        val bindings = Bindings()
        var authGeneration = 1
        var presence = AccountFileLocalPresence.ABSENT
        var observations = 0
        var allowOrdinaryReceive = false
        var reads = 0
        var writes = 0
        var remembered = 0
        var publications = 0
        var transportCreations = 0
        var state: String? = null
        private val store = object : VortxCheckpointStore {
            override fun inspectWebsiteRosterAbsence(scope: VortxAccountScope,
                readExistingKey: (VortxAccountScope) -> SecretKey?): AccountFileLocalPresence {
                assertEquals("account.${account.id}", scope.accountID)
                assertEquals(UserProfile.OWNER_ID, scope.ownerProfileID)
                observations++; return presence
            }
            override fun read(scope: VortxAccountScope): String? {
                check(allowOrdinaryReceive) { "Detached route touched production store" }; reads++; return state
            }
            override fun commit(scope: VortxAccountScope, snapshot: String) {
                check(allowOrdinaryReceive) { "Detached route wrote production store" }; writes++; state = snapshot
            }
            override fun remember(scope: VortxAccountScope) {
                check(allowOrdinaryReceive); remembered++
            }
            override fun readPreflight(accountID: String): NativeMigrationPreflight? {
                check(allowOrdinaryReceive) { "Detached route read production preflight" }; return null
            }
            override fun commitPreflight(next: NativeMigrationPreflight, expected: NativeMigrationPreflight?) =
                error("No production preflight write allowed")
        }
        val gateway = NativeAccountCoordinator(bindings, store, {
            check(allowOrdinaryReceive) { "Detached route created production resource transport" }; transportCreations++
            object : VortxResourceTransport {
                override fun makeCancellation(): VortxResourceCancellation = error("No provider request")
                override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No provider request")
            }
        }, { it == account }, { it() }, {
            check(allowOrdinaryReceive) { "Detached route published native state" }; publications++
        }, captureOwnAccountAdmission = { captured ->
            val generation = authGeneration
            if (captured != account) null else { action -> if (authGeneration == generation) action() else false }
        })
        fun read(raw: ByteArray, version: Long = 17) = NativeAccountReadCapture.fromAuthenticatedPull(
            account, authGeneration.toLong(), account.id, account.generation, version, raw)
        fun assertDetached() {
            assertNull(gateway.currentMountToken(account)); assertNull(state)
            assertEquals(0, reads); assertEquals(0, writes); assertEquals(0, remembered)
            assertEquals(0, publications); assertEquals(0, transportCreations)
            assertTrue(bindings.live.isEmpty()); assertEquals(bindings.created, bindings.freed)
        }
        override fun close() { gateway.retire(); assertTrue(bindings.live.isEmpty()) }
    }

    @Test fun `two real managers admit one encrypted website roster promotion`() =
        runWebsiteRosterRoundTrip(rejectFirst = false)

    @Test fun definitivelyRejectedWebsiteRosterCasRebasesAndSecondDeviceRestoresConfirmedHead() =
        runWebsiteRosterRoundTrip(rejectFirst = true)

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun runWebsiteRosterRoundTrip(rejectFirst: Boolean): Unit = runBlocking {
        assumeTrue("Explicit reviewed website roster JNI gate required", System.getenv("VORTX_JNI_WEBSITE_ROSTER_ADMISSION") == "1")
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val previousNotifications = NativeSettingsFence.queuedNotificationsForTest
        NativeSettingsFence.queuedNotificationsForTest = mutableListOf()
        val key = ByteArray(32) { 37 }
        try {
            withTimeout(30_000) {
                val identity = VortXSyncManager.Account(account.id, "fixture@example.invalid", "Fixture", false)
                val originalAddon = "https://fixture.invalid/manifest.json"
                val revisedAddon = "https://fixture.invalid/revised/manifest.json"
                fun websiteSource(addon: String, progress: String, opaque: String) = OHJson.literal(
                    """{
                      "addons":[{"transportUrl":"$addon","manifest":{"id":"com.example.fixture","name":"Fixture catalog","version":"1.0.0","types":["movie"],"resources":["catalog"],"catalogs":[]}}],
                      "addonOrder":["$addon"],
                      "webProgress":{"editedAt":1720000000000,"owner":[{"id":"tt0000101","type":"series","v":"tt0000101:1:2","t":$progress,"d":2500,"lastWatched":1720000000000}]},
                      "vortx":{"webFuture":{"n":$opaque,"z":-0}},
                      "future":{"exact":9007199254740993,"text":"\u0061"}
                    }""",
                )
                val original = websiteSource(originalAddon, "37.125", "1.2300e+2")
                val revised = websiteSource(revisedAddon, "79.25", "1.2500e+2")
                val expectedRevision = if (rejectFirst) 42L else 41L
                val expectedAddon = if (rejectFirst) revisedAddon else originalAddon
                val expectedSource = if (rejectFirst) revised else original
                val expectedProgress = JSONObject(expectedSource.toString(Charsets.UTF_8)).getJSONObject("webProgress")
                var cloudRevision = 40L
                var cloudCiphertext = VortXCrypto.sealDocument(key, original, identity.id, cloudRevision, writeV2 = true)
                val requests = mutableListOf<String>()
                val websiteOwner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "🍿", isOwner = true)
                val firstRequests = if (rejectFirst) {
                    listOf("first:GET:40", "first:PUT:40/41", "first:GET:41", "first:PUT:41/42", "first:GET:42")
                } else {
                    listOf("first:GET:40", "first:PUT:40/41", "first:GET:41")
                }

                fun cloudReply() = JSONObject().put("version", cloudRevision).put("document", cloudCiphertext)

                fun assertProjection(source: ByteArray, candidate: ByteArray) {
                    val sourceFields = OHJson.Obj(source)
                    val proposed = OHJson.Obj(candidate)
                    assertEquals(sourceFields.keys, proposed.keys)
                    for (field in sourceFields.keys - "vortx")
                        assertArrayEquals(field, sourceFields.raw(field), proposed.raw(field))
                    val sourceVortx = sourceFields.obj("vortx")
                    val vortx = proposed.obj("vortx")
                    assertEquals(sourceVortx.keys + setOf("roster", "rosterModified"), vortx.keys)
                    for (field in sourceVortx.keys)
                        assertArrayEquals(field, sourceVortx.raw(field), vortx.raw(field))
                    assertArrayEquals(OHJson.literal("0"), vortx.raw("rosterModified"))
                    val parsed = VortXSyncDoc.parse(JSONObject(candidate.toString(Charsets.UTF_8)))
                    assertTrue(parsed.rosterIsLossless)
                    assertEquals(listOf(websiteOwner), parsed.roster)
                }

                withRoundTripDevice { device ->
                    device.install(VortXSyncManager.Session("first-fixture", identity, key)) { method, path, body, bearer ->
                        assertEquals("/v1/backup", path)
                        assertEquals("first-fixture", bearer)
                        device.assertCold()
                        when (method) {
                            "GET" -> {
                                assertNull(body)
                                requests += "first:GET:$cloudRevision"
                                when {
                                    cloudRevision == expectedRevision -> {
                                        val receipt = NativeWebsiteRosterDenialReceipt.decode(
                                            requireNotNull(device.firstReceipt()), identity.id, key,
                                        )
                                        val head = requireNotNull(VortXCrypto.openDocument(key, cloudCiphertext, identity.id, cloudRevision))
                                        try {
                                            assertFalse(receipt.isDefinitivelyRejected)
                                            assertTrue(receipt.matchesProjectedBytes(identity.id, key, cloudRevision, head))
                                        } finally { head.fill(0) }
                                        device.allowInstallation()
                                    }
                                    cloudRevision == 41L && rejectFirst -> {
                                        assertTrue(device.closedDetachedRuntime())
                                        val rejected = NativeWebsiteRosterDenialReceipt.decode(
                                            requireNotNull(device.firstReceipt()), identity.id, key,
                                        )
                                        assertTrue(rejected.isDefinitivelyRejected)
                                        assertEquals(40L, rejected.originalRevision)
                                        assertEquals(41L, rejected.targetRevision)
                                        val head = requireNotNull(VortXCrypto.openDocument(key, cloudCiphertext, identity.id, 41L))
                                        try {
                                            assertArrayEquals(revised, head)
                                            assertFalse(OHJson.Obj(head).obj("vortx").keys.contains("roster"))
                                        } finally { head.fill(0) }
                                    }
                                    else -> {
                                        assertEquals(40L, cloudRevision)
                                        assertNull(device.firstReceipt())
                                    }
                                }
                                200 to cloudReply()
                            }
                            "PUT" -> {
                                assertTrue(device.closedDetachedRuntime())
                                val base = cloudRevision
                                assertTrue(base == 40L || rejectFirst && base == 41L)
                                val target = base + 1
                                requests += "first:PUT:$base/$target"
                                val request = requireNotNull(body)
                                assertEquals(base, request.getLong("baseRevision"))
                                assertEquals(target, request.getLong("version"))
                                val encrypted = request.getString("document")
                                assertTrue(encrypted.startsWith(VortXCrypto.DOC_V2_PREFIX))
                                assertNull(VortXCrypto.openDocument(key, encrypted, identity.id, target + 1))
                                val candidate = requireNotNull(VortXCrypto.openDocument(key, encrypted, identity.id, target))
                                try {
                                    val source = if (base == 40L) original else revised
                                    assertProjection(source, candidate)
                                    val receipt = NativeWebsiteRosterDenialReceipt.decode(
                                        requireNotNull(device.firstReceipt()), identity.id, key,
                                    )
                                    assertFalse(receipt.isDefinitivelyRejected)
                                    assertTrue(receipt.matchesAttempt(identity.id, key, base, source, target, candidate))
                                } finally { candidate.fill(0) }
                                cloudRevision = target
                                if (rejectFirst && base == 40L) {
                                    // Simulate a concurrent website writer winning this exact CAS.
                                    cloudCiphertext = VortXCrypto.sealDocument(key, revised, identity.id, target, writeV2 = true)
                                    200 to JSONObject().put("accepted", false).put("version", cloudRevision)
                                } else {
                                    cloudCiphertext = encrypted
                                    200 to JSONObject().put("accepted", true).put("version", cloudRevision)
                                }
                            }
                            else -> error("Unexpected backup method")
                        }
                    }
                    assertTrue(device.manager.syncDown(force = true))
                    assertEquals(firstRequests, requests)
                    assertEquals(expectedRevision, cloudRevision)
                    device.assertMounted(websiteOwner, expectedAddon, expectedProgress, expectedRevision)
                }

                val confirmedCiphertext = cloudCiphertext
                withRoundTripDevice { device ->
                    device.install(VortXSyncManager.Session("second-fixture", identity, key)) { method, path, body, bearer ->
                        assertEquals("/v1/backup", path)
                        assertEquals("second-fixture", bearer)
                        assertEquals("GET", method)
                        assertNull(body)
                        device.assertCold()
                        requests += "second:GET:$cloudRevision"
                        assertEquals(confirmedCiphertext, cloudCiphertext)
                        device.allowInstallation()
                        200 to cloudReply()
                    }
                    assertTrue(device.manager.syncDown(force = true))
                    assertEquals(firstRequests + "second:GET:$expectedRevision", requests)
                    assertEquals(expectedRevision, cloudRevision)
                    assertNull(device.firstReceipt())
                    device.assertMounted(websiteOwner, expectedAddon, expectedProgress, expectedRevision)
                }
            }
        } finally {
            key.fill(0)
            try {
                LibraryTombstones.activateAccount(null)
                AddonTombstones.activateAccount(null)
                AddonPrefsStore.activateAccount(null)
            } finally {
                NativeSettingsFence.queuedNotificationsForTest = previousNotifications
                Dispatchers.resetMain()
            }
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun websiteRosterReplayReadbackFloorSurvivesRestart() = runBlocking {
        assumeTrue("Explicit reviewed website roster JNI gate required", System.getenv("VORTX_JNI_WEBSITE_ROSTER_ADMISSION") == "1")
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val previousNotifications = NativeSettingsFence.queuedNotificationsForTest
        NativeSettingsFence.queuedNotificationsForTest = mutableListOf()
        val key = ByteArray(32) { 38 }
        try {
            withTimeout(30_000) {
                val context = RevisionContext()
                val identity = VortXSyncManager.Account(account.id, "fixture@example.invalid", "Fixture", false)
                val original = source()
                val candidate = requireNotNull(NativeWebsiteRosterProjection.project(original))
                val newer = b("""{"addons":[],"apiKeys":{"tmdb":"synthetic-new-head"},"webProgress":{"owner":[]}}""")
                val originalCiphertext = VortXCrypto.sealDocument(key, original, identity.id, 40L, writeV2 = true)
                val targetCiphertext = VortXCrypto.sealDocument(key, candidate, identity.id, 41L, writeV2 = true)
                val newerCiphertext = VortXCrypto.sealDocument(key, newer, identity.id, 50L, writeV2 = true)
                val originalReceipt = NativeWebsiteRosterDenialReceipt.create(identity.id, key, 40L, original, 41L, candidate).encode()
                assertTrue("Seed the original pending wire format", originalReceipt.startsWith("v1:"))

                fun encryptedReply(version: Long, ciphertext: String) =
                    200 to JSONObject().put("version", version).put("document", ciphertext)

                fun readRaisedPending(device: RoundTripDevice): String {
                    val saved = requireNotNull(device.firstReceipt())
                    val receipt = NativeWebsiteRosterDenialReceipt.decode(saved, identity.id, key)
                    assertFalse("A replay rejection cannot settle the first attempt", receipt.isDefinitivelyRejected)
                    assertEquals(40L, receipt.originalRevision)
                    assertEquals(41L, receipt.targetRevision)
                    assertEquals(50L, receipt.minimumReadbackRevision)
                    return saved
                }

                var requests = 0
                val persisted = withRoundTripDevice(context) { device ->
                    device.install(VortXSyncManager.Session("replay-fixture", identity, key)) { method, path, body, bearer ->
                        assertEquals("/v1/backup", path)
                        assertEquals("replay-fixture", bearer)
                        device.assertCold()
                        when (++requests) {
                            1 -> {
                                assertEquals("GET", method)
                                assertNull(body)
                                assertEquals(originalReceipt, device.firstReceipt())
                                encryptedReply(40L, originalCiphertext)
                            }
                            2 -> {
                                assertEquals("PUT", method)
                                assertTrue(device.closedDetachedRuntime())
                                assertEquals(originalReceipt, device.firstReceipt())
                                val request = requireNotNull(body)
                                assertEquals(40L, request.getLong("baseRevision"))
                                assertEquals(41L, request.getLong("version"))
                                val encrypted = request.getString("document")
                                assertTrue(encrypted.startsWith(VortXCrypto.DOC_V2_PREFIX))
                                val submitted = requireNotNull(VortXCrypto.openDocument(key, encrypted, identity.id, 41L))
                                try { assertArrayEquals(candidate, submitted) }
                                finally { submitted.fill(0) }
                                200 to JSONObject().put("accepted", false).put("version", 50L)
                            }
                            3 -> {
                                assertEquals("GET", method)
                                assertNull(body)
                                readRaisedPending(device)
                                encryptedReply(41L, targetCiphertext)
                            }
                            else -> error("Unexpected replay request")
                        }
                    }
                    device.seedFirstReceipt(originalReceipt)
                    assertFalse(device.manager.syncDown(force = true))
                    assertEquals(3, requests)
                    device.assertCold()
                    readRaisedPending(device)
                }

                // A new Manager and coordinator use the same synthetic persistent prefs.
                // Ordinary applied revision stays zero, so it cannot explain either refusal.
                var restartRequests = 0
                withRoundTripDevice(context) { device ->
                    device.install(VortXSyncManager.Session("restart-fixture", identity, key)) { method, path, body, bearer ->
                        assertEquals("/v1/backup", path)
                        assertEquals("restart-fixture", bearer)
                        assertEquals("GET", method)
                        assertNull(body)
                        device.assertCold()
                        assertEquals(persisted, readRaisedPending(device))
                        when (++restartRequests) {
                            1 -> encryptedReply(41L, targetCiphertext)
                            2 -> encryptedReply(50L, newerCiphertext)
                            else -> error("Unexpected request after restart")
                        }
                    }
                    assertFalse(device.manager.syncDown(force = true))
                    assertEquals(1, restartRequests)
                    device.assertCold()
                    assertFalse(device.manager.syncDown(force = true))
                    assertEquals(2, restartRequests)
                    device.assertCold()
                    assertEquals(persisted, readRaisedPending(device))
                }
            }
        } finally {
            key.fill(0)
            try {
                LibraryTombstones.activateAccount(null)
                AddonTombstones.activateAccount(null)
                AddonPrefsStore.activateAccount(null)
            } finally {
                NativeSettingsFence.queuedNotificationsForTest = previousNotifications
                Dispatchers.resetMain()
            }
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private inner class RoundTripDevice(private val context: RevisionContext) {
        private val bindings = Bindings()
        val manager = VortXSyncManager(context, CoroutineScope(SupervisorJob() + UnconfinedTestDispatcher()))
        private val scope = VortxAccountScope("account.${account.id}", UserProfile.OWNER_ID)
        private var mayInstall = false
        private var checkpoint: String? = null
        private var locator: VortxAccountScope? = null
        private var publications = 0
        private val store = object : VortxCheckpointStore {
            override fun inspectWebsiteRosterAbsence(scope: VortxAccountScope,
                readExistingKey: (VortxAccountScope) -> SecretKey?): AccountFileLocalPresence {
                assertEquals(this@RoundTripDevice.scope, scope)
                return if (checkpoint == null && locator == null) AccountFileLocalPresence.ABSENT else AccountFileLocalPresence.PRESENT
            }
            override fun read(scope: VortxAccountScope): String? {
                assertEquals(this@RoundTripDevice.scope, scope)
                return checkpoint
            }
            override fun commit(scope: VortxAccountScope, snapshot: String) {
                assertTrue("A separate readback must precede a local checkpoint", mayInstall)
                assertEquals(this@RoundTripDevice.scope, scope)
                checkpoint = snapshot
            }
            override fun discover(accountID: String): VortxAccountScope? {
                assertEquals(scope.accountID, accountID)
                return locator
            }
            override fun remember(scope: VortxAccountScope) {
                assertTrue(mayInstall)
                assertEquals(this@RoundTripDevice.scope, scope)
                assertNotNull(checkpoint)
                locator = scope
            }
            override fun commitPreflight(next: NativeMigrationPreflight, expected: NativeMigrationPreflight?) =
                error("The fixture must never write a migration preflight")
        }
        private val localBindings = object : VortxRuntimeBindings by bindings {
            override fun resolve(handle: Long, request: String): String? {
                assertTrue(mayInstall)
                assertEquals("installed_addons", JSONObject(request).getString("kind"))
                return VortxCore.nativeResolveJson(handle, request)
            }
        }
        private val gateway = NativeAccountCoordinator(
            bindings = localBindings,
            checkpoints = store,
            transport = {
                assertTrue(mayInstall)
                object : VortxResourceTransport {
                    override fun makeCancellation(): VortxResourceCancellation = error("No add-on network request")
                    override fun load(requestJson: String, cancellation: VortxResourceCancellation): String =
                        error("No add-on network request")
                }
            },
            accountCurrent = { manager.sessionOwnerSnapshot() == it },
            dispose = { it() },
            project = {
                assertTrue(mayInstall)
                publications++
            },
            watchedProducer = NativeWatchedMigrationProducer { throw AssertionError("No watched metadata request") },
            captureOwnAccountAdmission = { captured ->
                manager.captureLocalLibraryMutationAdmission()?.let { admission -> { action ->
                    admission { manager.sessionOwnerSnapshot() == captured && action() }
                } }
            },
        )

        private fun principal() = manager.sessionOwnerSnapshot() as SessionOwnerSnapshot.Account
        private fun state() = context.getSharedPreferences("vortx_sync_state", Context.MODE_PRIVATE)
        private fun receiptPreferenceKey() = NativeWebsiteRosterReceiptStore.storageKey(
            account.id, requireNotNull(manager.currentSession()).dataKey,
        )
        fun firstReceipt() = state().getString(receiptPreferenceKey(), null)
        fun seedFirstReceipt(encoded: String) {
            assertNull(firstReceipt())
            assertTrue(state().edit().putString(receiptPreferenceKey(), encoded).commit())
            assertEquals(encoded, firstReceipt())
        }
        private fun appliedVersion() = state().getLong("lastSyncedVersion.${account.id}", 0)

        fun install(session: VortXSyncManager.Session, transport: SyncRequestTestSeam) {
            manager.installSyncTestSeam(session, 0, transport)
            manager.installSessionRestoreTestSeam(manager.currentSession())
            manager.installNativeGatewayTestSeam(gateway, NativeProviderTestStore())
        }

        fun assertCold() {
            assertFalse(mayInstall)
            assertNull(gateway.currentMountToken(principal()))
            assertNull(checkpoint)
            assertNull(locator)
            assertEquals(0, publications)
            assertEquals(0L, appliedVersion())
            assertTrue(bindings.live.isEmpty())
        }

        fun closedDetachedRuntime() = bindings.created > 0 && bindings.created == bindings.freed && bindings.live.isEmpty()

        fun allowInstallation() { mayInstall = true }

        fun assertMounted(owner: UserProfile, addon: String, progress: JSONObject, revision: Long) {
            assertNotNull(gateway.currentMountToken(principal()))
            assertNotNull(checkpoint)
            assertEquals(scope, locator)
            assertEquals(1, publications)
            assertEquals(revision, appliedVersion())
            val exported = requireNotNull(gateway.exportDocument(principal()))
            assertEquals(listOf(owner.copy(disabledAddons = emptyList())), exported.roster)
            assertEquals(0.0, exported.rosterModifiedSeconds, 0.0)
            val session = gateway.session()
            val retained = session.read().state.getJSONObject("hostDocument").getJSONObject("webProgress")
            assertTrue(NativeHostPreferences.equal(progress, retained))
            val installed = session.resolve(JSONObject().put("kind", "installed_addons").put("profileId", owner.id))
                .getJSONArray("addons")
            assertEquals(1, installed.length())
            assertEquals(addon, installed.getJSONObject(0).getString("transportUrl"))
        }

        suspend fun close() {
            try {
                manager.cancelSyncTestWork()
            } finally {
                try {
                    gateway.retire()
                    assertTrue(bindings.live.isEmpty())
                    assertEquals(bindings.created, bindings.freed)
                } finally { NativeProviderAccess.unbindForTest() }
            }
        }
    }

    private suspend fun <T> withRoundTripDevice(
        context: RevisionContext = RevisionContext(),
        block: suspend (RoundTripDevice) -> T,
    ): T {
        val device = RoundTripDevice(context)
        return try { block(device) } finally { withContext(NonCancellable) { device.close() } }
    }


    @Test fun `real complete admission stays detached and ordinary receive starts only after callback release`() = runBlocking {
        Fixture().use { fixture ->
            val raw = source(); val before = raw.copyOf(); val capture = fixture.read(raw)
            val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            var retained: NativeWebsiteRosterCandidate? = null
            try {
                val confirmed = fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    retained = candidate
                    fixture.assertDetached()
                    assertTrue(candidate.currency.isCurrent())
                    assertEquals(17L, candidate.sourceRevision)
                    candidate.requireLocalAbsenceForSubmission()
                    val bytes = candidate.copyProjectedBytes()
                    assertArrayEquals(NativeWebsiteRosterProjection.project(before), bytes)
                    assertArrayEquals(OHJson.Obj(before).raw("apiKeys"), OHJson.Obj(bytes).raw("apiKeys"))
                    assertArrayEquals(OHJson.Obj(before).raw("future"), OHJson.Obj(bytes).raw("future"))
                    // A separate synthetic readback, never a relabelled source/candidate receipt.
                    bytes
                }
                val candidate = requireNotNull(retained)
                assertFalse(candidate.currency.isCurrent())
                assertTrue(runCatching { candidate.copyProjectedBytes() }.isFailure)
                fixture.assertDetached()
                assertArrayEquals(before, raw)
                fixture.allowOrdinaryReceive = true
                val confirmedBytes = requireNotNull(confirmed)
                val incoming = fixture.read(confirmedBytes, 18)
                try { assertTrue(fixture.gateway.applyRawDocument(account, incoming) { true }) }
                finally { incoming.retire(); confirmedBytes.fill(0) }
                assertNotNull(fixture.gateway.currentMountToken(account))
                assertEquals("Main", fixture.gateway.session().read().state.getJSONObject("roster")
                    .getJSONObject("profiles").getJSONObject(UserProfile.OWNER_ID).getString("name"))
                assertEquals(1, fixture.writes); assertEquals(1, fixture.remembered); assertEquals(1, fixture.publications)
            } finally { capture.retire() }
        }
    }

    @Test fun `local evidence changing after preparation prevents submission and expires the candidate`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            var retained: NativeWebsiteRosterCandidate? = null
            var passedSubmissionGate = false
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    retained = candidate; fixture.assertDetached(); fixture.presence = AccountFileLocalPresence.PRESENT
                    candidate.requireLocalAbsenceForSubmission()
                    passedSubmissionGate = true
                    Unit
                } }
                assertTrue(result.isFailure)
                assertFalse(passedSubmissionGate)
                assertFalse(requireNotNull(retained).currency.isCurrent())
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }

    @Test fun `same value auth retirement during actual native import closes the handle without callback`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            fixture.bindings.afterImport = { fixture.authGeneration++ }
            var callbacks = 0
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { callbacks++; Unit } }
                assertTrue(result.isFailure); assertEquals(0, callbacks)
                assertEquals(1, fixture.bindings.created)
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }

    @Test fun `noncooperative callback cancellation retains reservation until actual drain`() = runBlocking {
        Fixture().use { fixture -> coroutineScope {
            val entered = CompletableDeferred<NativeWebsiteRosterCandidate>()
            val release = CompletableDeferred<Unit>()
            val task = launch {
                val capture = fixture.read(source())
                val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
                try { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    entered.complete(candidate)
                    withContext(NonCancellable) { release.await() }
                    Unit
                } } finally { capture.retire() }
            }
            try {
                val candidate = withTimeout(10_000) { entered.await() }
                task.cancel()
                assertFalse(candidate.currency.isCurrent())
                assertNull(fixture.gateway.withRestoreNativeExclusion(account, {}) { true })
                assertFalse(task.isCompleted)
                release.complete(Unit)
                withTimeout(10_000) { task.join() }
                assertEquals(true, fixture.gateway.withRestoreNativeExclusion(account, {}) { true })
                fixture.assertDetached()
            } finally { release.complete(Unit); task.cancel(); task.join() }
        } }
    }

    @Test fun `retiring the exact read revokes detached currency before submission`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            var currentAfterRetirement: Boolean? = null
            var copyAfterRetirement: Result<ByteArray>? = null
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    capture.retire()
                    currentAfterRetirement = candidate.currency.isCurrent()
                    copyAfterRetirement = runCatching { candidate.copyProjectedBytes() }
                    Unit
                } }
                assertTrue(result.isFailure)
                assertEquals(false, currentAfterRetirement)
                assertTrue(requireNotNull(copyAfterRetirement).isFailure)
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }

    @Test fun `read retirement wins while candidate action waits for the real lifecycle monitor`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            val actions = AtomicInteger()
            val actionResult = AtomicReference<Result<Int?>?>()
            val retirementResult = AtomicReference<Result<Unit>?>()
            val retirementDone = CountDownLatch(1)
            var waitedForLifecycle = false
            var retiredBeforeRelease = false
            var callbacks = 0
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    callbacks++
                    val lifecycle = monitor(fixture.gateway, "lifecycleLock")
                    val worker = Thread {
                        actionResult.set(runCatching { candidate.currency.withCurrentSession { actions.incrementAndGet(); 7 } })
                    }.also { it.isDaemon = true }
                    val retireWorker = Thread {
                        try { retirementResult.set(runCatching { capture.retire() }) }
                        finally { retirementDone.countDown() }
                    }.also { it.isDaemon = true }
                    try {
                        synchronized(lifecycle) {
                            worker.start()
                            waitedForLifecycle = waitsFor(worker, lifecycle)
                            // V1 has already released the read lock at this point. V2 has not
                            // entered it yet. This retire must win before either action can run.
                            retireWorker.start()
                            retiredBeforeRelease = retirementDone.await(10, TimeUnit.SECONDS)
                        }
                    } finally {
                        joinBounded(worker)
                        if (retireWorker.state != Thread.State.NEW) joinBounded(retireWorker)
                    }
                    Unit
                } }
                assertTrue(result.isFailure) // Post-callback original read is retired.
                assertEquals(1, callbacks)
                assertTrue(waitedForLifecycle)
                assertTrue(retiredBeforeRelease)
                assertTrue(requireNotNull(retirementResult.get()).isSuccess)
                assertFalse(capture.isCurrentFor(account))
                assertEquals(0, actions.get())
                val observed = requireNotNull(actionResult.get())
                assertTrue(observed.isSuccess)
                assertNull(observed.getOrThrow())
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }

    @Test fun `candidate action linearizes before concurrent exact read retirement`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            val events = Collections.synchronizedList(mutableListOf<String>())
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val actionResult = AtomicReference<Result<String?>?>()
            val retirementResult = AtomicReference<Result<Unit>?>()
            var retirementWaitedForRead = false
            var callbacks = 0
            try {
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    callbacks++
                    val readMonitor = monitor(capture, "lock")
                    val worker = Thread {
                        actionResult.set(runCatching { candidate.currency.withCurrentSession {
                            events.add("action-start"); entered.countDown()
                            check(release.await(10, TimeUnit.SECONDS)) { "Fixture action release timed out" }
                            events.add("action-end")
                            "admitted"
                        } })
                    }.also { it.isDaemon = true }
                    val retireWorker = Thread {
                        retirementResult.set(runCatching { capture.retire(); events.add("retired"); Unit })
                    }.also { it.isDaemon = true }
                    try {
                        worker.start()
                        check(entered.await(10, TimeUnit.SECONDS)) { "Fixture candidate action did not enter" }
                        retireWorker.start()
                        retirementWaitedForRead = waitsFor(retireWorker, readMonitor)
                    } finally {
                        release.countDown()
                        joinBounded(worker)
                        if (retireWorker.state != Thread.State.NEW) joinBounded(retireWorker)
                    }
                    Unit
                } }
                assertTrue(result.isFailure) // Retirement completed before the outer callback returned.
                assertEquals(1, callbacks)
                assertTrue(retirementWaitedForRead)
                assertEquals("admitted", requireNotNull(actionResult.get()).getOrThrow())
                assertTrue(requireNotNull(retirementResult.get()).isSuccess)
                assertEquals(listOf("action-start", "action-end", "retired"), events.toList())
                assertFalse(capture.isCurrentFor(account))
                fixture.assertDetached()
            } finally { release.countDown(); capture.retire() }
        }
    }

    @Test fun `same account coordinator retirement revokes the reservation currency`() = runBlocking {
        Fixture().use { fixture ->
            val capture = fixture.read(source()); val original = requireNotNull(fixture.gateway.captureUploadOrigin(account) { true })
            var retained: NativeWebsiteRosterCandidate? = null
            try {
                var currentAfterRetirement: Boolean? = null
                var copyAfterRetirement: Result<ByteArray>? = null
                val result = runCatching { fixture.gateway.withWebsiteRosterCandidate(account, capture, original) { candidate ->
                    retained = candidate; fixture.gateway.retire()
                    currentAfterRetirement = candidate.currency.isCurrent()
                    copyAfterRetirement = runCatching { candidate.copyProjectedBytes() }
                    Unit
                } }
                assertTrue(result.isFailure)
                assertEquals(false, currentAfterRetirement)
                assertTrue(requireNotNull(copyAfterRetirement).isFailure)
                assertFalse(requireNotNull(retained).currency.isCurrent())
                assertEquals(true, fixture.gateway.withRestoreNativeExclusion(account, {}) { true })
                fixture.assertDetached()
            } finally { capture.retire() }
        }
    }
}
