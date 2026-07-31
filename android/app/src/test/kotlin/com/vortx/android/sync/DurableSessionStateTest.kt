package com.vortx.android.sync

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Job
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class DurableSessionStateTest {

    @Test
    fun pendingSyncRetriesAfterFailureAndCompletesOnlyAfterSuccess() = runBlocking {
        val waits = mutableListOf<Long>()
        var attempts = 0
        var pending = true

        val completed = runPendingSyncRetryLoop(
            initialDelayMs = 10,
            maxDelayMs = 40,
            shouldContinue = { true },
            wait = { waits += it },
            attempt = {
                attempts += 1
                attempts == 5
            },
        )
        if (completed) pending = false

        assertTrue(completed)
        assertFalse(pending)
        assertEquals(5, attempts)
        assertEquals(listOf(10L, 20L, 40L, 40L, 40L), waits)
    }

    @Test
    fun durablePendingMarkerRestoresAfterProcessRestartBeforeAnyPull() {
        val storage = FakePendingMarkerStore()
        val owner = pendingOwner()
        val firstState = storage.openPendingState()
        val firstAttempt = PendingSyncAttempt(owner)

        firstState.recordEdit(owner, firstAttempt)

        assertTrue(storage.durable)
        val restartedStorage = storage.restartProcess()
        val restartedState = restartedStorage.openPendingState()
        val restoredAttempt = PendingSyncAttempt(owner)
        val restored = restartedState.claimRestored(owner, restoredAttempt)

        assertTrue(restored.blockPull)
        assertTrue(restored.attemptToStart === restoredAttempt)
    }

    @Test
    fun failedMarkerCommitIsNotMistakenForDurabilityAfterMutatingTheProcessCache() {
        val storage = FakePendingMarkerStore().apply { rejectWrites = true }
        val owner = pendingOwner()
        val state = storage.openPendingState()
        val firstAttempt = PendingSyncAttempt(owner)
        val firstJob = Job()

        state.recordEdit(owner, firstAttempt)
        assertTrue(state.attachJob(firstAttempt, firstJob))
        assertTrue(storage.cache)
        assertFalse(storage.durable)
        assertFalse(state.ensureMarker(firstAttempt, firstJob))
        assertEquals(2, storage.writeCalls)

        state.resetTransient()
        val resumedAttempt = PendingSyncAttempt(owner)
        val resumed = state.claimRestored(owner, resumedAttempt)
        val resumedJob = Job()
        assertTrue(resumed.blockPull)
        assertTrue(resumed.attemptToStart === resumedAttempt)
        assertTrue(state.attachJob(resumedAttempt, resumedJob))

        storage.rejectWrites = false
        assertTrue(state.ensureMarker(resumedAttempt, resumedJob))
        assertTrue(storage.durable)
        firstJob.cancel()
        resumedJob.cancel()
    }

    @Test
    fun failedDurableClearKeepsDirtyAndRetriesUntilTheAcceptedPushCanClear() {
        val storage = FakePendingMarkerStore()
        val owner = pendingOwner()
        val state = storage.openPendingState()
        val attempt = PendingSyncAttempt(owner)
        val job = Job()
        state.recordEdit(owner, attempt)
        assertTrue(state.attachJob(attempt, job))
        storage.rejectClears = true

        assertFalse(state.completeAccepted(attempt, job) { true })
        assertTrue(state.claimRestored(owner, PendingSyncAttempt(owner)).blockPull)
        storage.rejectClears = false
        assertTrue(state.ensureMarker(attempt, job))
        assertTrue(state.completeAccepted(attempt, job) { true })
        assertFalse(state.claimRestored(owner, PendingSyncAttempt(owner)).blockPull)
        assertFalse(storage.durable)
        job.cancel()
    }

    @Test
    fun acceptedPushACannotClearTheMarkerWrittenByNewerEditB() {
        val storage = FakePendingMarkerStore()
        val owner = pendingOwner()
        val state = storage.openPendingState()
        val attemptA = PendingSyncAttempt(owner)
        val jobA = Job()
        state.recordEdit(owner, attemptA)
        assertTrue(state.attachJob(attemptA, jobA))

        val attemptB = PendingSyncAttempt(owner)
        val jobB = Job()
        val replacement = state.recordEdit(owner, attemptB)
        assertTrue(replacement.replacedJob === jobA)
        assertTrue(state.attachJob(attemptB, jobB))

        assertFalse(state.completeAccepted(attemptA, jobA) { true })
        assertTrue(storage.durable)
        assertTrue(state.completeAccepted(attemptB, jobB) { true })
        assertFalse(storage.durable)
        jobA.cancel()
        jobB.cancel()
    }

    @Test
    fun confirmedDirtyTruthSurvivesDetachAndRebindsToTheNewSessionGeneration() {
        val storage = FakePendingMarkerStore()
        val operations = SessionOperationCoordinator()
        val oldOwner = pendingOwner().copy(
            operationGeneration = operations.snapshot { it },
        )
        val state = storage.openPendingState()
        val oldAttempt = PendingSyncAttempt(oldOwner)
        val oldJob = Job()
        state.recordEdit(oldOwner, oldAttempt)
        assertTrue(state.attachJob(oldAttempt, oldJob))

        var retainedGeneration = -1L
        assertFalse(
            operations.invalidate {
                retainedGeneration = operations.snapshot { it }
                state.resetTransient()
                false
            },
        )
        val reboundOwner = oldOwner.copy(operationGeneration = retainedGeneration)
        val reboundAttempt = PendingSyncAttempt(reboundOwner)
        val rebound = state.claimRestored(reboundOwner, reboundAttempt)

        assertTrue(rebound.blockPull)
        assertTrue(rebound.attemptToStart === reboundAttempt)
        assertTrue(storage.durable)
        oldJob.cancel()
    }

    @Test
    fun unknownMarkerReadBlocksPullWithoutInventingAPush() {
        val storage = FakePendingMarkerStore().apply { rejectReads = true }
        val owner = pendingOwner()
        val state = storage.openPendingState()

        val unknown = state.claimRestored(owner, PendingSyncAttempt(owner))

        assertTrue(unknown.blockPull)
        assertNull(unknown.attemptToStart)
        assertEquals(0, storage.writeCalls)

        storage.rejectReads = false
        val clean = state.claimRestored(owner, PendingSyncAttempt(owner))
        assertFalse(clean.blockPull)
        assertNull(clean.attemptToStart)
        assertEquals(0, storage.writeCalls)
    }

    @Test
    fun failedSignOutResumesRealtimeOnlyWhenItWasPreviouslyActive() {
        assertFalse(
            shouldResumeRetainedRealtime(
                hadActiveRealtime = false,
                retainedSessionIsCurrent = true,
            ),
        )
        assertTrue(
            shouldResumeRetainedRealtime(
                hadActiveRealtime = true,
                retainedSessionIsCurrent = true,
            ),
        )
        assertFalse(
            shouldResumeRetainedRealtime(
                hadActiveRealtime = true,
                retainedSessionIsCurrent = false,
            ),
        )
    }

    @Test
    fun registerStorageFailureRetainsTheAlreadyMintedRecoveryCode() {
        val result = VortXSyncManager.RegisterResult.secureStorageFailure("recovery-code")

        assertEquals("recovery-code", result.recoveryCode)
        assertTrue(result.result is VortXSyncManager.AuthResult.Failed)
        assertTrue(
            (result.result as VortXSyncManager.AuthResult.Failed).message.contains("account was created"),
        )
    }

    @Test
    fun persistedSessionReloadMatchesByKeyBytesAndRejectsChangedTruth() {
        val account = VortXSyncManager.Account(
            id = "account-a",
            email = "a@example.test",
            username = "account-a",
            twoFactorEnabled = false,
        )
        val live = VortXSyncManager.Session("token-a", account, byteArrayOf(1, 2, 3))
        val identicalReload = VortXSyncManager.Session("token-a", account.copy(), byteArrayOf(1, 2, 3))

        assertTrue(sessionTruthMatches(live, identicalReload))
        assertFalse(sessionTruthMatches(live, identicalReload.copy(token = "token-b")))
        assertFalse(
            sessionTruthMatches(
                live,
                identicalReload.copy(account = account.copy(username = "changed")),
            ),
        )
        assertFalse(sessionTruthMatches(live, identicalReload.copy(dataKey = byteArrayOf(1, 2, 4))))
        assertFalse(sessionTruthMatches(live, null))
        assertTrue(sessionTruthMatches(null, null))
    }

    @Test
    fun failedInitialPersistDoesNotPublishOrSurviveRestart() {
        val backend = FakeSessionBackend().apply { rejectPersist = true }
        val state = backend.open()

        assertFalse(state.replace("new-session"))
        assertNull(state.value)
        assertNull(backend.durableValue)
        assertNull(backend.open().value)
    }

    @Test
    fun failedReplacementKeepsPriorPublicAndRestartState() {
        val backend = FakeSessionBackend("old-session", initialOwnerEpoch = 9).apply {
            rejectPersist = true
        }
        val state = backend.open()

        assertFalse(state.replace("new-session"))
        assertEquals("old-session", state.value)
        assertEquals(9L, state.ownerEpoch)
        assertEquals("old-session", backend.durableValue)
        assertEquals(9L, backend.durableOwnerEpoch)
        val restarted = backend.open()
        assertEquals("old-session", restarted.value)
        assertEquals(9L, restarted.ownerEpoch)
    }

    @Test
    fun failedClearKeepsPriorPublicAndRestartState() {
        val backend = FakeSessionBackend("live-session", initialOwnerEpoch = 12).apply {
            rejectClear = true
        }
        val state = backend.open()

        assertFalse(state.clear())
        assertEquals("live-session", state.value)
        assertEquals(12L, state.ownerEpoch)
        assertEquals("live-session", backend.durableValue)
        assertEquals(12L, backend.durableOwnerEpoch)
        val restarted = backend.open()
        assertEquals("live-session", restarted.value)
        assertEquals(12L, restarted.ownerEpoch)
    }

    @Test
    fun successfulMutationsPublishOnlyAfterDurableChange() {
        val backend = FakeSessionBackend()
        val state = backend.open()

        assertTrue(state.replace("live-session"))
        assertEquals("live-session", state.value)
        assertEquals("live-session", backend.open().value)

        assertTrue(state.clear())
        assertNull(state.value)
        assertNull(backend.open().value)
    }

    @Test
    fun tombstoneFailureLeavesThePriorSessionOwnerUnchangedAndUnpublished() {
        val backend = FakeSessionBackend("account-a")
        var persistenceCalls = 0
        var publications = 0
        val state = backend.open(
            ownerTransition = {
                false
            },
        )
        backend.beforePersist = { persistenceCalls += 1 }

        assertFalse(state.replace("account-b") { publications += 1 })
        assertEquals("account-a", state.value)
        assertEquals("account-a", backend.durableValue)
        assertEquals(0, persistenceCalls)
        assertEquals(0, publications)
    }

    @Test
    fun sessionPersistenceFailureAfterTombstoneKeepsPriorOwnerTruth() {
        val backend = FakeSessionBackend("account-a").apply { rejectPersist = true }
        var tombstones = 0
        var publications = 0
        val state = backend.open(
            ownerTransition = { mutation ->
                tombstones += 1
                mutation()
            },
        )

        assertFalse(state.replace("account-b") { publications += 1 })
        assertEquals(1, tombstones)
        assertEquals("account-a", state.value)
        assertEquals("account-a", backend.durableValue)
        assertEquals(0, publications)
    }

    @Test
    fun concurrentSignOutAndAccountReplacementSerializeThroughOneOwnerTransition() {
        val backend = FakeSessionBackend("account-a")
        val transitionLock = Any()
        val clearEntered = CountDownLatch(1)
        val releaseClear = CountDownLatch(1)
        val replacementFinished = CountDownLatch(1)
        val publications = mutableListOf<String>()
        var tombstones = 0
        backend.beforeClear = {
            clearEntered.countDown()
            assertTrue(releaseClear.await(2, TimeUnit.SECONDS))
        }
        val state = backend.open(
            ownerTransition = { mutation ->
                synchronized(transitionLock) {
                    tombstones += 1
                    mutation()
                }
            },
        )

        val signOut = thread {
            assertTrue(state.clear { publications += "signed-out" })
        }
        assertTrue(clearEntered.await(2, TimeUnit.SECONDS))
        val replacement = thread {
            assertTrue(state.replace("account-b") { publications += "account-b" })
            replacementFinished.countDown()
        }
        assertFalse(replacementFinished.await(100, TimeUnit.MILLISECONDS))

        releaseClear.countDown()
        signOut.join(2_000)
        replacement.join(2_000)

        assertFalse(signOut.isAlive)
        assertFalse(replacement.isAlive)
        assertEquals(2, tombstones)
        assertEquals(listOf("signed-out", "account-b"), publications)
        assertEquals("account-b", state.value)
        assertEquals("account-b", backend.durableValue)
    }

    @Test
    fun durableCallbacksObserveThePriorPublicState() {
        lateinit var state: DurableSessionState<String>
        val observed = mutableListOf<String?>()
        state = DurableSessionState(
            initialValue = "old-session",
            persist = {
                observed += state.value
                true
            },
            clear = {
                observed += state.value
                true
            },
        )

        assertTrue(state.replace("new-session"))
        assertTrue(state.clear())

        assertEquals(listOf("old-session", "new-session"), observed)
    }

    @Test
    fun ownerEpochSurvivesRestartAndAdvancesForSameAccountReauthentication() {
        val backend = FakeSessionBackend("account-a", initialOwnerEpoch = 41)
        val state = backend.open()

        assertTrue(state.replace("account-a"))
        assertEquals(42L, state.ownerEpoch)
        assertEquals(42L, backend.durableOwnerEpoch)

        val restarted = backend.open()
        assertEquals("account-a", restarted.value)
        assertEquals(42L, restarted.ownerEpoch)
    }

    @Test
    fun ownerEpochExhaustionFailsClosedWithoutReusingAnOldEpoch() {
        val backend = FakeSessionBackend("account-a", initialOwnerEpoch = Long.MAX_VALUE)
        val state = backend.open()

        assertFalse(state.replace("account-b"))
        assertFalse(state.clear())
        assertEquals("account-a", state.value)
        assertEquals(Long.MAX_VALUE, state.ownerEpoch)
        assertEquals("account-a", backend.durableValue)
        assertEquals(Long.MAX_VALUE, backend.durableOwnerEpoch)
    }

    @Test
    fun laterAuthenticationAdoptsBAndRejectsDelayedA() {
        val backend = FakeSessionBackend("account-old", initialOwnerEpoch = 4)
        val state = backend.open()
        val operations = SessionOperationCoordinator()
        val syncGeneration = operations.snapshot { it }
        var cancelledSyncCalls = 0
        val syncCall = requireNotNull(
            operations.acquireSessionCallPermit(syncGeneration) { true },
        )
        assertTrue(syncCall.attachCancellation { cancelledSyncCalls += 1 })
        val authA = operations.beginAuth()
        var cancelledAuthCalls = 0
        val authACall = requireNotNull(authA.acquireCallPermit())
        assertTrue(authACall.attachCancellation { cancelledAuthCalls += 1 })
        val authB = operations.beginAuth()
        var cancelledSessionWork = 0

        val adoptedB = authB.commitSessionMutation(
            onCommitted = { cancelledSessionWork += 1 },
        ) {
            state.replace("account-b")
        }
        var delayedARan = false
        val delayedA = authA.commitSessionMutation {
            delayedARan = true
            state.replace("account-a")
        }

        assertEquals(SessionMutationResult.Applied(true), adoptedB)
        assertEquals(1, cancelledAuthCalls)
        assertFalse(authACall.isCurrent())
        assertEquals(1, cancelledSyncCalls)
        assertFalse(syncCall.isCurrent())
        assertEquals(1, cancelledSessionWork)
        assertEquals(SessionMutationResult.Stale, delayedA)
        assertFalse(delayedARan)
        assertEquals("account-b", state.value)
        assertEquals(5L, state.ownerEpoch)
    }

    @Test
    fun retiredPermitCannotAttachAfterACompetingAuthWins() {
        val operations = SessionOperationCoordinator()
        val authA = operations.beginAuth()
        val permitA = requireNotNull(authA.acquireCallPermit())

        operations.beginAuth()
        var cancellations = 0

        assertFalse(permitA.attachCancellation { cancellations += 1 })
        assertEquals(0, cancellations)
        assertFalse(permitA.isCurrent())
    }

    @Test
    fun permitCancellationRunsAfterTheCoordinatorLockIsReleased() {
        val operations = SessionOperationCoordinator()
        val auth = operations.beginAuth()
        val permit = requireNotNull(auth.acquireCallPermit())
        var cancellationObservedUnlockedCoordinator = false
        assertTrue(
            permit.attachCancellation {
                val completed = CountDownLatch(1)
                val reader = thread {
                    operations.snapshot { it }
                    completed.countDown()
                }
                cancellationObservedUnlockedCoordinator =
                    completed.await(2, TimeUnit.SECONDS)
                reader.join(2_000)
            },
        )

        operations.beginAuth()

        assertTrue(cancellationObservedUnlockedCoordinator)
    }

    @Test
    fun failedAuthenticationPersistenceKeepsExistingSyncLeaseAndWorkCurrent() {
        val backend = FakeSessionBackend("account-a", initialOwnerEpoch = 6).apply {
            rejectPersist = true
        }
        val state = backend.open()
        val operations = SessionOperationCoordinator()
        val syncGeneration = operations.snapshot { it }
        var cancelledSyncCalls = 0
        val syncCall = requireNotNull(
            operations.acquireSessionCallPermit(syncGeneration) { true },
        )
        assertTrue(syncCall.attachCancellation { cancelledSyncCalls += 1 })
        val auth = operations.beginAuth()
        var cancelledSessionWork = false

        val adoption = auth.commitSessionMutation(
            onCommitted = { cancelledSessionWork = true },
        ) {
            state.replace("account-b")
        }

        assertEquals(SessionMutationResult.Applied(false), adoption)
        assertFalse(cancelledSessionWork)
        assertEquals(0, cancelledSyncCalls)
        assertTrue(syncCall.isCurrent())
        assertTrue(operations.isCurrent(syncGeneration))
        assertEquals("account-a", state.value)
        assertEquals(6L, state.ownerEpoch)
        syncCall.close()
    }

    @Test
    fun failedSignOutRetainsDurableSessionButInvalidatesAuthAndSyncLeases() {
        val backend = FakeSessionBackend("account-a", initialOwnerEpoch = 7).apply {
            rejectClear = true
        }
        val state = backend.open()
        val operations = SessionOperationCoordinator()
        val authA = operations.beginAuth()
        var cancelledAuthCalls = 0
        val authCall = requireNotNull(authA.acquireCallPermit())
        assertTrue(authCall.attachCancellation { cancelledAuthCalls += 1 })
        val syncGeneration = operations.snapshot { it }
        var cancelledSyncCalls = 0
        val syncCall = requireNotNull(
            operations.acquireSessionCallPermit(syncGeneration) { true },
        )
        assertTrue(syncCall.attachCancellation { cancelledSyncCalls += 1 })
        var retainedGeneration = -1L
        val retainedEpoch = state.ownerEpoch
        var pendingPush = true

        assertFalse(
            operations.invalidate {
                retainedGeneration = operations.snapshot { it }
                pendingPush = false
                state.clear()
            },
        )
        assertFalse(authA.isCurrent())
        assertFalse(operations.isCurrent(syncGeneration))
        assertEquals(1, cancelledAuthCalls)
        assertFalse(authCall.isCurrent())
        assertEquals(1, cancelledSyncCalls)
        assertFalse(syncCall.isCurrent())
        val rearmed = operations.mutateIfCurrent(retainedGeneration) {
            if (state.matches(retainedEpoch) { it == "account-a" }) {
                pendingPush = true
            }
        }
        assertEquals(SessionMutationResult.Applied(Unit), rearmed)
        assertTrue(pendingPush)
        assertEquals(
            SessionMutationResult.Stale,
            authA.commitSessionMutation { state.replace("delayed-account-a") },
        )
        assertEquals("account-a", state.value)
        assertEquals(7L, state.ownerEpoch)
        assertEquals("account-a", backend.durableValue)
        assertEquals(7L, backend.durableOwnerEpoch)
    }

    @Test
    fun pausedAccountASyncLeaseCannotPublishAfterAccountSwitchAndKeepsAIdentity() {
        val backend = FakeSessionBackend("account-a", initialOwnerEpoch = 20)
        val state = backend.open()
        val operations = SessionOperationCoordinator()
        val originalKey = byteArrayOf(1, 2, 3)
        val lease = operations.snapshot { operationGeneration ->
            SyncSessionLease(
                operationGeneration = operationGeneration,
                ownerEpoch = state.ownerEpoch,
                accountId = "account-a",
                token = "token-a",
                dataKey = originalKey,
            )
        }
        originalKey[0] = 99

        val authB = operations.beginAuth()
        val adoptedB = authB.commitSessionMutation { state.replace("account-b") }
        var stalePullPublished = false
        val stalePublication = operations.mutateIfCurrent(lease.operationGeneration) {
            stalePullPublished = true
        }

        assertEquals(SessionMutationResult.Applied(true), adoptedB)
        assertEquals(SessionMutationResult.Stale, stalePublication)
        assertFalse(stalePullPublished)
        assertEquals("account-a", lease.accountId)
        assertEquals("token-a", lease.token)
        assertArrayEquals(byteArrayOf(1, 2, 3), lease.dataKeyCopy())
        val callerCopy = lease.dataKeyCopy()
        callerCopy[1] = 88
        assertArrayEquals(byteArrayOf(1, 2, 3), lease.dataKeyCopy())
        assertEquals("account-b", state.value)
        assertEquals(21L, state.ownerEpoch)
    }

    @Test
    fun serializedRestoreCannotRepublishAStaleSessionAfterClear() {
        val backend = FakeSessionBackend("account-a")
        val state = backend.open()
        val restoreLoaded = CountDownLatch(1)
        val letRestoreFinish = CountDownLatch(1)
        val clearFinished = CountDownLatch(1)

        val restore = thread {
            state.serialized {
                val loadedBeforeClear = backend.durableValue
                restoreLoaded.countDown()
                assertTrue(letRestoreFinish.await(2, TimeUnit.SECONDS))
                state.restore(loadedBeforeClear)
            }
        }
        assertTrue(restoreLoaded.await(2, TimeUnit.SECONDS))

        val clear = thread {
            assertTrue(state.clear())
            clearFinished.countDown()
        }
        assertFalse(clearFinished.await(100, TimeUnit.MILLISECONDS))

        letRestoreFinish.countDown()
        restore.join(2_000)
        clear.join(2_000)

        assertEquals(0L, clearFinished.count)
        assertNull(state.value)
        assertNull(backend.durableValue)
    }

    @Test
    fun mutationCannotAcquireOwnerTransitionFromInsideSessionMonitor() {
        val state = FakeSessionBackend("account-a").open()

        assertThrows(IllegalStateException::class.java) {
            state.serialized { state.clear() }
        }
        assertEquals("account-a", state.value)
    }

    private class FakeSessionBackend(
        initialValue: String? = null,
        initialOwnerEpoch: Long = INITIAL_SESSION_OWNER_EPOCH,
    ) {
        @Volatile
        var durableValue: String? = initialValue
        @Volatile
        var durableOwnerEpoch: Long = initialOwnerEpoch
        var rejectPersist = false
        var rejectClear = false
        var beforePersist: (String) -> Unit = {}
        var beforeClear: () -> Unit = {}

        fun open(
            ownerTransition: ((() -> Boolean) -> Boolean) = { mutation -> mutation() },
        ): DurableSessionState<String> = DurableSessionState(
            initialValue = durableValue,
            initialOwnerEpoch = durableOwnerEpoch,
            persist = { candidate, nextOwnerEpoch ->
                beforePersist(candidate)
                if (rejectPersist) {
                    false
                } else {
                    durableValue = candidate
                    durableOwnerEpoch = nextOwnerEpoch
                    true
                }
            },
            clear = { nextOwnerEpoch ->
                beforeClear()
                if (rejectClear) {
                    false
                } else {
                    durableValue = null
                    durableOwnerEpoch = nextOwnerEpoch
                    true
                }
            },
            ownerTransition = ownerTransition,
        )
    }

    private class FakePendingMarkerStore(
        var durable: Boolean = false,
        var cache: Boolean = durable,
    ) {
        var rejectWrites = false
        var rejectClears = false
        var rejectReads = false
        var writeCalls = 0

        fun openPendingState(): DurablePendingSyncState =
            DurablePendingSyncState(
                readDirty = {
                    if (rejectReads) error("marker read unavailable")
                    cache
                },
                writeDirty = { _, pending ->
                    writeCalls += 1
                    cache = pending
                    if ((pending && rejectWrites) || (!pending && rejectClears)) {
                        false
                    } else {
                        durable = pending
                        true
                    }
                },
            )

        fun restartProcess(): FakePendingMarkerStore =
            FakePendingMarkerStore(durable = durable, cache = durable)
    }

    private fun pendingOwner(): PendingSyncOwner =
        PendingSyncOwner(
            operationGeneration = 3,
            ownerEpoch = 7,
            accountId = "account-a",
            token = "token-a",
        )
}
