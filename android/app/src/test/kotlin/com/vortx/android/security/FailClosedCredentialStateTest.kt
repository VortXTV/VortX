package com.vortx.android.security

import com.vortx.android.integrations.CredentialConnectionState
import com.vortx.android.integrations.CredentialStoreAccess
import com.vortx.android.integrations.SIMKLAuth
import com.vortx.android.integrations.SIMKLException
import com.vortx.android.integrations.TraktAuth
import com.vortx.android.integrations.TraktAuthException
import com.vortx.android.integrations.TraktToken
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class FailClosedCredentialStateTest {

    @Test
    fun missingSecureBackendUsesMemoryOnly() {
        val state = FailClosedCredentialState(backend = null)

        assertFalse(state.write(mapOf("token" to "secret")))
        assertEquals("secret", state.string("token"))
        val snapshot = state.confirmedSnapshot("token")
        assertEquals(PersistentCredentialAvailability.UNAVAILABLE, snapshot.availability)
        assertNull(snapshot.values["token"])
        assertFalse(state.hasPersistentBackend)
    }

    @Test
    fun secureOpenFailureReturnsNoDiskBackend() {
        var failures = 0

        val backend = openCredentialBackendOrNull(
            opener = { throw IllegalStateException("keystore unavailable") },
            onFailure = { failures += 1 },
        )

        assertNull(backend)
        assertEquals(1, failures)
    }

    @Test
    fun secureOpenSuccessPersistsAndMirrorsMemory() {
        val backend = FakeBackend()
        val state = FailClosedCredentialState(backend)

        assertTrue(state.write(mapOf("token" to "secret")))
        assertEquals("secret", backend.values["token"])
        assertEquals("secret", state.string("token"))
        assertEquals("secret", confirmedValue(state, "token"))
        assertTrue(state.hasPersistentBackend)
    }

    @Test
    fun postOpenReadFailureDisablesBackendAndReturnsAbsent() {
        var failures = 0
        val backend = FakeBackend().apply { failReads = true }
        val state = FailClosedCredentialState(backend) { failures += 1 }

        assertNull(state.string("token"))
        assertFalse(state.hasPersistentBackend)
        assertEquals(1, failures)
        assertFalse(state.write(mapOf("token" to "memory-secret")))
        assertEquals("memory-secret", state.string("token"))
    }

    @Test
    fun rejectedEncryptedWriteNeverUsesAnotherDiskBackend() {
        var failures = 0
        val backend = FakeBackend(mutableMapOf("token" to "persisted-secret")).apply {
            rejectWrites = true
        }
        val state = FailClosedCredentialState(backend) { failures += 1 }

        assertFalse(state.write(mapOf("token" to "memory-secret")))
        assertFalse(state.hasPersistentBackend)
        assertEquals("persisted-secret", state.string("token"))
        assertEquals("persisted-secret", confirmedValue(state, "token"))
        assertEquals(1, backend.writeAttempts)
        assertEquals(1, failures)
    }

    @Test
    fun rejectedEncryptedWriteRetainsBackingValueForLaterReopen() {
        val backend = FakeBackend().apply {
            values["token"] = "persisted-secret"
            rejectWrites = true
        }
        val failedState = FailClosedCredentialState(backend)

        assertFalse(failedState.write(mapOf("token" to "memory-secret")))
        assertEquals("persisted-secret", failedState.string("token"))
        assertEquals("persisted-secret", confirmedValue(failedState, "token"))

        backend.rejectWrites = false
        val reopenedState = FailClosedCredentialState(backend)

        assertEquals("persisted-secret", reopenedState.string("token"))
        assertTrue(reopenedState.hasPersistentBackend)
    }

    @Test
    fun missingBackendClearRemovesMemoryOnlyValue() {
        val state = FailClosedCredentialState(backend = null)
        state.write(mapOf("token" to "memory-secret"))

        state.write(mapOf("token" to null))

        assertNull(state.string("token"))
        assertNull(confirmedValue(state, "token"))
    }

    @Test
    fun rejectedClearKeepsConfirmedValueAndBlocksReopenUntilNewState() {
        val durable = mutableMapOf("token" to "persisted-secret")
        val failedBackend = FakeBackend(durable).apply { rejectWrites = true }
        val recoveredBackend = FakeBackend(durable)
        var reopenAttempts = 0
        val state = FailClosedCredentialState(
            backend = failedBackend,
            reopenBackend = {
                reopenAttempts += 1
                recoveredBackend
            },
        )

        assertFalse(state.write(mapOf("token" to null)))
        assertEquals("persisted-secret", state.string("token"))
        assertEquals("persisted-secret", confirmedValue(state, "token"))
        assertEquals("persisted-secret", durable["token"])

        assertFalse(state.write(mapOf("token" to null)))
        assertEquals("persisted-secret", state.string("token"))
        assertEquals("persisted-secret", confirmedValue(state, "token"))
        assertEquals(0, reopenAttempts)

        val restarted = FailClosedCredentialState(recoveredBackend)
        assertTrue(restarted.write(mapOf("token" to null)))
        assertNull(restarted.string("token"))
        assertFalse(durable.containsKey("token"))
    }

    @Test
    fun rejectedSaveKeepsConfirmedValueAndBlocksReopenUntilNewState() {
        val durable = mutableMapOf("token" to "old-secret")
        val failedBackend = FakeBackend(durable).apply { rejectWrites = true }
        val recoveredBackend = FakeBackend(durable)
        var reopenAttempts = 0
        val state = FailClosedCredentialState(
            backend = failedBackend,
            reopenBackend = {
                reopenAttempts += 1
                recoveredBackend
            },
        )

        assertFalse(state.write(mapOf("token" to "new-secret")))
        assertEquals("old-secret", confirmedValue(state, "token"))

        assertFalse(state.write(mapOf("token" to "new-secret")))
        assertEquals("old-secret", state.string("token"))
        assertEquals("old-secret", confirmedValue(state, "token"))
        assertEquals(0, reopenAttempts)

        val restarted = FailClosedCredentialState(recoveredBackend)
        assertTrue(restarted.write(mapOf("token" to "new-secret")))
        assertEquals("new-secret", restarted.string("token"))
    }

    @Test
    fun preWriteSnapshotReadFailureRemainsRetryableWithoutCallingWrite() {
        val durable = mutableMapOf("token" to "old-secret")
        val failedBackend = FakeBackend(durable)
        val recoveredBackend = FakeBackend(durable)
        var reopenAttempts = 0
        var failures = 0
        val state = FailClosedCredentialState(
            backend = failedBackend,
            reopenBackend = {
                reopenAttempts += 1
                recoveredBackend
            },
            onBackendFailure = { failures += 1 },
        )
        assertEquals("old-secret", confirmedValue(state, "token"))
        failedBackend.failReads = true

        assertFalse(state.write(mapOf("token" to "new-secret")))

        assertEquals(0, failedBackend.writeAttempts)
        assertEquals(0, recoveredBackend.writeAttempts)
        assertEquals(1, failures)
        assertFalse(state.hasPersistentBackend)
        assertEquals("old-secret", state.string("token"))
        assertEquals(1, reopenAttempts)
        assertTrue(state.hasPersistentBackend)
        assertEquals("old-secret", confirmedValue(state, "token"))
        assertEquals("old-secret", durable["token"])
    }

    @Test
    fun failedReadCanRecoverOnLaterClearWithoutRecreatingState() {
        val durable = mutableMapOf("token" to "persisted-secret")
        val failedBackend = FakeBackend(durable).apply { failReads = true }
        val recoveredBackend = FakeBackend(durable)
        val state = FailClosedCredentialState(
            backend = failedBackend,
            reopenBackend = { recoveredBackend },
        )

        assertNull(state.string("token"))
        assertFalse(state.hasPersistentBackend)

        assertTrue(state.write(mapOf("token" to null)))
        assertFalse(durable.containsKey("token"))
        assertNull(FailClosedCredentialState(FakeBackend(durable)).string("token"))
    }

    @Test
    fun unavailablePersistentReadIsExplicitAndLaterReadReopensCiphertext() {
        val durable = mutableMapOf("token" to "persisted-secret")
        var backendAvailable = false
        var reopenAttempts = 0
        val state = FailClosedCredentialState(
            backend = null,
            reopenBackend = {
                reopenAttempts += 1
                if (backendAvailable) FakeBackend(durable) else null
            },
        )

        val unavailable = state.confirmedSnapshot("token")

        assertEquals(PersistentCredentialAvailability.UNAVAILABLE, unavailable.availability)
        assertNull(unavailable.values["token"])
        assertEquals(1, reopenAttempts)

        backendAvailable = true
        val recovered = state.confirmedSnapshot("token")

        assertEquals(PersistentCredentialAvailability.AVAILABLE, recovered.availability)
        assertEquals("persisted-secret", recovered.values["token"])
        assertEquals(2, reopenAttempts)
        assertTrue(state.hasPersistentBackend)
    }

    @Test
    fun postOpenReadFailureRecoversOnTheNextConfirmedRead() {
        val durable = mutableMapOf("token" to "persisted-secret")
        val failedBackend = FakeBackend(durable).apply { failReads = true }
        val recoveredBackend = FakeBackend(durable)
        val state = FailClosedCredentialState(
            backend = failedBackend,
            reopenBackend = { recoveredBackend },
        )

        val unavailable = state.confirmedSnapshot("token")
        val recovered = state.confirmedSnapshot("token")

        assertEquals(PersistentCredentialAvailability.UNAVAILABLE, unavailable.availability)
        assertNull(unavailable.values["token"])
        assertEquals(PersistentCredentialAvailability.AVAILABLE, recovered.availability)
        assertEquals("persisted-secret", recovered.values["token"])
        assertTrue(state.hasPersistentBackend)
    }

    @Test
    fun ambiguousFalseCommitNeverPublishesMutatedProcessCache() {
        listOf(
            "candidate" to "new-secret",
            "removal" to null,
        ).forEach { (case, candidate) ->
            val harness = AmbiguousWriteHarness(mapOf("token" to "old-secret"))

            assertFalse(case, harness.state.write(mapOf("token" to candidate)))
            assertEquals(case, candidate, harness.processCache["token"])
            assertEquals(case, candidate, harness.reopenedBackend.string("token"))

            repeat(3) {
                val snapshot = harness.state.confirmedSnapshot("token")
                assertEquals(case, PersistentCredentialAvailability.UNAVAILABLE, snapshot.availability)
                assertEquals(case, "old-secret", snapshot.values["token"])
                assertEquals(case, "old-secret", harness.state.string("token"))
            }

            assertFalse(case, harness.state.write(mapOf("token" to candidate)))
            assertEquals(case, "old-secret", harness.state.string("token"))
            assertEquals(case, 0, harness.reopenAttempts)
            assertEquals(case, 1, harness.failures)
            assertFalse(case, harness.state.hasPersistentBackend)
        }
    }

    @Test
    fun ambiguousWriteExceptionAlsoPermanentlyPoisonsReopen() {
        val harness = AmbiguousWriteHarness(
            initialValues = mapOf("token" to "old-secret"),
            throwAfterMutation = true,
        )

        assertFalse(harness.state.write(mapOf("token" to "new-secret")))
        assertEquals("new-secret", harness.processCache["token"])
        assertEquals("new-secret", harness.reopenedBackend.string("token"))

        repeat(3) {
            val snapshot = harness.state.confirmedSnapshot("token")
            assertEquals(PersistentCredentialAvailability.UNAVAILABLE, snapshot.availability)
            assertEquals("old-secret", snapshot.values["token"])
        }
        assertEquals("old-secret", harness.state.string("token"))
        assertEquals(0, harness.reopenAttempts)
        assertEquals(1, harness.failures)
    }

    @Test
    fun ambiguousProviderSavesKeepTraktAndSimklStorageUnavailable() {
        val traktHarness = AmbiguousWriteHarness(oldTraktValues())
        val trakt = TraktAuth.TokenPersistence(traktHarness.store) { NOW }

        val traktError = assertThrows(TraktAuthException.SecureStorage::class.java) {
            trakt.save(NEW_TRAKT_TOKEN)
        }

        assertSame(TraktAuthException.SecureStorage, traktError)
        assertEquals(NEW_TRAKT_TOKEN.accessToken, traktHarness.processCache[TRAKT_ACCESS_KEY])
        repeat(3) {
            assertEquals(CredentialConnectionState.STORAGE_UNAVAILABLE, trakt.connectionState)
            assertThrows(TraktAuthException.SecureStorage::class.java, trakt::load)
        }
        assertEquals(0, traktHarness.reopenAttempts)

        val simklHarness = AmbiguousWriteHarness(oldSimklValues())
        val simkl = SIMKLAuth.TokenPersistence(simklHarness.store) { NOW }

        val simklError = assertThrows(SIMKLException.SecureStorage::class.java) {
            simkl.save("new-simkl-token")
        }

        assertSame(SIMKLException.SecureStorage, simklError)
        assertEquals("new-simkl-token", simklHarness.processCache[SIMKL_ACCESS_KEY])
        repeat(3) {
            assertEquals(CredentialConnectionState.STORAGE_UNAVAILABLE, simkl.connectionState)
            assertThrows(SIMKLException.SecureStorage::class.java, simkl::validToken)
        }
        assertEquals(0, simklHarness.reopenAttempts)
    }

    @Test
    fun ambiguousProviderClearsNeverReportDisconnected() {
        val traktHarness = AmbiguousWriteHarness(oldTraktValues())
        val trakt = TraktAuth.TokenPersistence(traktHarness.store) { NOW }

        val traktError = assertThrows(TraktAuthException.SecureStorage::class.java, trakt::clear)

        assertSame(TraktAuthException.SecureStorage, traktError)
        assertFalse(traktHarness.processCache.containsKey(TRAKT_ACCESS_KEY))
        repeat(3) {
            assertEquals(CredentialConnectionState.STORAGE_UNAVAILABLE, trakt.connectionState)
        }
        assertEquals(0, traktHarness.reopenAttempts)

        val simklHarness = AmbiguousWriteHarness(oldSimklValues())
        val simkl = SIMKLAuth.TokenPersistence(simklHarness.store) { NOW }

        val simklError = assertThrows(SIMKLException.SecureStorage::class.java, simkl::clear)

        assertSame(SIMKLException.SecureStorage, simklError)
        assertFalse(simklHarness.processCache.containsKey(SIMKL_ACCESS_KEY))
        repeat(3) {
            assertEquals(CredentialConnectionState.STORAGE_UNAVAILABLE, simkl.connectionState)
        }
        assertEquals(0, simklHarness.reopenAttempts)
    }

    @Test
    fun confirmedSnapshotCannotMixConcurrentWriteGenerations() {
        val firstRead = CountDownLatch(1)
        val releaseRead = CountDownLatch(1)
        val writeCompleted = CountDownLatch(1)
        val readFailure = AtomicReference<Throwable?>()
        val writeFailure = AtomicReference<Throwable?>()
        val loaded = AtomicReference<PersistentCredentialSnapshot?>()
        val backend = FakeBackend(
            mutableMapOf("access" to "old-access", "refresh" to "old-refresh"),
        ).apply {
            afterRead = { key ->
                if (key == "access") {
                    firstRead.countDown()
                    check(releaseRead.await(2, TimeUnit.SECONDS))
                }
            }
        }
        val state = FailClosedCredentialState(backend)

        val readThread = thread(name = "credential-snapshot") {
            runCatching {
                loaded.set(state.confirmedSnapshot("access", "refresh"))
            }.onFailure(readFailure::set)
        }
        assertTrue(firstRead.await(2, TimeUnit.SECONDS))

        val writeThread = thread(name = "credential-write") {
            runCatching {
                state.write(mapOf("access" to "new-access", "refresh" to "new-refresh"))
                writeCompleted.countDown()
            }.onFailure(writeFailure::set)
        }

        try {
            assertFalse(
                "A write interleaved with one confirmed credential snapshot",
                writeCompleted.await(250, TimeUnit.MILLISECONDS),
            )
        } finally {
            releaseRead.countDown()
            readThread.join(2_000L)
            writeThread.join(2_000L)
        }

        assertNull(readFailure.get())
        assertNull(writeFailure.get())
        assertEquals(PersistentCredentialAvailability.AVAILABLE, loaded.get()?.availability)
        assertEquals(
            mapOf("access" to "old-access", "refresh" to "old-refresh"),
            loaded.get()?.values,
        )
        assertEquals(
            mapOf("access" to "new-access", "refresh" to "new-refresh"),
            state.confirmedSnapshot("access", "refresh").values,
        )
    }

    @Test
    fun conditionalAdoptionReopensAndNeverOverwritesExistingDurableValue() {
        val durable = mutableMapOf("token" to "local-secret")
        val failedBackend = FakeBackend(durable).apply { failReads = true }
        val recoveredBackend = FakeBackend(durable)
        val state = FailClosedCredentialState(
            backend = failedBackend,
            reopenBackend = { recoveredBackend },
        )

        assertEquals(
            PersistentCredentialAvailability.UNAVAILABLE,
            state.confirmedSnapshot("token").availability,
        )
        assertEquals(
            ConditionalCredentialWrite.ALREADY_PRESENT,
            state.writeIfConfirmedAbsent("token", "remote-secret"),
        )
        assertEquals("local-secret", durable["token"])
        assertEquals(0, recoveredBackend.writeAttempts)
    }

    @Test
    fun conditionalAdoptionWritesOnlyAfterConfirmedAbsence() {
        val durable = mutableMapOf<String, String>()
        val backend = FakeBackend(durable)
        val state = FailClosedCredentialState(backend)

        assertEquals(
            ConditionalCredentialWrite.WRITTEN,
            state.writeIfConfirmedAbsent("token", "remote-secret"),
        )
        assertEquals("remote-secret", durable["token"])
        assertEquals(
            ConditionalCredentialWrite.ALREADY_PRESENT,
            state.writeIfConfirmedAbsent("token", "replacement"),
        )
        assertEquals("remote-secret", durable["token"])
    }

    @Test
    fun rejectedConditionalAdoptionPoisonsAmbiguousBackendState() {
        val harness = AmbiguousWriteHarness(emptyMap())

        assertEquals(
            ConditionalCredentialWrite.REJECTED,
            harness.state.writeIfConfirmedAbsent("token", "remote-secret"),
        )
        assertEquals("remote-secret", harness.processCache["token"])
        repeat(3) {
            val snapshot = harness.state.confirmedSnapshot("token")
            assertEquals(PersistentCredentialAvailability.UNAVAILABLE, snapshot.availability)
            assertNull(snapshot.values["token"])
            assertNull(harness.state.string("token"))
        }
        assertEquals(
            ConditionalCredentialWrite.UNAVAILABLE,
            harness.state.writeIfConfirmedAbsent("token", "replacement"),
        )
        assertEquals(0, harness.reopenAttempts)
        assertEquals(1, harness.failures)
    }

    private fun confirmedValue(state: FailClosedCredentialState, key: String): String? =
        state.confirmedSnapshot(key).values[key]

    private fun oldTraktValues(): Map<String, String> = mapOf(
        TRAKT_ACCESS_KEY to OLD_TRAKT_TOKEN.accessToken,
        TRAKT_REFRESH_KEY to OLD_TRAKT_TOKEN.refreshToken,
        TRAKT_EXPIRY_KEY to OLD_TRAKT_TOKEN.expiresAtSeconds.toString(),
        TRAKT_CREATED_KEY to OLD_TRAKT_TOKEN.createdAt.toString(),
    )

    private fun oldSimklValues(): Map<String, String> = mapOf(
        SIMKL_ACCESS_KEY to "old-simkl-token",
        SIMKL_EXPIRY_KEY to "0",
    )

    private class AmbiguousWriteHarness(
        initialValues: Map<String, String>,
        throwAfterMutation: Boolean = false,
    ) {
        val processCache = initialValues.toMutableMap()
        var reopenAttempts = 0
        var failures = 0
        val reopenedBackend = AmbiguousCommitBackend(processCache, acceptsWrites = true)
        val state = FailClosedCredentialState(
            backend = AmbiguousCommitBackend(processCache, throwAfterMutation = throwAfterMutation),
            reopenBackend = {
                reopenAttempts += 1
                reopenedBackend
            },
            onBackendFailure = { failures += 1 },
        )
        val store = StateCredentialStore(state)
    }

    private class AmbiguousCommitBackend(
        private val processCache: MutableMap<String, String>,
        private val throwAfterMutation: Boolean = false,
        private val acceptsWrites: Boolean = false,
    ) : CredentialBackend {
        override fun string(key: String): String? = processCache[key]

        override fun write(values: Map<String, String?>): Boolean {
            values.forEach { (key, value) ->
                if (value == null) processCache.remove(key) else processCache[key] = value
            }
            if (acceptsWrites) return true
            if (throwAfterMutation) error("commit failed after mutating process cache")
            return false
        }
    }

    private class StateCredentialStore(
        private val state: FailClosedCredentialState,
    ) : CredentialStoreAccess {
        override fun string(key: String): String? = state.string(key)

        override fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot =
            state.confirmedSnapshot(*keys)

        override fun set(key: String, value: String?): Boolean = state.write(mapOf(key to value))

        override fun set(values: Map<String, String?>): Boolean = state.write(values)

        override fun clear(vararg keys: String): Boolean = state.write(keys.associateWith { null })
    }

    private class FakeBackend(
        val values: MutableMap<String, String> = mutableMapOf(),
    ) : CredentialBackend {
        var failReads = false
        var rejectWrites = false
        var writeAttempts = 0
        var afterRead: ((String) -> Unit)? = null

        override fun string(key: String): String? {
            if (failReads) error("read failure")
            return values[key].also { afterRead?.invoke(key) }
        }

        override fun write(values: Map<String, String?>): Boolean {
            writeAttempts += 1
            if (rejectWrites) return false
            values.forEach { (key, value) ->
                if (value == null) this.values.remove(key) else this.values[key] = value
            }
            return true
        }
    }

    private companion object {
        const val NOW = 1_000L
        const val TRAKT_ACCESS_KEY = "vortx.trakt.accessToken"
        const val TRAKT_REFRESH_KEY = "vortx.trakt.refreshToken"
        const val TRAKT_EXPIRY_KEY = "vortx.trakt.expiresAt"
        const val TRAKT_CREATED_KEY = "vortx.trakt.createdAt"
        const val SIMKL_ACCESS_KEY = "vortx.simkl.accessToken"
        const val SIMKL_EXPIRY_KEY = "vortx.simkl.expiresAt"
        val OLD_TRAKT_TOKEN = TraktToken("old-access", "old-refresh", expiresIn = 10_000L, createdAt = NOW)
        val NEW_TRAKT_TOKEN = TraktToken("new-access", "new-refresh", expiresIn = 10_000L, createdAt = NOW)
    }
}
