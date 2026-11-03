package com.vortx.android.integrations

import com.vortx.android.engine.AccountFileLocalPresence
import com.vortx.android.integrations.ProviderRetryCredentialProof.Provider
import com.vortx.android.security.PersistentCredentialSnapshot
import com.vortx.android.sync.SessionOwnerSnapshot
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeProviderRetryVaultTest {
    private val original = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000123", 7)
    private val key = ByteArray(32) { it.toByte() }
    private val tuple = mapOf("traktAccess" to "access", "traktRefresh" to "refresh", "traktExpiry" to "2000000000")
    private var current = original
    private var paused = false
    private val backing = Backing("native.providers.account.${original.id}")
    private val coordinator = CredentialMutationCoordinator(NativeProviderCredentials.GROUPS[0])
    private val vault = NativeProviderVault(backing) { error("Unexpected legacy read") }

    @After fun unbind() = NativeProviderAccess.unbindForTest()

    @Test fun exactCredentialBindsExistingCoordinatorWithoutAllowingMutationOrRefresh() {
        val value = modern()
        backing.raw = value.encoded()
        bind()
        val credential = checkNotNull(capture())
        credential.use {
            val guard = credential.guard
            assertTrue(guard.isExistingOnlyRetry)
            assertEquals("access", credential.bearer)
            assertTrue(credential.matches())
            assertTrue(credential.operation.ownsRetryGuard(guard))
            val copy = checkNotNull(credential.copyProof())
            assertArrayEquals(ProviderRetryCredentialProof.derive(original.id, 11, key, Provider.TRAKT, value.encoded()), copy)
            copy.fill(0)
            assertTrue(checkNotNull(credential.copyProof()).any { it != 0.toByte() })
            checkNotNull(capture()).use { other ->
                assertFalse(credential.operation.ownsRetryGuard(other.guard))
            }
            assertTrue(credential.operation.isCurrent())
            assertNull(NativeProviderAccess.guarded(guard) { error("Unexpected mutable admission") })
            assertNull(NativeProviderAccess.readCurrentOwner(guard) { error("Unexpected peer adoption") })
            assertEquals(CredentialMutationResult.Stale, credential.operation.mutate { error("Unexpected OAuth edit") })
            assertEquals(CredentialMutationResult.Stale, credential.operation.readCurrentOwner { error("Unexpected rotation adoption") })
            var awaited = false
            var published = false
            val result = runBlocking {
                credential.operation.publishAfter(
                    awaitValue = { awaited = true; "synthetic" },
                    publish = { published = true; it },
                )
            }
            assertEquals(CredentialMutationResult.Stale, result)
            assertFalse(awaited)
            assertFalse(published)
        }
        assertNull(credential.copyProof())
        assertFalse(credential.matches())
    }

    @Test fun missingExistingOwnerAdmissionNeverFallsBackToOrdinaryOrOpensBacking() {
        backing.raw = modern().encoded()
        NativeProviderAccess.bind(vault, object : NativeProviderAdmission {
            override fun <T> withCurrent(expected: SessionOwnerSnapshot.Account?, action: (SessionOwnerSnapshot.Account) -> T): T? =
                error("Unexpected ordinary owner open")
        }) { error("Unexpected vault write callback") }
        assertNull(capture())
        assertEquals(0, backing.existingReads)
    }

    @Test fun absenceMalformedAndUnconfirmedReadsNeverSeedOrYieldProof() {
        bind()
        for (status in AccountFileLocalPresence.entries) {
            backing.status = status
            assertNull(capture())
        }
        backing.raw = modern().encoded()
        backing.status = AccountFileLocalPresence.UNAVAILABLE
        assertNull(capture())
        backing.status = AccountFileLocalPresence.PRESENT
        backing.repeatValue = true
        assertNull(capture())
        backing.repeatValue = false
        backing.raw = "{"
        assertNull(capture())
        backing.raw = "{\"actor\":null," + modern().encoded().drop(1)
        assertNull(capture())
        backing.raw = "{\"nested\":" + "[".repeat(1000) + "0" + "]".repeat(1000) + "}"
        assertNull(capture())
        backing.raw = NativeProviderCredentials("account.${original.id}").apply {
            merge(JSONObject().put("apiKeys", JSONObject(tuple)))
        }.encoded()
        assertNull(capture())
        backing.raw = modern().apply { edit(tuple.mapValues { null }) }.encoded()
        assertNull(capture())
        backing.raw = modern().apply { edit(tuple + ("traktRefresh" to " ")) }.encoded()
        assertNull(capture())
        backing.raw = modern().encoded()
        assertNull(capture(ownerEpoch = 0))
        assertNull(coordinator.snapshotRetryForOwner(original, 11, key, Provider.SIMKL) { true })
        assertNull(coordinator.snapshotRetryForOwner(original, 11, key, Provider.TRAKT) { false })
    }

    @Test fun originalGuardRechecksVaultIncarnationModernEventsCreationAndOwnerAtClaim() {
        val value = modern()
        backing.raw = value.encoded()
        bind()
        checkNotNull(capture()).use { credential ->
            val ticket = ProviderCallTicket { error("Unexpected retirement callback") }
            try {
                assertTrue(credential.operation.attachOutbound(ticket))
                value.edit(mapOf("simklAccess" to "unrelated", "simklExpiry" to "0"))
                backing.raw = value.encoded()
                assertTrue(credential.operation.isCurrent())
                val changedActor = JSONObject(value.encoded()).put("actor", "00000000-0000-0000-0000-000000000456")
                backing.raw = changedActor.toString()
                assertRefused(credential, ticket)
                backing.raw = JSONObject(value.encoded()).put("auxiliary", JSONObject().put("traktCreated", "101")).toString()
                assertRefused(credential, ticket)
                val baselineOnly = JSONObject(value.encoded())
                val fields = baselineOnly.getJSONObject("document").getJSONObject("fields")
                val baseline = baselineOnly.getJSONObject("baseline")
                val pending = baselineOnly.getJSONObject("pending")
                for (key in tuple.keys) {
                    baseline.put(key, fields.remove(key))
                    pending.remove(key)
                }
                backing.raw = baselineOnly.toString()
                assertRefused(credential, ticket)
                backing.raw = value.encoded()
                paused = true
                assertRefused(credential, ticket)
                paused = false
                current = original.copy(generation = 8)
                assertRefused(credential, ticket)
                current = original
                backing.status = AccountFileLocalPresence.UNAVAILABLE
                assertRefused(credential, ticket)
                backing.status = AccountFileLocalPresence.PRESENT
                assertTrue(credential.operation.claimOutbound(ticket, ticket::claim))
                assertFalse(credential.operation.claimOutbound(ticket, ticket::claim))
            } finally {
                credential.operation.closeOutbound(ticket)
                ticket.close()
            }
            bind()
            assertFalse(credential.operation.isCurrent())
        }
    }

    private fun assertRefused(credential: DurableProviderMirrorCredential, ticket: ProviderCallTicket) {
        assertFalse(credential.operation.isCurrent())
        assertFalse(credential.operation.claimOutbound(ticket) { error("Unexpected stale first I/O") })
    }

    private fun capture(ownerEpoch: Long = 11) =
        coordinator.snapshotRetryForOwner(original, ownerEpoch, key, Provider.TRAKT) { true }

    private fun modern() = NativeProviderCredentials("account.${original.id}").apply {
        edit(tuple, mapOf("traktCreated" to "100"))
    }

    private fun bind() = NativeProviderAccess.bind(vault, object : NativeProviderAdmission {
        override fun <T> withCurrent(expected: SessionOwnerSnapshot.Account?, action: (SessionOwnerSnapshot.Account) -> T): T? =
            error("Unexpected ordinary owner open")
        override fun <T> withExistingRetryCurrent(
            expected: SessionOwnerSnapshot.Account,
            action: (SessionOwnerSnapshot.Account) -> T,
        ): T? = if (paused || current != expected) null else action(current)
    }) { error("Unexpected vault write callback") }

    private class Backing(private val exactKey: String) : CredentialStoreAccess {
        var raw: String? = null
        var status = AccountFileLocalPresence.PRESENT
        var repeatValue = false
        var existingReads = 0
            private set
        override fun inspectExisting(key: String, isInert: (String) -> Boolean): AccountFileLocalPresence {
            check(key == exactKey)
            existingReads += 1
            raw?.let {
                check(!isInert(it))
                if (repeatValue) check(!isInert(it))
            }
            return status
        }
        override fun string(key: String): String? = error("Unexpected normal read")
        override fun confirmedSnapshot(vararg keys: String): PersistentCredentialSnapshot = error("Unexpected normal load")
        override fun set(key: String, value: String?): Boolean = error("Unexpected vault seed")
        override fun set(values: Map<String, String?>): Boolean = error("Unexpected vault write")
        override fun clear(vararg keys: String): Boolean = error("Unexpected vault clear")
    }
}
