package com.vortx.android.sync

import com.vortx.android.engine.OHJson
import com.vortx.android.engine.VortxAccountScope
import com.vortx.android.sync.AccountFileRestoreJournal.Read
import com.vortx.android.sync.AccountFileRestoreJournal.State
import com.vortx.android.sync.AccountFileRestoreTransaction.AuthenticatedReads
import com.vortx.android.sync.AccountFileRestoreTransaction.ExclusiveRestore
import com.vortx.android.sync.AccountFileRestoreTransaction.HeadPolicy
import com.vortx.android.sync.AccountFileRestoreTransaction.PutGrant
import com.vortx.android.sync.AccountFileRestoreTransaction.RawResponse
import com.vortx.android.sync.AccountFileRestoreTransaction.Reason
import com.vortx.android.sync.AccountFileRestoreTransaction.Refusal
import com.vortx.android.sync.AccountFileRestoreTransaction.Result
import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.UUID
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Exercises the actual transaction, converter, crypto and encrypted journal. Network transport,
 * account/exclusion state, common host admission and kernel bindings are explicit synthetic seams. */
class AccountFileRestoreTransactionTest {
    @Rule @JvmField val temporary = TemporaryFolder()
    private val f = AccountBackupRepairFixture

    private fun metadata(path: Path): AccountFileRestoreJournal.UnixMetadata {
        val attrs = Files.readAttributes(path, "unix:uid,gid,mode", LinkOption.NOFOLLOW_LINKS)
        fun number(name: String) = (attrs.getValue(name) as Number).toInt()
        return AccountFileRestoreJournal.UnixMetadata(number("uid"), number("gid"), number("mode"))
    }

    private inner class Fixture(val root: File = temporary.newFolder(), headV2: Boolean = true) : ExclusiveRestore {
        private val rootIdentity = metadata(root.toPath())
        fun reopen() = AccountFileRestoreJournal.forJvmFixture(root.toPath(), rootIdentity.uid,
            rootIdentity.gid, ::metadata)
        val journal = reopen()
        val key = f.key()
        val lease = SyncSessionLease(7L, 11L, f.account, "synthetic-bearer", key)
        val bindings = AccountBackupRepairFixture.Bindings()
        val selected = f.file()
        val headPlaintext = f.source()
        val head = sealHead(headPlaintext, f.version, headV2)
        var readPolicy = HeadPolicy(0, false, true)
        var active = true
        var gets = 0
        var puts = 0
        var absenceChecks = 0
        var candidateChecks = 0
        var retainedGrant: PutGrant? = null
        var submittedBody: ByteArray? = null
        var ownedResponseBuffers = mutableListOf<ByteArray>()
        var verifiedCandidatePlaintext: ByteArray? = null
        var onAbsence: (Int) -> Unit = {}
        var onCandidate: (ByteArray) -> Unit = {}
        var get: (Int) -> RawResponse = { call ->
            when (call) {
                1, 2 -> response(200, head)
                else -> response(200, currentSubmissionHead())
            }
        }
        var put: (PutGrant) -> RawResponse = { grant ->
            acceptBody(grant)
            response(200, OHJson.literal("{\"accepted\":true}"))
        }
        val transaction = transaction(journal)
        fun transaction(storage: AccountFileRestoreJournal) = AccountFileRestoreTransaction(storage, bindings) {
                plaintext, scope, actualBindings, checkCurrent ->
            checkCurrent()
            assertEquals(VortxAccountScope("account.${f.account}", f.owner), scope)
            assertSame(bindings, actualBindings)
            assertNotNull(OHJson.Obj(plaintext)["nativeSync"])
            candidateChecks++
            verifiedCandidatePlaintext = plaintext.copyOf()
            onCandidate(plaintext)
            checkCurrent()
        }

        override fun requireCurrent(original: SyncSessionLease) {
            if (!active || original !== lease) throw Refusal(Reason.ACCOUNT_CHANGED)
        }
        override fun policy(original: SyncSessionLease): HeadPolicy {
            requireCurrent(original)
            return readPolicy
        }
        override suspend fun getHead(original: SyncSessionLease): RawResponse {
            requireCurrent(original)
            return get(++gets)
        }
        override fun requireIdle(original: SyncSessionLease) = requireCurrent(original)
        override fun requireLocalAbsence(original: SyncSessionLease, scope: VortxAccountScope) {
            requireCurrent(original)
            assertEquals(VortxAccountScope("account.${f.account}", f.owner), scope)
            onAbsence(++absenceChecks)
        }
        override suspend fun putOnce(original: SyncSessionLease, grant: PutGrant): RawResponse {
            requireCurrent(original)
            assertEquals(State.PossibleSend, snapshot().state)
            retainedGrant = grant
            puts++
            return put(grant)
        }

        fun acceptBody(grant: PutGrant) {
            assertNull(submittedBody)
            val bytes = grant.take(lease)
            try {
                assertArrayEquals(snapshot().intent.submissionBytes(), bytes)
                submittedBody = bytes.copyOf()
            } finally { bytes.fill(0) }
        }
        fun currentSubmissionHead(versionBound: Boolean = true, plaintext: ByteArray = submittedPlaintext()): ByteArray =
            sealHead(plaintext, f.version + 1, versionBound)
        fun submittedPlaintext(): ByteArray {
            val body = OHJson.Obj(checkNotNull(submittedBody))
            return requireNotNull(VortXCrypto.openDocument(key, body.text("document"), f.account,
                OHJson.integer(body.raw("version"))))
        }
        fun sealHead(plaintext: ByteArray, version: Long, versionBound: Boolean): ByteArray {
            val document = requireNotNull(VortXCrypto.sealDocument(key, plaintext, f.account, version, versionBound))
            return OHJson.Obj().set("document", OHJson.quote(document))
                .set("version", OHJson.literal(version.toString())).encoded()
        }
        fun response(status: Int, bytes: ByteArray): RawResponse =
            RawResponse(status, bytes.copyOf().also(ownedResponseBuffers::add))
        fun snapshot(storage: AccountFileRestoreJournal = journal) =
            (storage.readExisting(f.account, key) as Read.Present).snapshot
        fun readOnly(owner: SyncSessionLease, response: () -> RawResponse): AuthenticatedReads = object : AuthenticatedReads {
            override fun requireCurrent(original: SyncSessionLease) { assertSame(owner, original) }
            override fun policy(original: SyncSessionLease): HeadPolicy { requireCurrent(original); return readPolicy }
            override suspend fun getHead(original: SyncSessionLease): RawResponse {
                requireCurrent(original); gets++
                return response()
            }
        }
    }

    @Test fun exactTwoHeadsLiveGrantAndGenuineReadbackConfirmOneRetainedSubmission() = runBlocking {
        val x = Fixture()
        val firstBytes = x.selected.copyOf()
        val fresh = OHJson.Obj(x.head).set("serverMetadata", OHJson.literal("{ \"marker\":1.00 }")).encoded()
        x.get = { call -> x.response(200, when (call) { 1 -> x.head; 2 -> fresh; else -> x.currentSubmissionHead() }) }
        x.put = { grant ->
            val other = SyncSessionLease(7L, 11L, f.account, "same fields but different lease", x.key)
            assertTrue(runCatching { grant.take(other) }.exceptionOrNull() is Refusal)
            x.acceptBody(grant)
            assertTrue(runCatching { grant.take(x.lease) }.exceptionOrNull() is Refusal)
            x.response(200, OHJson.literal("{\"accepted\":true}"))
        }
        val result = x.transaction.restore(x.lease, x.selected, x) as Result.ServerConfirmed
        val stored = x.snapshot()
        assertEquals(State.ServerConfirmed, stored.state)
        assertEquals(stored.intent.operationId, result.operationId)
        assertEquals(f.version + 1, result.revision)
        assertEquals(3, x.gets); assertEquals(1, x.puts); assertEquals(1, x.candidateChecks)
        assertTrue(x.absenceChecks >= 3)
        assertArrayEquals(firstBytes, x.selected)
        assertArrayEquals(firstBytes, stored.intent.selectedFile())
        assertArrayEquals(fresh, stored.intent.displacedHeadResponse())
        assertArrayEquals(x.submittedBody, stored.intent.submissionBytes())
        assertArrayEquals(x.verifiedCandidatePlaintext, x.submittedPlaintext())
        assertArrayEquals(x.verifiedCandidatePlaintext, f.plaintext(stored.intent.candidateFile()))
        assertEquals(OHJson.sha(x.submittedPlaintext()), stored.intent.plaintextSha256)
        val body = OHJson.Obj(checkNotNull(x.submittedBody))
        assertEquals(setOf("document", "version", "baseRevision"), body.keys)
        assertEquals(f.version, OHJson.integer(body.raw("baseRevision")))
        assertTrue(body.text("document").startsWith(VortXCrypto.DOC_V2_PREFIX))
        assertTrue(x.ownedResponseBuffers.all { it.all { byte -> byte == 0.toByte() } })
        assertEquals(x.bindings.created, x.bindings.freed)
        assertTrue(runCatching { checkNotNull(x.retainedGrant).take(x.lease) }.exceptionOrNull() is Refusal)
    }

    @Test fun authenticatedDestinationWithResolvableOwnerStillRejectsQueuedOwnAndHeldMaterial() = runBlocking {
        val legacy = f.source(settings = false)
        val queued = listOf("profileEdits", "profileEditEvents", "webAddonEdits").map { key ->
            OHJson.Obj(legacy).set(key, OHJson.literal("null")).encoded()
        }
        val independent = OHJson.Obj(legacy).let { head ->
            val vortx = head.obj("vortx")
            val roster = OHJson.array(vortx.raw("roster")).map { bytes ->
                val profile = OHJson.Obj(bytes)
                if (profile.text("id") == f.child) profile.set("usesOwnAccount", OHJson.literal("true")).encoded() else bytes
            }
            head.set("vortx", vortx.set("roster", OHJson.array(roster)).encoded()).encoded()
        }
        val held = OHJson.Obj(legacy).let { head ->
            val vortx = head.obj("vortx").set("addons",
                OHJson.literal("""[{"transportUrl":"https://fixture.invalid/manifest.json","name":"old"}]"""))
            head.set("vortx", vortx.encoded()).encoded()
        }
        for (unsupported in queued + listOf(independent, held)) {
            // The old gate accepted this full roster. Keep selected bytes valid and separate.
            assertEquals(f.owner, AccountFileLegacyAdmission.legacyOwnerID(unsupported))
            val x = Fixture()
            val selectedBefore = x.selected.copyOf()
            val destination = x.sealHead(unsupported, f.version, true)
            x.get = { call ->
                assertEquals(1, call)
                x.response(200, destination)
            }
            assertEquals(Result.NotSubmitted(Reason.UNSUPPORTED_HEAD),
                x.transaction.restore(x.lease, x.selected, x))
            assertEquals(1, x.gets)
            assertEquals(0, x.bindings.created)
            assertEquals(0, x.candidateChecks)
            assertEquals(0, x.absenceChecks)
            assertEquals(0, x.puts)
            assertEquals(Read.Missing, x.journal.readExisting(f.account, x.key))
            assertArrayEquals(selectedBefore, x.selected)
            assertTrue(x.ownedResponseBuffers.single().all { it == 0.toByte() })
        }
    }

    @Test fun secondHeadRejectsEqualRevisionWithDifferentCiphertextAndNewFloorOrDowngrade() = runBlocking {
        val changed = Fixture()
        val resealed = changed.sealHead(changed.headPlaintext, f.version, true)
        changed.get = { call -> changed.response(200, if (call == 1) changed.head else resealed) }
        assertEquals(Result.NotSubmitted(Reason.STALE_HEAD), changed.transaction.restore(changed.lease, changed.selected, changed))
        assertEquals(0, changed.puts); assertEquals(Read.Missing, changed.journal.readExisting(f.account, changed.key))

        val floor = Fixture()
        floor.get = { call ->
            if (call == 2) floor.readPolicy = HeadPolicy(f.version + 1, false, true)
            floor.response(200, floor.head)
        }
        assertEquals(Result.NotSubmitted(Reason.STALE_HEAD), floor.transaction.restore(floor.lease, floor.selected, floor))
        assertEquals(0, floor.puts); assertEquals(Read.Missing, floor.journal.readExisting(f.account, floor.key))

        val ratchet = Fixture(headV2 = false)
        ratchet.get = { call ->
            if (call == 2) ratchet.readPolicy = HeadPolicy(0, true, true)
            ratchet.response(200, ratchet.head)
        }
        assertEquals(Result.NotSubmitted(Reason.UNSUPPORTED_HEAD), ratchet.transaction.restore(ratchet.lease, ratchet.selected, ratchet))
        assertEquals(0, ratchet.puts)

        val writeGate = Fixture().also { it.readPolicy = HeadPolicy(0, false, false) }
        assertEquals(Result.NotSubmitted(Reason.REVISION_UNAVAILABLE),
            writeGate.transaction.restore(writeGate.lease, writeGate.selected, writeGate))
        assertEquals(0, writeGate.puts)
    }

    @Test fun permittedLegacyHeadRetainsExistingWriteGateAndNeverCreatesAnAbsentCloudRow() = runBlocking {
        val legacy = Fixture(headV2 = false)
        legacy.readPolicy = HeadPolicy(0, false, false)
        legacy.get = { call -> legacy.response(200, if (call < 3) legacy.head else legacy.currentSubmissionHead(versionBound = false)) }
        assertTrue(legacy.transaction.restore(legacy.lease, legacy.selected, legacy) is Result.ServerConfirmed)
        assertFalse(OHJson.Obj(checkNotNull(legacy.submittedBody)).text("document").startsWith(VortXCrypto.DOC_V2_PREFIX))

        val empty = Fixture()
        empty.get = { RawResponse(404, null) }
        assertEquals(Result.NotSubmitted(Reason.NO_CLOUD_BACKUP), empty.transaction.restore(empty.lease, empty.selected, empty))
        assertEquals(Read.Missing, empty.journal.readExisting(f.account, empty.key))
        assertEquals(1, empty.gets); assertEquals(0, empty.puts)
    }

    @Test fun laterCompatibleReimportIsRetainedAndSubmittedWithoutReplacingItsNativeBytes() = runBlocking {
        val x = Fixture()
        val fresh = f.context().use { context ->
            AccountBackupRepair.convert(x.selected, context, AccountBackupRepairFixture.Bindings()) {}.use { it.fileBytes() }
        }
        val reimport = f.replaceCandidate(fresh) { raw ->
            raw.set("nativeSync", raw.obj("nativeSync")
                .set("fixtureFutureState", OHJson.literal("{ \"number\":1.2300,\"retained\":true }")).encoded())
        }
        assertTrue(x.transaction.restore(x.lease, reimport, x) is Result.ServerConfirmed)
        val stored = x.snapshot()
        assertArrayEquals(reimport, stored.intent.selectedFile())
        assertArrayEquals(reimport, stored.intent.candidateFile())
        assertArrayEquals(f.plaintext(reimport), x.submittedPlaintext())
        assertEquals(x.bindings.created, x.bindings.freed)
    }

    @Test fun absenceLostAfterDurableAdmissionLeavesExactNotSubmittedRecordAndNoRetry() = runBlocking {
        val x = Fixture()
        x.onAbsence = { count ->
            if (count == 2) {
                assertEquals(State.Retained, x.snapshot().state)
                throw Refusal(Reason.PENDING_LOCAL_CHANGES)
            }
        }
        assertEquals(Result.NotSubmitted(Reason.PENDING_LOCAL_CHANGES), x.transaction.restore(x.lease, x.selected, x))
        val original = x.snapshot()
        assertEquals(State.NotSubmitted, original.state)
        assertArrayEquals(x.selected, original.intent.selectedFile())
        assertEquals(2, x.gets); assertEquals(0, x.puts)
        assertEquals(Result.ExistingIntent(original.intent.operationId, State.NotSubmitted),
            x.transaction.restore(x.lease, x.selected, x))
        assertEquals(2, x.gets); assertEquals(0, x.puts)
    }

    @Test fun recoveredRetainedHasNoReadbackOrPutAndWrongOperationNeverGets() = runBlocking {
        val x = Fixture()
        val operation = UUID.randomUUID()
        val source = AccountFileRestoreJournal.Intent(operation, f.account, f.owner, f.version, f.version + 1,
            OHJson.sha(x.headPlaintext), x.selected, x.selected, x.head, OHJson.literal("{\"synthetic\":true}"))
        assertTrue(x.journal.admit(source, x.key) is AccountFileRestoreJournal.Mutation.Applied)
        val restarted = x.transaction(x.reopen())
        assertEquals(Result.ExistingIntent(operation, State.Retained), restarted.restore(x.lease, x.selected, x))
        assertEquals(Result.ExistingIntent(operation, State.Retained), restarted.verify(x.lease, operation, x))
        assertEquals(Result.NotSubmitted(Reason.WRONG_OPERATION), restarted.verify(x.lease, UUID.randomUUID(), x))
        assertEquals(0, x.gets); assertEquals(0, x.puts)
        assertEquals(State.Retained, x.snapshot().state)
    }

    @Test fun strictFalseIsConflictButDuplicateStringOversizedOrNon200VerdictsRemainUnconfirmed() = runBlocking {
        val valid = Fixture()
        valid.put = { grant -> valid.acceptBody(grant); valid.response(200, OHJson.literal("{\"accepted\":false}")) }
        val conflict = valid.transaction.restore(valid.lease, valid.selected, valid) as Result.Conflict
        assertEquals(conflict.operationId, valid.snapshot().intent.operationId)
        assertEquals(State.Conflict, valid.snapshot().state)
        assertEquals(2, valid.gets); assertEquals(1, valid.puts)

        val bad = listOf(
            200 to OHJson.literal("{\"accepted\":true,\"accepted\":false}"),
            200 to OHJson.literal("{\"accepted\":\"true\"}"),
            200 to OHJson.literal("{\"accepted\":1}"),
            200 to OHJson.literal("{\"accepted\":null}"),
            200 to ByteArray(AccountFileRestoreTransaction.CONTROL_RESPONSE_LIMIT + 1) { 32 },
            409 to OHJson.literal("{\"accepted\":false}"),
        )
        for ((status, bytes) in bad) {
            val x = Fixture()
            x.get = { x.response(200, x.head) } // Genuine readback does not match submitted revision.
            x.put = { grant -> x.acceptBody(grant); x.response(status, bytes) }
            assertTrue(x.transaction.restore(x.lease, x.selected, x) is Result.DeliveryUnconfirmed)
            assertEquals(State.DeliveryUnconfirmed, x.snapshot().state)
            assertEquals(3, x.gets); assertEquals(1, x.puts)
        }
    }

    @Test fun aReplyWithoutGrantConsumptionCannotClaimAcceptance() = runBlocking {
        val x = Fixture()
        x.get = { x.response(200, x.head) }
        x.put = { x.response(200, OHJson.literal("{\"accepted\":true}")) }
        assertTrue(x.transaction.restore(x.lease, x.selected, x) is Result.DeliveryUnconfirmed)
        assertNull(x.submittedBody)
        assertEquals(State.DeliveryUnconfirmed, x.snapshot().state)
        assertTrue(runCatching { checkNotNull(x.retainedGrant).take(x.lease) }.exceptionOrNull() is Refusal)
    }

    @Test fun lostAuthorityAfterPossibleSendNeverRetriesAndNewLeaseCanOnlyVerifyOriginalId() = runBlocking {
        val x = Fixture()
        x.put = { grant ->
            x.acceptBody(grant)
            x.active = false
            x.response(200, OHJson.literal("{\"accepted\":true}"))
        }
        val unresolved = x.transaction.restore(x.lease, x.selected, x) as Result.DeliveryUnconfirmed
        assertEquals(State.DeliveryUnconfirmed, x.snapshot().state)
        assertEquals(2, x.gets); assertEquals(1, x.puts)
        val owner = SyncSessionLease(8L, 12L, f.account, "reauthenticated-synthetic-bearer", x.key)
        val readOnly = x.readOnly(owner) { x.response(200, x.currentSubmissionHead()) }
        val restarted = x.transaction(x.reopen())
        assertEquals(Result.NotSubmitted(Reason.WRONG_OPERATION), restarted.verify(owner, UUID.randomUUID(), readOnly))
        assertEquals(2, x.gets)
        val wrongKey = SyncSessionLease(8L, 12L, f.account, "wrong-key-synthetic-bearer", ByteArray(32))
        val wrongReads = x.readOnly(wrongKey) { error("Wrong key must not issue a verification GET") }
        assertEquals(Result.NotSubmitted(Reason.RECOVERY_UNAVAILABLE),
            restarted.verify(wrongKey, unresolved.operationId, wrongReads))
        assertEquals(2, x.gets)
        assertEquals(Result.ServerConfirmed(unresolved.operationId, f.version + 1),
            restarted.verify(owner, unresolved.operationId, readOnly))
        assertEquals(State.ServerConfirmed, x.snapshot().state)
        assertEquals(3, x.gets); assertEquals(1, x.puts)
    }

    @Test fun acceptedIsSeparateFromReadbackOfExactDigestRevisionAndVersionBinding() = runBlocking {
        val x = Fixture()
        x.get = { call ->
            x.response(200, if (call < 3) x.head else x.currentSubmissionHead(plaintext = x.headPlaintext))
        }
        val accepted = x.transaction.restore(x.lease, x.selected, x) as Result.UploadAccepted
        assertEquals(State.UploadAccepted, x.snapshot().state)
        val legacyRead = x.readOnly(x.lease) { x.response(200, x.currentSubmissionHead(versionBound = false)) }
        assertEquals(accepted, x.transaction.verify(x.lease, accepted.operationId, legacyRead))
        assertEquals(State.UploadAccepted, x.snapshot().state)
        val exact = x.readOnly(x.lease) { x.response(200, x.currentSubmissionHead()) }
        assertEquals(Result.ServerConfirmed(accepted.operationId, f.version + 1),
            x.transaction.verify(x.lease, accepted.operationId, exact))
        assertEquals(1, x.puts)
    }

    @Test fun transportBoundaryRechecksAbsenceAfterPossibleSendBeforeReleasingAnyBytes() = runBlocking {
        val x = Fixture()
        x.onAbsence = { count ->
            if (count == 3) {
                assertEquals(State.PossibleSend, x.snapshot().state)
                throw Refusal(Reason.PENDING_LOCAL_CHANGES)
            }
        }
        x.put = { grant ->
            assertTrue(runCatching { x.acceptBody(grant) }.exceptionOrNull() is Refusal)
            assertNull(x.submittedBody)
            assertTrue(runCatching { grant.take(x.lease) }.exceptionOrNull() is Refusal)
            x.response(200, OHJson.literal("{\"accepted\":true}"))
        }
        x.get = { x.response(200, x.head) }
        assertTrue(x.transaction.restore(x.lease, x.selected, x) is Result.DeliveryUnconfirmed)
        assertEquals(State.DeliveryUnconfirmed, x.snapshot().state)
        assertEquals(1, x.puts)
        assertNull(x.submittedBody)
    }

    @Test fun fullHostRefusalOrMutationNeverCreatesJournalOrSends() = runBlocking {
        val refused = Fixture()
        refused.onCandidate = { throw IllegalArgumentException("synthetic host refuses") }
        assertEquals(Result.NotSubmitted(Reason.INVALID_HOST_DATA),
            refused.transaction.restore(refused.lease, refused.selected, refused))
        assertEquals(0, refused.puts)
        assertEquals(Read.Missing, refused.journal.readExisting(f.account, refused.key))

        val mutated = Fixture()
        mutated.onCandidate = { it[0] = 32 }
        assertEquals(Result.NotSubmitted(Reason.INVALID_HOST_DATA),
            mutated.transaction.restore(mutated.lease, mutated.selected, mutated))
        assertEquals(0, mutated.puts)
        assertEquals(Read.Missing, mutated.journal.readExisting(f.account, mutated.key))
    }
}
