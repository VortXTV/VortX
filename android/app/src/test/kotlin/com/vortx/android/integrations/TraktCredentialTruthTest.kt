package com.vortx.android.integrations

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class TraktCredentialTruthTest {

    @Test
    fun failedInitialSaveDoesNotAuthorizeOrSurviveRestart() {
        val store = FakeCredentialStore().apply { rejectWrites = true }
        val persistence = TraktAuth.TokenPersistence(store) { NOW }

        val error = assertThrows(TraktAuthException.SecureStorage::class.java) {
            persistence.save(NEW_TOKEN)
        }

        assertSame(TraktAuthException.SecureStorage, error)
        assertFalse(persistence.isSignedIn)
        assertNull(persistence.load())
        assertNull(store.string(ACCESS_KEY))
        assertFalse(store.reopen().let { TraktAuth.TokenPersistence(it) { NOW }.isSignedIn })
    }

    @Test
    fun failedRefreshRotationKeepsPriorLogicalAndRestartToken() {
        val store = FakeCredentialStore(oldTokenValues()).apply { rejectWrites = true }
        val persistence = TraktAuth.TokenPersistence(store) { NOW }

        assertThrows(TraktAuthException.SecureStorage::class.java) {
            persistence.save(NEW_TOKEN)
        }

        assertEquals(OLD_TOKEN, persistence.load())
        assertEquals(OLD_TOKEN, TraktAuth.TokenPersistence(store.reopen()) { NOW }.load())
    }

    @Test
    fun failedSignOutKeepsPriorLogicalAndRestartState() {
        val store = FakeCredentialStore(oldTokenValues()).apply { rejectWrites = true }
        val persistence = TraktAuth.TokenPersistence(store) { NOW }

        val error = assertThrows(TraktAuthException.SecureStorage::class.java) {
            persistence.clear()
        }

        assertSame(TraktAuthException.SecureStorage, error)
        assertTrue(persistence.isSignedIn)
        assertEquals(OLD_TOKEN, persistence.load())
        assertTrue(TraktAuth.TokenPersistence(store.reopen()) { NOW }.isSignedIn)
    }

    @Test
    fun tokenLoadUsesOneAtomicConfirmedSnapshot() {
        val store = FakeCredentialStore(oldTokenValues())
        val persistence = TraktAuth.TokenPersistence(store) { NOW }

        assertEquals(OLD_TOKEN, persistence.load())
        assertEquals(1, store.snapshotCalls)
        assertEquals(
            setOf(ACCESS_KEY, REFRESH_KEY, EXPIRY_KEY, CREATED_KEY),
            store.lastSnapshotKeys,
        )
    }

    @Test
    fun storedTupleParserKeepsConnectionStateAndLoadStoredInLockstep() {
        val completeStore = FakeCredentialStore(oldTokenValues())
        val completePersistence = TraktAuth.TokenPersistence(completeStore) { NOW }

        assertEquals(
            CredentialConnectionState.CONNECTED,
            completePersistence.connectionState,
        )
        assertEquals(OLD_TOKEN, completePersistence.loadStored()?.token)
        assertEquals(2, completeStore.snapshotCalls)
        assertEquals(
            setOf(ACCESS_KEY, REFRESH_KEY, EXPIRY_KEY, CREATED_KEY),
            completeStore.lastSnapshotKeys,
        )

        listOf(
            "missing access" to (oldTokenValues() - ACCESS_KEY),
            "missing refresh" to (oldTokenValues() - REFRESH_KEY),
            "missing expiry" to (oldTokenValues() - EXPIRY_KEY),
            "empty access" to (oldTokenValues() + (ACCESS_KEY to "")),
            "empty refresh" to (oldTokenValues() + (REFRESH_KEY to "")),
            "empty expiry" to (oldTokenValues() + (EXPIRY_KEY to "")),
            "whitespace access" to (oldTokenValues() + (ACCESS_KEY to " \t ")),
            "whitespace refresh" to (oldTokenValues() + (REFRESH_KEY to "\n")),
            "whitespace expiry" to (oldTokenValues() + (EXPIRY_KEY to " ")),
            "malformed expiry" to (oldTokenValues() + (EXPIRY_KEY to "not-an-expiry")),
            "zero expiry" to (oldTokenValues() + (EXPIRY_KEY to "0")),
            "negative expiry" to (oldTokenValues() + (EXPIRY_KEY to "-1")),
        ).forEach { (case, corruptValues) ->
            val corruptStore = FakeCredentialStore(corruptValues)
            val persistence = TraktAuth.TokenPersistence(corruptStore) { NOW }
            assertEquals(
                "$case connection state",
                CredentialConnectionState.DISCONNECTED,
                persistence.connectionState,
            )
            assertNull("$case stored token", persistence.loadStored())
            assertEquals("$case snapshot count", 2, corruptStore.snapshotCalls)
            assertEquals(
                "$case snapshot keys",
                setOf(ACCESS_KEY, REFRESH_KEY, EXPIRY_KEY, CREATED_KEY),
                corruptStore.lastSnapshotKeys,
            )
        }

        val legacyPersistence = TraktAuth.TokenPersistence(
            FakeCredentialStore(oldTokenValues() - CREATED_KEY),
        ) { NOW }
        assertEquals(
            CredentialConnectionState.CONNECTED,
            legacyPersistence.connectionState,
        )
        assertNull(requireNotNull(legacyPersistence.loadStored()).lineage.createdAt)
    }

    @Test
    fun traktResponseParserRejectsBlankTokensWithoutTrimmingBearerValues() {
        listOf(
            "blank access" to tokenBody(access = "   ", refresh = "refresh"),
            "blank refresh" to tokenBody(access = "access", refresh = "   "),
        ).forEach { (case, body) ->
            assertNull(case, TraktAuth.parseToken(body))
        }

        val token = requireNotNull(
            TraktAuth.parseToken(tokenBody(access = " access ", refresh = " refresh ")),
        )
        assertEquals(" access ", token.accessToken)
        assertEquals(" refresh ", token.refreshToken)
    }

    @Test
    fun invalidSaveCandidatesNeverReachPersistentStorage() {
        listOf(
            "blank access" to TraktToken(" ", "refresh", expiresIn = 1L, createdAt = 1L),
            "blank refresh" to TraktToken("access", "\t", expiresIn = 1L, createdAt = 1L),
            "zero lifetime" to TraktToken("access", "refresh", expiresIn = 0L, createdAt = 1L),
            "nonpositive expiry" to TraktToken("access", "refresh", expiresIn = -1L, createdAt = 0L),
        ).forEach { (case, candidate) ->
            val store = FakeCredentialStore()
            val persistence = TraktAuth.TokenPersistence(store) { NOW }

            val error = assertThrows(case, TraktAuthException.Decoding::class.java) {
                persistence.save(candidate)
            }

            assertSame(case, TraktAuthException.Decoding, error)
            assertNull("$case access", store.string(ACCESS_KEY))
            assertNull("$case refresh", store.string(REFRESH_KEY))
            assertNull("$case expiry", store.string(EXPIRY_KEY))
            assertNull("$case created", store.string(CREATED_KEY))
        }
    }

    @Test
    fun refresh200PublishesWhenStoredLineageStillMatchesRequest() {
        val store = FakeCredentialStore(oldTokenValues())
        val persistence = TraktAuth.TokenPersistence(store) { NOW }
        val spentLineage = requireNotNull(persistence.loadStored()).lineage

        assertEquals(NEW_TOKEN, persistence.saveRefreshIfCurrent(spentLineage, NEW_TOKEN))
        assertEquals(NEW_TOKEN, persistence.load())
        assertEquals(NEW_TOKEN, TraktAuth.TokenPersistence(store.reopen()) { NOW }.load())
    }

    @Test
    fun productionRefresh200PreservesNewerStoredLineage() = runBlocking {
        val store = FakeCredentialStore(oldTokenValues())
        val persistence = TraktAuth.TokenPersistence(store) { NOW }
        val coordinator = CredentialMutationCoordinator()
        val operation = coordinator.operation()
        val spentToken = requireNotNull(persistence.loadStored())
        persistence.save(NEWER_TOKEN)

        val published = TraktAuth.performRefresh(
            operation = operation,
            spentToken = spentToken,
            persistence = persistence,
            clearCurrent = { error("A 200 response must not clear credentials") },
            request = { IntegrationsHttp.Response(200, tokenBody()) },
        )

        assertEquals(NEWER_TOKEN, published)
        assertEquals(NEWER_TOKEN, persistence.load())
        assertEquals(NEWER_TOKEN, TraktAuth.TokenPersistence(store.reopen()) { NOW }.load())
    }

    @Test
    fun productionRefresh401PreservesNewerStoredLineageThroughUnauthorizedHandler() = runBlocking {
        val store = FakeCredentialStore(oldTokenValues())
        val persistence = TraktAuth.TokenPersistence(store) { NOW }
        val coordinator = CredentialMutationCoordinator()
        val operation = coordinator.operation()
        val spentToken = requireNotNull(persistence.loadStored())
        persistence.save(NEWER_TOKEN)
        var clearCalled = false

        val published = TraktAuth.performRefresh(
            operation = operation,
            spentToken = spentToken,
            persistence = persistence,
            clearCurrent = {
                clearCalled = true
                coordinator.invalidate(persistence::clear)
            },
            request = { IntegrationsHttp.Response(401, "") },
        )

        assertEquals(NEWER_TOKEN, published)
        assertFalse(clearCalled)
        assertEquals(NEWER_TOKEN, persistence.load())
        assertEquals(NEWER_TOKEN, TraktAuth.TokenPersistence(store.reopen()) { NOW }.load())
    }

    @Test
    fun refresh401MatchingLineageClearsSession() {
        val store = FakeCredentialStore(oldTokenValues())
        val persistence = TraktAuth.TokenPersistence(store) { NOW }
        val spentLineage = requireNotNull(persistence.loadStored()).lineage
        val coordinator = CredentialMutationCoordinator()
        val rejectedOperation = coordinator.operation()

        val preserved = TraktAuth.handleUnauthorizedRefresh(
            spentLineage = spentLineage,
            loadStored = persistence::loadStored,
            clearCurrent = { coordinator.invalidate(persistence::clear) },
        )

        assertNull(preserved)
        assertSame(CredentialMutationResult.Stale, rejectedOperation.mutate { Unit })
        assertEquals(CredentialConnectionState.DISCONNECTED, persistence.connectionState)
        assertNull(persistence.load())
        assertNull(TraktAuth.TokenPersistence(store.reopen()) { NOW }.load())
    }

    @Test
    fun refresh401PreservesNewerLineage() {
        val store = FakeCredentialStore(oldTokenValues())
        val persistence = TraktAuth.TokenPersistence(store) { NOW }
        val spentLineage = requireNotNull(persistence.loadStored()).lineage
        persistence.save(NEW_TOKEN)
        var clearCalled = false

        val preserved = TraktAuth.handleUnauthorizedRefresh(
            spentLineage = spentLineage,
            loadStored = persistence::loadStored,
            clearCurrent = {
                clearCalled = true
                persistence.clear()
            },
        )

        assertEquals(NEW_TOKEN, preserved)
        assertFalse(clearCalled)
        assertEquals(NEW_TOKEN, persistence.load())
        assertEquals(NEW_TOKEN, TraktAuth.TokenPersistence(store.reopen()) { NOW }.load())
    }

    @Test
    fun refresh401SurfacesStorageUnavailableClearFailure() {
        val store = FakeCredentialStore(oldTokenValues())
        val persistence = TraktAuth.TokenPersistence(store) { NOW }
        val spentLineage = requireNotNull(persistence.loadStored()).lineage
        val coordinator = CredentialMutationCoordinator()
        val rejectedOperation = coordinator.operation()

        val error = assertThrows(TraktAuthException.SecureStorage::class.java) {
            TraktAuth.handleUnauthorizedRefresh(
                spentLineage = spentLineage,
                loadStored = persistence::loadStored,
                clearCurrent = {
                    store.persistentAvailable = false
                    coordinator.invalidate(persistence::clear)
                },
            )
        }

        assertSame(TraktAuthException.SecureStorage, error)
        assertSame(CredentialMutationResult.Stale, rejectedOperation.mutate { Unit })
        store.persistentAvailable = true
        assertEquals(OLD_TOKEN, persistence.load())
        assertEquals(OLD_TOKEN, TraktAuth.TokenPersistence(store.reopen()) { NOW }.load())
    }

    @Test
    fun legacyTokenWithoutCreatedAtKeepsStablePersistedLineage() {
        var now = NOW
        val store = FakeCredentialStore(oldTokenValues() - CREATED_KEY)
        val persistence = TraktAuth.TokenPersistence(store) { now }
        val first = requireNotNull(persistence.loadStored())

        now += 100
        val second = requireNotNull(persistence.loadStored())

        assertEquals(first.lineage, second.lineage)
        assertFalse(first.token.createdAt == second.token.createdAt)
        assertEquals(NEW_TOKEN, persistence.saveRefreshIfCurrent(first.lineage, NEW_TOKEN))
        assertEquals(NEW_TOKEN, persistence.load())
    }

    @Test
    fun unavailablePersistentReadIsExplicitAndRecovers() {
        val store = FakeCredentialStore(oldTokenValues()).apply {
            persistentAvailable = false
        }
        val persistence = TraktAuth.TokenPersistence(store) { NOW }

        assertEquals(
            CredentialConnectionState.STORAGE_UNAVAILABLE,
            persistence.connectionState,
        )
        assertThrows(TraktAuthException.SecureStorage::class.java) {
            persistence.load()
        }

        store.persistentAvailable = true

        assertEquals(CredentialConnectionState.CONNECTED, persistence.connectionState)
        assertEquals(OLD_TOKEN, persistence.load())
    }

    @Test
    fun singleKeyCompatibilityReadDoesNotPublishCachedValueWhileUnavailable() {
        val store = FakeCredentialStore(oldTokenValues()).apply {
            persistentAvailable = false
        }

        assertNull(store.confirmedString(ACCESS_KEY))

        store.persistentAvailable = true

        assertEquals(OLD_TOKEN.accessToken, store.confirmedString(ACCESS_KEY))
    }

    private fun oldTokenValues(): Map<String, String> = mapOf(
        ACCESS_KEY to OLD_TOKEN.accessToken,
        REFRESH_KEY to OLD_TOKEN.refreshToken,
        EXPIRY_KEY to OLD_TOKEN.expiresAtSeconds.toString(),
        CREATED_KEY to OLD_TOKEN.createdAt.toString(),
    )

    private fun tokenBody(
        access: String = NEW_TOKEN.accessToken,
        refresh: String = NEW_TOKEN.refreshToken,
    ): String = """
        {
          "access_token": "$access",
          "refresh_token": "$refresh",
          "expires_in": ${NEW_TOKEN.expiresIn},
          "created_at": ${NEW_TOKEN.createdAt}
        }
    """.trimIndent()

    private companion object {
        const val NOW = 1_000L
        const val ACCESS_KEY = "vortx.trakt.accessToken"
        const val REFRESH_KEY = "vortx.trakt.refreshToken"
        const val EXPIRY_KEY = "vortx.trakt.expiresAt"
        const val CREATED_KEY = "vortx.trakt.createdAt"
        val OLD_TOKEN = TraktToken("old-access", "old-refresh", expiresIn = 10_000L, createdAt = NOW)
        val NEW_TOKEN = TraktToken("new-access", "new-refresh", expiresIn = 10_000L, createdAt = NOW)
        val NEWER_TOKEN = TraktToken("newer-access", "newer-refresh", expiresIn = 20_000L, createdAt = NOW)
    }
}
