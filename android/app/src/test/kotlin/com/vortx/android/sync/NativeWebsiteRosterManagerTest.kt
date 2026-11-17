package com.vortx.android.sync

import android.content.Context
import com.vortx.android.engine.NativeWebsiteRosterProjection
import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.integrations.NativeProviderAccess
import com.vortx.android.integrations.NativeProviderTestStore
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Actual manager and encrypted CAS envelope with a synthetic detached reservation and server. */
@OptIn(ExperimentalCoroutinesApi::class)
class NativeWebsiteRosterManagerTest {
    @Test fun coldReceiveSendsOriginalCasAndMountsOnlyASeparateExactReadback() = withFixture { f ->
        assertTrue(f.manager.syncDown(force = true))
        assertEquals(listOf("GET", "PUT", "GET"), f.requests)
        assertEquals(listOf(40L to 41L), f.attempts)
        assertEquals(listOf(true), f.sentV2)
        assertEquals(listOf(41L), f.gateway.applied)
        assertEquals(41L, f.appliedVersion())
        assertArrayEquals(f.cloud, f.gateway.received)
        assertArrayEquals(OHJson.Obj(f.original).raw("future"), OHJson.Obj(f.cloud).raw("future"))
    }

    @Test fun sameTargetDifferentReadbackDoesNotMountOrAdvance() = withFixture { f ->
        f.replaceAcceptedWith = f.fullRoster("Other")
        assertFalse(f.manager.syncDown(force = true))
        assertEquals(listOf("GET", "PUT", "GET"), f.requests)
        assertTrue(f.gateway.applied.isEmpty())
        assertEquals(0L, f.appliedVersion())
    }

    @Test fun rejectedWriteUsesActualFullRosterWinnerAtTargetWithoutSecondPromotion() = withFixture { f ->
        val winner = f.fullRoster("Winner")
        f.conflictingWinner = winner
        assertTrue(f.manager.syncDown(force = true))
        assertEquals(listOf("GET", "PUT", "GET"), f.requests)
        assertEquals(listOf(41L), f.gateway.applied)
        assertArrayEquals(winner, f.gateway.received)
        assertEquals(41L, f.appliedVersion())
    }

    @Test fun authenticatedFullRosterBelowReportedConflictHeadDoesNotMount() = withFixture { f ->
        f.conflictingWinner = f.fullRoster("Stale")
        f.conflictVersionEcho = 50
        assertFalse(f.manager.syncDown(force = true))
        assertEquals(listOf("GET", "PUT", "GET"), f.requests)
        assertEquals(41L, f.revision)
        assertTrue(f.gateway.applied.isEmpty())
        assertEquals(0L, f.appliedVersion())
    }

    @Test fun explicitAcceptedVersionMustMatchTheSubmittedTarget() = withFixture { f ->
        f.acceptedVersionEcho = 50L
        assertFalse(f.manager.syncDown(force = true))
        assertEquals(listOf("GET", "PUT"), f.requests)
        assertEquals(listOf(40L to 41L), f.attempts)
        assertTrue(f.gateway.applied.isEmpty())
        assertEquals(0L, f.appliedVersion())
    }

    @Test fun lostAcceptanceDoesNotMountAndLaterAuthenticatedReadCanAdmitServerResult() = withFixture { f ->
        f.loseAcceptance = true
        assertFalse(f.manager.syncDown(force = true))
        assertEquals(listOf("GET", "PUT"), f.requests)
        assertTrue(f.gateway.applied.isEmpty())
        assertEquals(0L, f.appliedVersion())
        assertTrue(f.manager.syncDown(force = true))
        assertEquals(listOf("GET", "PUT", "GET"), f.requests)
        assertEquals(listOf(41L), f.gateway.applied)
    }

    @Test fun finalAbsenceRefusalPersistsFirstEvidenceAndBlocksNewerSameBytes() = withFixture { f ->
        f.gateway.blockFinalAbsence = true
        assertFalse(f.manager.syncDown(force = true))
        val first = f.firstReceipt()
        assertNotNull(first)
        assertEquals(listOf("GET"), f.requests)
        f.revision = 41
        f.gateway.blockFinalAbsence = false
        assertFalse(f.manager.syncDown(force = true))
        assertEquals(listOf("GET", "GET"), f.requests)
        assertEquals(first, f.firstReceipt())
        assertTrue(f.gateway.applied.isEmpty())
        assertEquals(0L, f.appliedVersion())
    }

    @Test fun existingPendingWebsiteReceiptMakesMissingBackupUnavailable() = withFixture { f ->
        val pending = f.seedPendingReceipt()
        f.backupMissing = true
        assertFalse(f.manager.syncDown(force = true))
        assertEquals(listOf("GET"), f.requests)
        assertTrue(f.attempts.isEmpty())
        assertTrue(f.gateway.applied.isEmpty())
        assertEquals(0L, f.appliedVersion())
        assertEquals(pending, f.firstReceipt())
    }

    @Test fun uploadPathUsesOrdinaryAckOnlyAfterSeparateOrdinaryPut() = withFixture { f ->
        f.ordinaryPutFails = true
        assertFalse(f.manager.syncUp())
        assertEquals(listOf("GET", "PUT", "GET", "PUT"), f.requests)
        assertEquals(listOf(40L to 41L, 41L to 42L), f.attempts)
        assertEquals(listOf(41L), f.gateway.applied)
        assertEquals(0, f.gateway.acknowledgments)
        assertEquals(0L, f.appliedVersion())
    }

    @Test fun aRetiredAccountCannotReadBackOrMountAfterPut() = withFixture { f ->
        f.switchAccountDuringFirstPut = true
        assertFalse(f.manager.syncDown(force = true))
        assertEquals(listOf("GET", "PUT"), f.requests)
        assertTrue(f.gateway.applied.isEmpty())
        assertEquals(0L, f.appliedVersion())
        assertFalse(f.gateway.held)
    }

    private fun withFixture(block: suspend (Fixture) -> Unit) = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val fixture = Fixture()
        try { block(fixture) } finally { fixture.close(); Dispatchers.resetMain() }
    }

    private class Fixture {
        val context = RevisionContext()
        private val key = ByteArray(32) { 37 }
        private val account = VortXSyncManager.Account(UUID.randomUUID().toString(), "fixture@example.invalid", "Fixture", false)
        val manager = VortXSyncManager(context, CoroutineScope(SupervisorJob() + UnconfinedTestDispatcher()))
        val gateway = Gateway()
        val requests = mutableListOf<String>()
        val attempts = mutableListOf<Pair<Long, Long>>()
        val sentV2 = mutableListOf<Boolean>()
        val original = OHJson.literal("""{"addons":[],"future":{"exact":9007199254740993}}""")
        var cloud = original.copyOf()
        var revision = 40L
        var replaceAcceptedWith: ByteArray? = null
        var conflictingWinner: ByteArray? = null
        var conflictVersionEcho: Long? = null
        var acceptedVersionEcho: Any? = null
        var loseAcceptance = false
        var ordinaryPutFails = false
        var switchAccountDuringFirstPut = false
        var backupMissing = false
        private fun state() = context.getSharedPreferences("vortx_sync_state", Context.MODE_PRIVATE)
        private val receiptKey = NativeWebsiteRosterReceiptStore.storageKey(account.id, key)
        fun firstReceipt() = state().getString(receiptKey, null)
        fun seedPendingReceipt(): String {
            assertEquals(0L, appliedVersion())
            assertFalse(state().getBoolean("nativeBackupSeen.${account.id}", false))
            assertNull(firstReceipt())
            val projected = requireNotNull(NativeWebsiteRosterProjection.project(original))
            val encoded = NativeWebsiteRosterDenialReceipt.create(account.id, key, revision, original, revision + 1, projected).encode()
            assertTrue(encoded.startsWith("v1:"))
            assertTrue(state().edit().putString(receiptKey, encoded).commit())
            return encoded
        }
        fun appliedVersion() = state().getLong("lastSyncedVersion.${account.id}", 0)
        fun fullRoster(name: String): ByteArray {
            val row = UserProfile(id = UserProfile.OWNER_ID, name = name, avatar = "star", isOwner = true)
                .encode().put("addonPreferences", JSONObject())
            val vortx = OHJson.Obj().set("roster", OHJson.array(listOf(OHJson.literal(row.toString()))))
                .set("rosterModified", OHJson.literal("0"))
            return OHJson.Obj().set("vortx", vortx.encoded()).encoded()
        }

        init {
            manager.installSyncTestSeam(VortXSyncManager.Session("fixture-only", account, key), 0, transport = { method, path, body, _ ->
                assertEquals("/v1/backup", path)
                requests += method
                if (method == "GET" && backupMissing) {
                    assertNull(body)
                    404 to null
                } else if (method == "GET") {
                    200 to JSONObject().put("version", revision).put("document",
                        VortXCrypto.sealDocument(key, cloud, account.id, revision, writeV2 = true))
                } else {
                    assertEquals("PUT", method)
                    val request = requireNotNull(body)
                    val base = request.getLong("baseRevision")
                    val next = request.getLong("version")
                    attempts += base to next
                    val encrypted = request.getString("document")
                    sentV2 += encrypted.startsWith(VortXCrypto.DOC_V2_PREFIX)
                    val candidate = requireNotNull(VortXCrypto.openDocument(key, encrypted, account.id, next))
                    if (attempts.size == 1) {
                        assertTrue(gateway.held)
                        assertTrue(gateway.finalAbsenceChecked)
                        assertTrue(gateway.applied.isEmpty())
                        val stored = NativeWebsiteRosterDenialReceipt.decode(requireNotNull(firstReceipt()), account.id, key)
                        assertTrue(stored.matchesAttempt(account.id, key, base, original, next, candidate))
                        if (switchAccountDuringFirstPut) manager.replaceSyncSessionTestSeam(VortXSyncManager.Session(
                            "replacement-fixture", account.copy(id = UUID.randomUUID().toString()), key,
                        ))
                    } else assertFalse(gateway.held)
                    if (ordinaryPutFails && attempts.size == 2) 500 to null
                    else if (conflictingWinner != null) {
                        cloud = requireNotNull(conflictingWinner); conflictingWinner = null; revision = next
                        200 to JSONObject().put("accepted", false).put("version", conflictVersionEcho ?: next)
                    } else {
                        assertEquals(revision, base)
                        assertEquals(BackupRevisionPolicy.next(base), next)
                        cloud = replaceAcceptedWith ?: candidate; revision = next
                        if (loseAcceptance) 0 to null else 200 to JSONObject().put("accepted", true).also { reply ->
                            acceptedVersionEcho?.let { reply.put("version", it) }
                        }
                    }
                }
            })
            manager.installSessionRestoreTestSeam(manager.currentSession())
            manager.installNativeGatewayTestSeam(gateway, NativeProviderTestStore())
        }

        suspend fun close() { manager.cancelSyncTestWork(); NativeProviderAccess.unbindForTest() }
    }

    private class Gateway : NativeAccountGateway {
        var held = false
        var finalAbsenceChecked = false
        var blockFinalAbsence = false
        val applied = mutableListOf<Long>()
        var received: ByteArray? = null
        var acknowledgments = 0
        private var installation: Any? = null
        private var first: NativeAccountReadCapture? = null
        override fun retire() { installation = null }
        override fun currentMountToken(account: SessionOwnerSnapshot.Account) = installation?.let { NativeAccountMountToken(it, 0) }
        override fun captureUploadOrigin(account: SessionOwnerSnapshot.Account, isCurrent: () -> Boolean) =
            object : NativeAccountUploadCurrency.Origin { override fun isCurrent() = isCurrent.invoke() }

        private fun currency(current: () -> Boolean) = object : NativeAccountUploadCurrency {
            override fun isCurrent() = current()
            override fun <T> withCurrentSession(action: () -> T): T? = if (isCurrent()) action() else null
        }

        override suspend fun <T : Any> withWebsiteRosterCandidate(account: SessionOwnerSnapshot.Account,
            source: NativeAccountReadCapture, original: NativeAccountUploadCurrency.Origin,
            operation: suspend (NativeWebsiteRosterCandidate) -> T): T? {
            val raw = source.copyRawForApply(account)
            val projected = (try { NativeWebsiteRosterProjection.project(raw) } finally { raw.fill(0) }) ?: return null
            assertFalse(held)
            assertNull(installation)
            first = source
            held = true
            try {
                return operation(object : NativeWebsiteRosterCandidate {
                    override val scope = VortxAccountScope("account.${account.id}", UserProfile.OWNER_ID)
                    override val sourceRevision = source.baseRevision
                    override val currency = currency { held && original.isCurrent() && installation == null }
                    override fun copyProjectedBytes() = projected.copyOf()
                    override suspend fun requireLocalAbsenceForSubmission() {
                        assertTrue(held)
                        check(!blockFinalAbsence)
                        finalAbsenceChecked = true
                    }
                })
            } finally { held = false; projected.fill(0) }
        }

        override suspend fun applyRawDocument(account: SessionOwnerSnapshot.Account, captured: NativeAccountReadCapture,
            isCurrent: () -> Boolean): Boolean {
            assertFalse(held)
            assertFalse(first?.sameObservation(captured) == true)
            if (!isCurrent()) return false
            val raw = captured.copyRawForApply(account)
            val document = com.vortx.android.engine.NativeProfileOverlayWitness.parseAccountDocument(raw)
            if (!VortXSyncDoc.parse(document).rosterIsLossless) return false
            applied += captured.baseRevision
            received = raw
            installation = Any()
            return true
        }

        override suspend fun applyDocument(account: SessionOwnerSnapshot.Account, document: JSONObject, isCurrent: () -> Boolean): Boolean =
            error("A detached candidate cannot be applied directly")

        override fun exportDocument(account: SessionOwnerSnapshot.Account) = NativeAccountExport(
            JSONObject().put("scope", "account.${account.id}").put("fixture", true),
            listOf(UserProfile(id = UserProfile.OWNER_ID, name = "Fixture", avatar = "star", isOwner = true)), 0.0,
            hostPreferences = JSONObject().put("globals", JSONObject().put("fields", JSONObject())))

        override fun <T> withUploadExport(account: SessionOwnerSnapshot.Account, source: NativeAccountReadCapture,
            originalRaw: ByteArray, original: NativeAccountUploadCurrency.Origin, isCurrent: () -> Boolean,
            action: (NativeAccountExport, NativeAccountMountToken?, ((JSONObject) -> ByteArray)?, NativeHostUploadAcknowledgment?, NativeAccountUploadCurrency) -> T): T? {
            val expected = installation ?: return null
            val currency = currency { original.isCurrent() && installation === expected }
            return currency.withCurrentSession { action(exportDocument(account), currentMountToken(account), null, null, currency) }
        }

        override fun acknowledgeHostPreferences(account: SessionOwnerSnapshot.Account, document: JSONObject): Boolean {
            acknowledgments++
            return true
        }
    }
}
