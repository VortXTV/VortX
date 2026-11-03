package com.vortx.android.ui.profilepicker

import com.vortx.android.diagnostics.performDiagnosticShare
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.VortXSyncManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import org.junit.Test

/** Actual controller; synthetic authority/transport/provider suspensions are explicit, no SAF proof. */
@OptIn(ExperimentalCoroutinesApi::class)
class ProfilePickerToolsControllerTest {
    private class Accounts : PickerToolsAccounts {
        private val manager = Any()
        private var session: Any? = Any()
        var signedIn = true
        var captures = 0
        private var epoch = 1L
        private var auth = 0L
        private val revision = MutableStateFlow(0L)
        var gets = 0
        var response: suspend () -> ByteArray = { byteArrayOf(1, 2, 3) }
        private val account = VortXSyncManager.Account("10000000-0000-0000-0000-000000000001", "fixture@example.invalid", "Fixture", false)
        override val authorityRevision get() = revision.value
        override val sessionMarker: Any get() = if (signedIn) "signed-in" else "signed-out"
        override val changes = revision.map { Unit }
        override fun capture(): PickerAccountSnapshot {
            captures++
            return PickerAccountSnapshot(manager, auth, epoch, epoch, session, account.takeIf { signedIn })
        }
        override fun isCurrent(original: PickerAccountSnapshot) = original.matchesAuthority(manager, auth, epoch) && original.matchesOwner(manager, epoch, session)
        override suspend fun download(original: PickerAccountSnapshot): ByteArray { gets++; return response() }
        fun replaceSameAccount() { epoch++; signedIn = true; session = Any(); revision.value++ }
        fun signOut() { auth++; epoch++; signedIn = false; session = null; revision.value++ }
        fun beginAuth() { auth++; revision.value++ }
    }
    private class Prepared : PickerToolsPreparedBackup {
        override val byteCount = 3
        override val sha256 = "fixed-synthetic-digest"
        var cleared = false
        override fun close() { cleared = true }
    }
    private class Preparer : PickerToolsBackupPreparer {
        val prepared = mutableListOf<Prepared>()
        override suspend fun prepare(bytes: ByteArray, isCurrent: () -> Boolean): PickerToolsPreparedBackup {
            check(isCurrent()); assertArrayEquals(byteArrayOf(1, 2, 3), bytes)
            return Prepared().also { prepared += it }
        }
    }
    private class Selected : PickerToolsSelectedBackup {
        val selected = byteArrayOf(4, 5, 6)
        val output = Prepared()
        var closed = false
        var preparations = 0
        override fun copyBytes() = selected.copyOf()
        override suspend fun prepareRepairedCopy(bytes: ByteArray, isCurrent: () -> Boolean): PickerToolsPreparedBackup {
            assertTrue(isCurrent())
            assertArrayEquals(byteArrayOf(7, 8, 9), bytes)
            preparations++
            return output
        }
        override fun close() { closed = true }
    }
    private class Export : PickerToolsRepairExport {
        override val profileCount = 2
        override val nativeSchema = 5
        override val byteCount = 3
        override val sha256 = "fixed-synthetic-digest"
        var releases = 0
        var closed = false
        var ownerCurrent = true
        var expiresInMillis = 60_000L
        val rawOutput = byteArrayOf(7, 8, 9)
        override fun remainingMillis() = expiresInMillis
        override fun canSave() = releases == 1 && !closed && ownerCurrent
        override fun take(): ByteArray {
            assertEquals(0, releases)
            assertFalse(closed)
            releases++
            return rawOutput
        }
        override fun close() { closed = true }
    }

    @Test fun repairReadsOriginalOnceAndReleasesOneCopyAfterCurrentPreviewApproval() = runTest {
        val accounts = Accounts()
        val file = Selected()
        val export = Export()
        var returnedInput: ByteArray? = null
        var reads = 0
        val controller = ProfilePickerToolsController(accounts, Preparer(), backgroundScope,
            repairPreparer = PickerToolsRepairPreparer { owner, bytes, current ->
                assertTrue(accounts.isCurrent(owner)); assertTrue(current())
                assertArrayEquals(file.selected, bytes)
                returnedInput = bytes
                export
            })
        try {
            val route = controller.attachPicker()
            controller.open(route)
            val grant = checkNotNull(controller.renderedActions(route))
            controller.repair(grant)
            val request = checkNotNull(controller.state.value.repairInput)
            controller.repairInputReturned(request) { error("unlaunched input accepted") }
            assertTrue(controller.claimRepairInputLaunch(request))
            assertFalse(controller.claimRepairInputLaunch(request))
            controller.repairInputReturned(request) { current -> assertTrue(current()); reads++; file }
            controller.repairInputReturned(request) { error("duplicate input accepted") }
            runCurrent()
            assertEquals(1, reads)
            assertEquals(0, accounts.gets) // Only the distinct repair worker owns its head GET.
            assertArrayEquals(ByteArray(3), checkNotNull(returnedInput))
            assertEquals(PickerToolsRepairReview(request, 2, 5, 3), controller.state.value.repairReview)
            assertNull(controller.state.value.destination)
            assertEquals(0, export.releases)
            val rotated = controller.attachPicker()
            controller.confirmRepair(grant, request, approved = true) // stale attachment cannot approve.
            runCurrent()
            assertEquals(0, export.releases)
            val active = checkNotNull(controller.renderedActions(rotated))
            controller.confirmRepair(active, request, approved = true)
            controller.confirmRepair(active, request, approved = true)
            runCurrent()
            val destination = checkNotNull(controller.state.value.destination)
            controller.destinationReturned(destination) { _, _ -> error("unlaunched repair destination accepted") }
            assertTrue(controller.claimDestinationLaunch(destination))
            controller.destinationReturned(destination) { ready, current ->
                assertTrue(current())
                PickerToolsSaveReceipt(ready.byteCount, ready.sha256)
            }
            runCurrent()
            assertEquals(1, export.releases)
            assertEquals(1, file.preparations)
            assertArrayEquals(ByteArray(3), export.rawOutput)
            assertTrue(export.closed && file.closed && file.output.cleared)
            assertTrue(controller.state.value.message!!.contains("read back successfully"))
        } finally { controller.close() }
    }

    @Test fun expiredPreviewRetiresFileAndDoesNotAcceptLateConfirmation() = runTest {
        val accounts = Accounts(); val file = Selected()
        val export = Export().also { it.expiresInMillis = 0 }
        val controller = ProfilePickerToolsController(accounts, Preparer(), backgroundScope,
            repairPreparer = PickerToolsRepairPreparer { _, _, _ -> export })
        try {
            val route = controller.attachPicker(); controller.open(route)
            val grant = checkNotNull(controller.renderedActions(route)); controller.repair(grant)
            val request = checkNotNull(controller.state.value.repairInput)
            assertTrue(controller.claimRepairInputLaunch(request))
            controller.repairInputReturned(request) { file }; runCurrent()
            controller.confirmRepair(grant, request, approved = true); runCurrent()
            assertEquals(0, export.releases); assertTrue(export.closed && file.closed)
            assertNull(controller.state.value.destination)
            assertEquals(PickerToolsFailure.REPAIR_EXPIRED.message, controller.state.value.message)
        } finally { controller.close() }
    }

    @Test fun lateRepairWorkerCannotReleaseItsPreviewOrFreeTheBusySlotBeforeReturn() = runTest {
        val accounts = Accounts(); val file = Selected(); val export = Export()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val controller = ProfilePickerToolsController(accounts, Preparer(), backgroundScope,
            repairPreparer = PickerToolsRepairPreparer { _, _, current ->
                withContext(NonCancellable) {
                    entered.complete(Unit); release.await(); assertFalse(current()); export
                }
            })
        try {
            val route = controller.attachPicker(); controller.open(route)
            val grant = checkNotNull(controller.renderedActions(route)); controller.repair(grant)
            val request = checkNotNull(controller.state.value.repairInput)
            assertTrue(controller.claimRepairInputLaunch(request))
            controller.repairInputReturned(request) { file }; runCurrent(); assertTrue(entered.isCompleted)
            accounts.replaceSameAccount(); runCurrent()
            val newer = controller.attachPicker(); controller.open(newer)
            val newerGrant = checkNotNull(controller.renderedActions(newer))
            controller.download(newerGrant); runCurrent(); assertEquals(0, accounts.gets)
            controller.repairInputReturned(request) { error("retired source reached a new route") }
            release.complete(Unit); runCurrent()
            assertTrue(file.closed && export.closed); assertEquals(0, export.releases)
            assertNull(controller.state.value.repairReview)
            controller.download(newerGrant); runCurrent(); assertEquals(1, accounts.gets)
        } finally { release.complete(Unit); controller.close() }
    }

    @Test fun accountWitnessLossBeforeDestinationBlocksProviderEvenAfterConfirmedRepair() = runTest {
        val accounts = Accounts(); val file = Selected(); val export = Export()
        val controller = ProfilePickerToolsController(accounts, Preparer(), backgroundScope,
            repairPreparer = PickerToolsRepairPreparer { _, _, _ -> export })
        try {
            val route = controller.attachPicker(); controller.open(route)
            val grant = checkNotNull(controller.renderedActions(route)); controller.repair(grant)
            val request = checkNotNull(controller.state.value.repairInput)
            assertTrue(controller.claimRepairInputLaunch(request))
            controller.repairInputReturned(request) { file }; runCurrent()
            controller.confirmRepair(grant, request, approved = true); runCurrent()
            val destination = checkNotNull(controller.state.value.destination)
            assertTrue(controller.claimDestinationLaunch(destination))
            export.ownerCurrent = false
            controller.destinationReturned(destination) { _, _ -> error("revoked key witness reached provider") }
            runCurrent()
            assertEquals(1, export.releases)
            assertTrue(file.closed && export.closed && file.output.cleared)
            assertNull(controller.state.value.message)
        } finally { controller.close() }
    }

    @Test fun sameAccountNewEpochBetweenGetAndPublicationCannotReachDestinationAndClearsRaw() = runTest {
        val accounts = Accounts(); val files = Preparer(); val done = CompletableDeferred<Unit>()
        val raw = byteArrayOf(1, 2, 3)
        accounts.response = { withContext(NonCancellable) { done.await(); raw } }
        val controller = ProfilePickerToolsController(accounts, files, backgroundScope)
        try {
            val route = controller.attachPicker(); controller.open(route); controller.download(checkNotNull(controller.renderedActions(route))); runCurrent()
            accounts.replaceSameAccount(); runCurrent(); done.complete(Unit); runCurrent()
            assertEquals(1, accounts.gets); assertTrue(files.prepared.isEmpty())
            assertArrayEquals(ByteArray(3), raw); assertNull(controller.state.value.destination)
            assertEquals(PickerToolsPhase.IDLE, controller.state.value.phase); assertNull(controller.state.value.message)
        } finally { controller.close() }
    }
    @Test fun cancelledProviderKeepsOnlySlotUntilRealReturnAndSuppressesLateReceipt() = runTest {
        val accounts = Accounts(); val files = Preparer(); val entered = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
        val controller = ProfilePickerToolsController(accounts, files, backgroundScope)
        try {
            val route = controller.attachPicker(); controller.open(route); controller.download(checkNotNull(controller.renderedActions(route))); runCurrent()
            val ticket = checkNotNull(controller.state.value.destination)
            controller.destinationReturned(ticket) { bytes, current ->
                withContext(NonCancellable) {
                    assertTrue(current()); entered.complete(Unit); finish.await()
                    assertFalse(current()); PickerToolsSaveReceipt(bytes.byteCount, bytes.sha256)
                }
            }
            runCurrent(); assertTrue(entered.isCompleted)
            controller.closeTools(route); controller.open(route); controller.download(checkNotNull(controller.renderedActions(route))); runCurrent()
            assertEquals(1, accounts.gets); assertFalse(files.prepared.single().cleared)
            assertEquals(PickerToolsPhase.CANCELLING, controller.state.value.phase)
            finish.complete(Unit); runCurrent()
            assertTrue(files.prepared.single().cleared); assertNull(controller.state.value.message)
            controller.download(checkNotNull(controller.renderedActions(route))); runCurrent(); assertEquals(2, accounts.gets)
        } finally { finish.complete(Unit); controller.close() }
    }
    @Test fun rotationReattachesSameOperationAndOldDisposalCannotRetireItsSuccessor() = runTest {
        val accounts = Accounts(); val files = Preparer(); val controller = ProfilePickerToolsController(accounts, files, backgroundScope)
        try {
            val first = controller.attachPicker(); controller.open(first); controller.download(checkNotNull(controller.renderedActions(first))); runCurrent()
            val ticket = checkNotNull(controller.state.value.destination)
            assertTrue(controller.claimDestinationLaunch(ticket))
            controller.detachPicker(first, changingConfigurations = true)
            val second = controller.attachPicker()
            controller.detachPicker(first, changingConfigurations = false) // Delayed old owner disposal.
            assertEquals(first.routeId, second.routeId); assertNotEquals(first.attachmentId, second.attachmentId)
            assertTrue(controller.state.value.open); assertEquals(ticket, controller.state.value.destination)
            assertFalse(controller.claimDestinationLaunch(ticket))
            var saves = 0
            controller.destinationReturned(ticket) { bytes, current ->
                assertTrue(current()); saves++; PickerToolsSaveReceipt(bytes.byteCount, bytes.sha256)
            }
            controller.destinationReturned(ticket) { _, _ -> error("duplicate destination must not save") }
            runCurrent()
            assertEquals(1, accounts.gets); assertEquals(1, saves)
            assertTrue(files.prepared.single().cleared); assertTrue(controller.state.value.message!!.contains("read back"))
            controller.closeTools(first) // A stale attachment cannot close the current UI.
            assertTrue(controller.state.value.open)
        } finally { controller.close() }
    }
    @Test fun delayedOldDestinationCannotPickNewOperationAndWrongReceiptIsRefused() = runTest {
        val accounts = Accounts(); val files = Preparer(); val controller = ProfilePickerToolsController(accounts, files, backgroundScope)
        try {
            val first = controller.attachPicker(); controller.open(first); controller.download(checkNotNull(controller.renderedActions(first))); runCurrent()
            val old = checkNotNull(controller.state.value.destination)
            controller.detachPicker(first, false); runCurrent()
            val second = controller.attachPicker(); controller.open(second); controller.download(checkNotNull(controller.renderedActions(second))); runCurrent()
            val current = checkNotNull(controller.state.value.destination)
            var staleSaves = 0
            controller.destinationReturned(old) { bytes, _ -> staleSaves++; PickerToolsSaveReceipt(bytes.byteCount, bytes.sha256) }
            controller.destinationReturned(current) { bytes, _ -> PickerToolsSaveReceipt(bytes.byteCount + 1, bytes.sha256) }
            runCurrent()
            assertEquals(0, staleSaves); assertEquals(PickerToolsFailure.WRONG_RECEIPT.message, controller.state.value.message)
            assertTrue(files.prepared.all { it.cleared })
        } finally { controller.close() }
    }
    @Test fun diagnosticRevocationDuringStagingPreventsPresentationOnActualSharePolicyPath() = runTest {
        val accounts = Accounts(); val stage = CompletableDeferred<Unit>(); var allowed = true; var presentations = 0
        val controller = ProfilePickerToolsController(accounts, Preparer(), backgroundScope)
        try {
            val route = controller.attachPicker(); controller.open(route)
            controller.diagnostics(checkNotNull(controller.renderedActions(route)), policy = { allowed }) { current ->
                performDiagnosticShare(stage = { stage.await(); Unit }, mayShare = current, present = { presentations++; true })
            }
            runCurrent(); allowed = false; stage.complete(Unit); runCurrent()
            assertEquals(0, presentations); assertNull(controller.state.value.message)
            assertEquals(PickerToolsPhase.IDLE, controller.state.value.phase)
        } finally { controller.close() }
    }
    @Test fun authStartRetiresAwaitingDestinationWithoutAdoptingAnotherAccount() = runTest {
        val accounts = Accounts(); val files = Preparer(); val controller = ProfilePickerToolsController(accounts, files, backgroundScope)
        try {
            val route = controller.attachPicker(); controller.open(route); controller.download(checkNotNull(controller.renderedActions(route))); runCurrent()
            val ticket = checkNotNull(controller.state.value.destination)
            accounts.beginAuth(); runCurrent()
            controller.destinationReturned(ticket) { _, _ -> error("retired auth must not write") }
            assertTrue(files.prepared.single().cleared); assertNull(controller.state.value.destination)
            assertEquals(PickerToolsPhase.IDLE, controller.state.value.phase)
        } finally { controller.close() }
    }
    @Test fun cancellationBeforeLazyCoroutineEntryDoesNotLeakTheOnlySlot() = runTest {
        val accounts = Accounts(); val controller = ProfilePickerToolsController(accounts, Preparer(), backgroundScope)
        try {
            val route = controller.attachPicker(); controller.open(route); controller.download(checkNotNull(controller.renderedActions(route))); controller.closeTools(route)
            runCurrent(); controller.open(route); controller.download(checkNotNull(controller.renderedActions(route))); runCurrent()
            assertEquals(1, accounts.gets); assertNotNull(controller.state.value.destination)
        } finally { controller.close() }
    }
    @Test fun replacementManagerCannotAllocateSecondSlotUntilRetiredProviderReallyDrains() = runTest {
        val gate = PickerToolsWorkGate(); val firstAccounts = Accounts(); val secondAccounts = Accounts()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val first = ProfilePickerToolsController(firstAccounts, Preparer(), backgroundScope, gate)
        val second = ProfilePickerToolsController(secondAccounts, Preparer(), backgroundScope, gate)
        try {
            val oldRoute = first.attachPicker(); first.open(oldRoute); first.download(checkNotNull(first.renderedActions(oldRoute))); runCurrent()
            first.destinationReturned(checkNotNull(first.state.value.destination)) { bytes, _ ->
                withContext(NonCancellable) { entered.complete(Unit); release.await(); PickerToolsSaveReceipt(bytes.byteCount, bytes.sha256) }
            }
            runCurrent(); assertTrue(entered.isCompleted)
            first.close() // The real holder clears the previous manager's VM on replacement.
            val newRoute = second.attachPicker(); second.open(newRoute); second.download(checkNotNull(second.renderedActions(newRoute))); runCurrent()
            assertEquals(0, secondAccounts.gets); assertTrue(gate.busy.value)
            assertTrue(second.state.value.cancellingFileSave)
            release.complete(Unit); runCurrent()
            assertFalse(gate.busy.value); assertEquals(PickerToolsPhase.IDLE, second.state.value.phase)
            assertFalse(second.state.value.cancellingFileSave)
            second.download(checkNotNull(second.renderedActions(newRoute))); runCurrent(); assertEquals(1, secondAccounts.gets)
        } finally { release.complete(Unit); first.close(); second.close() }
    }

    @Test fun laterAuthorityChangeClearsCompletedStatusAfterSlotHasDrained() = runTest {
        val accounts = Accounts(); val controller = ProfilePickerToolsController(accounts, Preparer(), backgroundScope)
        try {
            val route = controller.attachPicker(); controller.open(route); controller.download(checkNotNull(controller.renderedActions(route))); runCurrent()
            controller.destinationReturned(checkNotNull(controller.state.value.destination)) { bytes, _ ->
                PickerToolsSaveReceipt(bytes.byteCount, bytes.sha256)
            }
            runCurrent(); assertNotNull(controller.state.value.message)
            accounts.beginAuth(); runCurrent(); assertNull(controller.state.value.message)
        } finally { controller.close() }
    }

    @Test fun closeAndReopenRequiresNewRenderedPresentationGrantEvenForSameOwner() = runTest {
        val accounts = Accounts(); val controller = ProfilePickerToolsController(accounts, Preparer(), backgroundScope)
        try {
            val attachment = controller.attachPicker(); controller.open(attachment)
            val oldRendered = checkNotNull(controller.renderedActions(attachment))
            controller.closeTools(attachment); controller.open(attachment)
            controller.download(oldRendered); runCurrent()
            assertEquals(0, accounts.gets); assertEquals(1, accounts.captures)
            controller.download(checkNotNull(controller.renderedActions(attachment))); runCurrent()
            assertEquals(1, accounts.gets); assertEquals(1, accounts.captures)
        } finally { controller.close() }
    }
    @Test fun signedOutRouteCanSharePerPolicyButAnOldGrantCannotAcquireLaterFileAuthority() = runTest {
        val accounts = Accounts(); accounts.signOut()
        val controller = ProfilePickerToolsController(accounts, Preparer(), backgroundScope)
        try {
            val attachment = controller.attachPicker(); controller.open(attachment)
            val signedOut = checkNotNull(controller.renderedActions(attachment))
            var presented = 0
            controller.diagnostics(signedOut, policy = { true }) { current ->
                performDiagnosticShare(stage = { Unit }, mayShare = current, present = { presented++; true })
            }
            runCurrent(); assertEquals(1, presented)
            accounts.replaceSameAccount()
            controller.download(signedOut); runCurrent()
            assertEquals(0, accounts.gets); assertEquals(1, accounts.captures); assertFalse(controller.state.value.open)
            val freshAttachment = controller.attachPicker(); controller.open(freshAttachment)
            controller.download(checkNotNull(controller.renderedActions(freshAttachment))); runCurrent()
            assertEquals(1, accounts.gets); assertEquals(2, accounts.captures)
        } finally { controller.close() }
    }

}
