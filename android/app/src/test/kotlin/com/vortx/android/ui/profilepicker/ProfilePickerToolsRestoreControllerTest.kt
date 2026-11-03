package com.vortx.android.ui.profilepicker

import com.vortx.android.sync.AccountFileRestoreJournal.State as JournalState
import com.vortx.android.sync.AccountFileRestoreTransaction.Reason
import com.vortx.android.sync.AccountFileRestoreTransaction.Result as RestoreResult
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.sync.VortXSyncManager.FileRestoreStatus
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Actual controller and authority snapshots with synthetic provider, journal and manager I/O. */
@OptIn(ExperimentalCoroutinesApi::class)
class ProfilePickerToolsRestoreControllerTest {
    private class Accounts(signedIn: Boolean = true) : PickerToolsAccounts {
        private val issuer = Any()
        private var session: Any? = if (signedIn) Any() else null
        private var account: VortXSyncManager.Account? = if (signedIn) account(false) else null
        private val revision = MutableStateFlow(1L)
        override val authorityRevision get() = revision.value
        override val sessionMarker: Any get() = account?.id ?: Unit
        override val changes = revision.map { Unit }
        override fun capture(): PickerAccountSnapshot =
            PickerAccountSnapshot(issuer, revision.value, revision.value, revision.value, session, account)
        override fun isCurrent(original: PickerAccountSnapshot) =
            original.matchesAuthority(issuer, revision.value, revision.value) &&
                original.matchesOwner(issuer, revision.value, session)
        override suspend fun download(original: PickerAccountSnapshot): ByteArray = error("unexpected backup download")
        fun replace(differentAccount: Boolean) {
            account = account(differentAccount)
            session = Any()
            revision.value++
        }
        private fun account(differentAccount: Boolean) = VortXSyncManager.Account(
            if (differentAccount) "10000000-0000-0000-0000-000000000002" else "10000000-0000-0000-0000-000000000001",
            "fixture@example.invalid", "Fixture", false,
        )
    }

    private object Input : PickerToolsRestoreInput
    private class Candidate : PickerToolsRestoreCandidate {
        override val byteCount = 27
        var confirmations = 0
        var closes = 0
        var submit: suspend () -> RestoreResult = { RestoreResult.NotSubmitted(Reason.UNSUPPORTED_FILE) }
        override suspend fun confirm(): RestoreResult { confirmations++; return submit() }
        override fun close() { closes++ }
    }
    private class Actions : PickerToolsRestoreActions {
        var selectionAllowed = true
        override fun canSelect(original: PickerToolsActionGrant) = selectionAllowed
        var status: FileRestoreStatus = FileRestoreStatus.Missing
        val statusOwners = mutableListOf<PickerToolsActionGrant>()
        val inputOwners = mutableListOf<PickerToolsActionGrant>()
        val verifies = mutableListOf<Pair<PickerToolsActionGrant, UUID>>()
        val candidate = Candidate()
        var select: suspend (() -> Boolean) -> PickerToolsRestoreCandidate = { candidate }
        var verify: (UUID) -> RestoreResult = { RestoreResult.NotSubmitted(Reason.BUSY) }
        override suspend fun status(original: PickerToolsActionGrant, isCurrent: () -> Boolean): FileRestoreStatus {
            assertTrue(isCurrent()); statusOwners += original; return status
        }
        override suspend fun read(original: PickerToolsActionGrant, input: PickerToolsRestoreInput,
            isCurrent: () -> Boolean): PickerToolsRestoreCandidate {
            assertTrue(isCurrent()); assertSame(Input, input); inputOwners += original
            return select(isCurrent)
        }
        override suspend fun verify(original: PickerToolsActionGrant, operationId: UUID,
            isCurrent: () -> Boolean): RestoreResult {
            assertTrue(isCurrent()); verifies += original to operationId
            return verify(operationId)
        }
    }

    private fun controller(scope: CoroutineScope, accounts: Accounts, actions: Actions? = null,
        gate: PickerToolsWorkGate = PickerToolsWorkGate(),
        recoveryGate: PickerToolsWorkGate = PickerToolsWorkGate()) = ProfilePickerToolsController(
        accounts, PickerToolsBackupPreparer { _, _ -> error("unexpected file preparation") },
        scope, gate, restoreActions = actions, recoveryGate = recoveryGate,
    )
    private fun ProfilePickerToolsController.openRoute(): PickerToolsActionGrant {
        val route = attachPicker()
        open(route)
        return checkNotNull(renderedActions(route))
    }
    private fun ProfilePickerToolsController.deliverInput(): PickerToolsRestoreInputRequest {
        val request = checkNotNull(state.value.restoreInput)
        assertTrue(claimRestoreInputLaunch(request))
        restoreInputReturned(request, Input)
        return request
    }

    @Test fun defaultControllerCannotStartRestoreOrVerify() = runTest {
        controller(backgroundScope, Accounts()).use { controller ->
            val grant = controller.openRoute()
            assertFalse(controller.restoreAvailable)
            controller.restore(grant)
            controller.verifyRestore(grant, PickerToolsRestoreVerifyRequest("synthetic-stale-control"))
            runCurrent()
            assertEquals(PickerToolsPhase.IDLE, controller.state.value.phase)
            assertNull(controller.state.value.restoreInput)
            assertNull(controller.state.value.restoreStatus)
        }
    }

    @Test fun originalRequestRotatesWithoutRelaunchAndOnlyNewAttachmentCanConfirmOriginalGrant() = runTest {
        val actions = Actions()
        controller(backgroundScope, Accounts(), actions).use { controller ->
            val grant = controller.openRoute()
            controller.restore(grant); runCurrent()
            val request = checkNotNull(controller.state.value.restoreInput)
            controller.restoreInputReturned(request, Input) // Pre-launch result cannot satisfy this request.
            runCurrent()
            assertTrue(actions.inputOwners.isEmpty())
            assertTrue(controller.claimRestoreInputLaunch(request))
            controller.detachPicker(grant.attachment, changingConfigurations = true)
            val rotated = controller.attachPicker()
            val active = checkNotNull(controller.renderedActions(rotated))
            assertEquals(request, controller.state.value.restoreInput)
            assertFalse(controller.claimRestoreInputLaunch(request))
            controller.restoreInputReturned(request, Input)
            controller.restoreInputReturned(request, Input)
            controller.restoreInputRefused(request)
            runCurrent()
            assertEquals(PickerToolsRestoreReview(request, 27), controller.state.value.restoreReview)
            assertSame(grant, actions.statusOwners.single())
            assertSame(grant, actions.inputOwners.single())
            controller.confirmRestore(grant, request, approved = true); runCurrent()
            assertEquals(0, actions.candidate.confirmations)
            controller.confirmRestore(active, request, approved = true)
            controller.confirmRestore(active, request, approved = true)
            runCurrent()
            assertEquals(1, actions.candidate.confirmations)
            assertEquals(1, actions.candidate.closes)
            assertEquals("This restore was not submitted.", controller.state.value.message)
            assertNull(controller.state.value.restoreReview)
        }
    }

    @Test fun staleRenderedOwnersCannotStartAfterDifferentSameOrSignedOutAccountReplacement() = runTest {
        for ((signedIn, differentAccount) in listOf(true to true, true to false, false to false)) {
            val accounts = Accounts(signedIn)
            val actions = Actions()
            controller(backgroundScope, accounts, actions).use { controller ->
                val old = controller.openRoute()
                // Invoke the old rendered action before delivering the authority observer update.
                accounts.replace(differentAccount)
                controller.restore(old)
                controller.verifyRestore(old, PickerToolsRestoreVerifyRequest("old-control"))
                runCurrent()
                assertTrue(actions.statusOwners.isEmpty())
                assertTrue(actions.verifies.isEmpty())
                assertTrue(actions.inputOwners.isEmpty())
                val current = controller.openRoute()
                controller.restore(current); runCurrent()
                assertSame(current, actions.statusOwners.single())
                assertNotNull(controller.state.value.restoreInput)
            }
        }
    }

    @Test fun lateSelectionAndConfirmationCannotBorrowReopenedToolsSlot() = runTest {
        val actions = Actions()
        controller(backgroundScope, Accounts(), actions).use { controller ->
            val old = controller.openRoute()
            controller.restore(old); runCurrent()
            val prior = checkNotNull(controller.state.value.restoreInput)
            assertTrue(controller.claimRestoreInputLaunch(prior))
            controller.closeTools(old.attachment); runCurrent()
            controller.open(old.attachment)
            val current = checkNotNull(controller.renderedActions(old.attachment))
            controller.restore(current); runCurrent()
            val next = checkNotNull(controller.state.value.restoreInput)
            assertNotEquals(prior, next)
            controller.restoreInputReturned(prior, Input)
            controller.restoreInputRefused(prior)
            controller.confirmRestore(old, prior, approved = true)
            runCurrent()
            assertTrue(actions.inputOwners.isEmpty())
            assertTrue(controller.claimRestoreInputLaunch(next))
            controller.restoreInputReturned(next, Input); runCurrent()
            controller.confirmRestore(current, prior, approved = true)
            controller.confirmRestore(old, next, approved = true); runCurrent()
            assertEquals(0, actions.candidate.confirmations)
            controller.confirmRestore(current, next, approved = false); runCurrent()
            assertEquals(1, actions.candidate.closes)
            assertEquals(0, actions.candidate.confirmations)
        }
    }

    @Test fun cancelledSelectorRefusesLateDeliveryWithoutProviderRead() = runTest {
        val actions = Actions()
        controller(backgroundScope, Accounts(), actions).use { controller ->
            val grant = controller.openRoute()
            controller.restore(grant); runCurrent()
            val request = checkNotNull(controller.state.value.restoreInput)
            assertTrue(controller.claimRestoreInputLaunch(request))
            controller.restoreInputRefused(request)
            controller.restoreInputReturned(request, Input)
            runCurrent()
            assertTrue(actions.inputOwners.isEmpty())
            assertEquals("Restore cancelled.", controller.state.value.message)
            assertNull(controller.state.value.restoreInput)
        }
    }

    @Test fun retainedVerifyControlCannotSurviveAccountReplacement() = runTest {
        val accounts = Accounts()
        val actions = Actions()
        actions.status = FileRestoreStatus.Retained(UUID.randomUUID(), 7L, JournalState.PossibleSend)
        controller(backgroundScope, accounts, actions).use { controller ->
            val old = controller.openRoute()
            controller.restore(old); runCurrent()
            val request = checkNotNull(controller.state.value.restoreStatus?.verify)
            accounts.replace(differentAccount = true)
            controller.verifyRestore(old, request); runCurrent()
            assertNull(controller.state.value.restoreStatus)
            val next = controller.openRoute()
            controller.verifyRestore(next, request); runCurrent()
            assertTrue(actions.verifies.isEmpty())
            assertEquals(1, actions.statusOwners.size)
        }
    }

    @Test fun allRealRetainedStatesAreDistinctAndOnlyVerifiableStatesCarryAControl() = runTest {
        val actions = Actions()
        val operation = UUID.randomUUID()
        val messages = mutableSetOf<String>()
        controller(backgroundScope, Accounts(), actions).use { controller ->
            val grant = controller.openRoute()
            actions.status = FileRestoreStatus.Unavailable
            controller.restore(grant); runCurrent()
            assertTrue(checkNotNull(controller.state.value.message).contains("unavailable"))
            assertNull(controller.state.value.restoreInput)
            for (state in JournalState.entries) {
                actions.status = FileRestoreStatus.Retained(operation, 7L, state)
                controller.restore(grant); runCurrent()
                val status = checkNotNull(controller.state.value.restoreStatus)
                assertTrue(messages.add(status.message))
                val canVerify = state in setOf(JournalState.PossibleSend, JournalState.DeliveryUnconfirmed, JournalState.UploadAccepted)
                assertEquals(canVerify, status.verify != null)
                assertNull(controller.state.value.restoreInput)
                assertFalse(controller.state.value.toString().contains(operation.toString()))
            }
            assertTrue(actions.inputOwners.isEmpty())
            assertTrue(actions.verifies.isEmpty())
        }
    }

    @Test fun verifyReattachesAcrossRotationButUsesOnlyOriginalGrantAndJournalId() = runTest {
        val actions = Actions()
        val operation = UUID.randomUUID()
        actions.status = FileRestoreStatus.Retained(operation, 7L, JournalState.PossibleSend)
        actions.verify = {
            assertEquals(operation, it)
            actions.status = FileRestoreStatus.Retained(operation, 7L, JournalState.ServerConfirmed)
            RestoreResult.ServerConfirmed(operation, 7L)
        }
        controller(backgroundScope, Accounts(), actions).use { controller ->
            val grant = controller.openRoute()
            controller.restore(grant); runCurrent()
            val request = checkNotNull(controller.state.value.restoreStatus?.verify)
            val rotated = controller.attachPicker()
            val current = checkNotNull(controller.renderedActions(rotated))
            controller.verifyRestore(grant, request)
            controller.verifyRestore(current, PickerToolsRestoreVerifyRequest("wrong-control"))
            runCurrent()
            assertTrue(actions.verifies.isEmpty())
            controller.verifyRestore(current, request)
            controller.verifyRestore(current, request); runCurrent()
            assertEquals(operation, actions.verifies.single().second)
            assertSame(grant, actions.verifies.single().first)
            assertEquals(2, actions.statusOwners.size)
            assertTrue(actions.statusOwners.all { it === grant })
            assertNull(controller.state.value.restoreStatus?.verify)
            assertTrue(checkNotNull(controller.state.value.message).contains("verified"))
            assertTrue(actions.inputOwners.isEmpty())
            assertEquals(0, actions.candidate.confirmations)
        }
    }

    @Test fun allSixResultVariantsPublishDistinctFactsAndOnlyMatchingJournalReadCanEnableVerify() = runTest {
        val operation = UUID.randomUUID()
        val results = listOf(
            RestoreResult.NotSubmitted(Reason.BUSY) to null,
            RestoreResult.ExistingIntent(operation, JournalState.PossibleSend) to JournalState.PossibleSend,
            RestoreResult.Conflict(operation) to JournalState.Conflict,
            RestoreResult.DeliveryUnconfirmed(operation) to JournalState.DeliveryUnconfirmed,
            RestoreResult.UploadAccepted(operation) to JournalState.UploadAccepted,
            RestoreResult.ServerConfirmed(operation, 7L) to JournalState.ServerConfirmed,
        )
        val messages = mutableSetOf<String>()
        for ((result, state) in results) {
            val actions = Actions()
            actions.candidate.submit = {
                // Deliberately return a new journal ID after UploadAccepted to prove no control is invented.
                val retained = if (state == JournalState.UploadAccepted) UUID.randomUUID() else operation
                if (state != null) actions.status = FileRestoreStatus.Retained(retained, 7L, state)
                result
            }
            controller(backgroundScope, Accounts(), actions).use { controller ->
                val grant = controller.openRoute()
                controller.restore(grant); runCurrent()
                val request = controller.deliverInput(); runCurrent()
                controller.confirmRestore(grant, request, approved = true); runCurrent()
                assertTrue(messages.add(checkNotNull(controller.state.value.message)))
                assertEquals(1, actions.candidate.confirmations)
                assertEquals(1, actions.candidate.closes)
                val canVerify = state in setOf(JournalState.PossibleSend, JournalState.DeliveryUnconfirmed)
                assertEquals(canVerify, controller.state.value.restoreStatus?.verify != null)
                assertEquals(if (state == null) 1 else 2, actions.statusOwners.size)
                if (state == JournalState.UploadAccepted) assertNull(controller.state.value.restoreStatus)
            }
        }
    }

    @Test fun replacementControllerCannotOverlapNoncooperativeProviderAndLateCandidateCloses() = runTest {
        val gate = PickerToolsWorkGate()
        val actions = Actions()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        actions.select = { current ->
            withContext(NonCancellable) {
                entered.complete(Unit); release.await(); assertFalse(current()); actions.candidate
            }
        }
        val first = controller(backgroundScope, Accounts(), actions, gate)
        val newerActions = Actions()
        val second = controller(backgroundScope, Accounts(), newerActions, gate)
        try {
            val original = first.openRoute()
            first.restore(original); runCurrent()
            first.deliverInput(); runCurrent()
            assertTrue(entered.isCompleted)
            first.close()
            val successor = second.openRoute()
            second.restore(successor); runCurrent()
            assertTrue(gate.busy.value)
            assertTrue(newerActions.statusOwners.isEmpty())
            assertNull(first.state.value.restoreReview)
            release.complete(Unit); runCurrent()
            assertFalse(gate.busy.value)
            assertEquals(1, actions.candidate.closes)
            assertEquals(0, actions.candidate.confirmations)
            assertNull(first.state.value.restoreStatus)
            second.restore(successor); runCurrent()
            assertSame(successor, newerActions.statusOwners.single())
        } finally { release.complete(Unit); first.close(); second.close() }
    }

    @Test fun lateSubmitHoldsGateUntilActualReturnAndNeverPublishesIntoSuccessorPresentation() = runTest {
        val gate = PickerToolsWorkGate()
        val actions = Actions()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        actions.candidate.submit = {
            withContext(NonCancellable) {
                entered.complete(Unit); release.await(); RestoreResult.DeliveryUnconfirmed(UUID.randomUUID())
            }
        }
        controller(backgroundScope, Accounts(), actions, gate).use { controller ->
            try {
                val grant = controller.openRoute()
                controller.restore(grant); runCurrent()
                val request = controller.deliverInput(); runCurrent()
                controller.confirmRestore(grant, request, approved = true); runCurrent()
                assertTrue(entered.isCompleted)
                controller.closeTools(grant.attachment)
                controller.open(grant.attachment)
                val newer = checkNotNull(controller.renderedActions(grant.attachment))
                controller.restore(newer); runCurrent()
                assertTrue(gate.busy.value)
                assertEquals(0, actions.candidate.closes)
                assertEquals(1, actions.statusOwners.size)
                assertFalse(controller.state.value.cancellingFileSave)
                release.complete(Unit); runCurrent()
                assertFalse(gate.busy.value)
                assertEquals(1, actions.candidate.closes)
                assertNull(controller.state.value.restoreStatus)
                assertNull(controller.state.value.message)
                assertEquals(1, actions.statusOwners.size)
            } finally { release.complete(Unit) }
        }
    }

    @Test fun backClosesUnconsumedSelectionAndUnexpectedSubmitFailureIsUncertainty() = runTest {
        val backActions = Actions()
        controller(backgroundScope, Accounts(), backActions).use { controller ->
            val grant = controller.openRoute()
            controller.restore(grant); runCurrent()
            val request = controller.deliverInput(); runCurrent()
            controller.closeTools(grant.attachment); runCurrent()
            controller.confirmRestore(grant, request, approved = true); runCurrent()
            assertEquals(1, backActions.candidate.closes)
            assertEquals(0, backActions.candidate.confirmations)
            assertNull(controller.state.value.restoreReview)
        }
        val failActions = Actions()
        failActions.candidate.submit = { error("synthetic private provider detail") }
        controller(backgroundScope, Accounts(), failActions).use { controller ->
            val grant = controller.openRoute()
            controller.restore(grant); runCurrent()
            val request = controller.deliverInput(); runCurrent()
            controller.confirmRestore(grant, request, approved = true); runCurrent()
            val message = checkNotNull(controller.state.value.message)
            assertTrue(message.contains("could not be confirmed"))
            assertFalse(message.contains("not submitted"))
            assertFalse(message.contains("synthetic private"))
            assertFalse(message.contains("new copy"))
            assertEquals(1, failActions.candidate.closes)
        }
    }

    @Test fun explicitRecoverySignInNeedsDelegateAndExactCurrentSignedOutGrant() = runTest {
        controller(backgroundScope, Accounts(signedIn = false)).use { controller ->
            controller.beginRecoverySignIn(controller.openRoute()) { throw AssertionError("disabled recovery reached auth") }
            runCurrent()
            assertEquals(PickerToolsPhase.IDLE, controller.state.value.phase)
        }
        val accounts = Accounts(signedIn = false)
        val opened = mutableListOf<PickerAccountSnapshot>()
        controller(backgroundScope, accounts, Actions()).use { controller ->
            val original = controller.openRoute()
            controller.beginRecoverySignIn(original) { opened += it; true }
            controller.beginRecoverySignIn(original) { throw AssertionError("duplicate recovery reached auth") }
            runCurrent()
            assertSame(original.original, opened.single())
            accounts.replace(differentAccount = false)
            controller.beginRecoverySignIn(original) { throw AssertionError("retired recovery reached auth") }
            runCurrent()
            val signedIn = controller.openRoute()
            controller.beginRecoverySignIn(signedIn) { throw AssertionError("signed-in recovery reached auth") }
            runCurrent()
            assertEquals(1, opened.size)
        }
    }

    @Test fun resumeWaitsForActualRetiredRestoreDrainAndUsesOriginalSignedInOwner() = runTest {
        val actions = Actions()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val resumed = mutableListOf<PickerAccountSnapshot>()
        actions.select = { current ->
            withContext(NonCancellable) {
                entered.complete(Unit); release.await(); assertFalse(current()); actions.candidate
            }
        }
        controller(backgroundScope, Accounts(), actions).use { controller ->
            try {
                val original = controller.openRoute()
                controller.restore(original); runCurrent()
                controller.deliverInput(); runCurrent()
                assertTrue(entered.isCompleted)
                controller.closeTools(original.attachment)
                controller.open(original.attachment)
                val reopened = checkNotNull(controller.renderedActions(original.attachment))
                controller.resumeRecoverySync(original) { throw AssertionError("closed presentation reached resume") }
                controller.resumeRecoverySync(reopened) { throw AssertionError("undrained selection reached resume") }
                runCurrent()
                assertEquals(PickerToolsPhase.CANCELLING, controller.state.value.phase)
                assertFalse(controller.state.value.cancellingFileSave)
                release.complete(Unit); runCurrent()
                assertEquals(1, actions.candidate.closes)
                controller.resumeRecoverySync(reopened) { resumed += it; true }
                runCurrent()
                assertSame(original.original, resumed.single())
                assertEquals("Regular sync resumed.", controller.state.value.message)
                assertEquals(0, actions.candidate.confirmations)
            } finally { release.complete(Unit) }
        }
    }

    @Test fun staleOwnerAndSignedOutGrantCannotResumeEvenWithAQueuedCallback() = runTest {
        val accounts = Accounts()
        controller(backgroundScope, accounts, Actions()).use { controller ->
            val original = controller.openRoute()
            accounts.replace(differentAccount = true)
            controller.resumeRecoverySync(original) { throw AssertionError("retired owner reached resume") }
            runCurrent()
        }
        controller(backgroundScope, Accounts(signedIn = false), Actions()).use { controller ->
            controller.resumeRecoverySync(controller.openRoute()) { throw AssertionError("signed-out owner reached resume") }
            runCurrent()
            assertEquals(PickerToolsPhase.IDLE, controller.state.value.phase)
        }
    }

    @Test fun ordinaryOwnerCanVerifyRetainedStatusButMissingDoesNotLaunchFileSelection() = runTest {
        val actions = Actions().also { it.selectionAllowed = false }
        val operation = UUID.randomUUID()
        controller(backgroundScope, Accounts(), actions).use { controller ->
            val original = controller.openRoute()
            controller.restore(original); runCurrent()
            assertNull(controller.state.value.restoreInput)
            assertTrue(checkNotNull(controller.state.value.message).contains("Sign in for backup recovery"))
            assertTrue(actions.inputOwners.isEmpty())
            actions.status = FileRestoreStatus.Retained(operation, 7L, JournalState.DeliveryUnconfirmed)
            controller.restore(original); runCurrent()
            val verify = checkNotNull(controller.state.value.restoreStatus?.verify)
            controller.verifyRestore(original, verify); runCurrent()
            assertSame(original, actions.verifies.single().first)
            assertEquals(operation, actions.verifies.single().second)
            assertTrue(actions.inputOwners.isEmpty())
        }
    }

    @Test fun lostPauseRefusesChooserAndRetiredConfirmationNeverSubmits() = runTest {
        val beforeLaunch = Actions()
        controller(backgroundScope, Accounts(), beforeLaunch).use { controller ->
            val original = controller.openRoute()
            controller.restore(original); runCurrent()
            val request = checkNotNull(controller.state.value.restoreInput)
            beforeLaunch.selectionAllowed = false
            assertFalse(controller.claimRestoreInputLaunch(request))
            controller.restoreInputReturned(request, Input); runCurrent()
            assertNull(controller.state.value.restoreInput)
            assertTrue(beforeLaunch.inputOwners.isEmpty())
        }
        val beforeConfirmation = Actions()
        controller(backgroundScope, Accounts(), beforeConfirmation).use { controller ->
            val original = controller.openRoute()
            controller.restore(original); runCurrent()
            val request = controller.deliverInput(); runCurrent()
            assertNotNull(controller.state.value.restoreReview)
            beforeConfirmation.selectionAllowed = false
            controller.confirmRestore(original, request, approved = true); runCurrent()
            assertEquals(0, beforeConfirmation.candidate.confirmations)
            assertEquals(1, beforeConfirmation.candidate.closes)
            assertNull(controller.state.value.restoreReview)
        }
    }

    @Test fun separateActivitySlotsCannotResumeThroughSharedRecoveryGateUntilOtherHolderActuallyDrains() = runTest {
        val managerGate = PickerToolsWorkGate()
        val phoneGate = PickerToolsWorkGate()
        val tvGate = PickerToolsWorkGate()
        val actions = Actions()
        val entered = CompletableDeferred<Unit>()
        val returnFromProvider = CompletableDeferred<Unit>()
        val resumed = mutableListOf<PickerAccountSnapshot>()
        actions.select = { current ->
            withContext(NonCancellable) {
                entered.complete(Unit)
                returnFromProvider.await()
                assertFalse(current())
                actions.candidate
            }
        }
        val phone = controller(backgroundScope, Accounts(), actions, phoneGate, managerGate)
        // A default-null replacement must still share the recovery gate for its paused Resume exit.
        val tv = controller(backgroundScope, Accounts(), gate = tvGate, recoveryGate = managerGate)
        try {
            val phoneOwner = phone.openRoute()
            val tvOwner = tv.openRoute()
            phone.restore(phoneOwner); runCurrent()
            assertNotNull(phone.state.value.restoreInput)
            assertTrue(phone.recoveryBusy.value)
            assertTrue(tv.recoveryBusy.value)
            assertFalse(tvGate.busy.value)
            tv.resumeRecoverySync(tvOwner) { throw AssertionError("Resume overlapped the other holder's SAF selection") }
            runCurrent()
            phone.deliverInput(); runCurrent()
            assertTrue(entered.isCompleted)
            phone.close()
            tv.resumeRecoverySync(tvOwner) { throw AssertionError("Resume overlapped retired provider cleanup") }
            runCurrent()
            assertTrue(managerGate.busy.value)
            assertFalse(tvGate.busy.value)
            assertEquals(0, actions.candidate.closes)
            returnFromProvider.complete(Unit); runCurrent()
            assertEquals(1, actions.candidate.closes)
            assertFalse(phoneGate.busy.value)
            assertFalse(tv.recoveryBusy.value)
            tv.resumeRecoverySync(tvOwner) { resumed += it; true }
            runCurrent()
            assertSame(tvOwner.original, resumed.single())
            assertFalse(managerGate.busy.value)
        } finally {
            returnFromProvider.complete(Unit)
            phone.close()
            tv.close()
        }
    }
}
