package com.vortx.android.sync

import com.vortx.android.account.TitleRef
import com.vortx.android.security.AccountFileProviderWriters
import com.vortx.android.sync.ProviderRetryOutbox.Append
import com.vortx.android.sync.ProviderRetryOutbox.Lane
import com.vortx.android.sync.ProviderRetryOutbox.Provider
import com.vortx.android.sync.ProviderRetryOutbox.Read
import com.vortx.android.sync.ProviderRetryOutbox.Retire
import com.vortx.android.sync.ProviderRetryOutbox.Row
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Synthetic Android application directory, original owner, rows and keys. */
class ProviderRetryOutboxTest {
    @Rule @JvmField val temporary = TemporaryFolder()

    private val account = SessionOwnerSnapshot.Account("12345678-abcd-4abc-8abc-123456789abc", 7)
    private val foreign = SessionOwnerSnapshot.Account("22345678-abcd-4abc-8abc-123456789abc", 7)
    private val successor = account.copy(generation = 8)
    private val trakt = Lane(account, Provider.TRAKT)
    private val simkl = Lane(account, Provider.SIMKL)
    private val key = ByteArray(32) { (it + 11).toByte() }
    private val wrongKey = ByteArray(32) { (it + 79).toByte() }
    private val proof = ByteArray(32) { (it + 41).toByte() }

    @Test fun coordinatorRetiresVerifiedDeliveryAndHoldsAmbiguousDeliveryAcrossReopen() = runBlocking {
        val original = outbox()
        val coordinator = ProviderRetryCoordinator(original, original)
        var settle = true
        var preparations = 0
        var dispatches = 0
        val credential = object : ProviderRetryCredential {
            override fun copyProof() = proof.copyOf()
            override suspend fun dispatch(lane: Lane, row: Row, start: ProviderRetryStart): ProviderRetryDispatchOutcome {
                assertTrue(exists(startFile(record(lane))))
                assertTrue(start.tryClaimFirstIo())
                assertFalse(start.tryClaimFirstIo())
                dispatches++
                return if (settle) accepted(start) else ProviderRetryDispatchOutcome.Unsettled
            }
            override fun close() {}
        }
        val session = object : ProviderRetrySession {
            override val owner = account
            override fun requireCurrent() {}
            override fun <T> withDataKey(block: (ByteArray) -> T): T {
                val copy = key.copyOf()
                return try { block(copy) } finally { copy.fill(0) }
            }
            override fun isEnabled(provider: Provider) = true
            override suspend fun prepareCredential(provider: Provider): ProviderRetryCredential {
                preparations++
                return credential
            }
            override fun close() {}
        }
        val title = TitleRef("tt0123456", null, false)
        assertEquals(ProviderRetryCoordinator.Submit.UnsupportedTitle,
            coordinator.submit(session, Provider.TRAKT, true, title.copy(isSeries = null)))
        assertEquals(Read.Missing, original.readHead(trakt, key) {})
        val otherLane = Lane(foreign, Provider.SIMKL)
        val otherSession = object : ProviderRetrySession by session { override val owner = foreign }
        val unsupported = row(99)
        assertEquals(Append.Enqueued, original.append(otherLane, key, unsupported) {})
        coordinator.drain(otherSession, Provider.SIMKL)
        assertEquals(unsupported.operationId, pending(original, otherLane).row.operationId)
        assertFalse(exists(startFile(record(otherLane))))
        assertEquals(0, preparations)

        assertEquals(ProviderRetryCoordinator.Submit.Settled, coordinator.submit(session, Provider.TRAKT, true, title))
        assertEquals(Read.Missing, original.readHead(trakt, key) {})
        assertFalse(exists(startFile(record(trakt))))
        reserved { assertTrue(original.captureRestoreAbsence(account, it) != null) }

        settle = false
        assertEquals(ProviderRetryCoordinator.Submit.RecordedUnsettled, coordinator.submit(session, Provider.TRAKT, false, title))
        val reopened = outbox()
        ProviderRetryCoordinator(reopened, reopened).drain(session, Provider.TRAKT)
        assertEquals(2, preparations)
        assertEquals(2, dispatches)
        assertEquals(Read.Unavailable, reopened.readHead(trakt, key) {})
        reserved { assertNull(reopened.captureRestoreAbsence(account, it)) }
    }

    @Test fun restoredOriginalHeadSurvivesReopenAndRetirementChecksExactFifoRevision() {
        val outbox = outbox()
        val first = row(1)
        val second = row(2, add = false)
        assertEquals(Append.Enqueued, outbox.append(trakt, key, first) {})
        assertEquals(Append.AlreadyQueued, outbox.append(trakt, key, first) {})
        assertEquals(Append.Unavailable, outbox.append(trakt, key, row(1, add = false)) {})
        val previous = pending(outbox, trakt)
        assertEquals(Append.Enqueued, outbox.append(trakt, key, second) {})
        assertNull(outbox.claimBeforeIo(trakt, key, previous) {})

        val reopened = outbox()
        val live = pending(reopened, trakt)
        assertEquals(first.operationId, live.row.operationId)
        assertArrayEquals(proof, live.row.credentialProof())
        assertNull(reopened.claimBeforeIo(trakt, key, pending(outbox, trakt)) {})
        val firstStart = requireNotNull(reopened.claimBeforeIo(trakt, key, live) {})
        assertTrue(firstStart.tryClaimFirstIo())
        assertEquals(Retire.Retired, reopened.retireAccepted(trakt, key, firstStart, accepted(firstStart)) {})
        val next = pending(reopened, trakt)
        assertEquals(second.operationId, next.row.operationId)
        assertFalse(next.row.add)
        val secondStart = requireNotNull(reopened.claimBeforeIo(trakt, key, next) {})
        assertTrue(secondStart.tryClaimFirstIo())
        assertEquals(Retire.Retired, reopened.retireAccepted(trakt, key, secondStart, accepted(secondStart)) {})
        assertEquals(Read.Missing, reopened.readHead(trakt, key) {})
        assertFalse(Files.exists(record(trakt), LinkOption.NOFOLLOW_LINKS))
        reserved { assertTrue(reopened.captureRestoreAbsence(account, it) != null) }
    }

    @Test fun authenticatedBytesBindAccountEpochProviderAndOriginalKey() {
        val outbox = outbox()
        val foreignLane = Lane(foreign, Provider.TRAKT)
        val successorLane = Lane(successor, Provider.TRAKT)
        assertEquals(Append.Enqueued, outbox.append(trakt, key, row(1)) {})
        val original = Files.readAllBytes(record(trakt))
        assertEquals(Read.Unavailable, outbox.readHead(trakt, wrongKey) {})
        for (lane in listOf(foreignLane, successorLane, simkl)) {
            assertEquals(Read.Missing, outbox.readHead(lane, key) {})
            assertEquals(Append.Enqueued, outbox.append(lane, key, row(2)) {})
            Files.write(record(lane), original)
            assertEquals(Read.Unavailable, outbox.readHead(lane, key) {})
            assertArrayEquals(original, Files.readAllBytes(record(lane)))
        }
        assertArrayEquals(original, Files.readAllBytes(record(trakt)))
        assertEquals(Append.Unavailable, outbox.append(simkl, key, row(4, add = false)) {})
    }

    @Test fun restoreWitnessIsExistingOnlyIssuerBoundAndExpiresWithReservation() {
        val outbox = outbox()
        val another = outbox()
        val noBackup = appRoot().resolve("no_backup")
        val currency = reserved { reservation ->
            val absence = requireNotNull(outbox.captureRestoreAbsence(account, reservation))
            assertNull(another.recheckExisting(account, absence))
            assertNull(outbox.recheckExisting(successor, absence))
            assertEquals(Append.Unavailable, outbox.append(trakt, key, row(1)) {})
            assertFalse(Files.exists(noBackup, LinkOption.NOFOLLOW_LINKS))
            val verified = requireNotNull(outbox.recheckExisting(account, absence))
            assertTrue(outbox.isCurrent(account, verified))
            assertFalse(another.isCurrent(account, verified))
            verified
        }
        assertFalse(outbox.isCurrent(account, currency))
        assertFalse(Files.exists(noBackup, LinkOption.NOFOLLOW_LINKS))
    }

    @Test fun unknownForeignBackingDoesNotAffectThisOwnerAndOlderRowsStillBlock() {
        val outbox = outbox()
        val foreignLane = Lane(foreign, Provider.TRAKT)
        assertEquals(Append.Enqueued, outbox.append(foreignLane, key, row(1)) {})
        val malformed = byteArrayOf(7, 6, 5, 4)
        Files.write(record(foreignLane), malformed)
        reserved { reservation ->
            assertTrue(outbox.captureRestoreAbsence(account, reservation) != null)
            assertNull(outbox.captureRestoreAbsence(foreign, reservation))
        }
        assertEquals(Append.Enqueued, outbox.append(trakt, key, row(2)) {})
        val original = Files.readAllBytes(record(trakt))
        reserved { reservation ->
            assertNull(outbox.captureRestoreAbsence(successor, reservation))
        }
        assertArrayEquals(original, Files.readAllBytes(record(trakt)))
        assertArrayEquals(malformed, Files.readAllBytes(record(foreignLane)))
    }

    @Test fun abandonedStageAndRollbackStayIntactAndBlockReadsOrRestore() {
        val outbox = outbox()
        val target = record(trakt)
        val stage = target.resolveSibling("${target.fileName}.stage")
        val cancelled = runCatching {
            outbox.append(trakt, key, row(1)) {
                if (Files.exists(stage, LinkOption.NOFOLLOW_LINKS)) throw CancellationException()
            }
        }
        assertTrue(cancelled.exceptionOrNull() is CancellationException)
        val stagedBytes = Files.readAllBytes(stage)
        assertFalse(Files.exists(target, LinkOption.NOFOLLOW_LINKS))
        assertEquals(Read.Unavailable, outbox.readHead(trakt, key) {})
        reserved { assertNull(outbox.captureRestoreAbsence(account, it)) }
        assertArrayEquals(stagedBytes, Files.readAllBytes(stage))

        Files.move(stage, target.resolveSibling("${target.fileName}.bak"))
        assertEquals(Read.Unavailable, outbox.readHead(trakt, key) {})
        reserved { assertNull(outbox.captureRestoreAbsence(account, it)) }
        assertArrayEquals(stagedBytes, Files.readAllBytes(target.resolveSibling("${target.fileName}.bak")))
    }

    @Test fun finalPhysicalCheckRejectsNamespaceChangeAndSymlink() {
        val outbox = outbox()
        val noBackup = appRoot().resolve("no_backup")
        reserved { reservation ->
            val first = requireNotNull(outbox.captureRestoreAbsence(account, reservation))
            // Deliberately bypass app writer admission to prove the final physical probe runs.
            Files.createDirectory(noBackup, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
            assertNull(outbox.recheckExisting(account, first))
        }
        val unexpected = temporary.newFolder("unexpected").toPath()
        Files.createSymbolicLink(noBackup.resolve("vortx-provider-retries-v1"), unexpected)
        reserved { assertNull(outbox.captureRestoreAbsence(account, it)) }
        assertEquals(Append.Unavailable, outbox.append(trakt, key, row(1)) {})
        assertTrue(Files.newDirectoryStream(unexpected).use { !it.iterator().hasNext() })
    }

    @Test fun lastRowStartAndSettlementFailClosedAtEachDurabilityBoundary() {
        // Start directory force, ciphertext deletion force, then marker removal force.
        val expectedBeforeForce = listOf(true to true, false to true, false to false)
        for (failedForce in 1..3) {
            val root = temporary.newFolder("retirement-force-$failedForce").toPath()
            val record = record(trakt, root)
            val marker = startFile(record)
            val observed = mutableListOf<Pair<Boolean, Boolean>>()
            var retiring = false
            val outbox = outbox(root) { path ->
                if (retiring && path == record.parent && (exists(marker) || observed.isNotEmpty())) {
                    observed.add(exists(record) to exists(marker))
                    if (observed.size == failedForce) throw IOException("Synthetic directory force failure")
                }
            }
            assertEquals(Append.Enqueued, outbox.append(trakt, key, row(1)) {})
            val snapshot = pending(outbox, trakt)
            val bytes = Files.readAllBytes(record)
            retiring = true
            val start = outbox.claimBeforeIo(trakt, key, snapshot) {}
            if (failedForce == 1) {
                assertNull(start)
            } else {
                requireNotNull(start)
                assertTrue(start.tryClaimFirstIo())
                assertEquals(Retire.Unavailable, outbox.retireAccepted(trakt, key, start, accepted(start)) {})
            }
            assertEquals(expectedBeforeForce.take(failedForce), observed)
            assertEquals(failedForce == 1, exists(record))
            assertEquals(failedForce < 3, exists(marker))
            if (failedForce == 1) assertArrayEquals(bytes, Files.readAllBytes(record))

            val reopened = outbox(root)
            if (failedForce < 3) {
                assertEquals(Read.Unavailable, reopened.readHead(trakt, key) {})
                assertEquals(Append.Unavailable, reopened.append(trakt, key, row(2)) {})
                reserved { assertNull(reopened.captureRestoreAbsence(account, it)) }
                assertTrue(Files.size(marker) > 0L)
            } else {
                // The earlier force completed before marker unlink. A returning marker is a
                // conservative refusal, but a missing one cannot resurrect the old ciphertext.
                assertEquals(Read.Missing, reopened.readHead(trakt, key) {})
                reserved { assertTrue(reopened.captureRestoreAbsence(account, it) != null) }
                Files.createFile(marker, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
                reserved { assertNull(reopened.captureRestoreAbsence(account, it)) }
            }
        }
    }

    @Test fun interruptionAfterRecordUnlinkRetainsOriginalRetirementVeto() {
        val outbox = outbox()
        val record = record(trakt)
        val marker = startFile(record)
        assertEquals(Append.Enqueued, outbox.append(trakt, key, row(1)) {})
        val snapshot = pending(outbox, trakt)
        val start = requireNotNull(outbox.claimBeforeIo(trakt, key, snapshot) {})
        assertTrue(start.tryClaimFirstIo())
        val cancelled = runCatching {
            outbox.retireAccepted(trakt, key, start, accepted(start)) {
                if (!exists(record) && exists(marker)) throw CancellationException()
            }
        }
        assertTrue(cancelled.exceptionOrNull() is CancellationException)
        assertFalse(exists(record))
        assertTrue(exists(marker))
        val reopened = outbox()
        reserved { assertNull(reopened.captureRestoreAbsence(account, it)) }
        assertEquals(Read.Unavailable, reopened.readHead(trakt, key) {})
        assertTrue(exists(marker))
    }

    @Test fun durableStartIsSingleUseAndSettlementRequiresOriginalGuardAndExactReceipt() {
        val outbox = outbox()
        val record = record(trakt)
        assertEquals(Append.Enqueued, outbox.append(trakt, key, row(1)) {})
        val original = Files.readAllBytes(record)
        val snapshot = pending(outbox, trakt)
        var current = true
        val start = requireNotNull(outbox.claimBeforeIo(trakt, key, snapshot) { check(current) })
        assertTrue(start.head === snapshot)
        val marker = Files.readAllBytes(startFile(record))
        assertEquals(Retire.Changed, outbox.retireAccepted(trakt, key, start, accepted(start)) {})
        assertTrue(start.tryClaimFirstIo())
        assertTrue(start.wasClaimed())
        assertFalse(start.tryClaimFirstIo())

        val other = object : ProviderRetryStart {
            override val head = snapshot
            override fun tryClaimFirstIo(): Boolean = true
            override fun wasClaimed(): Boolean = true
        }
        assertEquals(Retire.Changed, outbox.retireAccepted(trakt, key, other, accepted(other)) {})
        assertEquals(Retire.Changed, outbox.retireAccepted(trakt, key, start, accepted(other)) {})
        assertEquals(Retire.Changed, outbox.retireAccepted(trakt, key, start, accepted(start, operationId = UUID(0, 9))) {})
        assertEquals(Retire.Changed, outbox.retireAccepted(simkl, key, start, accepted(start)) {})
        assertEquals(Retire.Changed, outbox().retireAccepted(trakt, key, start, accepted(start)) {})
        current = false
        assertEquals(Retire.Unavailable, outbox.retireAccepted(trakt, key, start, accepted(start)) {})
        current = true
        assertEquals(Read.Unavailable, outbox().readHead(trakt, key) {})
        assertNull(outbox.claimBeforeIo(trakt, key, snapshot) {})
        assertEquals(Append.Unavailable, outbox.append(trakt, key, row(2)) {})
        reserved { assertNull(outbox.captureRestoreAbsence(account, it)) }
        assertArrayEquals(original, Files.readAllBytes(record))
        assertArrayEquals(marker, Files.readAllBytes(startFile(record)))

        val tampered = marker.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        Files.write(startFile(record), tampered)
        assertEquals(Retire.Unavailable, outbox.retireAccepted(trakt, key, start, accepted(start)) {})
        assertArrayEquals(original, Files.readAllBytes(record))
        assertArrayEquals(tampered, Files.readAllBytes(startFile(record)))
    }

    @Test fun refusedFirstIoConsumesTheIssuedAttemptAndLeavesStartAndOldRetireVetoHeld() {
        val outbox = outbox()
        val record = record(trakt)
        assertEquals(Append.Enqueued, outbox.append(trakt, key, row(1)) {})
        var current = true
        val start = requireNotNull(outbox.claimBeforeIo(trakt, key, pending(outbox, trakt)) { check(current) })
        current = false
        assertFalse(start.tryClaimFirstIo())
        current = true
        assertFalse(start.tryClaimFirstIo())
        assertFalse(start.wasClaimed())
        assertEquals(Retire.Changed, outbox.retireAccepted(trakt, key, start, accepted(start)) {})
        assertTrue(exists(startFile(record)))
        assertEquals(Read.Unavailable, outbox().readHead(trakt, key) {})

        val oldVeto = record(simkl).let { it.resolveSibling("${it.fileName}.retire") }
        Files.createFile(oldVeto, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
        assertEquals(Read.Unavailable, outbox.readHead(simkl, key) {})
        assertEquals(Append.Unavailable, outbox.append(simkl, key, row(2)) {})
        assertTrue(exists(oldVeto))
    }

    @Test fun failedFifoPublicationKeepsDurableStartAndHoldsBothOldAndSuccessorReopen() {
        for (failedForce in 1..2) {
            val root = temporary.newFolder("fifo-force-$failedForce").toPath()
            val record = record(trakt, root)
            val marker = startFile(record)
            var forceCount = 0
            var settling = false
            val outbox = outbox(root) { path ->
                if (settling && path == record.parent && ++forceCount == failedForce)
                    throw IOException("Synthetic FIFO directory force failure")
            }
            assertEquals(Append.Enqueued, outbox.append(trakt, key, row(1)) {})
            assertEquals(Append.Enqueued, outbox.append(trakt, key, row(2)) {})
            val original = Files.readAllBytes(record)
            val start = requireNotNull(outbox.claimBeforeIo(trakt, key, pending(outbox, trakt)) {})
            val originalMarker = Files.readAllBytes(marker)
            assertTrue(start.tryClaimFirstIo())
            settling = true
            assertEquals(Retire.Unavailable, outbox.retireAccepted(trakt, key, start, accepted(start)) {})
            val reopened = outbox(root)
            if (failedForce == 1) {
                // Either directory image can survive interruption while the durable marker stays.
                assertArrayEquals(originalMarker, Files.readAllBytes(marker))
                assertEquals(Read.Unavailable, reopened.readHead(trakt, key) {})
                Files.write(record, original)
                assertEquals(Read.Unavailable, reopened.readHead(trakt, key) {})
            } else {
                assertFalse(exists(marker))
                assertEquals(row(2).operationId, pending(reopened, trakt).row.operationId)
                Files.createFile(marker, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
                assertEquals(Read.Unavailable, reopened.readHead(trakt, key) {})
            }
            reserved { assertNull(reopened.captureRestoreAbsence(account, it)) }
        }
    }

    @Test fun relatedParentAliasesRefuseButForeignOwnerAliasesRemainUnopened() {
        val outbox = outbox()
        assertEquals(Append.Enqueued, outbox.append(Lane(foreign, Provider.TRAKT), key, row(1)) {})
        val selected = record(trakt).parent.parent
        val foreignAlias = record(Lane(foreign, Provider.TRAKT)).parent.parent.let { it.resolveSibling("${it.fileName}.bak") }
        val targetAlias = selected.resolveSibling("${selected.fileName}.bak")
        val namespace = selected.parent
        val globalAlias = namespace.resolveSibling("vortx-provider-retries-v2")
        val platformAlias = namespace.parent.let { it.resolveSibling("${it.fileName}.bak") }
        val aliasBytes = byteArrayOf(3, 2, 1)
        Files.write(foreignAlias, aliasBytes)
        reserved { assertTrue(outbox.captureRestoreAbsence(account, it) != null) }
        for (alias in listOf(targetAlias, globalAlias, platformAlias)) {
            Files.write(alias, aliasBytes)
            reserved { assertNull(outbox.captureRestoreAbsence(account, it)) }
            assertEquals(Read.Unavailable, outbox.readHead(trakt, key) {})
            assertEquals(Append.Unavailable, outbox.append(trakt, key, row(2)) {})
            assertArrayEquals(aliasBytes, Files.readAllBytes(alias))
            assertFalse(exists(selected))
            Files.delete(alias)
        }
        assertArrayEquals(aliasBytes, Files.readAllBytes(foreignAlias))
        reserved { assertTrue(outbox.captureRestoreAbsence(account, it) != null) }
    }

    private fun pending(outbox: ProviderRetryOutbox, lane: Lane): ProviderRetryOutbox.Snapshot =
        (outbox.readHead(lane, key) {} as Read.Pending).head

    private fun accepted(start: ProviderRetryStart, operationId: UUID = start.head.row.operationId): ProviderRetryDispatchOutcome.Accepted {
        val row = start.head.row
        return ProviderRetryDispatchOutcome.Accepted(start, start.head.lane, operationId, row.add, TitleRef(row.imdb, row.tmdb, row.isSeries))
    }

    private fun row(id: Long, add: Boolean = true): Row = Row(UUID(0, id), add, "tt0123456", 145, null, proof)

    private fun outbox(root: Path = appRoot(), beforeDirectoryForce: (Path) -> Unit = {}): ProviderRetryOutbox {
        val owner = unix(root)
        return ProviderRetryOutbox.forJvmFixture(root, owner.uid, owner.gid, ::unix, beforeDirectoryForce)
    }

    private fun appRoot(): Path = temporary.root.toPath()

    private fun record(lane: Lane, root: Path = appRoot()): Path {
        val accountDigest = MessageDigest.getInstance("SHA-256").digest(lane.owner.id.toByteArray(Charsets.US_ASCII))
            .joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 255) }
        return root.resolve("no_backup/vortx-provider-retries-v1/$accountDigest/e-${lane.owner.generation}/${lane.provider.fileName}")
    }

    private fun exists(path: Path): Boolean = Files.exists(path, LinkOption.NOFOLLOW_LINKS)
    private fun startFile(record: Path): Path = record.resolveSibling("${record.fileName}.start")

    private fun unix(path: Path): ProviderRetryOutbox.UnixMetadata {
        val attrs = Files.readAttributes(path, "unix:uid,gid,mode", LinkOption.NOFOLLOW_LINKS)
        fun number(name: String) = (attrs.getValue(name) as Number).toInt()
        return ProviderRetryOutbox.UnixMetadata(number("uid"), number("gid"), number("mode"))
    }

    private fun <T> reserved(block: (AccountFileRestoreManagerExclusion.Reservation) -> T): T {
        val reservation = requireNotNull(AccountFileProviderWriters.tryReserve())
        return try { block(reservation) } finally { AccountFileProviderWriters.release(reservation) }
    }
}
