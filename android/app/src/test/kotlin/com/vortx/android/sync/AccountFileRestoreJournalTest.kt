package com.vortx.android.sync

import com.vortx.android.sync.AccountFileRestoreJournal.Intent
import com.vortx.android.sync.AccountFileRestoreJournal.Mutation
import com.vortx.android.sync.AccountFileRestoreJournal.Read
import com.vortx.android.sync.AccountFileRestoreJournal.State
import com.vortx.android.sync.AccountFileRestoreJournal.UnixMetadata
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermission
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Uses the real journal and synthetic keys/bytes in a fresh isolated directory. */
class AccountFileRestoreJournalTest {
    @Rule @JvmField val temporary = TemporaryFolder()

    private val account = "12345678-abcd-4abc-8abc-123456789abc"
    private val owner = "87654321-DCBA-4CBA-8CBA-CBA987654321"
    private val otherOwner = "87654321-DCBA-4CBA-8CBA-CBA987654322"
    private val key = ByteArray(32) { (it + 31).toByte() }
    private val wrongKey = ByteArray(32) { (it + 67).toByte() }
    private val selected = "exact selected source bytes 29de4c0b".toByteArray()
    private val candidate = "exact encrypted candidate bytes e5729ee4".toByteArray()
    private val head = "exact displaced head response 50b17eed".toByteArray()
    private val submission = "exact original submission 6fc490ee".toByteArray()

    private fun unixMetadata(path: Path): UnixMetadata {
        val attrs = Files.readAttributes(path, "unix:uid,gid,mode", LinkOption.NOFOLLOW_LINKS)
        fun number(name: String) = (attrs.getValue(name) as Number).toInt()
        return UnixMetadata(number("uid"), number("gid"), number("mode"))
    }

    private fun journal(
        root: File = temporary.root,
        uid: Int = unixMetadata(temporary.root.toPath()).uid,
        gid: Int = unixMetadata(temporary.root.toPath()).gid,
    ) = AccountFileRestoreJournal.forJvmFixture(root.toPath(), uid, gid, ::unixMetadata)
    private fun intent(source: ByteArray = selected, ownerId: String = owner) = Intent(
        UUID.randomUUID(), account, ownerId, 42L, 43L, "de".repeat(32),
        source, candidate, head, submission,
    )
    private fun journalDirectory() = temporary.root.resolve("account-file-restores-v1")
    private fun recordFile() = checkNotNull(journalDirectory().listFiles()).single { it.name.endsWith(".sealed") }
    private fun present(journal: AccountFileRestoreJournal) =
        (journal.readExisting(account, key) as Read.Present).snapshot
    private fun applied(result: Mutation) = (result as Mutation.Applied).snapshot

    @Test fun existingOnlyReadCreatesNothingAndRejectsUnsafeRootOrJournalPath() {
        assertEquals(Read.Missing, journal().readExisting(account, null))
        assertTrue(checkNotNull(temporary.root.list()).isEmpty())
        val absent = temporary.root.resolve("not-created")
        assertEquals(Read.Unavailable, journal(absent).readExisting(account, null))
        assertFalse(absent.exists())

        val real = temporary.newFolder("other")
        Files.createSymbolicLink(journalDirectory().toPath(), real.toPath())
        assertEquals(Read.Unavailable, journal().readExisting(account, key))
        assertTrue(checkNotNull(real.list()).isEmpty())
    }

    @Test fun platformGroupModeRequiresAppOwnershipAndPreservesStrictJournalModes() {
        val root = temporary.root.toPath()
        val platformMode = PosixFilePermissions.fromString("rwxrwx--x") // AOSP 0771.
        Files.setPosixFilePermissions(root, platformMode)
        val owner = unixMetadata(root)
        assertEquals(Read.Missing, journal().readExisting(account, null))
        assertEquals(Read.Unavailable, journal(uid = owner.uid xor 1).readExisting(account, null))
        assertEquals(Read.Unavailable, journal(gid = owner.gid xor 1).readExisting(account, null))
        assertFalse(journalDirectory().exists())

        val first = journal()
        applied(first.admit(intent(), key))
        assertEquals(State.Retained, present(first).state)
        assertEquals(platformMode, Files.getPosixFilePermissions(root))
        val directory = journalDirectory().toPath()
        val directoryMode = PosixFilePermissions.fromString("rwx------")
        val fileMode = PosixFilePermissions.fromString("rw-------")
        assertEquals(directoryMode, Files.getPosixFilePermissions(directory))
        for (file in checkNotNull(journalDirectory().listFiles())) {
            assertEquals(fileMode, Files.getPosixFilePermissions(file.toPath()))
        }
        Files.setPosixFilePermissions(root, platformMode + PosixFilePermission.OTHERS_WRITE)
        assertEquals(Read.Unavailable, journal().readExisting(account, key))
        Files.setPosixFilePermissions(root, platformMode)

        Files.setPosixFilePermissions(directory, directoryMode + PosixFilePermission.GROUP_READ)
        assertEquals(Read.Unavailable, journal().readExisting(account, key))
        Files.setPosixFilePermissions(directory, directoryMode)

        val record = recordFile().toPath()
        Files.setPosixFilePermissions(record, fileMode + PosixFilePermission.GROUP_READ)
        assertEquals(Read.Unavailable, journal().readExisting(account, key))
        Files.setPosixFilePermissions(record, fileMode)
        assertEquals(State.Retained, present(journal()).state)
        assertEquals(platformMode, Files.getPosixFilePermissions(root))
    }

    @Test fun exactEncryptedIntentAndPossibleSendSurviveRestart() {
        val callerBytes = selected.copyOf()
        val original = intent(callerBytes)
        callerBytes.fill(0)
        original.candidateFile().fill(0)
        val initial = journal()
        val retained = applied(initial.admit(original, key))
        assertEquals(State.Retained, retained.state)
        assertEquals(Mutation.Changed, initial.admit(intent(ownerId = otherOwner), key))
        assertEquals(Read.Unavailable, initial.readExisting(account, null))
        assertEquals(Read.Unavailable, initial.readExisting(account, wrongKey))
        assertEquals(Mutation.Unavailable, initial.compareAndAdvance(retained, State.PossibleSend, wrongKey))

        val possible = applied(initial.compareAndAdvance(retained, State.PossibleSend, key))
        assertTrue(possible.state.mayHaveSent)
        val sealedText = recordFile().readBytes().toString(Charsets.ISO_8859_1)
        for (marker in listOf(account, owner, selected.decodeToString(), candidate.decodeToString(),
            head.decodeToString(), submission.decodeToString())) {
            assertFalse(sealedText.contains(marker))
        }

        val restarted = journal()
        val recovered = present(restarted)
        assertEquals(State.PossibleSend, recovered.state)
        assertEquals("user_selected_file", recovered.intent.sourceKind)
        assertEquals(original.operationId, recovered.intent.operationId)
        assertEquals(account, recovered.intent.accountId)
        assertEquals(owner, recovered.intent.ownerProfileId)
        assertEquals(42L, recovered.intent.baseRevision)
        assertEquals(43L, recovered.intent.revision)
        assertEquals(original.plaintextSha256, recovered.intent.plaintextSha256)
        assertArrayEquals(selected, recovered.intent.selectedFile())
        assertArrayEquals(candidate, recovered.intent.candidateFile())
        assertArrayEquals(head, recovered.intent.displacedHeadResponse())
        assertArrayEquals(submission, recovered.intent.submissionBytes())
        recovered.intent.submissionBytes().fill(0)
        assertArrayEquals(submission, present(restarted).intent.submissionBytes())
        assertEquals(Mutation.Changed, restarted.compareAndAdvance(possible, State.ServerConfirmed, key))
        assertEquals(Mutation.Changed, restarted.compareAndAdvance(recovered, State.PossibleSend, key))
        assertEquals(Mutation.Changed, restarted.compareAndAdvance(recovered, State.NotSubmitted, key))
    }

    @Test fun staleCasCannotReplaceAnotherInstanceTransitionOrResetEvidence() {
        val first = journal()
        val second = journal()
        val original = intent()
        val admission = applied(first.admit(original, key))
        val competing = present(second)
        // Neither a same-instance reread nor a restarted journal can reconstruct the grant.
        assertEquals(Mutation.Changed, first.compareAndAdvance(present(first), State.PossibleSend, key))
        assertEquals(Mutation.Changed, second.compareAndAdvance(competing, State.PossibleSend, key))
        assertEquals(State.Retained, present(second).state)
        val possible = applied(first.compareAndAdvance(admission, State.PossibleSend, key))
        assertEquals(Mutation.Changed, first.compareAndAdvance(admission, State.PossibleSend, key))
        assertEquals(Mutation.Changed, second.compareAndAdvance(competing, State.NotSubmitted, key))
        val restartedPossible = present(second)
        assertEquals(possible.state, restartedPossible.state)
        val unconfirmed = applied(second.compareAndAdvance(restartedPossible, State.DeliveryUnconfirmed, key))
        assertEquals(Mutation.Changed, second.compareAndAdvance(restartedPossible, State.Conflict, key))
        val confirmed = applied(second.compareAndAdvance(unconfirmed, State.ServerConfirmed, key))
        assertEquals(Mutation.Changed, second.compareAndAdvance(confirmed, State.Retained, key))
        assertEquals(Mutation.Changed, second.admit(intent(), key))
        assertEquals(original.operationId, present(journal()).intent.operationId)
        assertEquals(State.ServerConfirmed, present(journal()).state)
    }

    @Test fun interruptedStageAndCorruptRecordRemainUnavailableAndAreNeverOverwritten() {
        val first = journal()
        val original = intent()
        val retained = applied(first.admit(original, key))
        val record = recordFile()
        val pristine = record.readBytes()
        val corrupt = pristine.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
        record.writeBytes(corrupt)
        assertEquals(Read.Unavailable, first.readExisting(account, key))
        assertEquals(Mutation.Unavailable, first.admit(intent(), key))
        assertEquals(Mutation.Unavailable, first.compareAndAdvance(retained, State.PossibleSend, key))
        assertArrayEquals(corrupt, record.readBytes())

        record.writeBytes(pristine)
        val stage = record.resolveSibling(record.name.removeSuffix(".sealed") + ".stage")
        stage.writeBytes(byteArrayOf(1, 2, 3))
        assertEquals(Read.Unavailable, first.readExisting(account, key))
        assertEquals(Mutation.Unavailable, first.compareAndAdvance(retained, State.PossibleSend, key))
        assertTrue(record.delete())
        assertEquals(Read.Unavailable, journal().readExisting(account, null))
        assertEquals(Mutation.Unavailable, journal().admit(original, key))
        assertArrayEquals(byteArrayOf(1, 2, 3), stage.readBytes())
    }

    @Test fun orphanRecordCannotBeReadOrRepairedByExistingOnlyProbe() {
        val first = journal()
        applied(first.admit(intent(), key))
        val record = recordFile()
        val lock = record.resolveSibling(record.name.removeSuffix(".sealed") + ".lock")
        assertTrue(lock.delete())
        assertEquals(Read.Unavailable, journal().readExisting(account, key))
        assertEquals(Mutation.Unavailable, journal().admit(intent(), key))
        assertFalse(lock.exists())
        assertTrue(record.isFile)
    }

    @Test fun survivingClaimWithoutRecordBlocksReadAndAdmissionAfterRestart() {
        val first = journal()
        val retained = applied(first.admit(intent(), key))
        val possible = applied(first.compareAndAdvance(retained, State.PossibleSend, key))
        val record = recordFile()
        val lock = record.resolveSibling(record.name.removeSuffix(".sealed") + ".lock")
        assertTrue(record.delete())
        assertTrue(lock.isFile)
        val restarted = journal()
        assertEquals(Read.Unavailable, restarted.readExisting(account, null))
        assertEquals(Read.Unavailable, restarted.readExisting(account, key))
        assertEquals(Mutation.Unavailable, restarted.admit(intent(), key))
        assertEquals(Mutation.Unavailable, first.compareAndAdvance(possible, State.DeliveryUnconfirmed, key))
        assertFalse(record.exists())
        assertTrue(lock.isFile)
    }

    @Test fun restartedRetainedCanRecordNoSubmissionButCannotAcquireSendGrant() {
        val first = journal()
        val admitted = applied(first.admit(intent(), key))
        val restarted = journal()
        val observed = present(restarted)
        assertEquals(State.Retained, observed.state)
        assertEquals(Mutation.Changed, restarted.compareAndAdvance(observed, State.PossibleSend, key))
        val notSubmitted = applied(restarted.compareAndAdvance(observed, State.NotSubmitted, key))
        assertFalse(notSubmitted.state.mayHaveSent)
        assertEquals(Mutation.Changed, first.compareAndAdvance(admitted, State.PossibleSend, key))
        assertEquals(State.NotSubmitted, present(journal()).state)
    }
}
