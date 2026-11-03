package com.vortx.android.ui.profilepicker

import com.vortx.android.security.FailClosedCredentialState
import com.vortx.android.sync.AccountBackupFile
import com.vortx.android.sync.AccountFileRepairFailure
import com.vortx.android.sync.AccountFileRepairExport
import com.vortx.android.sync.AccountFileRepairPrepared
import com.vortx.android.sync.AccountFileRepairReason
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.PickerSignOutResult
import com.vortx.android.sync.RenewalBackend
import com.vortx.android.sync.RenewalFixtures
import com.vortx.android.sync.RevisionContext
import com.vortx.android.sync.SessionRenewalPolicy
import com.vortx.android.sync.VortXCrypto
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.viewmodel.ManagerPickerToolsAccounts
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest

/** Actual controller + actual manager/snapshot/download/renewal APIs. HTTP and save are in-memory seams.
 * These authored tests are not a provider, packaged app, or JNI/device acceptance receipt. */
@OptIn(ExperimentalCoroutinesApi::class)
class ProfilePickerToolsManagerTest {
    private class Prepared(val encrypted: ByteArray) : PickerToolsPreparedBackup {
        override val byteCount = encrypted.size
        override val sha256 = MessageDigest.getInstance("SHA-256").digest(encrypted).joinToString("") { "%02x".format(it) }
        var cleared = false
        override fun close() { encrypted.fill(0); cleared = true }
    }
    private class Fixture(scope: CoroutineScope) : AutoCloseable {
        val original = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
        val manager = VortXSyncManager(RevisionContext(), scope)
        val document = requireNotNull(VortXCrypto.sealDocument(RenewalFixtures.key, "{}".toByteArray(), RenewalFixtures.accountID, 12, true))
        val raw = JSONObject().put("document", document).put("version", 12).toString().toByteArray()
        val prepared = mutableListOf<Prepared>()
        var gets = 0
        var captures = 0
        private val managerAccounts = ManagerPickerToolsAccounts(manager)
        val accounts = object : PickerToolsAccounts by managerAccounts {
            override fun capture(): PickerAccountSnapshot? { captures++; return managerAccounts.capture() }
        }
        val controller: ProfilePickerToolsController
        init {
            manager.installSyncTestSeam(original, 0, transport = { _, _, _, _ -> 500 to null })
            manager.installSessionRestoreTestSeam(original)
            manager.installAccountFileTransportTestSeam { method, path, _ ->
                assertEquals("GET", method); assertEquals("/v1/backup", path); gets++; 200 to raw
            }
            controller = ProfilePickerToolsController(accounts, PickerToolsBackupPreparer { bytes, current ->
                assertTrue(current()); AccountBackupFile.inspect(bytes)
                Prepared(bytes.copyOf()).also { prepared += it }
            }, scope)
        }
        override fun close() { controller.close(); manager.stopRealtime() }
    }
    @Test fun downloadUsesRealEncryptedFileAndOriginalSnapshotBeforeSyntheticSave() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val original = checkNotNull(f.manager.capturePickerAccountSnapshot())
            val route = f.controller.attachPicker(); f.controller.open(route); f.controller.download(checkNotNull(f.controller.renderedActions(route))); runCurrent()
            val ticket = checkNotNull(f.controller.state.value.destination)
            val file = f.prepared.single()
            assertEquals(f.document, JSONObject(String(file.encrypted)).getString("document"))
            assertEquals(12, JSONObject(String(file.encrypted)).getInt("version"))
            assertTrue(f.manager.isPickerAccountCurrent(original))
            f.controller.destinationReturned(ticket) { ready, current ->
                assertTrue(current()); assertTrue(f.manager.isPickerAccountCurrent(original))
                PickerToolsSaveReceipt(ready.byteCount, ready.sha256)
            }
            runCurrent(); assertTrue(file.cleared); assertTrue(f.controller.state.value.message!!.contains("read back"))
        } finally { f.close() }
    }
    @Test fun repairCannotUseTheSelectedFileAsOwnerWitnessAndRefusalReleasesTheRealManagerSlot() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val snapshot = checkNotNull(f.manager.capturePickerAccountSnapshot())
            val selected = AccountBackupFile.encodeServerResponse(f.raw, "Fixture", 0L)
            val original = selected.copyOf()
            repeat(2) {
                // The signed-in head authenticates but contains no full roster. A file or hint
                // cannot create an owner witness; the disposable native worker is not entered.
                val failure = runCatching { f.manager.prepareAccountBackupRepair(snapshot, selected) { true } }.exceptionOrNull()
                assertEquals(AccountFileRepairReason.OWNER_UNAVAILABLE, (failure as AccountFileRepairFailure).reason)
                assertArrayEquals(original, selected)
            }
            assertEquals(2, f.gets)
        } finally { f.close() }
    }

    @Test fun verifiedExportCanBeTakenOnceAndKeepsItsOriginalSaveFence() {
        val bytes = byteArrayOf(1, 2, 3)
        var current = true; var closes = 0
        val export = AccountFileRepairExport(AccountFileRepairPrepared(bytes, 2, 5, "fixture", true),
            deadline = { 10 }, checkCurrent = { check(current) }, saveCurrent = { current }, onClose = { closes++ })
        try {
            assertFalse(export.canSave())
            assertSame(bytes, export.take())
            assertTrue(export.canSave())
            assertTrue(runCatching { export.take() }.exceptionOrNull() is AccountFileRepairFailure)
            current = false
            assertFalse(export.canSave())
        } finally { export.close(); export.close() }
        assertEquals(1, closes)
        assertArrayEquals(byteArrayOf(1, 2, 3), bytes) // Taken bytes belong to the caller.
        bytes.fill(0)
    }

    @Test fun exportErasesBytesIfAuthorityRetiresDuringTheOneShotTransfer() {
        val bytes = byteArrayOf(1, 2, 3)
        var checks = 0; var closes = 0
        val export = AccountFileRepairExport(AccountFileRepairPrepared(bytes, 2, 5, "fixture", true),
            deadline = { 10 }, checkCurrent = { check(++checks < 2) }, saveCurrent = { checks < 2 }, onClose = { closes++ })
        export.use {
            assertTrue(runCatching { it.take() }.isFailure)
            assertArrayEquals(ByteArray(3), bytes)
            assertFalse(it.canSave())
        }
        assertEquals(1, closes)
    }

    @Test fun retiredRepairRouteCannotIssueAnAuthenticatedOwnerRead() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val snapshot = checkNotNull(f.manager.capturePickerAccountSnapshot())
            val selected = AccountBackupFile.encodeServerResponse(f.raw, "Fixture", 0L)
            val failure = runCatching { f.manager.prepareAccountBackupRepair(snapshot, selected) { false } }.exceptionOrNull()
            assertTrue(failure is java.util.concurrent.CancellationException)
            assertEquals(0, f.gets)
        } finally { f.close() }
    }

    @Test fun failedSecureClearKeepsActualSessionButRetiresOldFileAuthority() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val snapshot = checkNotNull(f.manager.capturePickerAccountSnapshot())
            val route = f.controller.attachPicker(); f.controller.open(route); f.controller.download(checkNotNull(f.controller.renderedActions(route))); runCurrent()
            val ticket = checkNotNull(f.controller.state.value.destination)
            f.manager.installSessionClearTestSeam { false }
            assertEquals(PickerSignOutResult.STORAGE_UNAVAILABLE, f.manager.signOut(snapshot))
            runCurrent()
            assertSame(f.original, f.manager.currentSession()); assertFalse(f.manager.isPickerAccountCurrent(snapshot))
            f.controller.destinationReturned(ticket) { _, _ -> error("old secure-clear authority must never save") }
            assertTrue(f.prepared.single().cleared); assertNull(f.controller.state.value.destination)
        } finally { f.close() }
    }
    @Test fun sameAccountReplacementSessionCannotSaveOriginalAwaitingCopy() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val snapshot = checkNotNull(f.manager.capturePickerAccountSnapshot())
            val route = f.controller.attachPicker(); f.controller.open(route); f.controller.download(checkNotNull(f.controller.renderedActions(route))); runCurrent()
            val ticket = checkNotNull(f.controller.state.value.destination)
            val replacement = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
            f.manager.installSyncTestSeam(replacement, 0, transport = { _, _, _, _ -> 500 to null })
            f.manager.installSessionRestoreTestSeam(replacement)
            runCurrent(); assertFalse(f.manager.isPickerAccountCurrent(snapshot))
            f.controller.destinationReturned(ticket) { _, _ -> error("replacement must not inherit save") }
            assertTrue(f.prepared.single().cleared); assertNull(f.controller.state.value.message)
        } finally { f.close() }
    }
    @Test fun confirmedSameSessionRenewalRetainsOriginalPickerAuthorityAndDownloadedCiphertext() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val secure = FailClosedCredentialState(RenewalBackend())
            val beforeRevision = f.manager.pickerAuthorityRevision.value
            val snapshot = checkNotNull(f.manager.capturePickerAccountSnapshot())
            f.manager.installSessionRenewalTestSeam(now = { RenewalFixtures.now }, persist = { owner, sent, epoch, next ->
                SessionRenewalPolicy.persistConfirmed(next, sent, owner, epoch,
                    secure.confirmedSnapshot(*SessionRenewalPolicy.tupleKeys), secure::replaceConfirmed).also { saved ->
                    if (saved) f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session(next, owner.account, owner.dataKey.copyOf()), epoch)
                }
            }, transport = { _, _, _ -> VortXSyncManager.SessionRenewalTestResponse(200, renewal = RenewalFixtures.next, rawBody = f.raw) })
            val route = f.controller.attachPicker(); f.controller.open(route); f.controller.download(checkNotNull(f.controller.renderedActions(route))); runCurrent()
            assertSame(f.original, f.manager.currentSession()); assertEquals(RenewalFixtures.next, f.original.currentBearer)
            assertEquals(beforeRevision, f.manager.pickerAuthorityRevision.value); assertTrue(f.manager.isPickerAccountCurrent(snapshot))
            assertEquals(f.document, JSONObject(String(f.prepared.single().encrypted)).getString("document"))
            val ticket = checkNotNull(f.controller.state.value.destination)
            f.controller.destinationReturned(ticket) { ready, current ->
                assertTrue(current()); PickerToolsSaveReceipt(ready.byteCount, ready.sha256)
            }
            runCurrent(); assertTrue(f.controller.state.value.message!!.contains("read back"))
        } finally { f.close() }
    }
    @Test fun authStartNotifiesToolsWithoutAdvancingExistingAccountRevisionOrSessionEpoch() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val accountRevision = f.manager.pickerAccountRevision.value
            val authorityRevision = f.manager.pickerAuthorityRevision.value
            val snapshot = checkNotNull(f.manager.capturePickerAccountSnapshot())
            val route = f.controller.attachPicker(); f.controller.open(route); f.controller.download(checkNotNull(f.controller.renderedActions(route))); runCurrent()
            f.manager.signIn("fixture@example.invalid", "synthetic never sent password")
            runCurrent()
            assertEquals(accountRevision, f.manager.pickerAccountRevision.value)
            assertTrue(f.manager.pickerAuthorityRevision.value > authorityRevision)
            assertSame(f.original, f.manager.currentSession()); assertFalse(f.manager.isPickerAccountCurrent(snapshot))
            assertTrue(f.prepared.single().cleared); assertNull(f.controller.state.value.destination)
        } finally { f.close() }
    }
    @Test fun originalExpectedSnapshotCannotIssueReplacementAccountGetInsideManagerCapture() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val snapshot = checkNotNull(f.manager.capturePickerAccountSnapshot())
            val replacement = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
            f.manager.installSyncTestSeam(replacement, 0, transport = { _, _, _, _ -> 500 to null })
            f.manager.installSessionRestoreTestSeam(replacement)
            var gets = 0
            f.manager.installAccountFileTransportTestSeam { _, _, _ -> gets++; 200 to f.raw }
            val failure = runCatching { f.manager.downloadAccountBackupFile(snapshot) }.exceptionOrNull()
            assertTrue(failure is AccountBackupFile.Failure)
            assertEquals(AccountBackupFile.Reason.SESSION_CHANGED, (failure as AccountBackupFile.Failure).reason)
            assertEquals(0, gets); assertTrue(f.prepared.isEmpty())
        } finally { f.close() }
    }

    @Test fun renderedOwnerAGrantCannotCaptureOrGetOwnerBBeforeItsFirstClick() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val attachment = f.controller.attachPicker(); f.controller.open(attachment)
            val renderedA = checkNotNull(f.controller.renderedActions(attachment))
            val oldClick = { f.controller.download(renderedA) }
            assertEquals(1, f.captures)
            val accountB = RenewalFixtures.account.copy(id = "20000000-0000-0000-0000-000000000002", email = "replacement@example.invalid")
            val replacement = VortXSyncManager.Session(RenewalFixtures.prior, accountB, RenewalFixtures.key)
            f.manager.installSyncTestSeam(replacement, 0, transport = { _, _, _, _ -> 500 to null })
            f.manager.installSessionRestoreTestSeam(replacement)
            // Invoke before the notification collector can run: exact original snapshot must reject it.
            oldClick(); runCurrent()
            assertEquals(0, f.gets); assertEquals(1, f.captures); assertTrue(f.prepared.isEmpty())
            assertFalse(f.controller.state.value.open); assertNull(f.controller.renderedActions(attachment))
        } finally { f.close() }
    }
    @Test fun renderedGrantCannotGainSameAccountReplacementSessionBeforeFirstClick() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val attachment = f.controller.attachPicker(); f.controller.open(attachment)
            val rendered = checkNotNull(f.controller.renderedActions(attachment))
            val replacement = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
            f.manager.installSyncTestSeam(replacement, 0, transport = { _, _, _, _ -> 500 to null })
            f.manager.installSessionRestoreTestSeam(replacement)
            f.controller.download(rendered); runCurrent()
            assertEquals(0, f.gets); assertEquals(1, f.captures); assertTrue(f.prepared.isEmpty())
        } finally { f.close() }
    }
    @Test fun originalGrantRejectsUnavailableRetryReplacementDespiteConflatedEqualUiAndRevision() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val attachment = f.controller.attachPicker(); f.controller.open(attachment)
            val rendered = checkNotNull(f.controller.renderedActions(attachment))
            val revision = f.manager.pickerAuthorityRevision.value
            val accountRevision = f.manager.pickerAccountRevision.value
            val ui = f.manager.sessionUiState.value
            f.manager.installUnavailableSessionRestoreTestSeam(); f.manager.sessionOwnerSnapshot()
            val replacement = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
            f.manager.installSessionRestoreTestSeam(replacement, ownerEpoch = 2L); f.manager.sessionOwnerSnapshot()
            assertSame(replacement, f.manager.currentSession()); assertEquals(ui, f.manager.sessionUiState.value)
            assertEquals(revision, f.manager.pickerAuthorityRevision.value); assertEquals(accountRevision, f.manager.pickerAccountRevision.value)
            // No scheduler advance: unknown/signed-in notifications may collapse to the equal final UI.
            f.controller.download(rendered); runCurrent()
            assertEquals(0, f.gets); assertEquals(1, f.captures); assertFalse(f.controller.state.value.open)
        } finally { f.close() }
    }
    @Test fun rotatedOldCallbackCannotGetOrRecaptureEvenWhenOriginalSessionIsStillCurrent() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val first = f.controller.attachPicker(); f.controller.open(first)
            val renderedBeforeRotation = checkNotNull(f.controller.renderedActions(first))
            f.controller.detachPicker(first, changingConfigurations = true)
            val replacementAttachment = f.controller.attachPicker()
            assertEquals(first.routeId, replacementAttachment.routeId)
            f.controller.download(renderedBeforeRotation); runCurrent()
            assertEquals(0, f.gets); assertEquals(1, f.captures)
            val freshRendered = checkNotNull(f.controller.renderedActions(replacementAttachment))
            f.controller.download(freshRendered); runCurrent()
            assertEquals(1, f.gets); assertEquals(1, f.captures)
        } finally { f.close() }
    }
    @Test fun signedOutRenderedToolsCannotGainFileAuthorityAfterLaterSignInWithoutNewRoute() = runTest {
        val f = Fixture(backgroundScope)
        try {
            f.manager.installSessionClearTestSeam { true }
            assertEquals(PickerSignOutResult.SIGNED_OUT, f.manager.signOut(checkNotNull(f.manager.capturePickerAccountSnapshot())))
            val attachment = f.controller.attachPicker(); f.controller.open(attachment)
            val signedOutGrant = checkNotNull(f.controller.renderedActions(attachment))
            f.controller.download(signedOutGrant); runCurrent()
            assertEquals(0, f.gets); assertEquals(1, f.captures)
            val replacement = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
            f.manager.installSyncTestSeam(replacement, 0, transport = { _, _, _, _ -> 500 to null })
            f.manager.installSessionRestoreTestSeam(replacement)
            f.controller.download(signedOutGrant); runCurrent()
            assertEquals(0, f.gets); assertEquals(1, f.captures); assertTrue(f.prepared.isEmpty())
        } finally { f.close() }
    }

    @Test fun sameSessionConfirmedRenewalBeforeFirstClickRetainsRenderedGrantWithoutNewCapture() = runTest {
        val f = Fixture(backgroundScope)
        try {
            val attachment = f.controller.attachPicker(); f.controller.open(attachment)
            val rendered = checkNotNull(f.controller.renderedActions(attachment))
            val secure = FailClosedCredentialState(RenewalBackend())
            f.manager.installSessionRenewalTestSeam(now = { RenewalFixtures.now }, persist = { owner, sent, epoch, next ->
                SessionRenewalPolicy.persistConfirmed(next, sent, owner, epoch,
                    secure.confirmedSnapshot(*SessionRenewalPolicy.tupleKeys), secure::replaceConfirmed).also { saved ->
                    if (saved) f.manager.installSessionRestoreTestSeam(VortXSyncManager.Session(next, owner.account, owner.dataKey.copyOf()), epoch)
                }
            }, transport = { _, _, _ -> VortXSyncManager.SessionRenewalTestResponse(200, renewal = RenewalFixtures.next, rawBody = f.raw) })
            f.manager.requestSessionRenewalForTest()
            assertSame(f.original, f.manager.currentSession()); assertEquals(RenewalFixtures.next, f.original.currentBearer)
            f.controller.download(rendered); runCurrent()
            assertNotNull(f.controller.state.value.destination); assertEquals(1, f.captures)
            assertEquals(f.document, JSONObject(String(f.prepared.single().encrypted)).getString("document"))
        } finally { f.close() }
    }

}
