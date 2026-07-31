package com.vortx.android.sync

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
    fun registerStorageFailureRetainsTheAlreadyMintedRecoveryCode() {
        val result = VortXSyncManager.RegisterResult.secureStorageFailure("recovery-code")

        assertEquals("recovery-code", result.recoveryCode)
        assertTrue(result.result is VortXSyncManager.AuthResult.Failed)
        assertTrue(
            (result.result as VortXSyncManager.AuthResult.Failed).message.contains("account was created"),
        )
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
        val backend = FakeSessionBackend("old-session").apply { rejectPersist = true }
        val state = backend.open()

        assertFalse(state.replace("new-session"))
        assertEquals("old-session", state.value)
        assertEquals("old-session", backend.durableValue)
        assertEquals("old-session", backend.open().value)
    }

    @Test
    fun failedClearKeepsPriorPublicAndRestartState() {
        val backend = FakeSessionBackend("live-session").apply { rejectClear = true }
        val state = backend.open()

        assertFalse(state.clear())
        assertEquals("live-session", state.value)
        assertEquals("live-session", backend.durableValue)
        assertEquals("live-session", backend.open().value)
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
    fun productionOwnerTrackerAdvancesFromUnavailableToAccountAndDefinitiveSignOut() {
        val tracker = SessionOwnerGenerationTracker(
            PersistentSessionOwnerState.UnknownOrUnavailable,
        )

        assertEquals(1L, tracker.observe(PersistentSessionOwnerState.UnknownOrUnavailable))
        assertEquals(2L, tracker.observe(PersistentSessionOwnerState.Account("account-a")))
        assertEquals(2L, tracker.observe(PersistentSessionOwnerState.Account("account-a")))
        assertEquals(3L, tracker.observe(PersistentSessionOwnerState.SignedOutLocal))
    }

    @Test
    fun productionOwnerTrackerInvalidatesTokensForSameAccountSessionMutation() {
        val tracker = SessionOwnerGenerationTracker(
            PersistentSessionOwnerState.Account("account-a"),
        )

        assertEquals(2L, tracker.recordMutation(PersistentSessionOwnerState.Account("account-a")))
        assertEquals(2L, tracker.observe(PersistentSessionOwnerState.Account("account-a")))
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

    private class FakeSessionBackend(initialValue: String? = null) {
        @Volatile
        var durableValue: String? = initialValue
        var rejectPersist = false
        var rejectClear = false
        var beforePersist: (String) -> Unit = {}
        var beforeClear: () -> Unit = {}

        fun open(
            ownerTransition: ((() -> Boolean) -> Boolean) = { mutation -> mutation() },
        ): DurableSessionState<String> = DurableSessionState(
            initialValue = durableValue,
            persist = {
                beforePersist(it)
                if (rejectPersist) {
                    false
                } else {
                    durableValue = it
                    true
                }
            },
            clear = {
                beforeClear()
                if (rejectClear) {
                    false
                } else {
                    durableValue = null
                    true
                }
            },
            ownerTransition = ownerTransition,
        )
    }
}
