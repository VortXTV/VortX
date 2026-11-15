package com.vortx.android.engine

import com.vortx.android.backup.SettingsBackup
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.NativeAccountSyncTest
import com.vortx.android.sync.SessionOwnerSnapshot
import com.vortx.android.sync.VortXCrypto
import com.vortx.android.sync.VortXSyncManager
import java.io.File
import java.nio.file.Files
import java.util.Date
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

/** Both account formats use the real encrypted backup path, JNI and a new sealed checkpoint. */
internal suspend fun verifyNativeLegacyPreferenceRestore(
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
    val manager = VortXSyncManager(context)
    val directory = Files.createTempDirectory(File("build").toPath(), "legacy-preference-restore-").toFile()
    val scope = VortxAccountScope("account.${account.id}", owner.id)
    val checkpoints = VortxEncryptedCheckpointStore(directory) { SecretKeySpec(key, "AES") }
    val runtime = NativeAccountCoordinator(VortxJniBindings, checkpoints, {
        object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("Unexpected provider request")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String =
                error("Unexpected provider request")
        }
    }, { manager.sessionOwnerSnapshot() == it }, { it() }, project = {},
        captureOwnAccountAdmission = { captured ->
            manager.captureLocalLibraryMutationAdmission()?.let { original -> { action ->
                original { manager.sessionOwnerSnapshot() == captured && action() }
            } }
        })
    val item = "tt0000902"
    try {
        manager.installSyncTestSeam(VortXSyncManager.Session("legacy-restore-fixture", account, key), 0,
            transport = { method, path, body, bearer ->
                assertEquals("/v1/backup", path)
                assertEquals("legacy-restore-fixture", bearer)
                requests += method
                when (method) {
                    "GET" -> {
                        assertNull(body)
                        200 to JSONObject().put("version", revision).put("document", cloud)
                    }
                    "PUT" -> {
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
        manager.installNativeGatewayTestSeam(runtime, NativeProviderTestStore())
        val principal = manager.sessionOwnerSnapshot() as SessionOwnerSnapshot.Account
        assertNull(checkpoints.captureCheckpoint(scope).plaintext)
        assertTrue("Cold authenticated backup restore must mount", manager.syncDown(force = true))
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
        assertTrue("A mounted account must be able to sync a subsequent edit", manager.syncUp())
        assertEquals(listOf("GET", "GET", "PUT"), requests)
        assertEquals(101L, revision)
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
