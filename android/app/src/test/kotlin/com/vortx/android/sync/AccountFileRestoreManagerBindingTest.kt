package com.vortx.android.sync

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.vortx.android.engine.AccountFileLocalPresence
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.UUID

class AccountFileRestoreManagerBindingTest {
    @get:Rule val noBackup = TemporaryFolder()

    private class Fixture(scope: CoroutineScope, noBackupDirectory: (() -> File)? = null) : AutoCloseable {
        private val revisionContext = RevisionContext()
        val context = if (noBackupDirectory == null) revisionContext else object : ContextWrapper(revisionContext) {
            override fun getApplicationContext(): Context = this
            override fun getPackageName(): String = revisionContext.packageName
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                revisionContext.getSharedPreferences(name, mode)
            override fun getNoBackupFilesDir(): File = noBackupDirectory()
        }
        val manager = VortXSyncManager(context, scope)

        init { installSession() }

        fun installSession() {
            val session = VortXSyncManager.Session(RenewalFixtures.prior, RenewalFixtures.account, RenewalFixtures.key)
            manager.installSyncTestSeam(session, 0, transport = { _, _, _, _ -> error("Unexpected routine sync") })
            manager.installSessionRestoreTestSeam(session)
        }

        override fun close() { manager.stopRealtime() }
    }

    @Test fun replacementSessionCannotInheritOldPickerRestoreOrVerify() = runTest {
        Fixture(backgroundScope).use { fixture ->
            val manager = fixture.manager
            val original = checkNotNull(manager.capturePickerAccountSnapshot())
            fixture.installSession()
            assertFalse(manager.isPickerAccountCurrent(original))
            val refusal = AccountFileRestoreTransaction.Result.NotSubmitted(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED)
            assertEquals(refusal, manager.restoreAccountBackupFile(original, byteArrayOf(1), { true }) { _, _, _ ->
                error("Old owner reached direct-writer reservation")
            })
            assertEquals(refusal, manager.verifyAccountBackupFileRestore(original, UUID(0, 1)) { true })
            assertEquals(VortXSyncManager.FileRestoreStatus.Unavailable, manager.readAccountBackupFileRestoreStatus(original) { true })
        }
    }

    @Test fun closedRouteCannotReserveWritersForTheCurrentAccount() = runTest {
        Fixture(backgroundScope).use { fixture ->
            val manager = fixture.manager
            val picker = checkNotNull(manager.capturePickerAccountSnapshot())
            assertEquals(AccountFileRestoreTransaction.Result.NotSubmitted(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED),
                manager.restoreAccountBackupFile(picker, byteArrayOf(1), { false }) { _, _, _ ->
                    error("Closed route reached direct-writer reservation")
                })
        }
    }

    @Test fun actualManagerWriterCannotDispatchDuringReservationAndCanDispatchAfterRelease() = runTest {
        Fixture(backgroundScope).use { fixture ->
            val manager = fixture.manager
            val picker = checkNotNull(manager.capturePickerAccountSnapshot())
            val realtime = checkNotNull(manager.captureRealtimeLease())
            var reservations = 0
            var writes = 0
            val result = manager.restoreAccountBackupFile(picker, byteArrayOf(1), { true }) { original, requireOriginal, _ ->
                requireOriginal()
                reservations++
                assertEquals(SessionOwnerSnapshot.Account(realtime.accountId, realtime.ownerEpoch), original.account)
                assertEquals(realtime.operationGeneration, original.operationGeneration)
                assertFalse(manager.admitRealtimeLease(realtime) { writes++; true })
            }
            assertEquals(AccountFileRestoreTransaction.Result.NotSubmitted(AccountFileRestoreTransaction.Reason.BUSY), result)
            assertEquals(1, reservations)
            assertEquals(0, writes)
            assertTrue(manager.admitRealtimeLease(realtime) { writes++; true })
            assertEquals(1, writes)
        }
    }

    @Test fun producedRestoreResultStaysPrivateWhenRouteOrOwnerRetiresDuringReservationCleanup() = runTest {
        val cleanupFailures = listOf(
            null,
            AccountFileRestoreTransaction.Refusal(AccountFileRestoreTransaction.Reason.ACCOUNT_CHANGED),
            IllegalStateException("Synthetic cleanup failure"),
        )
        for (replaceOwner in listOf(null, false, true)) {
            for (cleanupFailure in cleanupFailures) {
                val directory = noBackup.newFolder()
                Fixture(backgroundScope) { directory }.use { fixture ->
                    val manager = fixture.manager
                    val picker = checkNotNull(manager.capturePickerAccountSnapshot())
                    val writer = checkNotNull(manager.captureRealtimeLease())
                    val cleanupStarted = CompletableDeferred<Unit>()
                    val finishCleanup = CompletableDeferred<Unit>()
                    var routeOpen = true
                    val restoring = async {
                        runCatching {
                            manager.restoreAccountBackupFile(picker, byteArrayOf(), { routeOpen }) { owner, requireOriginal, operation ->
                                requireOriginal()
                                operation(object : AccountFileRestoreExternalExclusion.Reservation {
                                    override fun requireCurrent(original: AccountFileRestoreExternalExclusion.Owner) {
                                        check(original === owner)
                                        requireOriginal()
                                    }

                                    override fun requireLocalAbsence(original: AccountFileRestoreExternalExclusion.Owner,
                                        scope: com.vortx.android.engine.VortxAccountScope) {
                                        error("Empty selected file must refuse before checking absence")
                                    }
                                })
                                // Real transaction returned UnsupportedFile. Hold only the external cleanup.
                                cleanupStarted.complete(Unit)
                                finishCleanup.await()
                                if (cleanupFailure != null) throw cleanupFailure
                            }
                        }
                    }
                    try {
                        withTimeout(1_000) { cleanupStarted.await() }
                        assertFalse(restoring.isCompleted)
                        assertFalse(manager.admitRealtimeLease(writer) { error("Writer admitted before cleanup drained") })
                        when (replaceOwner) {
                            true -> fixture.installSession()
                            false -> routeOpen = false
                            null -> Unit
                        }
                    } finally { finishCleanup.complete(Unit) }
                    val result = restoring.await()
                    if (replaceOwner == null) {
                        assertEquals(AccountFileRestoreTransaction.Result.NotSubmitted(AccountFileRestoreTransaction.Reason.UNSUPPORTED_FILE),
                            result.getOrThrow())
                    } else {
                        assertTrue(result.exceptionOrNull() is CancellationException)
                    }
                    assertTrue(manager.admitRealtimeLease(checkNotNull(manager.captureRealtimeLease())) { true })
                    assertTrue(checkNotNull(directory.list()).isEmpty())
                }
            }
        }
    }

    @Test fun verifySuppressesTheOldRouteAfterItsOwnedWorkerReturns() = runTest {
        val directory = noBackup.newFolder()
        var routeOpen = true
        var closeOnJournalAccess = false
        Fixture(backgroundScope) {
            if (closeOnJournalAccess) routeOpen = false
            directory
        }.use { fixture ->
            val manager = fixture.manager
            val picker = checkNotNull(manager.capturePickerAccountSnapshot())
            closeOnJournalAccess = true
            val result = runCatching { manager.verifyAccountBackupFileRestore(picker, UUID(0, 1)) { routeOpen } }
            val failure = result.exceptionOrNull()
            val outcome = result.getOrNull() as? AccountFileRestoreTransaction.Result.NotSubmitted
            assertTrue("Unexpected Verify outcome: ${failure?.javaClass?.name ?: outcome?.reason}; routeOpen=$routeOpen",
                failure is CancellationException)
            assertFalse(routeOpen)
            assertTrue(checkNotNull(directory.list()).isEmpty())
        }
    }

    @Test fun reservationWaitsForDrainAndRetiresWhenAnEditWasAlreadyObserved() {
        val gate = AccountFileRestoreManagerExclusion()
        assertTrue(gate.enterWriter(observedEdit = false))
        assertNull(gate.tryReserve())
        gate.exitWriter()
        val original = checkNotNull(gate.tryReserve())
        assertFalse(gate.enterWriter(observedEdit = false))
        assertTrue(gate.isCurrent(original))
        gate.release(AccountFileRestoreManagerExclusion.Reservation())
        assertTrue(gate.isCurrent(original))
        assertTrue(gate.enterWriter(observedEdit = true))
        assertFalse(gate.isCurrent(original))
        gate.release(original)
        assertNull(gate.tryReserve())
        gate.exitWriter()
        assertNotNull(gate.tryReserve())
    }

    @Test fun pendingMarkerWitnessFailsClosedOnUnknownStorageAndExistingMarker() {
        var marker = false
        var unavailable = false
        val pending = DurablePendingSyncState(
            readDirty = {
                check(!unavailable)
                marker
            },
            writeDirty = { _, _ -> error("Read-only witness must not write") },
        )
        assertEquals(AccountFileLocalPresence.ABSENT, pending.inspectFileRestorePending("owner"))
        marker = true
        assertEquals(AccountFileLocalPresence.PRESENT, pending.inspectFileRestorePending("owner"))
        unavailable = true
        assertEquals(AccountFileLocalPresence.UNAVAILABLE, pending.inspectFileRestorePending("owner"))
    }
}
