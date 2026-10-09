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
import com.vortx.android.engine.VortxCheckpointStore
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.engine.VortxNativeRuntime
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.CompletableDeferred
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
    private fun realCoordinator(manager: VortXSyncManager, checkpoints: VortxCheckpointStore) = NativeAccountCoordinator(
        bindings(), checkpoints, { noNetwork() }, { manager.sessionOwnerSnapshot() == it }, { it() }, {},
        captureOwnAccountAdmission = { captured -> manager.captureLocalLibraryMutationAdmission()?.let { admission ->
            val guard: (() -> Boolean) -> Boolean = { action -> admission { manager.sessionOwnerSnapshot() == captured && action() } }
            guard
        } },
        projectTransfer = { _, admission -> admission.publish {
            com.vortx.android.profile.ContinueWatchingOwnerGate.transition({ Unit }) {}
        } })

    private fun loadTransferJni() {
        org.junit.Assume.assumeTrue("Required for final transfer acceptance: reviewed local JNI", System.getenv("VORTX_JNI_SYNC") == "1")
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
    }

    @Test fun `real native runtime lifetime survives transfer hold abandon and successful completion but not account replacement`() = runBlocking {
        loadTransferJni()
        for (preMounted in listOf(false, true)) {
            val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-transfer-life-").toFile()
            val checkpointKey = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
            val manager = VortXSyncManager(TestContext())
            val runtime = realCoordinator(manager, VortxEncryptedCheckpointStore(directory) { checkpointKey })
            var resumed = 0
            try {
                val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "star", isOwner = true)
                val cloud = JSONObject().put("vortx", JSONObject().put("roster", org.json.JSONArray().put(owner.encode()))
                    .put("rosterModified", 1).put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                    transport = { _, _, _, _ -> 200 to envelope(cloud) })
                manager.installRealtimeStartTestSeam { resumed++ }
                installNative(manager, runtime)
                if (preMounted) {
                    assertTrue(manager.syncDown(true))
                    val heldSession = runtime.session(); val before = heldSession.read().owner
                    val hold = requireNotNull(manager.captureAccountTransfer())
                    assertTrue(hold.canKeepDevice()); assertEquals(before, heldSession.read().owner)
                    hold.abandon(); assertEquals(before, heldSession.read().owner)
                }
                val transfer = requireNotNull(manager.captureAccountTransfer())
                assertTrue(transfer.restore())
                val installed = runtime.session()
                assertTrue(transfer.resumeSync()); assertEquals(1, resumed)
                assertEquals(owner.id, installed.read().owner.profileID)
                // Mutating through the same mounted production writer proves the lifetime predicate
                // is no longer the retired transfer capability, not merely a cached projection read.
                val access = NativeProfileAccess { runtime.session() }
                access.save(access.read().profiles.single().copy(name = "After transfer"), false)
                assertEquals("After transfer", access.read().profiles.single().name)
                val replacement = VortXSyncManager.Session("replacement", account.copy(id = "00000000-0000-0000-0000-000000000456"), key)
                manager.replaceSyncSessionTestSeam(replacement); manager.installSessionRestoreTestSeam(replacement)
                assertTrue(runCatching { installed.read() }.isFailure)
            } finally {
                runtime.retire(); manager.cancelSyncTestWork()
                directory.listFiles()?.forEach { it.delete() }; directory.delete()
            }
        }
    }

    @Test fun `real native transfer rejects active profile deletion before any checkpoint or runtime install`() = runBlocking {
        loadTransferJni()
        val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-transfer-selection-").toFile()
        val checkpointKey = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val encrypted = VortxEncryptedCheckpointStore(directory) { checkpointKey }; var writes = 0
        val checkpoints = object : VortxCheckpointStore by encrypted {
            override fun commit(scope: VortxAccountScope, snapshot: String) { writes++; encrypted.commit(scope, snapshot) }
        }
        val manager = VortXSyncManager(TestContext()); val runtime = realCoordinator(manager, checkpoints)
        try {
            val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "star", isOwner = true)
            val child = UserProfile(id = "00000000-0000-0000-0000-000000000789", name = "Selected A", avatar = "moon")
            val cloud = JSONObject().put("vortx", JSONObject().put("roster", org.json.JSONArray().put(owner.encode()).put(child.encode()))
                .put("rosterModified", 1).put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                transport = { _, _, _, _ -> 200 to envelope(cloud) })
            installNative(manager, runtime); assertTrue(manager.syncDown(true))
            NativeProfileAccess { runtime.session() }.select(child.id)
            val installed = runtime.session(); val before = installed.read()
            val checkpoint = checkpoints.read(before.owner.scope); val count = writes
            val diskBytes = directory.listFiles().orEmpty().associate { it.name to it.readBytes().toList() }
            // Produce a valid independently-clocked native deletion from the same baseline.
            VortxNativeRuntime.create(bindings(), owner.id, owner.name).use { peer ->
                for (action in listOf(
                    JSONObject().put("type", "bind_sync_scope").put("scope", before.owner.scope.accountID),
                    JSONObject().put("type", "merge_native_sync").put("document", before.state.getJSONObject("nativeSync")),
                    JSONObject().put("type", "delete_profile").put("id", child.id))) {
                    assertTrue(JSONObject(peer.dispatch(action.toString())).getBoolean("ok"))
                }
                cloud.put("nativeSync", JSONObject(peer.stateJson()).getJSONObject("nativeSync"))
            }
            // Establish the adversarial premise with the real kernel: without the host's
            // precommit validator this accepted merge changes A to the remaining owner B.
            VortxNativeRuntime.create(bindings(), owner.id, owner.name).use { unguarded ->
                for (action in listOf(
                    JSONObject().put("type", "bind_sync_scope").put("scope", before.owner.scope.accountID),
                    JSONObject().put("type", "merge_native_sync").put("document", before.state.getJSONObject("nativeSync")),
                    JSONObject().put("type", "switch_profile").put("id", child.id),
                    JSONObject().put("type", "merge_native_sync").put("document", cloud.getJSONObject("nativeSync")))) {
                    assertTrue(JSONObject(unguarded.dispatch(action.toString())).getBoolean("ok"))
                }
                assertEquals(owner.id, JSONObject(unguarded.stateJson()).getString("activeProfileId"))
            }
            val transfer = requireNotNull(manager.captureAccountTransfer())
            assertFalse(transfer.restore())
            assertEquals(count, writes); assertEquals(checkpoint, checkpoints.read(before.owner.scope))
            assertEquals(diskBytes, directory.listFiles().orEmpty().associate { it.name to it.readBytes().toList() })
            assertSame(installed, runtime.session()); assertEquals(before.owner, installed.read().owner)
            assertEquals(before.state.toString(), installed.read().state.toString())
            transfer.abandon()
        } finally {
            runtime.retire(); manager.cancelSyncTestWork()
            directory.listFiles()?.forEach { it.delete() }; directory.delete()
        }
    }

    @Test fun `real website and legacy edit candidate validators reject before checkpoint publication`() = runBlocking {
        loadTransferJni()
        val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-transfer-website-").toFile()
        val checkpointKey = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val encrypted = VortxEncryptedCheckpointStore(directory) { checkpointKey }; var writes = 0
        val checkpoints = object : VortxCheckpointStore by encrypted {
            override fun commit(scope: VortxAccountScope, snapshot: String) { writes++; encrypted.commit(scope, snapshot) }
        }
        val manager = VortXSyncManager(TestContext()); val runtime = realCoordinator(manager, checkpoints)
        try {
            val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "star", isOwner = true)
            val aggregate = JSONObject().put("editedAt", 1_000_001).put("roster", org.json.JSONArray()
                .put(JSONObject().put("id", owner.id).put("name", "Legacy name"))).put("libraryAdds", JSONObject())
            val cloud = JSONObject().put("vortx", JSONObject().put("roster", org.json.JSONArray().put(owner.encode()))
                .put("rosterModified", 1).put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
                .put("profileEdits", aggregate)
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                transport = { _, _, _, _ -> 200 to envelope(cloud) })
            installNative(manager, runtime); assertTrue(manager.syncDown(true))
            val installed = runtime.session()
            assertEquals("Legacy name", installed.read().state.getJSONObject("roster")
                .getJSONObject("profiles").getJSONObject(owner.id).getString("name"))
            assertEquals(1, installed.read().state.getJSONObject("nativeSync").getJSONObject("legacyProfileEditReceipts").length())
            for (legacy in listOf(false, true)) {
                val before = installed.read(); val checkpoint = checkpoints.read(before.owner.scope); val count = writes; var validated = false
                val diskBytes = directory.listFiles().orEmpty().associate { it.name to it.readBytes().toList() }
                val reject: (VortxNativeRuntime) -> Unit = { validated = true; error("Selected profile candidate rejected") }
                val event = JSONObject().put("eventId", "00000000-0000-4000-8000-000000000001").put("editedAt", 2_000_001)
                    .put("observedNativeClock", 1000).put("roster", org.json.JSONArray()
                        .put(JSONObject().put("id", owner.id).put("name", "Rejected name"))).put("libraryAdds", JSONObject())
                // Prove schema/clock/bootstrap admission against the exact sealed baseline on a
                // disposable real native writer before testing the precommit rejection boundary.
                val cloneDirectory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-transfer-website-control-").toFile()
                val cloneKey = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
                try {
                    val cloneStore = VortxEncryptedCheckpointStore(cloneDirectory) { cloneKey }
                    cloneStore.commit(before.owner.scope, requireNotNull(checkpoint))
                    com.vortx.android.engine.VortxNativeSession.open(before.owner.scope, owner.name, bindings(), cloneStore, noNetwork()).use { control ->
                        assertTrue("legacy=$legacy event must be accepted without the rejecting validator",
                            if (legacy) control.applyLegacyWebsiteAggregate(aggregate) else control.applyWebsiteProfileEdit(event))
                        assertEquals(if (legacy) "Legacy name" else "Rejected name", control.read().state.getJSONObject("roster")
                            .getJSONObject("profiles").getJSONObject(owner.id).getString("name"))
                    }
                } finally { cloneDirectory.listFiles()?.forEach { it.delete() }; cloneDirectory.delete() }
                val rejected = runCatching {
                    if (legacy) installed.applyLegacyWebsiteAggregate(aggregate, verifyCandidate = reject)
                    else installed.applyWebsiteProfileEdit(event, verifyCandidate = reject)
                }
                assertEquals("legacy=$legacy must reach the candidate validator", "Selected profile candidate rejected", rejected.exceptionOrNull()?.message)
                assertTrue("legacy=$legacy validator invoked", validated); assertEquals(count, writes)
                assertEquals(checkpoint, checkpoints.read(before.owner.scope)); assertEquals(before.owner, installed.read().owner)
                assertEquals(diskBytes, directory.listFiles().orEmpty().associate { it.name to it.readBytes().toList() })
                assertEquals(before.state.toString(), installed.read().state.toString())
            }
        } finally {
            runtime.retire(); manager.cancelSyncTestWork()
            directory.listFiles()?.forEach { it.delete() }; directory.delete()
        }
    }

    @Test fun `real native global and acknowledgement commits cannot write after transfer retirement`() = runBlocking {
        loadTransferJni()
        for (mutation in listOf("record-globals", "acknowledge-host")) for (cancel in listOf(false, true)) {
            val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-transfer-mutation-").toFile()
            val checkpointKey = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
            val encrypted = VortxEncryptedCheckpointStore(directory) { checkpointKey }; var writes = 0
            val checkpoints = object : VortxCheckpointStore by encrypted {
                override fun commit(scope: VortxAccountScope, snapshot: String) { writes++; encrypted.commit(scope, snapshot) }
            }
            val context = TestContext(); val manager = VortXSyncManager(context); val runtime = realCoordinator(manager, checkpoints)
            try {
                val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "star", isOwner = true)
                val cloud = JSONObject().put("vortx", JSONObject().put("roster", org.json.JSONArray().put(owner.encode()))
                    .put("rosterModified", 1).put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, _, _ ->
                    if (method == "GET") 200 to envelope(cloud) else 200 to JSONObject().put("accepted", true)
                })
                installNative(manager, runtime); assertTrue(manager.syncDown(true))
                if (mutation == "record-globals") {
                    context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", true).commit()
                    context.getSharedPreferences("vortx_sync_dirty", 0).edit()
                        .putString("vortx.sync.dirtySettings.${account.id}", "{\"stremiox.autoSkip\":123.25}").commit()
                }
                val transfer = requireNotNull(manager.captureAccountTransfer())
                var reached = false; var writesBefore = -1; var before = ""; var checkpoint: String? = null
                var diskBytes = emptyMap<String, List<Byte>>()
                manager.installTransferNativeMutationTestSeam { kind -> if (kind == mutation) {
                    reached = true; writesBefore = writes
                    val read = runtime.session().read(); before = read.state.toString(); checkpoint = checkpoints.read(read.owner.scope)
                    diskBytes = directory.listFiles().orEmpty().associate { it.name to it.readBytes().toList() }
                    if (cancel) transfer.abandon() else com.vortx.android.profile.ContinueWatchingOwnerGate.advance()
                } }
                assertFalse(transfer.keepDevice()); assertTrue(reached)
                val after = runtime.session().read()
                assertEquals(writesBefore, writes); assertEquals(before, after.state.toString())
                assertEquals(checkpoint, checkpoints.read(after.owner.scope))
                assertEquals(diskBytes, directory.listFiles().orEmpty().associate { it.name to it.readBytes().toList() })
                transfer.abandon()
            } finally {
                runtime.retire(); manager.cancelSyncTestWork()
                directory.listFiles()?.forEach { it.delete() }; directory.delete()
            }
        }
    }
    private open class Gateway : NativeAccountGateway {
        var applied = 0
        var retired = 0
        var reopened = 0
        var seeds = 0
        var last: JSONObject? = null
        override fun retire() { retired++ }
        override suspend fun prepareEmptyAccount(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): JSONObject? {
            check(isCurrent()); seeds++; return null
        }
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

    private fun envelope(doc: JSONObject = JSONObject().put("nativeSync", JSONObject())) =
        JSONObject().put("version", 100).put("document", VortXCrypto.sealDocument(key, doc.toString().toByteArray(), account.id, 100, true))

    @Test fun `already issued actual outbound permit cannot dispatch after hold cancel or successor`() = runBlocking {
        for (transition in listOf("hold", "cancel", "successor")) {
            val manager = VortXSyncManager(TestContext()); var sent = 0; var canceled = 0
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                    transport = { _, _, _, _ -> sent++; 200 to JSONObject().put("accepted", true) })
                installNative(manager, Gateway())
                val unstarted = requireNotNull(manager.captureOutboundPermitTestSeam())
                val attached = requireNotNull(manager.captureOutboundPermitTestSeam())
                assertTrue(attached.attachCancellation { canceled++ })
                val first = requireNotNull(manager.captureAccountTransfer())
                val second = if (transition == "successor") requireNotNull(manager.captureAccountTransfer()) else null
                if (transition != "hold") first.abandon()
                assertFalse(unstarted.isCurrent()); assertFalse(attached.isCurrent())
                assertFalse(unstarted.attachCancellation { canceled++ })
                assertEquals(0, manager.dispatchOutboundPermitTestSeam(unstarted))
                assertEquals(0, sent); assertEquals(1, canceled)
                if (second != null) { assertTrue(second.isCurrent()); second.abandon() } else first.abandon()
            } finally { manager.cancelSyncTestWork() }
        }
    }

    @Test fun `transfer globals and host acknowledgement are denied at actual native mutation boundary`() = runBlocking {
        for (mutation in listOf("record-globals", "acknowledge-host")) for (cancel in listOf(false, true)) {
            val context = TestContext(); val manager = VortXSyncManager(context); var recorded = 0; var acknowledged = 0
            val gateway = object : Gateway() {
                override fun recordGlobalPreferences(account: SessionOwnerSnapshot.Account, changes: JSONObject): Boolean { recorded++; return true }
                override fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean { acknowledged++; return true }
                override fun exportDocument(account: SessionOwnerSnapshot.Account) = super.exportDocument(account).copy(hostPreferences = JSONObject())
            }
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, _, _ ->
                    if (method == "GET") 200 to envelope() else 200 to JSONObject().put("accepted", true)
                })
                installNative(manager, gateway)
                if (mutation == "record-globals") {
                    context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", true).commit()
                    context.getSharedPreferences("vortx_sync_dirty", 0).edit()
                        .putString("vortx.sync.dirtySettings.${account.id}", "{\"stremiox.autoSkip\":123.25}").commit()
                }
                val transfer = requireNotNull(manager.captureAccountTransfer()); var reached = false
                manager.installTransferNativeMutationTestSeam { kind -> if (kind == mutation) {
                    reached = true
                    if (cancel) transfer.abandon() else com.vortx.android.profile.ContinueWatchingOwnerGate.advance()
                } }
                assertFalse(transfer.keepDevice()); assertTrue(reached)
                assertEquals(0, recorded); assertEquals(0, acknowledged)
                transfer.abandon()
            } finally { manager.cancelSyncTestWork() }
        }
    }

    @Test fun `suspended automatic pull cannot publish after hold cancel ABA or successor hold`() = runBlocking {
        for (successor in listOf(false, true)) {
            val manager = VortXSyncManager(TestContext()); val gateway = Gateway()
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { _, _, _, _ ->
                    entered.complete(Unit); release.await(); 200 to envelope()
                })
                installNative(manager, gateway)
                val old = async { manager.syncDown(true) }; entered.await()
                val first = requireNotNull(manager.captureAccountTransfer())
                val second = if (successor) requireNotNull(manager.captureAccountTransfer()) else null
                first.abandon()
                if (second != null) assertTrue(second.isCurrent())
                release.complete(Unit)
                assertFalse(old.await()); assertEquals(0, gateway.applied)
                second?.abandon()
            } finally { release.complete(Unit); manager.cancelSyncTestWork() }
        }
    }

    @Test fun `suspended transfer pull rejects cancel and irreversible profile ABA before apply`() = runBlocking {
        for (cancel in listOf(false, true)) {
            val manager = VortXSyncManager(TestContext()); val gateway = Gateway()
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { _, _, _, _ ->
                    entered.complete(Unit); release.await(); 200 to envelope()
                })
                installNative(manager, gateway)
                val transfer = requireNotNull(manager.captureAccountTransfer())
                val result = async { transfer.restore() }; entered.await()
                if (cancel) transfer.abandon() else {
                    com.vortx.android.profile.ContinueWatchingOwnerGate.advance()
                    com.vortx.android.profile.ContinueWatchingOwnerGate.advance()
                }
                release.complete(Unit)
                assertFalse(result.await()); assertEquals(0, gateway.applied); assertFalse(transfer.isCurrent())
                transfer.abandon()
            } finally { release.complete(Unit); manager.cancelSyncTestWork() }
        }
    }

    @Test fun `held debounce dirty intent survives and explicit restore never retries upload`() = runBlocking {
        val context = TestContext(); val manager = VortXSyncManager(context); val gateway = Gateway(); var calls = 0
        val prefs = context.getSharedPreferences("vortx_sync_state", 0)
        try {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                transport = { _, _, _, _ -> calls++; 200 to envelope() })
            installNative(manager, gateway)
            manager.requestSyncSoon() // A real pending debounce is canceled by the hold; its intent is not.
            val transfer = requireNotNull(manager.captureAccountTransfer())
            manager.requestSyncSoon() // A newer edit while held also stays durable.
            assertTrue(transfer.hasPendingChanges()); assertTrue(prefs.getBoolean("pendingPush.${account.id}", false))
            assertFalse(transfer.restore()); assertFalse(manager.syncUp()); assertFalse(manager.syncDown(true))
            assertEquals(0, calls); assertEquals(0, gateway.applied)
            transfer.abandon()
            assertTrue(prefs.getBoolean("pendingPush.${account.id}", false))
        } finally { manager.cancelSyncTestWork() }
    }

    @Test fun `native projection receipt preserves only its own transition and rejects a delayed foreign transition`() = runBlocking {
        for (foreign in listOf(false, true)) {
            val manager = VortXSyncManager(TestContext())
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); var published = 0; var committed = 0
            val gateway = object : Gateway() {
                override suspend fun applyTransferDocument(account: SessionOwnerSnapshot.Account, document: JSONObject,
                    isCurrent: () -> Boolean, projection: NativeTransferProjection): Boolean {
                    entered.complete(Unit); release.await()
                    if (!projection.commit { committed++ }) return false
                    return projection.publish {
                        com.vortx.android.profile.ContinueWatchingOwnerGate.transition({ Unit }) { published++ }
                    }
                }
            }
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                    transport = { _, _, _, _ -> 200 to envelope() })
                installNative(manager, gateway)
                val transfer = requireNotNull(manager.captureAccountTransfer()); val result = async { transfer.restore() }
                entered.await()
                if (foreign) com.vortx.android.profile.ContinueWatchingOwnerGate.advance()
                release.complete(Unit)
                assertEquals(!foreign, result.await()); assertEquals(if (foreign) 0 else 1, published)
                assertEquals(if (foreign) 0 else 1, committed)
                assertEquals(!foreign, transfer.isCurrent())
                transfer.abandon()
            } finally { release.complete(Unit); manager.cancelSyncTestWork() }
        }
    }

    @Test fun `nested foreign transition is never excused by projection receipt`() {
        val gate = com.vortx.android.profile.ContinueWatchingOwnerGate
        val witness = gate.captureTransferWitness()
        assertFalse(witness.project({ true }) {
            gate.transition({ Unit }) { gate.transition({ Unit }) {} }
        })
        assertFalse(witness.isCurrent())
    }

    @Test fun `real native coordinator transfer projection is fenced across Main suspension`() = runBlocking {
        org.junit.Assume.assumeTrue("Requires reviewed local JNI", System.getenv("VORTX_JNI_SYNC") == "1")
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        for (foreign in listOf(false, true)) {
            val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-transfer-").toFile()
            val checkpointKey = javax.crypto.KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
            val manager = VortXSyncManager(TestContext()); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            var published = 0
            val runtime = NativeAccountCoordinator(bindings(), VortxEncryptedCheckpointStore(directory) { checkpointKey },
                { noNetwork() }, { manager.sessionOwnerSnapshot() == it }, { it() }, {},
                projectTransfer = { accepted, admission ->
                    val owner = accepted.read().owner
                    entered.complete(Unit); release.await()
                    admission.publish {
                        accepted.owned(owner) {
                            com.vortx.android.profile.ContinueWatchingOwnerGate.transition({ Unit }) { published++ }
                        }
                    }
                })
            try {
                val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Main", avatar = "star", isOwner = true)
                val cloud = JSONObject().put("vortx", JSONObject().put("roster", org.json.JSONArray().put(owner.encode()))
                    .put("rosterModified", 1).put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                    transport = { _, _, _, _ -> 200 to envelope(cloud) })
                installNative(manager, runtime)
                val transfer = requireNotNull(manager.captureAccountTransfer()); val result = async { transfer.restore() }
                entered.await()
                if (foreign) com.vortx.android.profile.ContinueWatchingOwnerGate.advance()
                release.complete(Unit)
                assertEquals(!foreign, result.await()); assertEquals(if (foreign) 0 else 1, published)
                transfer.abandon()
            } finally {
                release.complete(Unit); runtime.retire(); manager.cancelSyncTestWork()
                directory.listFiles()?.forEach { it.delete() }; directory.delete()
            }
        }
    }

    @Test fun `QR late approval cannot persist after cancellation or foreign profile change`() = runBlocking {
        for (cancel in listOf(false, true)) {
            val manager = VortXSyncManager(TestContext()); val gateway = Gateway(); var persisted = 0
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); var payload = ""
            val approval = QrTransferApproval()
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("prior-fixture", account, key), 0, transport = { _, path, body, _ ->
                    when {
                        path == "/v1/qr/start" -> {
                            val (claim, wrapped) = requireNotNull(VortXPairingCrypto.wrapDataKey(key, body!!.getString("devicePublicKey")))
                            payload = JSONObject().put("claim", claim).put("wrapped", wrapped).toString()
                            200 to JSONObject().put("pairingID", "fixture-pair").put("code", "ABC123")
                        }
                        path.startsWith("/v1/qr/status") -> 200 to JSONObject().put("token", "approved-fixture").put("payload", payload)
                        path == "/v1/auth/me" -> {
                            entered.complete(Unit); release.await()
                            200 to JSONObject().put("account", JSONObject().put("id", account.id).put("email", account.email))
                        }
                        else -> error("Unexpected pre-choice request")
                    }
                })
                installNative(manager, gateway)
                manager.installSessionPersistTestSeam { _, _ -> persisted++; true }
                val qr = requireNotNull(manager.qrStart(approval)); val result = async { manager.qrPoll(qr) }
                entered.await()
                if (cancel) { approval.retire(); manager.cancelQrJoiner(qr) }
                else com.vortx.android.profile.ContinueWatchingOwnerGate.advance()
                release.complete(Unit)
                assertEquals(VortXSyncManager.QrJoinResult.Failed, result.await())
                assertEquals(0, persisted); assertEquals("prior-fixture", manager.currentSession()?.token)
                assertEquals(0, gateway.retired)
            } finally { approval.retire(); release.complete(Unit); manager.cancelSyncTestWork() }
        }
    }

    @Test fun `explicit QR adopts once with no sync and cold recovery remains visibly pending until choice`() = runBlocking {
        val context = TestContext(); val manager = VortXSyncManager(context); val gateway = Gateway()
        val approval = QrTransferApproval(); var persisted = 0; var backupRequests = 0; var payload = ""
        try {
            val transport: SyncRequestTestSeam = { _, path, body, _ -> when {
                path == "/v1/qr/start" -> {
                    val (claim, wrapped) = requireNotNull(VortXPairingCrypto.wrapDataKey(key, body!!.getString("devicePublicKey")))
                    payload = JSONObject().put("claim", claim).put("wrapped", wrapped).toString()
                    200 to JSONObject().put("pairingID", "fixture-pair").put("code", "ABC123")
                }
                path.startsWith("/v1/qr/status") -> 200 to JSONObject().put("token", "approved-fixture").put("payload", payload)
                path == "/v1/auth/me" -> 200 to JSONObject().put("account", JSONObject().put("id", account.id).put("email", account.email))
                else -> { backupRequests++; 200 to envelope() }
            } }
            manager.installSignedOutAuthTestSeam(transport)
            manager.installNativeGatewayTestSeam(gateway, providerStore)
            assertEquals(VortXSyncManager.SessionUiState.SignedOut, manager.sessionUiState.value)
            manager.installSessionPersistTestSeam { accepted, epoch ->
                persisted++; manager.installSessionRestoreTestSeam(accepted, epoch); true
            }
            val qr = requireNotNull(manager.qrStart(approval))
            assertTrue(manager.qrPoll(qr) is VortXSyncManager.QrJoinResult.SignedIn)
            assertEquals(VortXSyncManager.QrJoinResult.Failed, manager.qrPoll(qr))
            assertEquals(1, persisted); assertEquals(0, backupRequests); assertEquals(0, gateway.applied)
            assertTrue(manager.transferPending.value)
            val captured = requireNotNull(manager.captureAccountTransfer()); captured.abandon()
            assertFalse(manager.syncDown(true)); assertEquals(0, backupRequests)
            val recovered = VortXSyncManager(context)
            try {
                recovered.installSyncTestSeam(requireNotNull(manager.currentSession()), 0, transport)
                installNative(recovered, gateway)
                assertTrue(recovered.transferPending.value)
                assertFalse(recovered.syncDown(true)); assertFalse(recovered.syncUp()); assertEquals(0, backupRequests)
                val chosen = requireNotNull(recovered.captureAccountTransfer())
                assertEquals(AccountTransferSession.Probe.HAS_DATA, chosen.probe()); assertEquals(0, gateway.applied)
                assertTrue(chosen.restore()); assertEquals(1, gateway.applied)
                chosen.abandon() // Cancellation is not confirmation; the restart marker stays visible.
                assertTrue(recovered.transferPending.value)
            } finally { recovered.cancelSyncTestWork() }
        } finally { approval.retire(); manager.cancelSyncTestWork() }
    }

    @Test fun `explicit restore on an empty native account never seeds or uploads`() = runBlocking {
        val manager = VortXSyncManager(TestContext()); val gateway = Gateway(); var puts = 0
        try {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, _, _ ->
                if (method == "PUT") puts++
                404 to null
            })
            installNative(manager, gateway)
            val captured = requireNotNull(manager.captureAccountTransfer())
            assertEquals(AccountTransferSession.Probe.EMPTY, captured.probe())
            assertFalse(captured.restore())
            assertEquals(0, gateway.seeds); assertEquals(0, gateway.applied); assertEquals(0, puts)
        } finally { manager.cancelSyncTestWork() }
    }

    @Test fun `captured transfer rejects changed profile and replacement account before mutation`() = runBlocking {
        for (changeAccount in listOf(false, true)) {
            val manager = VortXSyncManager(TestContext()); val gateway = Gateway(); var requests = 0
            try {
                manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { _, _, _, _ -> requests++; 404 to null })
                installNative(manager, gateway)
                val captured = requireNotNull(manager.captureAccountTransfer())
                if (changeAccount) manager.replaceSyncSessionTestSeam(VortXSyncManager.Session("replacement", account.copy(id = "replacement"), key))
                else com.vortx.android.profile.ContinueWatchingOwnerGate.advance()
                assertFalse(captured.isCurrent())
                assertEquals(AccountTransferSession.Probe.UNAVAILABLE, captured.probe())
                assertFalse(captured.keepDevice()); assertFalse(captured.restore()); assertFalse(captured.merge()); assertFalse(captured.seed())
                assertEquals(0, requests); assertEquals(0, gateway.applied); assertEquals(0, gateway.seeds)
            } finally { manager.cancelSyncTestWork() }
        }
    }

    @Test fun `explicit transfer probe never applies account data and restore uses real guarded pull`() = runBlocking {
        val manager = VortXSyncManager(TestContext()); val gateway = Gateway(); var puts = 0
        val cloud = JSONObject().put("vortx", JSONObject().put("fixture", true))
        try {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, _, _ ->
                if (method == "PUT") puts++
                200 to JSONObject().put("version", 100).put("document", VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, 100, true))
            })
            installNative(manager, gateway)
            val captured = requireNotNull(manager.captureAccountTransfer())
            assertEquals(AccountTransferSession.Probe.HAS_DATA, captured.probe())
            assertEquals(0, gateway.applied); assertEquals(0, puts)
            assertTrue(captured.restore()); assertEquals(1, gateway.applied); assertEquals(0, puts)
        } finally { manager.cancelSyncTestWork() }
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
