package com.vortx.android.debrid

import com.vortx.android.sync.DurableSessionState
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DebridKeysContractTest {

    @Test
    fun unknownOwnerCannotReadOrClaimLegacyUntilSignOutIsDefinitive() {
        val legacyKey = DebridService.REAL_DEBRID.legacyStorageKey
        val values = mutableMapOf(legacyKey to "legacy-key")
        val claim = ClaimState()
        var state: DebridAccountOwnerState = DebridAccountOwnerState.UnknownOrUnavailable
        val keys = DebridKeys(
            FakeDebridKeyValueStore(values, claim = claim),
            DebridAccountOwnerBinding().apply { bind { state } },
        )

        assertEquals("", keys.key(DebridService.REAL_DEBRID))
        assertTrue(keys.status(DebridService.REAL_DEBRID).storageUnavailable)
        assertEquals(LegacyOwnerReservation.Missing, claim.value)

        state = DebridAccountOwnerState.SignedOutLocal(generation = 2)

        assertEquals("legacy-key", keys.key(DebridService.REAL_DEBRID))
        assertEquals(
            LegacyOwnerReservation.Claimed(DebridKeys.LOCAL_OWNER_IDENTITY),
            claim.value,
        )
    }

    @Test
    fun processBindingSwitchesEveryReaderAndGenerationInvalidatesSameAccountToken() {
        val store = FakeDebridKeyValueStore()
        var state: DebridAccountOwnerState =
            DebridAccountOwnerState.Account("account-a", generation = 1)
        DebridKeys.bindAccountOwnerSource { state }
        try {
            val ui = DebridKeys(store)
            val resolver = DebridKeys(store)

            assertTrue(ui.setKey(DebridService.REAL_DEBRID, "key-a"))
            assertEquals("key-a", resolver.key(DebridService.REAL_DEBRID))
            val firstToken = resolver.ownerToken()!!

            state = DebridAccountOwnerState.Account("account-a", generation = 2)

            assertFalse(resolver.isCurrent(firstToken))
            assertNotEquals(firstToken, resolver.ownerToken())
            assertEquals("key-a", resolver.key(DebridService.REAL_DEBRID))

            state = DebridAccountOwnerState.SignedOutLocal(generation = 3)
            assertEquals("", ui.key(DebridService.REAL_DEBRID))
            assertEquals(DebridKeys.LOCAL_OWNER_IDENTITY, ui.ownerIdentity())
        } finally {
            DebridKeys.bindAccountOwnerSource(null)
        }
    }

    @Test
    fun accountNamedLocalCannotCollideWithSignedOutDeviceStorage() {
        val store = FakeDebridKeyValueStore()
        var state: DebridAccountOwnerState =
            DebridAccountOwnerState.Account("local", generation = 1)
        val keys = DebridKeys(
            store,
            DebridAccountOwnerBinding().apply { bind { state } },
        )

        assertTrue(keys.setKey(DebridService.TOR_BOX, "account-key"))
        val accountIdentity = keys.ownerIdentity()

        state = DebridAccountOwnerState.SignedOutLocal(generation = 2)
        assertNotEquals(accountIdentity, keys.ownerIdentity())
        assertEquals("", keys.key(DebridService.TOR_BOX))
        assertTrue(keys.setKey(DebridService.TOR_BOX, "device-key"))

        state = DebridAccountOwnerState.Account("local", generation = 3)
        assertEquals("account-key", keys.key(DebridService.TOR_BOX))
    }

    @Test
    fun claimedOwnerMirrorsLegacyReplaceAndClearForRollback() {
        val legacyKey = DebridService.REAL_DEBRID.legacyStorageKey
        val values = mutableMapOf(legacyKey to "legacy-key")
        val claim = ClaimState()
        val keys = accountKeys(
            FakeDebridKeyValueStore(values, claim = claim),
            id = "account-a",
        )

        assertEquals("legacy-key", keys.key(DebridService.REAL_DEBRID))
        assertTrue(keys.setKey(DebridService.REAL_DEBRID, "new-key"))
        assertEquals("new-key", values[legacyKey])
        assertEquals("new-key", keys.key(DebridService.REAL_DEBRID))

        assertTrue(keys.setKey(DebridService.REAL_DEBRID, ""))
        assertFalse(values.containsKey(legacyKey))
        assertEquals("", keys.key(DebridService.REAL_DEBRID))
    }

    @Test
    fun nonClaimedOwnerTombstonesRollbackSlotAndPreservesClaimantsScopedCopy() {
        val legacyKey = DebridService.ALL_DEBRID.legacyStorageKey
        val scopedA = DebridService.ALL_DEBRID.storageKey(DebridOwnerScope.Account("account-a"))
        val values = mutableMapOf(
            legacyKey to "owner-a-key",
            DebridKeys.LEGACY_OWNER_KEY to "account:account-a",
        )
        val store = FakeDebridKeyValueStore(
            values,
            claim = ClaimState(LegacyOwnerReservation.Claimed("account:account-a")),
        )
        val keys = accountKeys(store, id = "account-b")

        assertTrue(keys.setKey(DebridService.ALL_DEBRID, "owner-b-key"))
        assertFalse(values.containsKey(legacyKey))
        assertEquals("owner-a-key", values[scopedA])
        assertEquals("owner-b-key", keys.key(DebridService.ALL_DEBRID))

        assertTrue(keys.setKey(DebridService.ALL_DEBRID, ""))
        assertFalse(values.containsKey(legacyKey))
        // This is exactly the pre-scoping reader at 6277116: rollback sees no global credential under B.
        assertEquals("", values[legacyKey].orEmpty())
    }

    @Test
    fun failedFirstClaimSurvivesRestartBlocksBAndLetsAResume() {
        val legacyKey = DebridService.PREMIUMIZE.legacyStorageKey
        val scopedA =
            DebridService.PREMIUMIZE.storageKey(DebridOwnerScope.Account("account-a"))
        val scopedB =
            DebridService.PREMIUMIZE.storageKey(DebridOwnerScope.Account("account-b"))
        val values = mutableMapOf(legacyKey to "legacy-key")
        val firstClaim = ClaimState()
        val firstStore = FakeDebridKeyValueStore(
            values,
            claim = firstClaim,
            claimSucceeds = false,
        )

        assertEquals("", accountKeys(firstStore, "account-a").key(DebridService.PREMIUMIZE))
        assertEquals("account:account-a", values[DebridKeys.LEGACY_OWNER_KEY])
        assertFalse(values.containsKey(scopedA))
        assertEquals(LegacyOwnerReservation.Missing, firstClaim.value)

        val restartedClaim = ClaimState()
        val ownerB = accountKeys(
            FakeDebridKeyValueStore(values, claim = restartedClaim),
            "account-b",
        )
        assertEquals("", ownerB.key(DebridService.PREMIUMIZE))
        assertFalse(values.containsKey(scopedB))
        assertEquals(LegacyOwnerReservation.Missing, restartedClaim.value)

        val ownerA = accountKeys(
            FakeDebridKeyValueStore(values, claim = restartedClaim),
            "account-a",
        )
        assertEquals("legacy-key", ownerA.key(DebridService.PREMIUMIZE))
        assertEquals("legacy-key", values[scopedA])
        assertEquals(
            LegacyOwnerReservation.Claimed("account:account-a"),
            restartedClaim.value,
        )
    }

    @Test
    fun accountSwitchAfterFailedClaimTombstonesGlobalSlotInSameProcess() {
        val legacyKey = DebridService.REAL_DEBRID.legacyStorageKey
        val scopedA = DebridService.REAL_DEBRID.storageKey(DebridOwnerScope.Account("account-a"))
        val values = mutableMapOf(legacyKey to "owner-a-key")
        val store = FakeDebridKeyValueStore(
            persistentValues = values,
            claimSucceeds = false,
        )
        var state: DebridAccountOwnerState =
            DebridAccountOwnerState.Account("account-a", generation = 1)
        val keys = DebridKeys(
            store,
            DebridAccountOwnerBinding().apply { bind { state } },
        )

        assertEquals("", keys.key(DebridService.REAL_DEBRID))
        assertEquals("account:account-a", values[DebridKeys.LEGACY_OWNER_KEY])

        state = DebridAccountOwnerState.Account("account-b", generation = 2)

        assertEquals("", keys.key(DebridService.REAL_DEBRID))
        assertFalse(values.containsKey(legacyKey))
        assertEquals("owner-a-key", values[scopedA])
    }

    @Test
    fun reservedOwnerMutationWaitsForClaimSoRollbackCannotResurrectOldKey() {
        val legacyKey = DebridService.PREMIUMIZE.legacyStorageKey
        val scopedA =
            DebridService.PREMIUMIZE.storageKey(DebridOwnerScope.Account("account-a"))
        val values = mutableMapOf(legacyKey to "old-key")
        val claim = ClaimState()
        val store = FakeDebridKeyValueStore(
            values,
            claim = claim,
            claimSucceeds = false,
        )
        val keys = accountKeys(store, "account-a")

        assertEquals("", keys.key(DebridService.PREMIUMIZE))
        assertFalse(keys.setKey(DebridService.PREMIUMIZE, "new-key"))
        assertEquals("old-key", values[legacyKey])
        assertFalse(values.containsKey(scopedA))

        store.claimSucceeds = true

        assertTrue(keys.setKey(DebridService.PREMIUMIZE, "new-key"))
        assertEquals("new-key", values[legacyKey])
        assertEquals("new-key", values[scopedA])

        assertTrue(keys.setKey(DebridService.PREMIUMIZE, ""))
        assertFalse(values.containsKey(legacyKey))
        assertFalse(values.containsKey(scopedA))
    }

    @Test
    fun ownerSwitchDuringLegacyMirrorCannotRecreateTombstonedRollbackSlot() {
        val legacyKey = DebridService.REAL_DEBRID.legacyStorageKey
        val scopedA =
            DebridService.REAL_DEBRID.storageKey(DebridOwnerScope.Account("account-a"))
        val values = mutableMapOf(
            legacyKey to "owner-a-key",
            DebridKeys.LEGACY_OWNER_KEY to "account:account-a",
        )
        val mirrorWriteEntered = CountDownLatch(1)
        val releaseMirrorWrite = CountDownLatch(1)
        val store = FakeDebridKeyValueStore(
            persistentValues = values,
            claim = ClaimState(LegacyOwnerReservation.Claimed("account:account-a")),
            beforeWrite = { mutation ->
                if (mutation[legacyKey] == "replacement-a") {
                    mirrorWriteEntered.countDown()
                    assertTrue(
                        "Timed out waiting to release the legacy mirror write",
                        releaseMirrorWrite.await(5, TimeUnit.SECONDS),
                    )
                }
            },
        )
        val state = AtomicReference<DebridAccountOwnerState>(
            DebridAccountOwnerState.Account("account-a", generation = 1),
        )
        val binding = DebridAccountOwnerBinding().apply { bind(state::get) }
        val writerKeys = DebridKeys(store, binding)
        val switchKeys = DebridKeys(store, binding)
        val mutationResult = AtomicReference<Boolean>()
        val writerFailure = AtomicReference<Throwable?>()
        val switchFailure = AtomicReference<Throwable?>()
        val switchFinished = CountDownLatch(1)

        assertEquals("owner-a-key", writerKeys.key(DebridService.REAL_DEBRID))
        val writer = thread(name = "debrid-mirror-writer") {
            runCatching {
                mutationResult.set(writerKeys.setKey(DebridService.REAL_DEBRID, "replacement-a"))
            }.onFailure(writerFailure::set)
        }
        assertTrue(mirrorWriteEntered.await(5, TimeUnit.SECONDS))

        state.set(DebridAccountOwnerState.Account("account-b", generation = 2))
        val switcher = thread(name = "debrid-owner-switch") {
            try {
                switchKeys.key(DebridService.REAL_DEBRID)
            } catch (error: Throwable) {
                switchFailure.set(error)
            } finally {
                switchFinished.countDown()
            }
        }

        try {
            awaitCompletionOrMonitorBlock(switcher, switchFinished)
        } finally {
            releaseMirrorWrite.countDown()
        }
        writer.join(5_000)
        switcher.join(5_000)

        assertFalse("Legacy mirror writer did not finish", writer.isAlive)
        assertFalse("Owner switch did not finish", switcher.isAlive)
        writerFailure.get()?.let { throw AssertionError("Legacy mirror writer failed", it) }
        switchFailure.get()?.let { throw AssertionError("Owner switch failed", it) }
        assertFalse("The stale mutation must report that its owner changed", mutationResult.get())
        assertFalse("The old-reader rollback slot must stay tombstoned", values.containsKey(legacyKey))
        assertEquals("replacement-a", values[scopedA])
        assertEquals("", switchKeys.key(DebridService.REAL_DEBRID))
    }

    @Test
    fun ownerPublicationWaitsAcrossTheFinalMirrorCheckAndTombstonesBeforeBecomingVisible() {
        val service = DebridService.ALL_DEBRID
        val legacyKey = service.legacyStorageKey
        val scopedA = service.storageKey(DebridOwnerScope.Account("account-a"))
        val values = mutableMapOf(
            legacyKey to "owner-a-key",
            DebridKeys.LEGACY_OWNER_KEY to "account:account-a",
        )
        val finalCheckArmed = AtomicBoolean(false)
        val finalCheckEntered = CountDownLatch(1)
        val releaseFinalCheck = CountDownLatch(1)
        val transitionFinished = CountDownLatch(1)
        val ownerPublished = CountDownLatch(1)
        val state = AtomicReference<DebridAccountOwnerState>(
            DebridAccountOwnerState.Account("account-a", generation = 1),
        )
        val store = FakeDebridKeyValueStore(
            persistentValues = values,
            claim = ClaimState(LegacyOwnerReservation.Claimed("account:account-a")),
            afterSnapshot = { keys ->
                if (
                    keys.toSet() == setOf(scopedA, legacyKey) &&
                    values[legacyKey] == "replacement-a"
                ) {
                    finalCheckArmed.set(true)
                }
            },
        )
        val binding = DebridAccountOwnerBinding().apply {
            bind {
                if (finalCheckArmed.compareAndSet(true, false)) {
                    finalCheckEntered.countDown()
                    assertTrue(releaseFinalCheck.await(5, TimeUnit.SECONDS))
                }
                state.get()
            }
        }
        val writerKeys = DebridKeys(store, binding)
        val transitionKeys = DebridKeys(store, binding)
        val writerResult = AtomicReference<Boolean>()
        val transitionResult = AtomicReference<Boolean>()
        val writerFailure = AtomicReference<Throwable?>()
        val transitionFailure = AtomicReference<Throwable?>()

        assertEquals("owner-a-key", writerKeys.key(service))
        val writer = thread(name = "debrid-final-check-writer") {
            runCatching {
                writerResult.set(writerKeys.setKey(service, "replacement-a"))
            }.onFailure(writerFailure::set)
        }
        assertTrue(finalCheckEntered.await(5, TimeUnit.SECONDS))

        val transition = thread(name = "debrid-owner-publication") {
            try {
                transitionResult.set(
                    transitionKeys.runOwnerTransition {
                        assertTrue(
                            DebridService.entries.all {
                                !values.containsKey(it.legacyStorageKey)
                            },
                        )
                        state.set(DebridAccountOwnerState.Account("account-b", generation = 2))
                        ownerPublished.countDown()
                        true
                    },
                )
            } catch (error: Throwable) {
                transitionFailure.set(error)
            } finally {
                transitionFinished.countDown()
            }
        }
        awaitCompletionOrMonitorBlock(transition, transitionFinished)
        assertEquals("The new owner cannot publish before the mirror lock releases", 1L, ownerPublished.count)

        releaseFinalCheck.countDown()
        writer.join(5_000)
        transition.join(5_000)

        assertFalse("Legacy mirror writer did not finish", writer.isAlive)
        assertFalse("Owner publication did not finish", transition.isAlive)
        writerFailure.get()?.let { throw AssertionError("Legacy mirror writer failed", it) }
        transitionFailure.get()?.let { throw AssertionError("Owner publication failed", it) }
        assertTrue(writerResult.get())
        assertTrue(transitionResult.get())
        assertEquals(
            DebridAccountOwnerState.Account("account-b", generation = 2),
            state.get(),
        )
        assertFalse(values.containsKey(legacyKey))
        assertEquals("replacement-a", values[scopedA])
    }

    @Test
    fun failedRollbackTombstoneVerificationPreventsOwnerMutationAndPublication() {
        val retainedLegacyKey = DebridService.REAL_DEBRID.legacyStorageKey
        val scopedA =
            DebridService.REAL_DEBRID.storageKey(DebridOwnerScope.Account("account-a"))
        val values = mutableMapOf(
            retainedLegacyKey to "owner-a-key",
            scopedA to "owner-a-key",
        )
        var attemptedTombstones: Map<String, String?> = emptyMap()
        var mutationCalled = false
        val keys = accountKeys(
            FakeDebridKeyValueStore(
                persistentValues = values,
                retainKeysOnClear = setOf(retainedLegacyKey),
                beforeWrite = { mutation ->
                    if (mutation.values.all { it == null }) attemptedTombstones = mutation
                },
            ),
            id = "account-a",
        )

        assertFalse(
            keys.runOwnerTransition {
                mutationCalled = true
                true
            },
        )

        assertFalse(mutationCalled)
        assertEquals(
            DebridService.entries.map { it.legacyStorageKey }.toSet(),
            attemptedTombstones.keys,
        )
        assertTrue(attemptedTombstones.values.all { it == null })
        assertEquals("owner-a-key", values[retainedLegacyKey])
        assertEquals("owner-a-key", values[scopedA])
    }

    @Test
    fun failedSessionReplacementAfterTombstoneKeepsPriorOwnerAndScopedCredential() {
        val legacyKey = DebridService.PREMIUMIZE.legacyStorageKey
        val scopedA =
            DebridService.PREMIUMIZE.storageKey(DebridOwnerScope.Account("account-a"))
        val values = mutableMapOf(
            legacyKey to "owner-a-key",
        )
        val keys = accountKeys(FakeDebridKeyValueStore(values), id = "account-a")
        var durableOwner = "account-a"
        var publications = 0
        val session = DurableSessionState(
            initialValue = durableOwner,
            persist = {
                false
            },
            clear = {
                durableOwner = ""
                true
            },
            ownerTransition = keys::runOwnerTransition,
        )

        assertFalse(session.replace("account-b") { publications += 1 })
        assertEquals("account-a", session.value)
        assertEquals("account-a", durableOwner)
        assertEquals(0, publications)
        assertFalse(values.containsKey(legacyKey))
        assertEquals("owner-a-key", values[scopedA])
    }

    @Test
    fun invalidOrPartialReservationBlocksEveryLegacyAdoption() {
        val legacyKey = DebridService.TOR_BOX.legacyStorageKey
        val values = mutableMapOf(legacyKey to "legacy-key")
        val store = FakeDebridKeyValueStore(
            values,
            claim = ClaimState(LegacyOwnerReservation.InvalidOrUnavailable),
        )

        assertEquals("", accountKeys(store, "account-a").key(DebridService.TOR_BOX))
        assertFalse(
            values.containsKey(
                DebridService.TOR_BOX.storageKey(DebridOwnerScope.Account("account-a")),
            ),
        )
    }

    @Test
    fun matchingEncryptedReservationRepairsCorruptClaimBeforeMutation() {
        val legacyKey = DebridService.TOR_BOX.legacyStorageKey
        val scoped = DebridService.TOR_BOX.storageKey(DebridOwnerScope.Account("account-a"))
        val values = mutableMapOf(
            legacyKey to "legacy-key",
            DebridKeys.LEGACY_OWNER_KEY to "account:account-a",
        )
        val claim = ClaimState(LegacyOwnerReservation.InvalidOrUnavailable)
        val keys = accountKeys(FakeDebridKeyValueStore(values, claim = claim), "account-a")

        assertEquals("legacy-key", keys.key(DebridService.TOR_BOX))
        assertEquals(LegacyOwnerReservation.Claimed("account:account-a"), claim.value)
        assertEquals("legacy-key", values[scoped])
        assertTrue(keys.setKey(DebridService.TOR_BOX, "replacement"))
        assertEquals("replacement", values[scoped])
    }

    @Test
    fun failedCorruptClaimRepairIsUnavailableAndRetryable() {
        val legacyKey = DebridService.PREMIUMIZE.legacyStorageKey
        val values = mutableMapOf(
            legacyKey to "legacy-key",
            DebridKeys.LEGACY_OWNER_KEY to "account:account-a",
        )
        val store = FakeDebridKeyValueStore(
            values,
            claim = ClaimState(LegacyOwnerReservation.InvalidOrUnavailable),
            repairSucceeds = false,
        )
        val keys = accountKeys(store, "account-a")

        assertTrue(keys.status(DebridService.PREMIUMIZE).storageUnavailable)
        assertFalse(keys.setKey(DebridService.PREMIUMIZE, "replacement"))

        store.repairSucceeds = true

        assertTrue(keys.setKey(DebridService.PREMIUMIZE, "replacement"))
        assertFalse(keys.status(DebridService.PREMIUMIZE).storageUnavailable)
        assertEquals("replacement", keys.key(DebridService.PREMIUMIZE))
    }

    @Test
    fun initialSecureStoreUnavailableIsVisibleAndLaterReadRecovers() {
        val scoped =
            DebridService.REAL_DEBRID.storageKey(DebridOwnerScope.Account("account-a"))
        val store = FakeDebridKeyValueStore(
            persistentValues = mutableMapOf(scoped to "saved-key"),
            available = false,
        )
        val keys = accountKeys(store, "account-a")

        assertEquals("", keys.key(DebridService.REAL_DEBRID))
        assertTrue(keys.status(DebridService.REAL_DEBRID).storageUnavailable)
        assertFalse(keys.status(DebridService.REAL_DEBRID).durablyConfigured)

        store.available = true

        assertEquals("saved-key", keys.key(DebridService.REAL_DEBRID))
        assertFalse(keys.status(DebridService.REAL_DEBRID).storageUnavailable)
        assertTrue(keys.status(DebridService.REAL_DEBRID).durablyConfigured)
    }

    @Test
    fun rejectedMutationNeverPublishesUnconfirmedValue() {
        val scoped =
            DebridService.TOR_BOX.storageKey(DebridOwnerScope.Account("account-a"))
        val store = FakeDebridKeyValueStore(
            persistentValues = mutableMapOf(scoped to "old-key"),
            writeSucceeds = false,
        )
        val keys = accountKeys(store, "account-a")

        assertFalse(keys.setKey(DebridService.TOR_BOX, "new-key"))
        assertEquals("", keys.key(DebridService.TOR_BOX))
        assertTrue(keys.status(DebridService.TOR_BOX).storageUnavailable)

        store.available = true
        store.writeSucceeds = true

        assertEquals("old-key", keys.key(DebridService.TOR_BOX))
    }

    @Test
    fun credentialSnapshotAdvancesOnlyWithConfirmedCredentialMutation() {
        val store = FakeDebridKeyValueStore()
        val keys = accountKeys(store, "account-revision")
        val initial = keys.credentialSnapshot(DebridService.TOR_BOX)

        assertTrue(keys.setKey(DebridService.TOR_BOX, "key-a"))
        val keyA = keys.credentialSnapshot(DebridService.TOR_BOX)
        assertEquals("key-a", keyA.key)
        assertTrue(keyA.revision > initial.revision)

        assertTrue(keys.setKey(DebridService.TOR_BOX, "key-a"))
        assertEquals(keyA.revision, keys.credentialSnapshot(DebridService.TOR_BOX).revision)

        store.writeSucceeds = false
        assertFalse(keys.setKey(DebridService.TOR_BOX, "key-b"))
        val unavailable = keys.credentialSnapshot(DebridService.TOR_BOX)
        assertEquals("", unavailable.key)
        assertTrue(unavailable.revision > keyA.revision)
    }

    @Test
    fun ownerClaimCodecRejectsPartialOversizedAndCorruptRecords() {
        val encoded = LegacyOwnerClaimCodec.encode("account:account-a")
        assertEquals(
            LegacyOwnerReservation.Claimed("account:account-a"),
            LegacyOwnerClaimCodec.decode(encoded),
        )

        assertEquals(
            LegacyOwnerReservation.InvalidOrUnavailable,
            LegacyOwnerClaimCodec.decode(encoded.copyOf(encoded.size - 1)),
        )

        val corrupt = encoded.copyOf().also { it[it.lastIndex] = (it.last() + 1).toByte() }
        assertEquals(
            LegacyOwnerReservation.InvalidOrUnavailable,
            LegacyOwnerClaimCodec.decode(corrupt),
        )
        assertEquals(
            LegacyOwnerReservation.InvalidOrUnavailable,
            LegacyOwnerClaimCodec.decode(ByteArray(DebridKeys.MAX_CLAIM_FILE_BYTES + 1)),
        )
        assertThrows(IllegalArgumentException::class.java) {
            LegacyOwnerClaimCodec.encode("x".repeat(DebridKeys.MAX_CLAIM_OWNER_BYTES + 1))
        }
        assertArrayEquals(encoded, LegacyOwnerClaimCodec.encode("account:account-a"))
    }

    private fun accountKeys(
        store: DebridKeyValueStore,
        id: String,
        generation: Long = 1,
    ): DebridKeys = DebridKeys(
        store,
        DebridAccountOwnerBinding().apply {
            bind { DebridAccountOwnerState.Account(id, generation) }
        },
    )

    private class ClaimState(
        var value: LegacyOwnerReservation = LegacyOwnerReservation.Missing,
    )

    private class FakeDebridKeyValueStore(
        persistentValues: MutableMap<String, String> = mutableMapOf(),
        private val claim: ClaimState = ClaimState(),
        var writeSucceeds: Boolean = true,
        var claimSucceeds: Boolean = true,
        var repairSucceeds: Boolean = true,
        var available: Boolean = true,
        private val beforeWrite: (Map<String, String?>) -> Unit = {},
        private val afterSnapshot: (List<String>) -> Unit = {},
        private val retainKeysOnClear: Set<String> = emptySet(),
        override val adoptionDomain: Any = Any(),
    ) : DebridKeyValueStore {
        private val values = persistentValues

        override fun snapshot(vararg keys: String): DebridStorageSnapshot {
            val snapshot = DebridStorageSnapshot(
                availability = if (available) {
                    DebridStorageAvailability.AVAILABLE
                } else {
                    DebridStorageAvailability.UNAVAILABLE
                },
                values = keys.distinct().associateWith { values[it] },
            )
            afterSnapshot(keys.toList())
            return snapshot
        }

        override fun write(values: Map<String, String?>): Boolean {
            beforeWrite(values)
            if (!available || !writeSucceeds) {
                available = false
                return false
            }
            values.forEach { (key, value) ->
                if (value == null) {
                    if (key !in retainKeysOnClear) this.values.remove(key)
                } else {
                    this.values[key] = value
                }
            }
            return true
        }

        override fun legacyOwnerReservation(): LegacyOwnerReservation = claim.value

        override fun claimLegacyOwner(owner: String): Boolean {
            val existing = claim.value
            if (existing is LegacyOwnerReservation.Claimed) return existing.owner == owner
            if (existing == LegacyOwnerReservation.InvalidOrUnavailable || !claimSucceeds) {
                return false
            }
            claim.value = LegacyOwnerReservation.Claimed(owner)
            return true
        }

        override fun repairLegacyOwner(owner: String): Boolean {
            if (!repairSucceeds) return false
            claim.value = LegacyOwnerReservation.Claimed(owner)
            return true
        }
    }

    private fun awaitCompletionOrMonitorBlock(
        worker: Thread,
        completed: CountDownLatch,
    ) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (
            completed.count > 0 &&
            worker.state != Thread.State.BLOCKED &&
            System.nanoTime() < deadline
        ) {
            Thread.yield()
        }
        assertTrue(
            "Owner-switch thread neither completed nor blocked on the process migration lock",
            completed.count == 0L || worker.state == Thread.State.BLOCKED,
        )
    }
}
