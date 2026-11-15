package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.NativeAccountExport
import com.vortx.android.sync.NativeAccountGateway
import com.vortx.android.sync.NativeAccountMountToken
import com.vortx.android.sync.NativeAccountReadCapture
import com.vortx.android.sync.NativeAccountSyncTest
import com.vortx.android.sync.NativeAccountUploadCurrency
import com.vortx.android.sync.NativeHostUploadAcknowledgment
import com.vortx.android.sync.NativeWebsiteRosterCandidate
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.sync.VortXCrypto
import com.vortx.android.sync.VortXSyncManager
import java.io.File
import java.nio.file.Files
import java.util.Date
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

/** Both account formats use the real encrypted backup path, JNI and a new sealed checkpoint. */
@OptIn(ExperimentalCoroutinesApi::class)
internal suspend fun TestScope.verifyNativeLegacyPreferenceRestore(
    accountId: String,
    owner: UserProfile,
    typedSource: NativeOwnerHistoryAccount? = null,
) {
    val brokenKey = "stremiox.seriesSourceSticky.${owner.id}"
    val retainedKey = "stremiox.autoSkip"
    val roster = JSONArray().put(owner.encode())
    val settingsBytes = requireNotNull(SettingsBackup.encode(
        linkedMapOf(SettingsBackup.ROSTER_KEY to roster.toString().toByteArray(Charsets.UTF_8),
            retainedKey to true, brokenKey to mapOf("tt0000101" to mapOf("bingeGroup" to "["))),
        "tv.vortx", "VortX", Date(0),
    ))
    val blob = OHJson.b64(settingsBytes)
    // Use a noncanonical string spelling to prove preservation beyond decoded string equality.
    val token = OHJson.literal("\"\\u0065${blob.drop(1)}\"")
    assertEquals(blob, OHJson.text(token))
    val source = OHJson.Obj(typedSource?.encoded() ?: OHJson.literal("{}"))
        .set("settings", token)
        .set("vortx", JSONObject().put("roster", roster).put("rosterModified", 1).toString().toByteArray(Charsets.UTF_8))
        .encoded()
    val key = ByteArray(32) { 71 }
    val account = VortXSyncManager.Account(accountId, "legacy-restore@example.invalid", "Fixture", false)
    var revision = 100L
    var cloud = requireNotNull(VortXCrypto.sealDocument(key, source, account.id, revision, writeV2 = true))
    val requests = mutableListOf<String>()
    val context = NativeAccountSyncTest.TestContext()
    val manager = VortXSyncManager(context, CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)))
    manager.uploadClockMs = { testScheduler.currentTime }
    val directory = Files.createTempDirectory(File("build").toPath(), "legacy-preference-restore-").toFile()
    val scope = VortxAccountScope("account.${account.id}", owner.id)
    val checkpoints = VortxEncryptedCheckpointStore(directory) { SecretKeySpec(key, "AES") }
    val runtime = NativeAccountCoordinator(VortxJniBindings, checkpoints, {
        object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("Unexpected provider request")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String =
                error("Unexpected provider request")
        }
    }, { manager.sessionOwnerSnapshot() == it }, { it() }, project = {}, onMutation = { manager.onLocalNativeMutation(it) },
        captureOwnAccountAdmission = { captured ->
            manager.captureLocalLibraryMutationAdmission()?.let { original -> { action ->
                original { manager.sessionOwnerSnapshot() == captured && action() }
            } }
        })
    val trace = RestoreTrace()
    // Observe exceptions the public sync calls convert to false, using only fixed phases and
    // public source coordinates. The original coordinator still owns every read and write.
    val gateway = object : NativeAccountGateway by runtime {
        override suspend fun reopenCheckpoint(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean): Boolean =
            trace.observe("reopen") { runtime.reopenCheckpoint(account, isCurrent) }

        override fun captureUploadOrigin(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean) =
            trace.observe("origin") { runtime.captureUploadOrigin(account, isCurrent) }

        override suspend fun <T : Any> withWebsiteRosterCandidate(account: SessionOwnerSnapshot.Account,
            source: NativeAccountReadCapture, original: NativeAccountUploadCurrency.Origin,
            operation: suspend (NativeWebsiteRosterCandidate) -> T): T? =
            trace.observe("website") { runtime.withWebsiteRosterCandidate(account, source, original, operation) }

        override suspend fun applyRawDocument(account: SessionOwnerSnapshot.Account, captured: NativeAccountReadCapture,
            isCurrent: () -> Boolean): Boolean = trace.observe("apply") { runtime.applyRawDocument(account, captured, isCurrent) }

        override fun exportDocument(account: SessionOwnerSnapshot.Account): NativeAccountExport? =
            trace.observe("export") { runtime.exportDocument(account) }

        override fun <T> withUploadExport(account: SessionOwnerSnapshot.Account, source: NativeAccountReadCapture,
            originalRaw: ByteArray, original: NativeAccountUploadCurrency.Origin, isCurrent: () -> Boolean,
            action: (NativeAccountExport, NativeAccountMountToken?, ((JSONObject) -> ByteArray)?,
                NativeHostUploadAcknowledgment?, NativeAccountUploadCurrency) -> T): T? = trace.observe("uploadExport") {
            runtime.withUploadExport(account, source, originalRaw, original, isCurrent, action)
        }

        override fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean =
            trace.observe("ackHost") { runtime.acknowledgeHostPreferences(account, document) }
    }
    val item = "tt0000902"
    try {
        manager.installSyncTestSeam(VortXSyncManager.Session("legacy-restore-fixture", account, key), 0,
            transport = { method, path, body, bearer ->
                assertEquals("/v1/backup", path)
                assertEquals("legacy-restore-fixture", bearer)
                requests += method
                when (method) {
                    "GET" -> {
                        trace.add("GET")
                        assertNull(body)
                        200 to JSONObject().put("version", revision).put("document", cloud)
                    }
                    "PUT" -> {
                        trace.add("PUT")
                        val request = requireNotNull(body)
                        assertEquals(revision, request.getLong("baseRevision"))
                        assertEquals(revision + 1, request.getLong("version"))
                        val ciphertext = request.getString("document")
                        assertTrue(ciphertext.startsWith(VortXCrypto.DOC_V2_PREFIX))
                        val opened = requireNotNull(VortXCrypto.openDocument(key, ciphertext, account.id, revision + 1))
                        try {
                            val uploaded = OHJson.Obj(opened)
                            assertArrayEquals(token, uploaded.raw("settings"))
                            assertTrue(OHJson.utf8(uploaded.raw("nativeSync")).contains(item))
                            assertFalse(uploaded.keys.contains("excludedCredentialPaths"))
                        } finally { opened.fill(0) }
                        cloud = ciphertext
                        revision++
                        200 to JSONObject().put("accepted", true)
                    }
                    else -> error("Unexpected backup request")
                }
            },
        )
        manager.installSessionRestoreTestSeam(manager.currentSession())
        manager.installNativeGatewayTestSeam(gateway, NativeProviderTestStore())
        val principal = manager.sessionOwnerSnapshot() as SessionOwnerSnapshot.Account
        assertNull(checkpoints.captureCheckpoint(scope).plaintext)
        if (!manager.syncDown(force = true)) trace.fail("DOWN")
        assertEquals(listOf("GET"), requests)
        assertNotNull(runtime.currentMountToken(principal))
        assertNotNull(checkpoints.captureCheckpoint(scope).plaintext)
        val session = runtime.session()
        assertEquals(typedSource != null, session.hasOwnerHistory())
        val restored = session.read()
        assertEquals(owner.id, restored.owner.profileID)
        val localBlob = restored.state.getJSONObject("hostDocument").getString("settings")
        val localSettings = requireNotNull(SettingsBackup.decodeDomain(OHJson.un64(localBlob)))
        assertFalse(localSettings.containsKey(brokenKey))
        assertEquals(true, localSettings[retainedKey])
        assertArrayEquals(roster.toString().toByteArray(Charsets.UTF_8), localSettings[SettingsBackup.ROSTER_KEY] as ByteArray)
        val paths = restored.state.getJSONArray("excludedCredentialPaths")
        assertEquals(listOf("held:/settings/payloadBase64/$brokenKey"), (0 until paths.length()).map(paths::getString))
        NativeHostDocument.requireCredentialFree(restored.state.getJSONObject("hostDocument"))

        val edit = JSONObject().put("type", "mark_watched").put("metaId", item)
        assertTrue(JSONObject(session.dispatch(listOf(edit), restored.owner).single()).getBoolean("ok"))
        val statePrefs = context.getSharedPreferences("vortx_sync_state", 0)
        val dirtyKey = "pendingPush.${account.id}"
        trace.add("pending=${statePrefs.getBoolean(dirtyKey, false)}")
        runCurrent()
        advanceTimeBy(2_501)
        runCurrent()
        if (statePrefs.getBoolean(dirtyKey, false) || revision != 101L) trace.fail("PUSH")
        assertEquals(listOf("GET", "GET", "PUT"), requests)
    } finally {
        try { manager.cancelSyncTestWork() } finally {
            try { runtime.retire() } finally {
                NativeProviderAccess.unbindForTest()
                key.fill(0)
                assertTrue(directory.deleteRecursively())
            }
        }
    }
}

private class RestoreTrace {
    private val events = mutableListOf<String>()
    fun add(event: String) { if (events.size < 18) events.add(event) }

    inline fun <T> observe(stage: String, action: () -> T): T {
        return try {
            action().also { result ->
                val outcome = when (result) {
                    null -> "none"
                    is Boolean -> result.toString()
                    else -> "ready"
                }
                add("$stage=$outcome")
            }
        } catch (failure: Exception) {
            val kind = failure.javaClass.simpleName.takeIf { it.matches(Regex("[A-Za-z0-9]{1,40}")) } ?: "Exception"
            val frames = failure.stackTrace.filter {
                it.className.startsWith("com.vortx.android.") && it.lineNumber in 1..9999 &&
                    it.fileName?.matches(Regex("[A-Za-z0-9_]{1,32}\\.kt")) == true
            }.take(2)
            add("$stage=$kind" + (frames.firstOrNull()?.let { ":${it.fileName}:${it.lineNumber}" } ?: ""))
            frames.getOrNull(1)?.let { add("caller=${it.fileName}:${it.lineNumber}") }
            throw failure
        }
    }

    fun fail(stage: String): Nothing =
        throw AssertionError("LEGACY_RESTORE_TRACE: $stage,${events.joinToString(",").ifEmpty { "noEvents" }}")
}
