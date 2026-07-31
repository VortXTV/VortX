package com.vortx.android.integrations

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class CredentialMutationCoordinatorTest {

    @Test
    fun signOutDuringAwaitCannotRepublishAndDoesNotWaitForNetwork() = runBlocking {
        val coordinator = CredentialMutationCoordinator()
        val operation = coordinator.operation()
        val store = FakeCredentialStore()
        val persistence = TraktAuth.TokenPersistence(store) { NOW }
        val requestStarted = CompletableDeferred<Unit>()
        val releaseResponse = CompletableDeferred<Unit>()

        val publication = async(Dispatchers.Default) {
            operation.publishAfter(
                awaitValue = {
                    requestStarted.complete(Unit)
                    releaseResponse.await()
                    NEW_TOKEN
                },
                publish = {
                    persistence.save(it)
                    it
                },
            )
        }
        requestStarted.await()

        val signOut = async(Dispatchers.Default) {
            coordinator.invalidate(persistence::clear)
        }
        val signOutCompletedBeforeResponse = withTimeoutOrNull(2_000L) {
            signOut.await()
            true
        } ?: false

        releaseResponse.complete(Unit)
        val result = publication.await()
        signOut.await()

        assertTrue("Network await must not hold the mutation lock", signOutCompletedBeforeResponse)
        assertSame(CredentialMutationResult.Stale, result)
        assertFalse("A stale response must not publish credentials", persistence.isSignedIn)
    }

    @Test
    fun simklPollResponseAfterSignOutCannotPublish() = runBlocking {
        val coordinator = CredentialMutationCoordinator()
        val operation = coordinator.operation()
        val store = FakeCredentialStore()
        val persistence = SIMKLAuth.TokenPersistence(store) { NOW }
        val requestStarted = CompletableDeferred<Unit>()
        val releaseResponse = CompletableDeferred<Unit>()

        val publication = async(Dispatchers.Default) {
            operation.publishAfter(
                awaitValue = {
                    requestStarted.complete(Unit)
                    releaseResponse.await()
                    "simkl-token"
                },
                publish = {
                    persistence.save(it)
                    it
                },
            )
        }
        requestStarted.await()
        coordinator.invalidate(persistence::clear)
        releaseResponse.complete(Unit)

        assertSame(CredentialMutationResult.Stale, publication.await())
        assertFalse(persistence.isSignedIn)
    }

    @Test
    fun refresh200CannotOverwriteNewerDeviceFlowLineage() = runBlocking {
        val coordinator = CredentialMutationCoordinator()
        val store = FakeCredentialStore(oldTokenValues())
        val persistence = TraktAuth.TokenPersistence(store) { NOW }
        val snapshot = coordinator.snapshot(persistence::loadStored)
        val spentToken = requireNotNull(snapshot.value)
        val requestStarted = CompletableDeferred<Unit>()
        val releaseResponse = CompletableDeferred<Unit>()

        val refreshPublication = async(Dispatchers.Default) {
            snapshot.operation.publishAfter(
                awaitValue = {
                    requestStarted.complete(Unit)
                    releaseResponse.await()
                    NEW_TOKEN
                },
                publish = { candidate ->
                    persistence.saveRefreshIfCurrent(spentToken.lineage, candidate)
                },
            )
        }
        requestStarted.await()

        assertEquals(spentToken.token.accessToken, DEVICE_TOKEN.accessToken)
        assertEquals(spentToken.token.refreshToken, DEVICE_TOKEN.refreshToken)
        assertEquals(spentToken.token.expiresAtSeconds, DEVICE_TOKEN.expiresAtSeconds)
        assertFalse("Only persisted createdAt differs", spentToken.token.createdAt == DEVICE_TOKEN.createdAt)
        val devicePublication = coordinator.operation().mutate {
            persistence.save(DEVICE_TOKEN)
            DEVICE_TOKEN
        }
        assertEquals(CredentialMutationResult.Applied(DEVICE_TOKEN), devicePublication)

        releaseResponse.complete(Unit)

        assertEquals(
            CredentialMutationResult.Applied(DEVICE_TOKEN),
            refreshPublication.await(),
        )
        assertEquals(DEVICE_TOKEN, persistence.load())
        assertEquals(DEVICE_TOKEN, TraktAuth.TokenPersistence(store.reopen()) { NOW }.load())
    }

    @Test
    fun publishAndSignOutClearAreOrderedByOneMutationLock() {
        val coordinator = CredentialMutationCoordinator()
        val operation = coordinator.operation()
        val publishEntered = CountDownLatch(1)
        val releasePublish = CountDownLatch(1)
        val clearCalling = CountDownLatch(1)
        val clearEntered = CountDownLatch(1)
        val publishFailure = AtomicReference<Throwable?>()
        val clearFailure = AtomicReference<Throwable?>()
        var durableToken: String? = "old-token"

        val publishThread = thread(name = "credential-publish") {
            runCatching {
                operation.mutate {
                    publishEntered.countDown()
                    check(releasePublish.await(2, TimeUnit.SECONDS))
                    durableToken = "new-token"
                }
            }.onFailure(publishFailure::set)
        }
        assertTrue(publishEntered.await(2, TimeUnit.SECONDS))

        val clearThread = thread(name = "credential-clear") {
            runCatching {
                clearCalling.countDown()
                coordinator.invalidate {
                    clearEntered.countDown()
                    durableToken = null
                }
            }.onFailure(clearFailure::set)
        }
        assertTrue(clearCalling.await(2, TimeUnit.SECONDS))

        try {
            assertFalse(
                "Clear entered while credential publication still held the mutation lock",
                clearEntered.await(250, TimeUnit.MILLISECONDS),
            )
        } finally {
            releasePublish.countDown()
            publishThread.join(2_000L)
            clearThread.join(2_000L)
        }

        assertNull(publishFailure.get())
        assertNull(clearFailure.get())
        assertTrue(clearEntered.await(2, TimeUnit.SECONDS))
        assertNull("Sign-out must be the final durable mutation", durableToken)
    }

    @Test
    fun failedClearInvalidatesOldOperationButLaterOperationCanPublish() {
        val store = FakeCredentialStore(oldTokenValues()).apply { rejectWrites = true }
        val persistence = TraktAuth.TokenPersistence(store) { NOW }
        val coordinator = CredentialMutationCoordinator()
        val oldOperation = coordinator.snapshot(persistence::load).operation

        assertThrows(TraktAuthException.SecureStorage::class.java) {
            coordinator.invalidate(persistence::clear)
        }
        assertEquals(CredentialConnectionState.CONNECTED, persistence.connectionState)
        assertEquals(OLD_TOKEN, persistence.load())
        assertSame(
            CredentialMutationResult.Stale,
            oldOperation.mutate { persistence.save(NEW_TOKEN) },
        )
        assertEquals(OLD_TOKEN, persistence.load())

        store.rejectWrites = false
        val newOperation = coordinator.operation()
        val result = newOperation.mutate {
            persistence.save(NEW_TOKEN)
            NEW_TOKEN
        }

        assertEquals(CredentialMutationResult.Applied(NEW_TOKEN), result)
        assertEquals(NEW_TOKEN, persistence.load())
    }

    private fun oldTokenValues(): Map<String, String> = mapOf(
        ACCESS_KEY to OLD_TOKEN.accessToken,
        REFRESH_KEY to OLD_TOKEN.refreshToken,
        EXPIRY_KEY to OLD_TOKEN.expiresAtSeconds.toString(),
        CREATED_KEY to OLD_TOKEN.createdAt.toString(),
    )

    private companion object {
        const val NOW = 1_000L
        const val ACCESS_KEY = "vortx.trakt.accessToken"
        const val REFRESH_KEY = "vortx.trakt.refreshToken"
        const val EXPIRY_KEY = "vortx.trakt.expiresAt"
        const val CREATED_KEY = "vortx.trakt.createdAt"
        val OLD_TOKEN = TraktToken("old-access", "old-refresh", expiresIn = 10_000L, createdAt = NOW)
        val NEW_TOKEN = TraktToken("new-access", "new-refresh", expiresIn = 10_000L, createdAt = NOW)
        val DEVICE_TOKEN = TraktToken("old-access", "old-refresh", expiresIn = 9_000L, createdAt = 2_000L)
    }
}
