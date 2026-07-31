package com.vortx.android.integrations

import com.vortx.android.security.PersistentCredentialAvailability
import com.vortx.android.security.PersistentCredentialSnapshot
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class SIMKLCredentialTruthTest {

    @Test
    fun failedInitialSaveDoesNotAuthorizeOrSurviveRestart() {
        val store = FakeCredentialStore().apply { rejectWrites = true }
        val persistence = SIMKLAuth.TokenPersistence(store) { NOW }

        val error = assertThrows(SIMKLException.SecureStorage::class.java) {
            persistence.save("new-token")
        }

        assertSame(SIMKLException.SecureStorage, error)
        assertFalse(persistence.isSignedIn)
        assertNull(persistence.validToken())
        assertNull(store.string(ACCESS_KEY))
        assertFalse(SIMKLAuth.TokenPersistence(store.reopen()) { NOW }.isSignedIn)
    }

    @Test
    fun failedSignOutKeepsPriorLogicalAndRestartState() {
        val store = FakeCredentialStore(
            mapOf(ACCESS_KEY to "old-token", EXPIRY_KEY to "0"),
        ).apply {
            rejectWrites = true
        }
        val persistence = SIMKLAuth.TokenPersistence(store) { NOW }

        val error = assertThrows(SIMKLException.SecureStorage::class.java) {
            persistence.clear()
        }

        assertSame(SIMKLException.SecureStorage, error)
        assertTrue(persistence.isSignedIn)
        assertEquals("old-token", persistence.validToken())
        assertTrue(SIMKLAuth.TokenPersistence(store.reopen()) { NOW }.isSignedIn)
    }

    @Test
    fun unavailablePersistentReadIsExplicitAndRecovers() {
        val store = FakeCredentialStore(
            mapOf(ACCESS_KEY to "old-token", EXPIRY_KEY to "0"),
        ).apply {
            persistentAvailable = false
        }
        val persistence = SIMKLAuth.TokenPersistence(store) { NOW }

        assertEquals(
            CredentialConnectionState.STORAGE_UNAVAILABLE,
            persistence.connectionState,
        )
        assertThrows(SIMKLException.SecureStorage::class.java) {
            persistence.validToken()
        }

        store.persistentAvailable = true

        assertEquals(CredentialConnectionState.CONNECTED, persistence.connectionState)
        assertEquals("old-token", persistence.validToken())
    }

    @Test
    fun blankStoredTokensAreDisconnectedAndUnusable() {
        listOf("", " ", "\t\n").forEach { blank ->
            val persistence = SIMKLAuth.TokenPersistence(
                FakeCredentialStore(mapOf(ACCESS_KEY to blank, EXPIRY_KEY to "0")),
            ) { NOW }

            assertEquals(
                "stored token <$blank>",
                CredentialConnectionState.DISCONNECTED,
                persistence.connectionState,
            )
            assertNull("stored token <$blank>", persistence.validToken())
        }
    }

    @Test
    fun secureStoreProjectionPreservesPresentEmptyExpiryForStructuredValidation() {
        val projected = SecureTokenStore.projectConfirmedSnapshot(
            PersistentCredentialSnapshot(
                availability = PersistentCredentialAvailability.AVAILABLE,
                values = mapOf(
                    ACCESS_KEY to "persisted-token",
                    EXPIRY_KEY to "",
                ),
            ),
        )

        assertEquals("", projected.values[EXPIRY_KEY])
        val store = FakeCredentialStore(
            projected.values.mapValues { (_, value) -> requireNotNull(value) },
        )
        assertNull(store.confirmedString(EXPIRY_KEY))
        val persistence = SIMKLAuth.TokenPersistence(store) { NOW }
        assertEquals(CredentialConnectionState.DISCONNECTED, persistence.connectionState)
        assertNull(persistence.validToken())
    }

    @Test
    fun secureStoreConfirmedSnapshotIsWiredToTheExactProjection() {
        val source = readSecureTokenStoreSource()
        assertTrue(
            "SecureTokenStore.confirmedSnapshot must use the exact-value projection",
            exactSnapshotProjectionIsWired(source),
        )

        val historicalMutation = source.replace(
            "projectConfirmedSnapshot(store.confirmedSnapshot(*keys))",
            """
                store.confirmedSnapshot(*keys).let { snapshot ->
                    snapshot.copy(values = snapshot.values.mapValues { (_, value) ->
                        value?.takeIf { it.isNotEmpty() }
                    })
                }
            """.trimIndent(),
        )
        assertFalse(
            "The previous empty-to-absent projection escaped the production wiring contract",
            exactSnapshotProjectionIsWired(historicalMutation),
        )
    }

    @Test
    fun connectionStateAndValidTokenShareStoredRecordValidity() {
        listOf(
            "missing expiry" to (mapOf(ACCESS_KEY to "missing-expiry") to "missing-expiry"),
            "zero expiry" to (mapOf(ACCESS_KEY to "zero-expiry", EXPIRY_KEY to "0") to "zero-expiry"),
            "future expiry" to (
                mapOf(ACCESS_KEY to " future-token ", EXPIRY_KEY to (NOW + 1L).toString()) to
                    " future-token "
            ),
            "expiry boundary" to (mapOf(ACCESS_KEY to "boundary", EXPIRY_KEY to NOW.toString()) to null),
            "past expiry" to (mapOf(ACCESS_KEY to "past", EXPIRY_KEY to (NOW - 1L).toString()) to null),
            "malformed expiry" to (mapOf(ACCESS_KEY to "malformed", EXPIRY_KEY to "not-a-number") to null),
            "blank expiry" to (mapOf(ACCESS_KEY to "blank-expiry", EXPIRY_KEY to "") to null),
            "double-zero expiry" to (mapOf(ACCESS_KEY to "double-zero", EXPIRY_KEY to "00") to null),
            "plus-zero expiry" to (mapOf(ACCESS_KEY to "plus-zero", EXPIRY_KEY to "+0") to null),
            "minus-zero expiry" to (mapOf(ACCESS_KEY to "minus-zero", EXPIRY_KEY to "-0") to null),
            "leading-space zero expiry" to (mapOf(ACCESS_KEY to "leading-space", EXPIRY_KEY to " 0") to null),
            "trailing-space zero expiry" to (mapOf(ACCESS_KEY to "trailing-space", EXPIRY_KEY to "0 ") to null),
            "negative expiry" to (mapOf(ACCESS_KEY to "negative", EXPIRY_KEY to "-1") to null),
        ).forEach { (case, expectation) ->
            val (values, expectedToken) = expectation
            val persistence = SIMKLAuth.TokenPersistence(FakeCredentialStore(values)) { NOW }

            assertEquals(
                case,
                expectedToken != null,
                persistence.connectionState == CredentialConnectionState.CONNECTED,
            )
            assertEquals(case, expectedToken, persistence.validToken())
        }
    }

    @Test
    fun blankAuthorizedResponsesAreRejectedWithoutTrimmingBearerValues() {
        listOf("", " ", "   ").forEach { blank ->
            val error = assertThrows(SIMKLException.Decoding::class.java) {
                SIMKLAuth.parsePollToken(
                    """{"result":"OK","access_token":"$blank"}""",
                )
            }
            assertSame(SIMKLException.Decoding, error)
        }

        assertEquals(
            " usable-token ",
            SIMKLAuth.parsePollToken(
                """{"result":"OK","access_token":" usable-token "}""",
            ),
        )
    }

    @Test
    fun blankSaveCandidateNeverReachesPersistentStorage() {
        val store = FakeCredentialStore()
        val persistence = SIMKLAuth.TokenPersistence(store) { NOW }

        val error = assertThrows(SIMKLException.Decoding::class.java) {
            persistence.save(" ")
        }

        assertSame(SIMKLException.Decoding, error)
        assertNull(store.string(ACCESS_KEY))
        assertNull(store.string(EXPIRY_KEY))
    }

    private fun exactSnapshotProjectionIsWired(source: String): Boolean =
        Regex(
            """override\s+fun\s+confirmedSnapshot\s*\(\s*vararg\s+keys:\s*String\s*\)""" +
                """\s*:\s*PersistentCredentialSnapshot\s*=\s*""" +
                """projectConfirmedSnapshot\s*\(\s*store\.confirmedSnapshot\s*\(\s*\*keys\s*\)\s*\)""",
        ).containsMatchIn(source)

    private fun readSecureTokenStoreSource(): String {
        val candidates = listOf(
            File("src/main/kotlin/com/vortx/android/integrations/SecureTokenStore.kt"),
            File("app/src/main/kotlin/com/vortx/android/integrations/SecureTokenStore.kt"),
            File("android/app/src/main/kotlin/com/vortx/android/integrations/SecureTokenStore.kt"),
        )
        return candidates.firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate SecureTokenStore.kt from ${File(".").absolutePath}")
    }

    private companion object {
        const val NOW = 1_000L
        const val ACCESS_KEY = "vortx.simkl.accessToken"
        const val EXPIRY_KEY = "vortx.simkl.expiresAt"
    }
}
