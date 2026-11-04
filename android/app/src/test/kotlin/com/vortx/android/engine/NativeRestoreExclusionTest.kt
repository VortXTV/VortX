package com.vortx.android.engine

import com.vortx.android.profile.UserProfile
import com.vortx.android.sync.SessionOwnerSnapshot
import javax.crypto.SecretKey
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeRestoreExclusionTest {
    private val account = SessionOwnerSnapshot.Account("00000000-0000-0000-0000-000000000456", 7)
    private val owner = "00000000-0000-0000-0000-000000000001"
    private val scope = VortxAccountScope("account.${account.id}", owner)
    private val otherOwner = scope.copy(ownerProfileID = "00000000-0000-0000-0000-000000000002")

    private open inner class Store : VortxCheckpointStore {
        var checkpoint: String? = null
        var preflight: NativeMigrationPreflight? = null
        var discoveries = 0
        var commits = 0
        var onDiscover: () -> Unit = {}
        override fun discover(accountID: String): VortxAccountScope? {
            assertEquals(scope.accountID, accountID)
            discoveries++
            onDiscover()
            return scope.takeIf { checkpoint != null }
        }
        override fun readPreflight(accountID: String): NativeMigrationPreflight? = preflight
        override fun read(scope: VortxAccountScope): String? = checkpoint
        override fun commit(scope: VortxAccountScope, snapshot: String) {
            commits++
            checkpoint = snapshot
        }
    }

    private inner class ProofStore : Store() {
        var observed = AccountFileLocalPresence.ABSENT
        val checked = mutableListOf<VortxAccountScope>()
        var duringProof: () -> Unit = {}
        override fun inspectRestoreAbsence(scope: VortxAccountScope, readCompleteAliases: () -> Set<String>,
            readExistingKey: (VortxAccountScope) -> SecretKey?): AccountFileLocalPresence {
            checked.add(scope)
            duringProof()
            return observed
        }
    }

    private class Runtime : VortxRuntimeBindings {
        private var stored: String? = null
        var failFree = false
        var hydrations = 0
        var frees = 0
        override fun create(ownerId: String, ownerName: String): Long = error("No new native session")
        override fun hydrate(snapshot: String): Long { stored = snapshot; hydrations++; return 1 }
        override fun dispatch(handle: Long, action: String): String {
            check(JSONObject(action).getString("type") == "bind_sync_scope")
            return """{"ok":true}"""
        }
        override fun resolve(handle: Long, request: String): String = error("No native resolution")
        override fun state(handle: Long): String = checkNotNull(stored)
        override fun delta(handle: Long): String = error("No native delta")
        override fun free(handle: Long) {
            frees++
            check(!failFree) { "Fixture unconfirmed free" }
            stored = null
        }
    }

    private inner class Fixture(val store: Store = ProofStore()) {
        val runtime = Runtime()
        val disposals = mutableListOf<() -> Unit>()
        var original = account
        var ordinaryAccountReads = 0
        var authorityChanged: () -> Unit = {}
        val coordinator = NativeAccountCoordinator(runtime, store, { object : VortxResourceTransport {
            override fun makeCancellation(): VortxResourceCancellation = error("No native request")
            override fun load(requestJson: String, cancellation: VortxResourceCancellation): String = error("No native request")
        } }, { ordinaryAccountReads++; it == original }, { disposals.add(it) }, {},
            onAuthorityChanged = { authorityChanged() })
        val requireOriginal: () -> Unit = { check(original == account) { "Original fixture owner epoch retired" } }
    }

    private fun snapshot(): String {
        val profile = JSONObject().put("id", owner).put("name", "Main").put("owner", true).put("deleted", false)
        val native = JSONObject().put("schemaVersion", 1).put("scope", scope.accountID).put("ownerProfileId", owner)
            .put("profiles", JSONObject()).put("addons", JSONObject()).put("libraries", JSONObject())
            .put("watches", JSONObject()).put("legacyImport", JSONObject())
        return JSONObject().put("roster", JSONObject().put("profiles", JSONObject().put(owner, profile)))
            .put("activeProfileId", owner).put("libraries", JSONObject().put(owner, JSONObject()))
            .put("nativeSync", native).toString()
    }

    @Test fun heldWitnessChecksPhysicalEvidenceAndPinsExactScopeAndEpoch() = runBlocking {
        val store = ProofStore()
        val fixture = Fixture(store)
        val coordinator = fixture.coordinator
        lateinit var prior: NativeAccountCoordinator.RestoreNativeExclusion
        assertEquals(true, coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { held ->
            prior = held
            held.requireCurrent(account)
            assertTrue(runCatching { held.requireCurrent(account, scope) }.isFailure)
            assertTrue(runCatching { held.requireCurrent(account.copy(generation = 8)) }.isFailure)
            assertTrue(runCatching { held.inspectAbsenceOnWorker(account, scope.copy(accountID = "account.$owner")) }.isFailure)
            assertEquals(AccountFileLocalPresence.ABSENT, held.inspectAbsence(account, scope))
            held.requireCurrent(account, scope)
            assertTrue(runCatching { held.inspectAbsenceOnWorker(account, otherOwner) }.isFailure)
            store.observed = AccountFileLocalPresence.PRESENT
            assertEquals(AccountFileLocalPresence.PRESENT, held.inspectAbsenceOnWorker(account, scope))
            store.observed = AccountFileLocalPresence.UNAVAILABLE
            assertEquals(AccountFileLocalPresence.UNAVAILABLE, held.inspectAbsenceOnWorker(account, scope))
            assertEquals(listOf(scope, scope, scope), store.checked)
            assertEquals(0, fixture.ordinaryAccountReads)
            assertEquals(0, fixture.runtime.hydrations)
            assertEquals(0, store.discoveries)
            assertEquals(0, store.commits)
            true
        })
        assertTrue(runCatching { prior.requireCurrent(account) }.isFailure)
        assertEquals(true, coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) {
            assertTrue(runCatching { prior.requireCurrent(account) }.isFailure)
            true
        })

        val unavailable = Fixture(Store())
        assertEquals(AccountFileLocalPresence.UNAVAILABLE,
            unavailable.coordinator.withRestoreNativeExclusion(account, unavailable.requireOriginal) {
                it.inspectAbsenceOnWorker(account, scope)
            })
    }

    @Test fun writerAndRestoreReservationExcludeEachOtherWithoutMutexReentry() = runBlocking {
        val fixture = Fixture()
        val coordinator = fixture.coordinator
        lateinit var inFlight: Deferred<Boolean?>
        fixture.store.onDiscover = {
            inFlight = async(start = CoroutineStart.UNDISPATCHED) {
                coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) {
                    fail("In-flight native writer was missed")
                    true
                }
            }
        }
        assertFalse(coordinator.reopenCheckpoint(account) { true })
        assertNull(inFlight.await())

        val ordinaryReads = fixture.ordinaryAccountReads
        withTimeout(2_000) {
            assertEquals(true, coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) {
                assertNull(coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { false })
                assertTrue(runCatching { coordinator.reopenCheckpoint(account) { true } }.isFailure)
                assertTrue(runCatching { coordinator.prepareEmptyAccount(account) { true } }.isFailure)
                assertTrue(runCatching { coordinator.applyDocument(account, JSONObject()) { true } }.isFailure)
                assertTrue(runCatching { coordinator.applyRawDocument(account, byteArrayOf(0)) { true } }.isFailure)
                assertEquals(ordinaryReads, fixture.ordinaryAccountReads)
                assertEquals(1, fixture.store.discoveries)
                assertEquals(0, fixture.store.commits)
                true
            })
        }
    }

    @Test fun ownerRetirementDuringProofRevokesResultButHoldsWriterUntilDrain() = runBlocking {
        val store = ProofStore()
        val fixture = Fixture(store)
        val coordinator = fixture.coordinator
        assertEquals(true, coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { held ->
            store.duringProof = coordinator::retire
            assertTrue(runCatching { held.inspectAbsenceOnWorker(account, scope) }.isFailure)
            assertTrue(runCatching { held.requireCurrent(account) }.isFailure)
            assertNull(coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { false })
            assertTrue(runCatching { coordinator.reopenCheckpoint(account) { true } }.isFailure)
            assertEquals(0, store.discoveries)
            true
        })
        assertEquals(true, coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { held ->
            fixture.original = account.copy(generation = 8)
            assertTrue(runCatching { held.requireCurrent(account) }.isFailure)
            true
        })
        fixture.original = account
        store.duringProof = { throw CancellationException("Fixture cancellation") }
        val cancelled = runCatching {
            coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) {
                it.inspectAbsenceOnWorker(account, scope)
            }
        }.exceptionOrNull()
        assertTrue(cancelled is CancellationException)
        assertEquals(true, coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { true })
    }

    @Test fun mountedAndQueuedRetiredWritersRefuseEvenWithoutCheckpoint() = runBlocking {
        val store = ProofStore()
        val fixture = Fixture(store)
        val coordinator = fixture.coordinator
        store.checkpoint = snapshot()
        assertTrue(coordinator.reopenCheckpoint(account) { true })
        store.checkpoint = null
        assertNull(coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { false })
        coordinator.retire()
        assertNull(coordinator.currentMountToken(account))
        assertNull(coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { false })
        assertEquals(emptyList<VortxAccountScope>(), store.checked)
        fixture.disposals.single().invoke()
        assertEquals(1, fixture.runtime.frees)
        assertEquals(AccountFileLocalPresence.ABSENT,
            coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { it.inspectAbsenceOnWorker(account, scope) })
    }

    @Test fun pendingPreflightPresentationCannotBeMistakenForAnIdleNullMount() = runBlocking {
        val store = ProofStore()
        val fixture = Fixture(store)
        val coordinator = fixture.coordinator
        val profile = UserProfile(id = owner, name = "Main", avatar = "A", isOwner = true)
        val legacy = JSONObject().put("vortx", JSONObject().put("roster", JSONArray().put(profile.encode()))
            .put("rosterModified", 0).put("library", JSONArray()).put("addons", JSONArray()))
        store.preflight = NativeMigrationPreflight.create(scope, NativeHostDocument.archive(legacy), emptyList())
        assertFalse(coordinator.reopenCheckpoint(account) { true })
        store.preflight = null
        assertNull(coordinator.currentMountToken(account))
        assertNull(coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { false })
        assertEquals(emptyList<VortxAccountScope>(), store.checked)
        coordinator.retire()
        assertEquals(AccountFileLocalPresence.ABSENT,
            coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { it.inspectAbsenceOnWorker(account, scope) })
    }

    @Test fun interruptedInstallationWithoutAMountDoesNotCertifyIdle() = runBlocking {
        val store = ProofStore()
        val fixture = Fixture(store)
        val coordinator = fixture.coordinator
        store.checkpoint = snapshot()
        fixture.authorityChanged = { check(fixture.runtime.hydrations == 0) { "Fixture interrupted publication" } }
        assertTrue(runCatching { coordinator.reopenCheckpoint(account) { true } }.isFailure)
        assertEquals(1, fixture.runtime.hydrations)
        store.checkpoint = null
        assertNull(coordinator.currentMountToken(account))
        assertNull(coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { false })
        assertEquals(emptyList<VortxAccountScope>(), store.checked)
    }

    @Test fun unconfirmedRetirementStaysRefusedAfterOrdinaryRetryClearsTheQueue() = runBlocking {
        val store = ProofStore()
        val fixture = Fixture(store)
        val coordinator = fixture.coordinator
        store.checkpoint = snapshot()
        assertTrue(coordinator.reopenCheckpoint(account) { true })
        coordinator.retire()
        store.checkpoint = null
        fixture.runtime.failFree = true
        assertTrue(runCatching { fixture.disposals.single().invoke() }.isFailure)
        assertEquals(1, fixture.runtime.frees)
        assertNull(coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { false })
        fixture.runtime.failFree = false
        // Generic runtime cleared its handle before free. The next close returns without a second free.
        assertFalse(coordinator.reopenCheckpoint(account) { true })
        assertEquals(1, fixture.runtime.frees)
        assertNull(coordinator.withRestoreNativeExclusion(account, fixture.requireOriginal) { false })
        assertEquals(emptyList<VortxAccountScope>(), store.checked)
    }
}
