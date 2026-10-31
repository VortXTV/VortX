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
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.advanceTimeBy
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
    @org.junit.Before fun mainDispatcher() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        NativeSettingsFence.queuedNotificationsForTest = mutableListOf()
    }
    @org.junit.After fun resetDispatcher() {
        NativeSettingsFence.queuedNotificationsForTest = null
        com.vortx.android.integrations.NativeProviderAccess.unbindForTest(); Dispatchers.resetMain()
    }
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
    /** Synthetic login/transport, genuine original manager admission for actual JNI upload fixtures. */
    private fun originalTestAdmission(manager: VortXSyncManager, captured: SessionOwnerSnapshot.Account):
        ((() -> Boolean) -> Boolean)? = manager.captureLocalLibraryMutationAdmission()?.let { original -> { action ->
            original { manager.sessionOwnerSnapshot() == captured && action() }
        } }
    private class Gateway : NativeAccountGateway {
        var applied = 0
        var retired = 0
        var reopened = 0
        var last: JSONObject? = null
        data class AppliedRead(val account: SessionOwnerSnapshot.Account, val operationGeneration: Long,
                               val baseRevision: Long, val raw: ByteArray)
        val appliedReads = mutableListOf<AppliedRead>()
        override fun retire() { retired++ }
        override fun captureUploadOrigin(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): NativeAccountUploadCurrency.Origin {
            val capturedRetirement = retired
            return object : NativeAccountUploadCurrency.Origin { override fun isCurrent() = retired == capturedRetirement && isCurrent.invoke() }
        }
        override fun <T> withUploadExport(account: SessionOwnerSnapshot.Account, source: NativeAccountReadCapture,
            originalRaw: ByteArray, original: NativeAccountUploadCurrency.Origin, isCurrent: () -> Boolean,
            action: (NativeAccountExport, NativeAccountMountToken?, ((JSONObject) -> ByteArray)?, NativeHostUploadAcknowledgment?, NativeAccountUploadCurrency) -> T): T? {
            // Explicit synthetic no-Session currency, bounded by this gateway's retirement.
            val currency = object : NativeAccountUploadCurrency {
                override fun isCurrent() = original.isCurrent()
                override fun <T> withCurrentSession(action: () -> T): T? = if (isCurrent()) action() else null
            }
            val exported = exportDocument(account)
            return currency.withCurrentSession { if (!isCurrent()) null else action(exported, null, null, null, currency) }
        }
        override suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): Boolean {
            check(isCurrent()); reopened++; return true
        }
        override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean {
            check(isCurrent()); applied++; last = JSONObject(document.toString()); return true
        }
        override suspend fun applyRawDocument(
            account: SessionOwnerSnapshot.Account,
            captured: NativeAccountReadCapture,
            isCurrent: () -> Boolean,
        ): Boolean {
            val exact = captured.copyRawForApply(account)
            return try {
                check(isCurrent())
                appliedReads += AppliedRead(account, captured.operationGeneration, captured.baseRevision, exact.copyOf())
                super<NativeAccountGateway>.applyRawDocument(account, captured, isCurrent)
            } finally {
                exact.fill(0)
            }
        }
        fun clearReads() { appliedReads.forEach { it.raw.fill(0) }; appliedReads.clear() }
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
            assertTrue(gateway.appliedReads.isNotEmpty())
            val captured = gateway.appliedReads.first()
            assertEquals(SessionOwnerSnapshot.Account(account.id, 0L), captured.account)
            assertEquals(100L, captured.baseRevision)
            assertTrue(captured.operationGeneration >= 0L)
            assertArrayEquals(doc.toString().toByteArray(Charsets.UTF_8), captured.raw)
            // The projected export deliberately has a different name and clock. Neither may rewrite
            // the original legacy receipt input; the next native-native pull must see the same input.
            assertEquals(doc.getJSONObject("vortx").toString(), result.getJSONObject("vortx").toString())
        } finally { manager.cancelSyncTestWork(); gateway.clearReads() }
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

    @Test fun `unsupported host settings remain dirty while native push may read its merge base`() = runBlocking {
        val context = TestContext(); val manager = VortXSyncManager(context); val gateway = Gateway()
        var requests = 0
        val storageKey = "vortx.sync.dirtySettings.${account.id}"
        try {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                transport = { _, _, _, _ -> requests++; 500 to null })
            installNative(manager, gateway)
            context.getSharedPreferences("vortx_sync_dirty", 0).edit().putString(storageKey, "{\"stremiox.audioLang\":123.25}").commit()
            assertFalse(manager.syncUp())
            assertEquals(1, requests)
            assertEquals("{\"stremiox.audioLang\":123.25}", context.getSharedPreferences("vortx_sync_dirty", 0).getString(storageKey, null))
        } finally { manager.cancelSyncTestWork() }
    }

    /** Genuine generic export -> real encrypted GET -> manager capture -> actual coordinator mount.
     * Never fabricate a native schema carrier or a verified streaming UID. UNRUN proposal.
     */
    private inner class GenericPlaylistFixture(val padding: Int = 0,
        val initialXperience: Pair<String, ByteArray>? = null) {
        val context = TestContext()
        val manager = VortXSyncManager(context)
        val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "generic-playlist-admission-").toFile()
        val disk = VortxEncryptedCheckpointStore(directory) { javax.crypto.spec.SecretKeySpec(key, "AES") }
        var forks = 0
        var checkpointAttempts = 0
        private val checkpoints = object : com.vortx.android.engine.VortxCheckpointStore by disk {
            override fun compareAndCommitCheckpoint(scope: com.vortx.android.engine.VortxAccountScope,
                expected: com.vortx.android.engine.NativeCheckpointRead, snapshot: String): com.vortx.android.engine.NativeCheckpointRead {
                checkpointAttempts++
                return disk.compareAndCommitCheckpoint(scope, expected, snapshot)
            }
        }
        lateinit var principal: SessionOwnerSnapshot.Account
        lateinit var runtime: NativeAccountCoordinator
        lateinit var originalRaw: ByteArray
        var uploaded: ByteArray? = null
        var uploadedVersion: Long? = null
        var serverVersion = 100L
        var getCount = 0
        var beforeGet: (() -> Unit)? = null
        var controlledAdmissionEpoch = 0L
        var putCount = 0
        var rejectNextPut = false
        var updateServerAfterPut = false
        var beforePut: (() -> Unit)? = null
        val sentCandidates = mutableListOf<ByteArray>()
        var onFork: (() -> Unit)? = null
        val field = com.vortx.android.engine.NativePlaylist.field(java.util.UUID.fromString("00000000-0000-0000-0000-000000000101"))
        fun value() = com.vortx.android.engine.NativePlaylist.encodedValue(com.vortx.android.engine.NativePlaylist.Document(
            "00000000-0000-0000-0000-000000000101", "Saved", listOf(com.vortx.android.engine.NativePlaylist.Entry(
                "00000000-0000-0000-0000-000000000201", "tt000101", "movie", "Title"))))
        suspend fun start() {
            org.junit.Assume.assumeTrue("Requires reviewed local JNI", System.getenv("VORTX_JNI_SYNC") == "1")
            System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0,
                transport = { method, _, body, _ ->
                    if (method == "GET") {
                        getCount++
                        beforeGet?.invoke()
                        200 to JSONObject().put("version", serverVersion).put("document",
                            VortXCrypto.sealDocument(key, originalRaw, account.id, serverVersion, true))
                    }
                    else {
                        val sent = requireNotNull(body)
                        uploadedVersion = sent.getLong("version")
                        uploaded = VortXCrypto.openDocument(key, sent.getString("document"), account.id, sent.getLong("version"))
                        sentCandidates += checkNotNull(uploaded).copyOf(); putCount++
                        beforePut?.also { beforePut = null }?.invoke()
                        if (rejectNextPut) {
                            rejectNextPut = false
                            // Rejection echo is deliberately unrelated to the next real GET.
                            200 to JSONObject().put("accepted", false).put("version", 999_999).put("document", "not-a-merge-base")
                        } else {
                            if (updateServerAfterPut) {
                                val previous = originalRaw
                                originalRaw = checkNotNull(uploaded).copyOf(); previous.fill(0)
                                serverVersion = checkNotNull(uploadedVersion)
                            }
                            200 to JSONObject().put("accepted", true)
                        }
                    }
                })
            manager.installSessionRestoreTestSeam(manager.currentSession())
            principal = manager.sessionOwnerSnapshot() as SessionOwnerSnapshot.Account
            val baseBindings = bindings()
            val hooked = object : VortxRuntimeBindings by baseBindings {
                override fun hydrate(snapshot: String): Long = baseBindings.hydrate(snapshot).also {
                    forks++
                    val action = onFork; onFork = null; action?.invoke()
                }
            }
            runtime = NativeAccountCoordinator(hooked, checkpoints, { noNetwork() }, { manager.sessionOwnerSnapshot() == it },
                { it() }, {}, captureOwnAccountAdmission = { captured ->
                    val originalEpoch = controlledAdmissionEpoch // Explicit controlled credential-admission retirement.
                    manager.captureLocalLibraryMutationAdmission()?.let { admission -> { action ->
                        admission { controlledAdmissionEpoch == originalEpoch && manager.sessionOwnerSnapshot() == captured && action() }
                    } }
                })
            val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Owner", avatar = "star", isOwner = true)
            val legacy = JSONObject().put("vortx", JSONObject().put("roster", org.json.JSONArray().put(owner.encode()))
                .put("rosterModified", 1).put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
            assertTrue(runtime.applyDocument(principal, legacy) { true })
            val genuine = requireNotNull(runtime.exportDocument(principal))
            assertNull(genuine.rawAccount)
            assertTrue(genuine.nativeSync.getInt("schemaVersion") in 1..5)
            assertTrue(genuine.nativeSync.has("legacyImport"))
            val unknown = "{\"number\":1.2300e+2,\"negativeZero\":-0}".toByteArray()
            val native = com.vortx.android.engine.OHJson.Obj(genuine.nativeSync.toString().toByteArray())
                .set("futureNative", unknown).encoded()
            val host = JSONObject(requireNotNull(genuine.hostPreferences).toString())
            val profiles = host.getJSONObject("profiles")
            val profile = com.vortx.android.engine.NativeHostPreferences.canonicalProfileID(owner.id)
            val bucket = profiles.optJSONObject(profile) ?: JSONObject().put("fields", JSONObject()).also { profiles.put(profile, it) }
            bucket.getJSONObject("fields").put("playlist.v2.future", JSONObject().put("clock", 1)
                .put("actor", "00000000-0000-0000-0000-000000000222")
                .put("value", JSONObject().put("schema", 2).put("future", JSONObject().put("opaque", true))))
            val rawHost = com.vortx.android.engine.OHJson.Obj(host.toString().toByteArray())
            initialXperience?.let { (field, register) ->
                // Explicit synthetic SERVER baseline, installed before the actual authenticated
                // manager GET. Never a DTO serialized and represented as an original raw record.
                val groups = rawHost.obj("profiles"); val group = groups.obj(profile)
                group.set("fields", group.obj("fields").set(field, register).encoded())
                rawHost.set("profiles", groups.set(profile, group.encoded()).encoded())
            }
            val root = com.vortx.android.engine.OHJson.Obj(legacy.toString().toByteArray())
                .set("nativeSync", native).set("futureRoot", unknown)
                .set("nativeHostPreferences", if (initialXperience == null) host.toString().toByteArray() else rawHost.encoded())
                .set("apiKeys", "{\"futureKey\":\"preserved\"}".toByteArray())
            if (padding > 0) root.set("padding", com.vortx.android.engine.OHJson.quote("x".repeat(padding)))
            originalRaw = root.encoded()
            installNative(manager, runtime)
            assertTrue(manager.syncDown(true))
            val retained = requireNotNull(coordinatorRead(runtime))
            assertArrayEquals(originalRaw, retained.copyRawForApply(principal))
            assertNotNull(runtime.exportDocument(principal)?.genericSourceNativeProjection)
        }
        suspend fun edit(target: NativePlaylistProfileGateway.Target = runtime.capturePlaylistProfile().getOrThrow().target) =
            runtime.compareAndSetPlaylistField(target, "00000000-0000-0000-0000-000000000301", field, null, value())
        suspend fun rejectAt(message: String, checkpointCalls: Int = 0) {
            // Capture must succeed, and a real fork must be reached. An earlier admission failure
            // cannot masquerade as provider/host budget, ABA, or encrypted checkpoint-CAS coverage.
            val target = runtime.capturePlaylistProfile().getOrThrow().target
            val priorForks = forks
            val priorAttempts = checkpointAttempts
            val failure = edit(target).exceptionOrNull()
            assertNotNull(failure)
            assertEquals(message, failure!!.message)
            assertEquals(priorForks + 1, forks)
            assertEquals(priorAttempts + checkpointCalls, checkpointAttempts)
        }
        suspend fun finish() {
            if (::runtime.isInitialized) runtime.retire()
            manager.cancelSyncTestWork()
            if (::originalRaw.isInitialized) originalRaw.fill(0)
            uploaded?.fill(0)
            sentCandidates.forEach { it.fill(0) }; sentCandidates.clear()
            directory.listFiles()?.forEach { it.delete() }; directory.delete()
        }
        suspend fun coldReopen() {
            runtime.retire()
            // New Store instance authenticates/decrypts the durable file; no retained runtime,
            // per-edit receipt or old authenticated-read object is carried across this reopen.
            val reopened = VortxEncryptedCheckpointStore(directory) { javax.crypto.spec.SecretKeySpec(key, "AES") }
            runtime = NativeAccountCoordinator(bindings(), reopened, { noNetwork() }, { manager.sessionOwnerSnapshot() == it },
                { it() }, {}, captureOwnAccountAdmission = { captured ->
                    manager.captureLocalLibraryMutationAdmission()?.let { admission -> { action ->
                        admission { manager.sessionOwnerSnapshot() == captured && action() }
                    } }
                })
            installNative(manager, runtime)
            assertTrue(runtime.reopenCheckpoint(principal) { manager.sessionOwnerSnapshot() == principal })
            assertNull(coordinatorRead(runtime))
        }
    }

    /** Additional separately selected Xperience controls reuse the ACTUAL manager/provider/
     * settings/encrypted-store/JNI fixture. This is not a new @Test in the retained 19/87 roster.
     * All transport responses and credentials remain synthetic; no live account/network proof. */
    internal suspend fun verifyXperienceAccountProducerCases() {
        for (mode in listOf("success", "providerBudget", "settingBudget", "providerAck", "settingsAba")) {
            providerStore.values.clear()
            val namespace = java.util.UUID.fromString("00000000-0000-0000-0000-000000000401")
            fun document(title: String) = com.vortx.android.xperience.XperienceCollections.parse(
                """[{"id":"c","title":"$title","folders":[],"future":{"n":1.0,"z":-0.0}}]""".toByteArray())
            fun append(id: java.util.UUID = namespace) = com.vortx.android.xperience.XperienceImportNamespace.append(document("A"), "Saved", id)
            val originalA = append()
            val serverEvent = com.vortx.android.engine.OHJson.Obj().set("clock", "1".toByteArray())
                .set("actor", com.vortx.android.engine.OHJson.quote("00000000-0000-0000-0000-000000000222"))
                .set("value", originalA.value()).encoded()
            val fixture = GenericPlaylistFixture(if (mode.endsWith("Budget")) 2_000_000 else 0,
                if (mode == "success") originalA.field to serverEvent else null)
            val notifications = mutableListOf<() -> Unit>()
            NativeSettingsFence.queuedNotificationsForTest = notifications
            try {
                fixture.start()
                if (mode == "success") {
                    val profiles = NativeProfileAccess { fixture.runtime.session() }
                    profiles.save(profiles.read().profiles.single().copy(name = "Pending local name"), false)
                    fixture.context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", true).apply()
                }
                if (mode == "providerBudget")
                    assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "p".repeat(1_200_000))))
                if (mode == "settingBudget") {
                    fixture.context.getSharedPreferences("vortx_settings", 0).edit()
                        .putString("stremiox.languageOverride", "x".repeat(3_700_000)).apply()
                    assertTrue(notifications.isNotEmpty())
                }
                if (mode == "providerAck") {
                    assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "fixture-pending")))
                    val wire = com.vortx.android.integrations.NativeProviderVault(providerStore).load(fixture.principal).document()
                    fixture.onFork = { assertTrue(com.vortx.android.integrations.NativeProviderAccess.acknowledge(fixture.principal, wire)) }
                }
                if (mode == "settingsAba") fixture.onFork = {
                    val prefs = fixture.context.getSharedPreferences("vortx_settings", 0)
                    val old = prefs.getString("stremiox.languageOverride", null)
                    prefs.edit().putString("stremiox.languageOverride", "intermediate").apply()
                    prefs.edit().putString("stremiox.languageOverride", old).apply()
                }
                val opening = fixture.runtime.captureXperienceProfile().getOrThrow()
                val target = opening.target
                val before = fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext
                val forks = fixture.forks; val attempts = fixture.checkpointAttempts
                val proposal = if (mode == "success") {
                    val old = com.vortx.android.xperience.XperienceImportNamespace.read(originalA.field, opening.registers().getValue(originalA.field))
                    old.replacement(document("Refreshed"), old.label, old.bindings)
                } else append()
                val result = fixture.runtime.writeXperience(target, proposal)
                assertEquals(forks + 1, fixture.forks) // Reach actual candidate/producer, not an earlier refusal.
                if (mode != "success") {
                    val expected = when (mode) {
                        "providerAck" -> "Pending provider family changed"
                        "settingsAba" -> "Pending settings changed"
                        else -> "Complete account exceeds encrypted budget"
                    }
                    assertEquals(expected, result.exceptionOrNull()?.message)
                    assertEquals(attempts, fixture.checkpointAttempts)
                    assertEquals(before, fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext)
                    assertFalse(fixture.runtime.session().requiresRecovery())
                    if (mode == "providerBudget") assertTrue(com.vortx.android.integrations.NativeProviderAccess.hasPending(fixture.principal) == true)
                } else {
                    val acceptedA = result.getOrThrow()
                    // The genuine fixture GET contained synthetic old A. Refresh A and append B
                    // without another GET/upload; only local persistence/readback is asserted.
                    val rawA = acceptedA.registers().getValue(append().field)
                    assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "fixture-still-pending")))
                    val second = append(java.util.UUID.fromString("00000000-0000-0000-0000-000000000402"))
                    val acceptedB = fixture.runtime.writeXperience(opening.target, second).getOrThrow()
                    assertArrayEquals(rawA, acceptedB.registers().getValue(append().field))
                    assertNotNull(acceptedB.registers()[second.field])
                    assertEquals("Pending local name", NativeProfileAccess { fixture.runtime.session() }.read().profiles.single().name)
                    assertTrue(com.vortx.android.integrations.NativeProviderAccess.hasPending(fixture.principal) == true)
                    val local = checkNotNull(fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext)
                    assertFalse(local.contains("fixture-still-pending")) // Full provider candidate was sized, never leaked into host/JNI.
                    assertFalse(fixture.runtime.session().requiresRecovery())
                }
            } finally {
                fixture.finish()
                com.vortx.android.integrations.NativeProviderAccess.unbindForTest()
                NativeSettingsFence.queuedNotificationsForTest = mutableListOf()
            }
        }
    }

    /** Separately selected upload controls; old 19 and domain18/JNI3 methods remain unchanged.
     * Real manager/crypto/JNI/Session/store bodies, synthetic server/provider inputs only. */
    private fun issuedTestCurrency(fixture: GenericPlaylistFixture): NativeAccountUploadCurrency {
        val origin = requireNotNull(fixture.runtime.captureUploadOrigin(fixture.principal) { true })
        val read = requireNotNull(coordinatorRead(fixture.runtime))
        val raw = read.copyRawForApply(fixture.principal)
        return try { requireNotNull(fixture.runtime.withUploadExport(fixture.principal, read, raw, origin, { true }) {
            exported, _, _, ack, currency ->
            try { currency } finally {
                ack?.close(); exported.genericSourceNativeProjection?.fill(0)
                exported.rawHostPreferences?.fill(0); exported.rawAccount?.fill(0)
            }
        }) } finally { raw.fill(0) }
    }

    /** Controlled two-thread lock test using the ACTUAL manager operations admission and actual
     * Session/currency. It is not an Android scheduler/deadlock reproduction. Finite release/join
     * also cleans up the intentionally wrong Session-taking predicate without leaving ABBA. */
    internal suspend fun verifyUploadCurrencyLockOrder() {
        val fixture = GenericPlaylistFixture()
        val held = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val scalarDone = java.util.concurrent.CountDownLatch(1)
        val publisherDone = java.util.concurrent.CountDownLatch(1)
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable?>(null)
        var threads: List<Thread> = emptyList()
        try {
            fixture.start()
            val session = fixture.runtime.session()
            val currency = issuedTestCurrency(fixture)
            val original = requireNotNull(fixture.manager.captureLocalLibraryMutationAdmission())
            fun launch(name: String, body: () -> Unit) = Thread({
                try { body() } catch (error: Throwable) { failure.compareAndSet(null, error) }
            }, name).apply { isDaemon = true }
            val writer = launch("raw-upload-session-owner") {
                synchronized(session) {
                    held.countDown()
                    check(release.await(5, java.util.concurrent.TimeUnit.SECONDS)) { "Owned Session release timed out" }
                }
                // Wait outside Session so a deliberately Session-taking broken scalar predicate
                // can exit after the assertion timeout; cleanup itself must not form ABBA.
                check(publisherDone.await(5, java.util.concurrent.TimeUnit.SECONDS))
                check(currency.withCurrentSession {
                    check(Thread.holdsLock(session))
                    original { currency.isCurrent() }
                } == true) { "Session-first original admission failed" }
            }
            val publisher = launch("raw-upload-operations-owner") {
                try {
                    check(held.await(5, java.util.concurrent.TimeUnit.SECONDS))
                    check(original {
                        check(currency.isCurrent()) // Actual operations monitor; Session held by writer.
                        scalarDone.countDown(); true
                    })
                } finally { publisherDone.countDown() }
            }
            threads = listOf(writer, publisher)
            threads.forEach { it.start() }
            assertTrue("Scalar upload currency entered Session while operations were held",
                scalarDone.await(2, java.util.concurrent.TimeUnit.SECONDS))
            release.countDown()
            threads.forEach { it.join(6_000) }
            check(threads.none { it.isAlive }) { "Owned currency chain did not finish" }
            failure.get()?.let { throw AssertionError("Upload currency chain failed", it) }
            // Controlled equal-plaintext encrypted-file replacement, not a natural device repro.
            // It keeps original scalar identity while forcing the REAL Session CAS uncertainty.
            val scope = session.scope
            fixture.disk.commit(scope, checkNotNull(fixture.disk.captureCheckpoint(scope).plaintext))
            assertTrue(runCatching { session.dispatch(emptyList(), session.read().owner, progressOnly = true) }.isFailure)
            assertTrue(session.requiresRecovery())
            assertTrue(currency.isCurrent()) // Deliberately not cached health.
            assertNull(currency.withCurrentSession { fail("Recovering Session admitted") })
            assertNull(fixture.runtime.currentMountToken(fixture.principal))
        } finally {
            release.countDown()
            threads.forEach { it.join(6_000) }
            threads.filter { it.isAlive }.forEach { it.interrupt(); it.join(1_000) }
            // Do not call Session close while a failed thread still owns it. Retain the fixture
            // on that exceptional failure rather than turning a bounded assertion into a hang.
            if (threads.none { it.isAlive }) fixture.finish()
            check(threads.none { it.isAlive }) { "Owned upload currency threads did not terminate" }
            failure.get()?.let { throw AssertionError("Upload currency lock control failed", it) }
        }
    }

    internal suspend fun verifyRawHostUploadCase(mode: String) {
        val namespace = java.util.UUID.fromString("00000000-0000-0000-0000-000000000501")
        fun document(title: String, number: String) = com.vortx.android.xperience.XperienceCollections.parse(
            """[{"id":"c","title":"$title","folders":[],"future":{"n":$number,"z":-0.0}}]""".toByteArray())
        val append = com.vortx.android.xperience.XperienceImportNamespace.append(document("Old server A", "1.0"), "A", namespace)
        val value = com.vortx.android.engine.OHJson.Obj(append.value())
            .set("futureValue", """{"wide":18446744073709551615,"n":1.2300e+2,"z":-0.0}""".toByteArray())
        val event = com.vortx.android.engine.OHJson.Obj().set("clock", "1e0".toByteArray())
            .set("actor", com.vortx.android.engine.OHJson.quote("00000000-0000-0000-0000-000000000222"))
            .set("value", value.encoded()).encoded()
        val fixture = GenericPlaylistFixture(if (mode.endsWith("Budget")) 2_000_000 else 0, append.field to event)
        fixture.updateServerAfterPut = true
        val notifications = mutableListOf<() -> Unit>()
        NativeSettingsFence.queuedNotificationsForTest = notifications
        var remoteFlag: java.lang.reflect.Field? = null
        try {
            fixture.start()
            val profileID = com.vortx.android.engine.NativeHostPreferences.canonicalProfileID(UserProfile.OWNER_ID)
            fun fields(raw: ByteArray) = com.vortx.android.engine.OHJson.Obj(raw).obj("nativeHostPreferences")
                .obj("profiles").obj(profileID).obj("fields")
            fun localFields() = com.vortx.android.engine.OHJson.Obj(fixture.runtime.session().rawHostPreferences())
                .obj("profiles").obj(profileID).obj("fields")
            fun replacingServer(register: ByteArray): ByteArray {
                val root = com.vortx.android.engine.OHJson.Obj(fixture.originalRaw)
                val host = root.obj("nativeHostPreferences"); val groups = host.obj("profiles"); val group = groups.obj(profileID)
                group.set("fields", group.obj("fields").set(append.field, register).encoded())
                host.set("profiles", groups.set(profileID, group.encoded()).encoded())
                return root.set("nativeHostPreferences", host.encoded())
                    .set("futureRetry", """{"n":1.000e+3,"zero":-0}""".toByteArray()).encoded()
            }
            val opening = fixture.runtime.captureXperienceProfile().getOrThrow()
            val old = com.vortx.android.xperience.XperienceImportNamespace.read(append.field, opening.registers().getValue(append.field))
            val changed = fixture.runtime.writeXperience(opening.target,
                old.replacement(document("Pending A", "2.0"), old.label, old.bindings)).getOrThrow()
            val pendingA = changed.registers().getValue(append.field)
            val second = com.vortx.android.xperience.XperienceImportNamespace.append(document("Pending B", "3e0"), "B",
                java.util.UUID.fromString("00000000-0000-0000-0000-000000000502"))
            fixture.runtime.writeXperience(opening.target, second).getOrThrow()
            val pendingB = localFields().raw(second.field)
            val savedScope = fixture.runtime.session().scope
            val source = com.vortx.android.engine.OHJson.Obj(fixture.originalRaw)
            val rootUnknown = source.raw("futureRoot"); val nativeUnknown = source.obj("nativeSync").raw("futureNative")
            val gets = fixture.getCount
            if (mode == "cold") fixture.coldReopen()
            if (mode == "originGlobal") {
                // Controlled credential-admission retirement DURING the real native fork.
                // Original admission remains held, but this active predicate can revoke without
                // taking its monitor (as caller cancellation can). The file barrier must recheck.
                val origin = requireNotNull(fixture.runtime.captureUploadOrigin(fixture.principal) { true })
                val session = fixture.runtime.session()
                val before = session.rawHostPreferences()
                val diskBefore = fixture.disk.captureCheckpoint(savedScope).plaintext
                val forks = fixture.forks; val attempts = fixture.checkpointAttempts
                fixture.onFork = { fixture.controlledAdmissionEpoch++ }
                val rejected = runCatching { fixture.runtime.recordGlobalPreferences(fixture.principal,
                    JSONObject().put("stremiox.autoSkip", true), origin) }.exceptionOrNull()
                assertEquals("Original upload authentication or mount retired", rejected?.message)
                assertEquals(forks + 1, fixture.forks); assertEquals(attempts, fixture.checkpointAttempts)
                assertArrayEquals(before, session.rawHostPreferences()); before.fill(0)
                assertEquals(diskBefore, fixture.disk.captureCheckpoint(savedScope).plaintext)
                assertFalse(session.requiresRecovery()); assertEquals(0, fixture.putCount)
                return
            }
            if (mode == "originGet" || mode == "originRetry") {
                // Controlled same-account credential-admission epoch, NOT a natural credential
                // store/customer reproduction. A post-GET recapture would wrongly adopt it.
                val originalPrincipal = fixture.manager.sessionOwnerSnapshot()
                if (mode == "originRetry") fixture.rejectNextPut = true
                fixture.beforeGet = {
                    if (fixture.getCount >= gets + if (mode == "originGet") 1 else 2) fixture.controlledAdmissionEpoch++
                }
                assertFalse(fixture.manager.syncUp())
                assertEquals(originalPrincipal, fixture.manager.sessionOwnerSnapshot())
                assertEquals(if (mode == "originGet") 0 else 1, fixture.putCount)
                assertEquals(gets + if (mode == "originGet") 1 else 2, fixture.getCount)
                assertTrue(fixture.runtime.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
                return
            }

            if (mode == "capture") {
                val firstRead = requireNotNull(coordinatorRead(fixture.runtime))
                val copiedRaw = firstRead.copyRawForApply(fixture.principal)
                val origin = requireNotNull(fixture.runtime.captureUploadOrigin(fixture.principal) { true })
                var escaped: ((JSONObject) -> ByteArray)? = null
                var acknowledgment: NativeHostUploadAcknowledgment? = null
                fixture.runtime.withUploadExport(fixture.principal, firstRead, copiedRaw, origin, { true }) { exported, _, compose, ack, _ ->
                    val composeRaw = requireNotNull(compose)
                    escaped = composeRaw; acknowledgment = ack
                    try {
                        // DTO/read-only byte mutation cannot replace the private Session snapshot.
                        exported.nativeSync.put("scope", "wrong-DTO-scope")
                        exported.rawHostPreferences?.fill(0)
                        val providers = requireNotNull(com.vortx.android.integrations.NativeProviderAccess.merge(fixture.principal, JSONObject(com.vortx.android.engine.OHJson.utf8(copiedRaw))))
                        val candidate = composeRaw(providers)
                        try {
                            val exact = com.vortx.android.engine.OHJson.Obj(candidate)
                            assertEquals(savedScope.accountID, exact.obj("nativeSync").text("scope"))
                            assertArrayEquals(pendingA, fields(candidate).raw(append.field))
                            assertTrue(runCatching { composeRaw(providers) }.isFailure) // Single consumption.
                        } finally { candidate.fill(0) }
                    } finally { exported.genericSourceNativeProjection?.fill(0); exported.rawAccount?.fill(0) }
                }
                assertTrue(runCatching { escaped!!(JSONObject()) }.exceptionOrNull()?.message?.contains("expired") == true)
                acknowledgment?.close()
                assertTrue(fixture.manager.syncDown(true))
                val next = requireNotNull(coordinatorRead(fixture.runtime))
                // A separate explicit test operation, not the production retry's original origin.
                val nextOrigin = requireNotNull(fixture.runtime.captureUploadOrigin(fixture.principal) { true })
                assertFalse(next.sameObservation(firstRead))
                assertTrue(runCatching { firstRead.copyRawForApply(fixture.principal) }.isFailure)
                assertEquals("Original authenticated upload read changed", runCatching { fixture.runtime.withUploadExport(fixture.principal, firstRead, copiedRaw, nextOrigin, { true }) { _, _, _, _, _ -> fail("Old read admitted") } }.exceptionOrNull()?.message)
                val equalMetadata = NativeAccountReadCapture.fromAuthenticatedPull(fixture.principal, next.operationGeneration,
                    fixture.principal.id, fixture.principal.generation, next.baseRevision, fixture.originalRaw)
                try {
                    assertFalse(next.sameObservation(equalMetadata))
                    assertEquals("Original authenticated upload read changed", runCatching { fixture.runtime.withUploadExport(fixture.principal, equalMetadata, fixture.originalRaw, nextOrigin, { true }) { _, _, _, _, _ -> fail("Unrelated read admitted") } }.exceptionOrNull()?.message)
                } finally { equalMetadata.retire() }
                assertEquals("Authenticated upload bytes changed", runCatching { fixture.runtime.withUploadExport(fixture.principal, next, fixture.originalRaw + byteArrayOf(32), nextOrigin, { true }) { _, _, _, _, _ -> fail("Wrong exact source admitted") } }.exceptionOrNull()?.message)
                var current = true
                assertTrue(runCatching { fixture.runtime.withUploadExport(fixture.principal, next, fixture.originalRaw, nextOrigin, { current }) { _, _, compose, ack, _ ->
                    try { current = false; requireNotNull(compose)(JSONObject()) } finally { ack?.close() }
                } }.isFailure)
                assertTrue(runCatching { fixture.runtime.withUploadExport(fixture.principal, next, fixture.originalRaw, nextOrigin, { true }) { _, _, compose, ack, _ ->
                    try {
                        fixture.runtime.session().dispatch(emptyList(), fixture.runtime.session().read().owner, progressOnly = true)
                        requireNotNull(compose)(JSONObject()) // Original checkpoint cannot rebase.
                    } finally { ack?.close() }
                } }.isFailure)
                copiedRaw.fill(0); assertEquals(0, fixture.putCount)
                return
            }

            var remoteWinner: ByteArray? = null
            if (mode == "retry" || mode == "equalConflict") {
                fixture.rejectNextPut = true
                fixture.beforePut = {
                    val local = com.vortx.android.engine.OHJson.Obj(pendingA)
                    val updated = if (mode == "retry") {
                        val saved = com.vortx.android.xperience.XperienceImportNamespace.read(append.field, pendingA)
                        val newValue = saved.replacement(document("Remote winner", "4.0"), saved.label, saved.bindings).value()
                        local.set("clock", (com.vortx.android.engine.NativeRawHostPreferences.exactClock(local.raw("clock")) + 10).toString().toByteArray())
                            .set("value", newValue).encoded()
                    } else local.set("value", local.obj("value").set("label", com.vortx.android.engine.OHJson.quote("Contradictory same event")).encoded()).encoded()
                    remoteWinner = updated
                    val previous = fixture.originalRaw
                    fixture.originalRaw = replacingServer(updated); previous.fill(0); fixture.serverVersion = 101
                }
            }
            if (mode == "lateEdit") fixture.beforePut = {
                val profiles = NativeProfileAccess { fixture.runtime.session() }
                profiles.save(profiles.read().profiles.single().copy(name = "Newer local profile"), false)
                // A separate explicit local gesture during PUT captures its own current target.
                runBlocking {
                    val now = fixture.runtime.captureXperienceProfile().getOrThrow()
                    val saved = com.vortx.android.xperience.XperienceImportNamespace.read(append.field, now.registers().getValue(append.field))
                    fixture.runtime.writeXperience(now.target, saved.replacement(document("Later A", "5.0"), saved.label, saved.bindings)).getOrThrow()
                }
            }
            if (mode == "lateSettings") fixture.beforePut = {
                fixture.context.getSharedPreferences("vortx_settings", 0).edit()
                    .putString("stremiox.languageOverride", "later-queued-value").apply()
            }
            if (mode == "retire") fixture.beforePut = { fixture.runtime.retire() }
            if (mode == "auth") fixture.beforePut = { fixture.manager.expireSyncOperationTestSeam() }
            if (mode == "ackFileDrift") fixture.beforePut = {
                // Same plaintext, new authenticated encrypted-file capability outside Session.
                fixture.disk.commit(savedScope, checkNotNull(fixture.disk.captureCheckpoint(savedScope).plaintext))
            }
            val cancellation = kotlinx.coroutines.SupervisorJob()
            if (mode == "cancel") fixture.beforePut = { cancellation.cancel() }
            assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "fixture-raw-upload")))
            if (mode == "providerBudget") assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "p".repeat(1_200_000))))
            if (mode == "settingBudget") {
                fixture.context.getSharedPreferences("vortx_settings", 0).edit().putString("stremiox.languageOverride", "x".repeat(3_700_000)).apply()
                assertTrue(notifications.isNotEmpty())
            }
            if (mode == "warm" || mode == "cold") {
                assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "fixture-upload-pending")))
                fixture.context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", true).apply()
            }
            val dirtyBytes = when (mode) { "malformedDirty" -> "{broken"; "negativeStamp" -> "{\"stremiox.autoSkip\":-1}"; else -> null }
            if (dirtyBytes != null) fixture.context.getSharedPreferences("vortx_sync_dirty", 0).edit()
                .putString("vortx.sync.dirtySettings.${fixture.principal.id}", dirtyBytes).commit()
            if (mode == "remoteWindow") {
                // Controlled remote/suppression frame, not a natural scheduler/device repro.
                remoteFlag = VortXSyncManager::class.java.getDeclaredField("applyingRemote").apply { isAccessible = true }
                NativeSettingsFence.mutateBookkeeping { remoteFlag!!.setBoolean(fixture.manager, true) }
                fixture.context.getSharedPreferences("vortx_settings", 0).edit().putBoolean("stremiox.autoSkip", true).apply()
            }
            if (mode == "clearGuard") {
                // Controlled post-own-apply domain witness exercises the REAL private clear
                // body. It is not a natural scheduler reproduction or authored server receipt.
                val dirty = fixture.context.getSharedPreferences("vortx_sync_dirty", 0)
                val key = "vortx.sync.dirtySettings.${fixture.principal.id}"
                val raw = "{\"stremiox.languageOverride\":1.0}"
                dirty.edit().putString(key, raw).commit()
                fixture.context.getSharedPreferences("vortx_settings", 0).edit().putString("stremiox.languageOverride", "later-queued-value").apply()
                val clear = VortXSyncManager::class.java.getDeclaredMethod("clearNativePushedDirtySettings", Map::class.java, Map::class.java)
                    .apply { isAccessible = true }
                assertEquals(false, clear.invoke(fixture.manager, mapOf("stremiox.languageOverride" to 1.0), mapOf("stremiox.languageOverride" to "accepted-old-value")))
                assertEquals(raw, dirty.getString(key, null))
            }
            val success = try {
                if (mode == "cancel") runCatching { kotlinx.coroutines.withContext(cancellation) { fixture.manager.syncUp() } }.getOrDefault(false)
                else fixture.manager.syncUp()
            } finally { cancellation.cancel() }
            if (mode == "lateSettings") {
                assertFalse(success); assertEquals(1, fixture.putCount) // Older immutable wire PUT was accepted.
                assertEquals("later-queued-value", fixture.context.getSharedPreferences("vortx_settings", 0).getString("stremiox.languageOverride", null))
                assertTrue(fixture.runtime.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
                val dirty = fixture.context.getSharedPreferences("vortx_sync_dirty", 0)
                    .getString("vortx.sync.dirtySettings.${fixture.principal.id}", null)?.let(::JSONObject)
                assertFalse(dirty?.has("stremiox.languageOverride") == true) // No fabricated stamp.
                assertTrue(fixture.manager.syncUp())
                val latest = com.vortx.android.engine.OHJson.Obj(requireNotNull(fixture.uploaded)).obj("nativeHostPreferences")
                    .obj("globals").obj("fields").obj("stremiox.languageOverride")
                assertEquals("later-queued-value", com.vortx.android.engine.OHJson.text(latest.raw("value")))
                assertFalse(fixture.runtime.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
                return
            }
            if (mode in setOf("retire", "auth", "cancel", "ackFileDrift", "equalConflict", "providerBudget", "settingBudget", "malformedDirty", "negativeStamp", "remoteWindow")) {
                assertFalse(success)
                val durable = com.vortx.android.engine.OHJson.Obj(checkNotNull(fixture.disk.captureCheckpoint(savedScope).plaintext).toByteArray())
                    .obj("nativeHostPreferenceState")
                assertEquals("true", com.vortx.android.engine.OHJson.utf8(durable.raw("pending")))
                if (mode.endsWith("Budget")) assertEquals(0, fixture.putCount)
                if (mode == "equalConflict") assertEquals(1, fixture.putCount) // First PUT rejected; contradictory GET is never rebuilt.
                if (mode == "ackFileDrift") {
                    assertTrue(fixture.runtime.session().requiresRecovery())
                    assertNull(fixture.runtime.currentMountToken(fixture.principal)) // Original health contract retained.
                }
                if (dirtyBytes != null || mode == "remoteWindow") {
                    assertEquals(gets, fixture.getCount); assertEquals(0, fixture.putCount)
                    if (dirtyBytes != null) assertEquals(dirtyBytes, fixture.context.getSharedPreferences("vortx_sync_dirty", 0)
                        .getString("vortx.sync.dirtySettings.${fixture.principal.id}", null))
                }
                return
            }
            assertTrue(success)
            val uploaded = requireNotNull(fixture.uploaded)
            assertArrayEquals(rootUnknown, com.vortx.android.engine.OHJson.Obj(uploaded).raw("futureRoot"))
            assertArrayEquals(nativeUnknown, com.vortx.android.engine.OHJson.Obj(uploaded).obj("nativeSync").raw("futureNative"))
            assertArrayEquals(value.raw("futureValue"), com.vortx.android.engine.OHJson.Obj(fields(uploaded).raw(append.field)).obj("value").raw("futureValue"))
            assertArrayEquals(pendingB, fields(uploaded).raw(second.field))
            if (mode == "warm" || mode == "cold") assertArrayEquals("true".toByteArray(), com.vortx.android.engine.OHJson.Obj(uploaded)
                .obj("nativeHostPreferences").obj("globals").obj("fields").obj("stremiox.autoSkip").raw("value"))
            if (mode == "clearGuard") assertEquals("later-queued-value", com.vortx.android.engine.OHJson.text(com.vortx.android.engine.OHJson.Obj(uploaded)
                .obj("nativeHostPreferences").obj("globals").obj("fields").obj("stremiox.languageOverride").raw("value")))
            if (mode == "retry") {
                assertEquals(2, fixture.putCount); assertTrue(fixture.getCount >= gets + 2)
                assertEquals(102L, fixture.uploadedVersion)
                assertArrayEquals(requireNotNull(remoteWinner), fields(uploaded).raw(append.field))
                assertArrayEquals("""{"n":1.000e+3,"zero":-0}""".toByteArray(), com.vortx.android.engine.OHJson.Obj(uploaded).raw("futureRetry"))
            } else assertArrayEquals(pendingA, fields(uploaded).raw(append.field))
            if (mode == "lateEdit") {
                assertNotEquals("Newer local profile", JSONObject(com.vortx.android.engine.OHJson.utf8(uploaded))
                    .getJSONObject("nativeSync").getJSONObject("profiles").getJSONObject(UserProfile.OWNER_ID)
                    .getJSONObject("profile").getString("name"))
                assertTrue(fixture.runtime.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
                assertFalse(pendingA.contentEquals(localFields().raw(append.field)))
                assertEquals("Newer local profile", NativeProfileAccess { fixture.runtime.session() }.read().profiles.single().name)
                assertTrue(fixture.manager.syncUp())
                assertArrayEquals(localFields().raw(append.field), fields(requireNotNull(fixture.uploaded)).raw(append.field))
            }
            assertFalse(fixture.runtime.session().read().state.getJSONObject("nativeHostPreferenceState").getBoolean("pending"))
            if (mode == "warm" || mode == "cold") assertTrue(com.vortx.android.integrations.NativeProviderAccess.hasPending(fixture.principal) == false)
        } finally {
            remoteFlag?.let { flag -> NativeSettingsFence.mutateBookkeeping { flag.setBoolean(fixture.manager, false) } }
            fixture.finish()
            NativeSettingsFence.queuedNotificationsForTest = mutableListOf()
        }
    }

    @Test fun `generic saved edit retains real GET after sync lease expiry and uploads raw siblings`() = runBlocking {
        val fixture = GenericPlaylistFixture()
        try {
            fixture.start()
            val retained = requireNotNull(coordinatorRead(fixture.runtime))
            val staleTarget = fixture.runtime.capturePlaylistProfile().getOrThrow().target
            fixture.manager.expireSyncOperationTestSeam()
            assertTrue(fixture.edit(staleTarget).isFailure)
            // Fresh UI authority is legal; old GET generation remains provenance, not live authority.
            assertSame(retained, coordinatorRead(fixture.runtime))
            assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "fixture-pending")))
            val accepted = fixture.edit().getOrThrow()
            val ticket = requireNotNull(accepted.receipt)
            val receiptOwner = accepted.target.receiptOwner
            assertEquals(com.vortx.android.engine.NativePlaylistCloudReceiptLedger.State.Pending,
                fixture.runtime.playlistReceiptState(receiptOwner, ticket, ticket.fingerprint))
            assertTrue(accepted.registers.has(fixture.field))
            assertTrue(accepted.registers.has("playlist.v2.future"))
            assertTrue(com.vortx.android.integrations.NativeProviderAccess.hasPending(fixture.principal) == true)
            val local = fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext!!
            assertFalse(local.contains("fixture-pending"))
            assertTrue(fixture.manager.syncUp())
            // nativeSyncUp freezes this edit before its fresh GET replaces retained raw identity.
            // The original receipt survives that merge; the original mutation target does not.
            assertNotSame(retained, coordinatorRead(fixture.runtime))
            assertFalse(fixture.runtime.playlistTargetIsCurrent(accepted.target))
            assertEquals(com.vortx.android.engine.NativePlaylistCloudReceiptLedger.State.Saved(requireNotNull(fixture.uploadedVersion)),
                fixture.runtime.playlistReceiptState(receiptOwner, ticket, ticket.fingerprint))
            val sent = com.vortx.android.engine.OHJson.Obj(requireNotNull(fixture.uploaded))
            val original = com.vortx.android.engine.OHJson.Obj(fixture.originalRaw)
            assertArrayEquals(original.raw("futureRoot"), sent.raw("futureRoot"))
            assertArrayEquals(original.obj("nativeSync").raw("futureNative"), sent.obj("nativeSync").raw("futureNative"))
            val id = com.vortx.android.engine.NativeHostPreferences.canonicalProfileID(UserProfile.OWNER_ID)
            assertArrayEquals(original.obj("nativeHostPreferences").obj("profiles").obj(id).obj("fields").raw("playlist.v2.future"),
                sent.obj("nativeHostPreferences").obj("profiles").obj(id).obj("fields").raw("playlist.v2.future"))
            assertEquals("preserved", JSONObject(com.vortx.android.engine.OHJson.utf8(sent.raw("apiKeys"))).getString("futureKey"))
        } finally { fixture.finish() }
    }

    @Test fun `full pending provider family can reject playlist before any local checkpoint replacement`() = runBlocking {
        val fixture = GenericPlaylistFixture(2_000_000)
        try {
            fixture.start()
            assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "p".repeat(1_200_000))))
            val before = fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext
            val updates = fixture.runtime.session().playlistUpdates.value
            fixture.rejectAt("Complete account exceeds encrypted budget")
            assertEquals(before, fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext)
            assertEquals(updates, fixture.runtime.session().playlistUpdates.value)
            assertFalse(fixture.runtime.session().requiresRecovery())
            assertTrue(com.vortx.android.integrations.NativeProviderAccess.hasPending(fixture.principal) == true)
        } finally { fixture.finish() }
    }

    @Test fun `queued dirty callback cannot hide oversized current host setting from precommit budget`() = runBlocking {
        val fixture = GenericPlaylistFixture(2_000_000)
        val notifications = mutableListOf<() -> Unit>()
        NativeSettingsFence.queuedNotificationsForTest = notifications
        try {
            fixture.start()
            val prefs = fixture.context.getSharedPreferences("vortx_settings", 0)
            // 2 MB retained root + 3.7 MB prospective host is unambiguously above the encrypted
            // 7 MiB envelope bound, even before JSON/nonce/tag/prefix overhead.
            prefs.edit().putString("stremiox.languageOverride", "x".repeat(3_700_000)).apply()
            assertTrue(notifications.isNotEmpty()) // The real changed value exists while its dirty callback waits.
            val before = fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext
            fixture.rejectAt("Complete account exceeds encrypted budget")
            assertEquals(before, fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext)
            assertFalse(fixture.runtime.session().requiresRecovery())
        } finally { fixture.finish(); NativeSettingsFence.queuedNotificationsForTest = mutableListOf() }
    }

    @Test fun `host ABA after capture and before fork commit is rejected by writer revision`() = runBlocking {
        val fixture = GenericPlaylistFixture()
        try {
            fixture.start()
            val before = fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext
            fixture.onFork = {
                val prefs = fixture.context.getSharedPreferences("vortx_settings", 0)
                val old = prefs.getString("stremiox.languageOverride", null)
                prefs.edit().putString("stremiox.languageOverride", "fixture-intermediate").apply()
                prefs.edit().putString("stremiox.languageOverride", old).apply()
            }
            fixture.rejectAt("Pending settings changed")
            assertEquals(before, fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext)
            assertFalse(fixture.runtime.session().requiresRecovery())
        } finally { fixture.finish() }
    }

    @Test fun `provider pending acknowledgement invalidates full record even when selected credential event is unchanged`() = runBlocking {
        val fixture = GenericPlaylistFixture()
        try {
            fixture.start()
            assertTrue(com.vortx.android.integrations.NativeProviderAccess.edit(mapOf("tmdb" to "fixture-value")))
            val wire = com.vortx.android.integrations.NativeProviderVault(providerStore).load(fixture.principal).document()
            val before = fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext
            fixture.onFork = { assertTrue(com.vortx.android.integrations.NativeProviderAccess.acknowledge(fixture.principal, wire)) }
            fixture.rejectAt("Pending provider family changed")
            assertEquals(before, fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext)
            assertFalse(fixture.runtime.session().requiresRecovery())
        } finally { fixture.finish() }
    }

    @Test fun `original absent register observation cannot overwrite a first committed playlist edit`() = runBlocking {
        val fixture = GenericPlaylistFixture()
        try {
            fixture.start()
            val target = fixture.runtime.capturePlaylistProfile().getOrThrow().target
            fixture.edit(target).getOrThrow()
            val before = fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext
            assertEquals("Stale playlist register", fixture.edit(target).exceptionOrNull()?.message)
            assertEquals(before, fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext)
        } finally { fixture.finish() }
    }

    @Test fun `same plaintext checkpoint replacement cannot reuse original encrypted file capability`() = runBlocking {
        val fixture = GenericPlaylistFixture()
        try {
            fixture.start()
            val scope = fixture.runtime.session().scope
            val before = requireNotNull(fixture.disk.captureCheckpoint(scope).plaintext)
            fixture.onFork = { fixture.disk.commit(scope, before) }
            fixture.rejectAt("Native checkpoint changed", checkpointCalls = 1)
            assertEquals(before, fixture.disk.captureCheckpoint(scope).plaintext)
            assertTrue(fixture.runtime.session().requiresRecovery())
        } finally { fixture.finish() }
    }

    @Test fun `second authenticated raw read retires old playlist raw identity before a later edit`() = runBlocking {
        val fixture = GenericPlaylistFixture()
        try {
            fixture.start()
            val target = fixture.runtime.capturePlaylistProfile().getOrThrow().target
            val original = requireNotNull(coordinatorRead(fixture.runtime))
            assertTrue(fixture.manager.syncDown(true))
            assertNotSame(original, coordinatorRead(fixture.runtime))
            val before = fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext
            assertTrue(fixture.edit(target).isFailure)
            assertEquals(before, fixture.disk.captureCheckpoint(fixture.runtime.session().scope).plaintext)
        } finally { fixture.finish() }
    }

    @Test fun `generic frozen receipt survives fresh GET while rejected candidate and retired lifetime cannot ACK`() = runBlocking {
        val fixture = GenericPlaylistFixture()
        try {
            fixture.start()
            val accepted = fixture.edit().getOrThrow()
            val ticket = requireNotNull(accepted.receipt)
            val receiptOwner = accepted.target.receiptOwner
            val frozen = fixture.runtime.freezePlaylistReceipts(fixture.principal)
            val original = requireNotNull(coordinatorRead(fixture.runtime))
            assertTrue(fixture.manager.syncDown(true))
            assertNotSame(original, coordinatorRead(fixture.runtime))
            assertFalse(fixture.runtime.playlistTargetIsCurrent(accepted.target))
            assertEquals(com.vortx.android.engine.NativePlaylistCloudReceiptLedger.State.Pending,
                fixture.runtime.playlistReceiptState(receiptOwner, ticket, ticket.fingerprint))
            // Fresh GET has no saved field. It cannot acknowledge this exact frozen register.
            fixture.runtime.acceptPlaylistReceipts(fixture.principal, frozen, fixture.originalRaw.toString(Charsets.UTF_8), 101)
            assertEquals(com.vortx.android.engine.NativePlaylistCloudReceiptLedger.State.Pending,
                fixture.runtime.playlistReceiptState(receiptOwner, ticket, ticket.fingerprint))
            val host = requireNotNull(fixture.runtime.exportDocument(fixture.principal)?.hostPreferences)
            fixture.runtime.acceptPlaylistReceipts(fixture.principal, frozen,
                JSONObject().put("nativeHostPreferences", host).toString(), 102)
            assertEquals(com.vortx.android.engine.NativePlaylistCloudReceiptLedger.State.Saved(102),
                fixture.runtime.playlistReceiptState(receiptOwner, ticket, ticket.fingerprint))
            fixture.runtime.retirePlaylistReceiptOwner(receiptOwner)
            fixture.runtime.acceptPlaylistReceipts(fixture.principal, frozen,
                JSONObject().put("nativeHostPreferences", host).toString(), 103)
            assertEquals(com.vortx.android.engine.NativePlaylistCloudReceiptLedger.State.Unknown,
                fixture.runtime.playlistReceiptState(receiptOwner, ticket, ticket.fingerprint))
        } finally { fixture.finish() }
    }

    @Test fun `settings wrapper detaches sets and keeps clear multi key listener and unregister behavior`() {
        val prefs = TestContext().getSharedPreferences("vortx_settings", 0)
        val notifications = mutableListOf<() -> Unit>()
        NativeSettingsFence.queuedNotificationsForTest = notifications
        val events = mutableListOf<String?>()
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, name -> events += name }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        val input = mutableSetOf("one", "two")
        prefs.edit().putStringSet("set", input).putString("other", "value").commit()
        input.clear()
        prefs.getStringSet("set", null)!!.clear()
        (prefs.all.getValue("set") as MutableSet<*>).clear()
        assertEquals(setOf("one", "two"), prefs.getStringSet("set", null))
        assertTrue(events.isEmpty())
        notifications.toList().forEach { it() }; notifications.clear()
        assertEquals(setOf("set", "other"), events.toSet())
        events.clear()
        prefs.edit().clear().putString("afterClear", "kept").commit()
        notifications.toList().forEach { it() }; notifications.clear()
        assertTrue(events.contains(null)); assertTrue(events.contains("afterClear"))
        assertEquals(mapOf("afterClear" to "kept"), prefs.all)
        prefs.unregisterOnSharedPreferenceChangeListener(listener)
        events.clear(); prefs.edit().putString("later", "value").apply()
        notifications.toList().forEach { it() }
        assertTrue(events.isEmpty())
    }

    private fun coordinatorRead(coordinator: NativeAccountCoordinator): NativeAccountReadCapture? {
        val mountedField = NativeAccountCoordinator::class.java.getDeclaredField("mounted").also { it.isAccessible = true }
        val reference = mountedField.get(coordinator) as java.util.concurrent.atomic.AtomicReference<*>
        val mount = reference.get() ?: return null
        val readField = mount.javaClass.getDeclaredField("authenticatedRead").also { it.isAccessible = true }
        return readField.get(mount) as? NativeAccountReadCapture
    }

    private fun injectCoordinatorRead(coordinator: NativeAccountCoordinator, capture: NativeAccountReadCapture) {
        val mountedField = NativeAccountCoordinator::class.java.getDeclaredField("mounted").also { it.isAccessible = true }
        val reference = mountedField.get(coordinator) as java.util.concurrent.atomic.AtomicReference<*>
        val mount = requireNotNull(reference.get())
        val readField = mount.javaClass.getDeclaredField("authenticatedRead").also { it.isAccessible = true }
        readField.set(mount, capture)
    }

    @Test fun `real coordinator clears prior provenance before failed direct and typed applies and retirement`() = kotlinx.coroutines.test.runTest {
        org.junit.Assume.assumeTrue("Requires reviewed local JNI", System.getenv("VORTX_JNI_SYNC") == "1")
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-read-capture-").toFile()
        val checkpoints = VortxEncryptedCheckpointStore(directory) { javax.crypto.spec.SecretKeySpec(key, "AES") }
        val principal = SessionOwnerSnapshot.Account(account.id, 4)
        var current = principal
        var failProjection = false
        fun coordinator() = NativeAccountCoordinator(bindings(), checkpoints, { noNetwork() }, { it == current }, { it() },
            project = { if (failProjection) error("Fixture projection failure") })
        val runtime = coordinator()
        val owner = UserProfile(id = "00000000-0000-0000-0000-000000000111", name = "Historical owner", avatar = "star", isOwner = true)
        val doc = JSONObject().put("vortx", JSONObject().put("roster", org.json.JSONArray().put(owner.encode().put("auth", "fixture-only")))
            .put("rosterModified", 123.5).put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
        fun syntheticCapture(generation: Long, revision: Long = 100L): NativeAccountReadCapture {
            val bytes = doc.toString().toByteArray(Charsets.UTF_8)
            val capturedAccount = SessionOwnerSnapshot.Account(principal.id, generation)
            return try { NativeAccountReadCapture.fromAuthenticatedPull(capturedAccount, 17L, principal.id, generation, revision, bytes) }
                finally { bytes.fill(0) }
        }
        try {
            assertTrue(runtime.applyDocument(principal, doc) { current == principal })

            // This test-only injection exercises private real-mount lifecycle behavior; it does not
            // create a production sync/write authority or replace the authenticated manager test.
            val baseline = syntheticCapture(principal.generation)
            injectCoordinatorRead(runtime, baseline)
            val rejected = syntheticCapture(principal.generation + 1)
            var rejectedAsStale = false
            try { runtime.applyRawDocument(principal, rejected) { current == principal } }
            catch (_: IllegalStateException) { rejectedAsStale = true }
            assertTrue(rejectedAsStale)
            rejected.retire()
            assertSame(baseline, coordinatorRead(runtime))
            baseline.copyRawForApply(principal).fill(0)

            // The real generic apply dispatches before its projection callback; a later failure
            // must not leave the previous authenticated bytes on the still-mounted coordinator.
            failProjection = true
            var failedAfterApply = false
            try { runtime.applyDocument(principal, JSONObject(doc.toString()).put("fixtureEdit", true)) { current == principal } }
            catch (_: IllegalStateException) { failedAfterApply = true }
            assertTrue(failedAfterApply)
            assertNull(coordinatorRead(runtime))
            var retiredReadRejected = false
            try { baseline.copyRawForApply(principal) } catch (_: IllegalStateException) { retiredReadRejected = true }
            assertTrue(retiredReadRejected)
            failProjection = false

            // Even a malformed owner-history attempt enters the typed route only after the exact
            // generic baseline has been revoked. Successful typed checkpoint transfer remains a
            // separately gated fixture because it requires a genuine native history carrier.
            val beforeTyped = syntheticCapture(principal.generation, 101L)
            injectCoordinatorRead(runtime, beforeTyped)
            val invalidTyped = """{"nativeSync":{"schemaVersion":6,"scope":"account.${principal.id}","ownerProfileId":"${owner.id}"}}""".toByteArray()
            var typedRejected = false
            try { runtime.applyRawDocument(principal, invalidTyped) { current == principal } }
            catch (_: Exception) { typedRejected = true /* Expected: no genuine history carrier supplied. */ }
            finally { invalidTyped.fill(0) }
            assertTrue(typedRejected)
            assertNull(coordinatorRead(runtime))
            var typedAttemptRetiredRead = false
            try { beforeTyped.copyRawForApply(principal) } catch (_: IllegalStateException) { typedAttemptRetiredRead = true }
            assertTrue(typedAttemptRetiredRead)

            val onRetire = syntheticCapture(principal.generation, 102L)
            injectCoordinatorRead(runtime, onRetire)
            runtime.retire()
            assertNull(coordinatorRead(runtime))
            var mountRetiredReadRejected = false
            try { onRetire.copyRawForApply(principal) } catch (_: IllegalStateException) { mountRetiredReadRejected = true }
            assertTrue(mountRetiredReadRejected)

            // Replacing the mount with the same account id but a new owner generation cannot
            // resurrect any of the previous mount's raw read evidence.
            val capturedNewAccount = SessionOwnerSnapshot.Account(principal.id, principal.generation + 1L)
            current = capturedNewAccount
            assertTrue(runtime.applyDocument(capturedNewAccount, doc) { current == capturedNewAccount })
            assertNull(coordinatorRead(runtime))
        } finally { runtime.retire(); directory.listFiles()?.forEach { it.delete() }; directory.delete() }
    }

    @Test fun `real native library checkpoint retries past retained theme dirty stamp and receives peer after cold restart`() = kotlinx.coroutines.test.runTest {
        org.junit.Assume.assumeTrue("Requires reviewed local JNI", System.getenv("VORTX_JNI_SYNC") == "1")
        System.load(requireNotNull(System.getenv("VORTX_JNI_LIBRARY")))
        val directory = java.nio.file.Files.createTempDirectory(java.io.File("build").toPath(), "native-retained-setting-").toFile()
        val checkpoints = VortxEncryptedCheckpointStore(directory) { javax.crypto.spec.SecretKeySpec(key, "AES") }
        val context = TestContext()
        val principal = SessionOwnerSnapshot.Account(account.id, 1)
        val dirtyKey = "vortx.sync.dirtySettings.${account.id}"
        val retained = "{\"stremiox.theme.oled\":123.25}"
        val owner = UserProfile(id = UserProfile.OWNER_ID, name = "Owner", avatar = "star", isOwner = true)
        var cloud = JSONObject().put("vortx", JSONObject().put("roster", org.json.JSONArray().put(owner.encode()))
            .put("rosterModified", 123.5).put("library", org.json.JSONArray()).put("addons", org.json.JSONArray()))
        var version = 100L
        var puts = 0
        var failPut = true
        var manager = VortXSyncManager(context, kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() +
            kotlinx.coroutines.test.StandardTestDispatcher(testScheduler)))
        fun coordinator() = NativeAccountCoordinator(bindings(), checkpoints, { noNetwork() }, { it == principal }, { it() },
            project = {}, onMutation = { manager.onLocalNativeMutation(it) },
            captureOwnAccountAdmission = { originalTestAdmission(manager, it) })
        var runtime = coordinator()
        fun install() {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, _, body, _ ->
                if (method == "GET") 200 to JSONObject().put("version", version).put("document",
                    VortXCrypto.sealDocument(key, cloud.toString().toByteArray(), account.id, version, true))
                else {
                    puts++
                    if (failPut) 500 to null else {
                        val sent = requireNotNull(body); version = sent.getLong("version")
                        cloud = JSONObject(String(requireNotNull(VortXCrypto.openDocument(key, sent.getString("document"), account.id, version))))
                        200 to JSONObject().put("accepted", true)
                    }
                }
            })
            installNative(manager, runtime)
        }
        try {
            install(); assertTrue(manager.syncDown(true))
            context.getSharedPreferences("vortx_sync_dirty", 0).edit().putString(dirtyKey, retained).commit()
            val read = runtime.session().read()
            runtime.session().dispatch(listOf(JSONObject().put("type", "add_library_item").put("profileId", owner.id)
                .put("item", JSONObject().put("kind", "standard").put("id", "tt-dirty-stamp").put("type", "movie")
                    .put("name", "Synthetic library edit").put("poster", JSONObject.NULL))), read.owner)
            runCurrent()
            advanceTimeBy(2_501); runCurrent()
            assertEquals(1, puts)
            assertTrue(context.getSharedPreferences("vortx_sync_state", 0).getBoolean("pendingPush.${account.id}", false))
            runtime.retire(); manager.cancelSyncTestWork()
            manager = VortXSyncManager(context, kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() +
                kotlinx.coroutines.test.StandardTestDispatcher(testScheduler)))
            runtime = coordinator(); install(); failPut = false
            assertFalse(manager.syncDown()) // Reopen the real encrypted checkpoint, then retry its durable edit.
            runCurrent()
            advanceTimeBy(2_501); runCurrent()
            assertEquals(2, puts)
            assertTrue(cloud.getJSONObject("nativeSync").toString().contains("tt-dirty-stamp"))
            assertFalse(context.getSharedPreferences("vortx_sync_state", 0).getBoolean("pendingPush.${account.id}", false))
            assertEquals(retained, context.getSharedPreferences("vortx_sync_dirty", 0).getString(dirtyKey, null))
            val peerDirectory = directory.resolve("peer")
            // An independent checkpoint receives the real encrypted cloud carrier.
            val receiving = NativeAccountCoordinator(bindings(), VortxEncryptedCheckpointStore(peerDirectory) {
                javax.crypto.spec.SecretKeySpec(key, "AES") }, { noNetwork() }, { it == principal }, { it() }, {})
            try {
                assertTrue(receiving.applyDocument(principal, cloud) { true })
                NativeProfileAccess { receiving.session() }.let { profiles ->
                    profiles.save(profiles.read().profiles.single().copy(name = "Peer received and edited"), false)
                }
                val exported = requireNotNull(receiving.exportDocument(principal))
                cloud.put("nativeSync", exported.nativeSync).put("nativeHostPreferences", exported.hostPreferences); version++
            } finally { receiving.retire() }
            assertTrue(manager.syncDown())
            assertEquals("Peer received and edited", NativeProfileAccess { runtime.session() }.read().profiles.single().name)
            assertTrue(runtime.session().read().state.getJSONObject("nativeSync").toString().contains("tt-dirty-stamp"))
            assertEquals(retained, context.getSharedPreferences("vortx_sync_dirty", 0).getString(dirtyKey, null))
        } finally { runtime.retire(); manager.cancelSyncTestWork(); directory.deleteRecursively() }
    }

    @Test fun `real JNI native and host fields sync separately with failed push cold persistence and exact event acknowledgement`() = kotlinx.coroutines.test.runTest {
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
        val manager = VortXSyncManager(context, kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() +
            kotlinx.coroutines.test.StandardTestDispatcher(testScheduler)))
        fun coordinator() = NativeAccountCoordinator(bindings, checkpoints, { noNetwork }, { true }, { it() }, {},
            captureOwnAccountAdmission = { originalTestAdmission(manager, it) })
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
            // Initial native import already armed the production causal-republish worker.
            assertFalse(manager.syncUp()); runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(1, uploads)
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
            // Cold recovery likewise owns a pending repair; let that exact worker upload it.
            assertFalse(manager.syncUp()); runCurrent(); advanceTimeBy(2_501); runCurrent()
            assertEquals(2, uploads)
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
            val runtime = NativeAccountCoordinator(bindings(), checkpoints, { noNetwork() }, { true }, { it() }, {},
                captureOwnAccountAdmission = { originalTestAdmission(manager, it) })
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
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            NativeSettingsFence.wrap(name, stores.getOrPut(name) { memoryPreferences() })
        override fun deleteSharedPreferences(name: String) = stores.remove(name) != null
    }
    companion object {
        private fun memoryPreferences(): SharedPreferences {
            val values = linkedMapOf<String, Any?>()
            val listeners = java.util.WeakHashMap<SharedPreferences.OnSharedPreferenceChangeListener, Unit>()
            lateinit var preference: SharedPreferences
            fun editor(): SharedPreferences.Editor {
                val edits = linkedMapOf<String, Any?>(); var clear = false
                return Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
                    when (method.name) {
                        "clear" -> { clear = true; proxy }
                        "remove" -> { edits[args!![0] as String] = null; proxy }
                        "commit", "apply" -> {
                            if (clear) values.clear()
                            edits.forEach { (k, v) -> if (v == null) values.remove(k) else values[k] = v }
                            val keys = edits.keys.map { it as String? } + if (clear) listOf(null) else emptyList()
                            listeners.keys.toList().forEach { listener -> keys.forEach { listener.onSharedPreferenceChanged(preference, it) } }
                            if (method.name == "commit") true else null
                        }
                        else -> if (method.name.startsWith("put")) { edits[args!![0] as String] = args[1]; proxy } else null
                    }
                } as SharedPreferences.Editor
            }
            preference = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
                when (method.name) {
                    "getAll" -> values.toMap()
                    "contains" -> values.containsKey(args!![0])
                    "edit" -> editor()
                    "registerOnSharedPreferenceChangeListener" -> { listeners[args!![0] as SharedPreferences.OnSharedPreferenceChangeListener] = Unit; null }
                    "unregisterOnSharedPreferenceChangeListener" -> { listeners.remove(args!![0] as SharedPreferences.OnSharedPreferenceChangeListener); null }
                    else -> if (method.name.startsWith("get")) values[args!![0]] ?: args[1] else null
                }
            } as SharedPreferences
            return preference
        }
    }
}
