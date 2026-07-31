package com.vortx.android.ui.screens

import com.vortx.android.integrations.CredentialConnectionState
import com.vortx.android.integrations.FakeCredentialStore
import com.vortx.android.integrations.SIMKLException
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.integrations.TraktAuthException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IntegrationsDisconnectStateTest {

    @Test
    fun successfulDisconnectPublishesIdle() {
        assertEquals(ConnectUi.Idle, disconnectProvider { })
    }

    @Test
    fun traktStorageFailureKeepsConnectedAndSurfacesStatus() {
        val result = disconnectProvider { throw TraktAuthException.SecureStorage }

        assertEquals(
            ConnectUi.Connected(TraktAuthException.SecureStorage.message),
            result,
        )
    }

    @Test
    fun simklStorageFailureKeepsConnectedAndSurfacesStatus() {
        val result = disconnectProvider { throw SIMKLException.SecureStorage }

        assertEquals(
            ConnectUi.Connected(SIMKLException.SecureStorage.message),
            result,
        )
    }

    @Test
    fun unavailablePersistentReadSurfacesErrorInsteadOfSignedOut() {
        assertEquals(
            ConnectUi.StorageUnavailable(TraktAuthException.SecureStorage.message!!),
            initialProviderState(
                CredentialConnectionState.STORAGE_UNAVAILABLE,
                TraktAuthException.SecureStorage.message!!,
            ),
        )
    }

    @Test
    fun availablePersistentReadMapsExactConnectionTruth() {
        assertEquals(
            ConnectUi.Connected(),
            initialProviderState(CredentialConnectionState.CONNECTED, "unavailable"),
        )
        assertEquals(
            ConnectUi.Idle,
            initialProviderState(CredentialConnectionState.DISCONNECTED, "unavailable"),
        )
    }

    @Test
    fun storageRetryReevaluatesConnectionStateAndPublishesRecoveredTruth() {
        val store = FakeCredentialStore(completeTraktTokenValues()).apply {
            persistentAvailable = false
        }
        val persistence = TraktAuth.TokenPersistence(store)
        var reads = 0
        val readState = {
            reads += 1
            persistence.connectionState
        }

        assertEquals(
            ConnectUi.StorageUnavailable("storage unavailable"),
            retryStorageUnavailable(readState, "storage unavailable"),
        )

        store.persistentAvailable = true

        assertEquals(
            ConnectUi.Connected(),
            retryStorageUnavailable(readState, "storage unavailable"),
        )
        assertEquals(2, reads)
    }

    @Test
    fun storageRetryRejectsPartialAndCorruptTokenTuples() {
        listOf(
            completeTraktTokenValues() - "vortx.trakt.refreshToken",
            completeTraktTokenValues() + ("vortx.trakt.expiresAt" to "not-an-expiry"),
        ).forEach { invalidValues ->
            val store = FakeCredentialStore(invalidValues).apply {
                persistentAvailable = false
            }
            val persistence = TraktAuth.TokenPersistence(store)

            assertEquals(
                ConnectUi.StorageUnavailable("storage unavailable"),
                retryStorageUnavailable({ persistence.connectionState }, "storage unavailable"),
            )

            store.persistentAvailable = true

            assertEquals(
                ConnectUi.Idle,
                retryStorageUnavailable({ persistence.connectionState }, "storage unavailable"),
            )
        }
    }

    @Test
    fun staleProviderCompletionAfterSignOutNeverPublishesConnectedUi() = runBlocking {
        listOf<Exception>(
            TraktAuthException.NotSignedIn,
            SIMKLException.NotSignedIn,
        ).forEach { staleCompletion ->
            val states = mutableListOf<ConnectUi>()

            driveConnect(
                onState = states::add,
                requestCode = {
                    ConnectStep("code", "https://example.invalid") {
                        throw staleCompletion
                    }
                },
            )

            assertEquals(ConnectUi.Requesting, states[0])
            assertTrue(states[1] is ConnectUi.Awaiting)
            assertEquals(ConnectUi.Error(staleCompletion.message!!), states[2])
            assertFalse(states.any { it is ConnectUi.Connected })
        }
    }

    private fun completeTraktTokenValues(): Map<String, String> = mapOf(
        "vortx.trakt.accessToken" to "persisted-access",
        "vortx.trakt.refreshToken" to "persisted-refresh",
        "vortx.trakt.expiresAt" to "11000",
        "vortx.trakt.createdAt" to "1000",
    )
}
