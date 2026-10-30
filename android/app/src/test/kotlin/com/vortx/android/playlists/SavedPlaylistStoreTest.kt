package com.vortx.android.playlists

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.engine.NativeHostPreferences
import com.vortx.android.engine.NativePlaylist
import com.vortx.android.engine.NativePlaylistCloudReceiptLedger
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.player.queue.PlaybackQueueCodec
import com.vortx.android.player.queue.PlaybackQueueEntry
import com.vortx.android.player.queue.PlaybackQueueModel
import com.vortx.android.player.queue.PlaybackQueuePersistence
import com.vortx.android.player.queue.PlaybackQueueStore
import com.vortx.android.sync.NativePlaylistProfileGateway
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Proposed pure controller regressions. UNRUN in this recovery packet. */
@OptIn(ExperimentalCoroutinesApi::class)
class SavedPlaylistStoreTest {
    private val accountID = "00000000-0000-0000-0000-000000000111"
    private val profileID = "owner"
    private val actorID = "00000000-0000-0000-0000-000000000222"
    private val owner = ContinueWatchingOwner(profileID, "native", "account.$accountID", true, 7L)
    private val otherOwner = owner.copy(profileId = "guest", revision = 8L)

    private class MemoryQueuePersistence : PlaybackQueuePersistence {
        val values = mutableMapOf<String, String>()
        val writes = mutableListOf<Pair<String, String>>()
        override fun read(key: String): String? = values[key]
        override fun write(key: String, value: String): Boolean {
            writes += key to value
            values[key] = value
            return true
        }
    }

    private class FakeReceiptOwner : NativePlaylistProfileGateway.ReceiptOwner {
        var active = true
    }

    private class FakeTarget(
        override val accountId: String,
        override val profileId: String,
        override val receiptOwner: FakeReceiptOwner = FakeReceiptOwner(),
    ) : NativePlaylistProfileGateway.Target {
        var active = true
    }

    private class FakeSnapshot(
        override val target: FakeTarget,
        registers: JSONObject,
        override val receipt: NativePlaylistCloudReceiptLedger.Ticket? = null,
    ) : NativePlaylistProfileGateway.Snapshot {
        private val detached = JSONObject(registers.toString())
        override val registers: JSONObject get() = JSONObject(detached.toString())
    }

    private class FakeGateway(
        private val accountID: String,
        private val profileID: String,
        private val actorID: String,
        initial: JSONObject,
    ) : NativePlaylistProfileGateway {
        override val playlistChanges: Flow<Unit> get() = hints
        override val playlistReceiptChanges: Flow<Long> get() = receiptHints
        private val hints = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
        private val receiptHints = MutableStateFlow(0L)
        private var registers = JSONObject(initial.toString())
        private val receiptStates = mutableMapOf<UUID, NativePlaylistCloudReceiptLedger.State>()
        private val receiptOwners = mutableMapOf<UUID, FakeReceiptOwner>()
        private var clock = 10L
        var accountCurrent = true
        var writes = 0
        var publications = 0
        var retiredReceiptOwners = 0
        var nativeAccesses = 0
        var nativeAccessForbidden = false
        val writeTargets = mutableListOf<NativePlaylistProfileGateway.Target>()
        var issueReceipts = true
        var failNextWrite = false
        var conflictBeforeNextWrite: ((String, JSONObject) -> Unit)? = null
        var afterCompareAndSet: (() -> Unit)? = null
        var afterSnapshot: (() -> Unit)? = null

        private fun accessed() {
            nativeAccesses += 1
            check(!nativeAccessForbidden) { "Unexpected gateway access" }
        }

        override fun capturePlaylistProfile(): Result<NativePlaylistProfileGateway.Snapshot> = runCatching {
            accessed()
            check(accountCurrent)
            FakeSnapshot(FakeTarget(accountID, profileID), registers)
        }

        override fun playlistTargetIsCurrent(target: NativePlaylistProfileGateway.Target): Boolean {
            accessed()
            return accountCurrent && target is FakeTarget && target.active &&
                target.accountId == accountID && target.profileId == profileID
        }

        override fun playlistSnapshot(target: NativePlaylistProfileGateway.Target): Result<NativePlaylistProfileGateway.Snapshot> =
            runCatching {
                accessed()
                check(playlistTargetIsCurrent(target))
                FakeSnapshot(target as FakeTarget, registers).also { afterSnapshot?.also { callback ->
                    afterSnapshot = null
                    callback()
                } }
            }

        override fun publishPlaylistIfCurrent(
            snapshot: NativePlaylistProfileGateway.Snapshot,
            publication: () -> Unit,
        ): Boolean {
            accessed()
            publications += 1
            if (!playlistTargetIsCurrent(snapshot.target) ||
                !NativeHostPreferences.equal(snapshot.registers, registers)
            ) return false
            publication()
            return true
        }

        override fun retirePlaylistTarget(target: NativePlaylistProfileGateway.Target) {
            accessed()
            (target as? FakeTarget)?.active = false
        }

        override fun retirePlaylistReceiptOwner(owner: NativePlaylistProfileGateway.ReceiptOwner) {
            accessed()
            (owner as? FakeReceiptOwner)?.let {
                if (it.active) retiredReceiptOwners += 1
                it.active = false
            }
        }

        override fun playlistReceiptState(
            owner: NativePlaylistProfileGateway.ReceiptOwner,
            ticket: NativePlaylistCloudReceiptLedger.Ticket,
            current: NativePlaylistCloudReceiptLedger.Fingerprint,
        ): NativePlaylistCloudReceiptLedger.State {
            accessed()
            if ((owner as? FakeReceiptOwner)?.active != true || ticket.fingerprint != current) {
                return NativePlaylistCloudReceiptLedger.State.Unknown
            }
            if (receiptOwners[ticket.id] !== owner) return NativePlaylistCloudReceiptLedger.State.Unknown
            return receiptStates[ticket.id] ?: NativePlaylistCloudReceiptLedger.State.Unknown
        }

        override suspend fun compareAndSetPlaylistField(
            target: NativePlaylistProfileGateway.Target,
            editId: String,
            field: String,
            expectedRegister: JSONObject?,
            value: Any,
        ): Result<NativePlaylistProfileGateway.Snapshot> = runCatching {
            accessed()
            check(playlistTargetIsCurrent(target))
            if (failNextWrite) {
                failNextWrite = false
                error("Injected checkpoint failure")
            }
            writeTargets += target
            conflictBeforeNextWrite?.also { conflictBeforeNextWrite = null }?.invoke(field, registers)
            NativePlaylist.validateMutation(field, expectedRegister, value, registers)
            val detachedValue = if (value === JSONObject.NULL) JSONObject.NULL else JSONObject((value as JSONObject).toString())
            val register = JSONObject().put("clock", ++clock).put("actor", actorID).put("value", detachedValue)
            registers.put(field, register)
            writes += 1
            val ticket = if (!issueReceipts) null else {
                val id = UUID.fromString(editId)
                val canonical = requireNotNull(NativePlaylist.canonicalReceiptRegister(register))
                NativePlaylistCloudReceiptLedger.Ticket(
                    id, field, NativePlaylistCloudReceiptLedger.Fingerprint.of(canonical),
                ).also {
                    receiptOwners[id] = (target as FakeTarget).receiptOwner
                    receiptStates[id] = NativePlaylistCloudReceiptLedger.State.Pending
                }
            }
            afterCompareAndSet?.also { callback -> afterCompareAndSet = null; callback() }
            FakeSnapshot(target as FakeTarget, registers, ticket)
        }

        fun replaceRegister(field: String, value: Any) {
            val detached = if (value === JSONObject.NULL) JSONObject.NULL else JSONObject((value as JSONObject).toString())
            registers.put(field, JSONObject().put("clock", ++clock).put("actor", actorID).put("value", detached))
            hints.tryEmit(Unit)
        }

        fun emitPlaylistHint() {
            hints.tryEmit(Unit)
        }

        fun rawRegisters(): JSONObject = JSONObject(registers.toString())

        fun markSaved(editID: String, version: Long) {
            receiptStates[UUID.fromString(editID)] = NativePlaylistCloudReceiptLedger.State.Saved(version)
            receiptHints.value += 1
        }
    }

    private fun document(id: String, name: String, count: Int = 1): NativePlaylist.Document =
        NativePlaylist.Document(id, name, (1..count).map { number ->
            NativePlaylist.Entry(
                entryID = UUID(0L, number.toLong()).toString(),
                contentID = "tt$number",
                type = MediaType.MOVIE.id,
                title = "Movie $number",
            )
        })

    private fun largeDocument(id: String, name: String): NativePlaylist.Document =
        NativePlaylist.Document(id, name, (1..100).map { number ->
            NativePlaylist.Entry(
                entryID = UUID(2L, number.toLong()).toString(),
                contentID = "x".repeat(1024),
                type = MediaType.MOVIE.id,
                title = "T".repeat(512),
            )
        })

    private fun register(value: Any, clock: Long = 1L): JSONObject =
        JSONObject().put("clock", clock).put("actor", actorID).put("value", value)

    private fun queueEntry(number: Int) = PlaybackQueueEntry(
        UUID(1L, number.toLong()).toString(), MetaItem("queue-$number", MediaType.MOVIE, "Queue $number"),
    )

    private fun playlistHandle(
        store: SavedPlaylistStore,
        owner: ContinueWatchingOwner,
        field: String,
    ): SavedPlaylistHandle = requireNotNull(store.catalog(owner)).playlists.single { it.handle.field == field }.handle

    private fun duplicateDocument(id: String, name: String): NativePlaylist.Document = NativePlaylist.Document(
        id,
        name,
        listOf(
            NativePlaylist.Entry(UUID(9L, 1L).toString(), "tt-duplicate", MediaType.MOVIE.id, "Same"),
            NativePlaylist.Entry(UUID(9L, 2L).toString(), "tt-duplicate", MediaType.MOVIE.id, "Same"),
        ),
    )

    @Test fun `future playlists are read only and no content crosses owner boundary`() = runTest {
        val id = "00000000-0000-0000-0000-000000000301"
        val field = NativePlaylist.field(UUID.fromString(id))
        val futureField = "playlist.v2.opaque"
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(document(id, "Trips"))))
            .put(futureField, register(JSONObject().put("schema", 2).put("secretFutureShape", "preserve"), 2)))
        var currentOwner = owner
        val persistence = MemoryQueuePersistence()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(persistence, this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()

        val visible = requireNotNull(store.catalog(owner))
        assertEquals(2, visible.playlists.size)
        assertTrue(visible.playlists.single { it.handle.field == field }.editable)
        assertFalse(visible.playlists.single { it.handle.field == futureField }.editable)
        val futureHandle = visible.playlists.single { it.handle.field == futureField }.handle
        val supportedHandle = visible.playlists.single { it.handle.field == field }.handle
        assertTrue(store.detail(owner, futureHandle) is SavedPlaylistDetail.ReadOnlyFuture)

        currentOwner = otherOwner
        assertNull(store.catalog(owner))
        assertNull(store.detail(owner, supportedHandle))
        assertNull(store.drafts(owner))
        store.close()
    }

    @Test fun `stale register retains draft and explicit copy mints a fresh playlist`() = runTest {
        val id = "00000000-0000-0000-0000-000000000302"
        val field = NativePlaylist.field(UUID.fromString(id))
        val original = document(id, "Original")
        val gateway = FakeGateway(accountID, profileID, actorID,
            JSONObject().put(field, register(NativePlaylist.encodedValue(original))))
        var currentOwner = owner
        val persistence = MemoryQueuePersistence()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(persistence, this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val ids = ArrayDeque((400L..420L).map { UUID(0L, it) })
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher) { ids.removeFirst() }
        runCurrent()

        val rename = requireNotNull(store.captureRename(owner, playlistHandle(store, owner, field), "My edit"))
        gateway.conflictBeforeNextWrite = { conflictedField, fields ->
            val remote = NativePlaylist.encodedValue(original.copy(name = "Remote edit"))
            fields.put(conflictedField, register(remote, 12))
        }
        val failed = async { store.commit(rename) }
        runCurrent()
        assertEquals(SavedPlaylistWriteResult.DraftRetained, failed.await())
        val retainedDraft = requireNotNull(store.drafts(owner)).drafts.single()
        assertEquals("My edit", requireNotNull(store.draft(owner, retainedDraft.handle)).name)
        assertEquals(0, gateway.writes)

        val retainedView = requireNotNull(store.draft(owner, retainedDraft.handle))
        val copy = requireNotNull(store.captureDraftAsCopy(
            owner, requireNotNull(retainedView.copyHandle), "My copy",
        ))
        val copied = async { store.commit(copy) }
        runCurrent()
        assertTrue(copied.await() is SavedPlaylistWriteResult.Accepted)
        runCurrent()
        val documents = gateway.rawRegisters().keys().asSequence().mapNotNull { key ->
            (NativePlaylist.projection(key, gateway.rawRegisters().getJSONObject(key).get("value"))
                as? NativePlaylist.Projection.Supported)?.document
        }.toList()
        assertEquals(setOf("Remote edit", "My copy"), documents.map { it.name }.toSet())
        assertEquals(2, documents.map { it.id }.toSet().size)
        assertEquals(2, gateway.writeTargets.size)
        assertTrue(gateway.writeTargets[0] !== gateway.writeTargets[1])
        assertTrue(requireNotNull(store.drafts(owner)).drafts.isEmpty())
        store.close()
    }

    @Test fun `local checkpoint remains pending and owner change cannot retarget captured edit`() = runTest {
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject())
        var currentOwner = owner
        val persistence = MemoryQueuePersistence()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(persistence, this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        runCurrent()
        assertTrue(queue.appendCandidates(owner, listOf(MetaItem("tt-save", MediaType.MOVIE, "Saved"))))
        runCurrent()
        val ids = ArrayDeque((500L..520L).map { UUID(0L, it) })
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher) { ids.removeFirst() }
        runCurrent()

        val intent = requireNotNull(store.captureCreateFromQueue(
            owner, requireNotNull(store.catalog(owner)).creationHandle, "Watch later",
        ))
        val saved = async { store.commit(intent) }
        runCurrent()
        val result = saved.await() as SavedPlaylistWriteResult.Accepted
        runCurrent()
        val summary = requireNotNull(store.catalog(owner)).playlists.single()
        assertEquals(SavedPlaylistStatus.LocalPending, summary.status)
        assertEquals(SavedPlaylistStatus.LocalPending, result.status)
        assertTrue(result.editID.isNotBlank())

        gateway.markSaved(result.editID, 42L)
        runCurrent()
        assertEquals(SavedPlaylistStatus.CloudSaved(42L),
            requireNotNull(store.catalog(owner)).playlists.single().status)

        val second = requireNotNull(store.captureRename(owner, summary.handle, "Do not retarget"))
        gateway.afterCompareAndSet = { store.invalidateAuthority() }
        val stale = async { store.commit(second) }
        runCurrent()
        assertEquals(SavedPlaylistWriteResult.Superseded, stale.await())
        assertEquals(2, gateway.writes) // Local CAS won, but authority cut prevents a success claim.
        val returnedOwner = owner.copy(revision = 9L)
        currentOwner = returnedOwner
        val staleDraft = requireNotNull(store.drafts(returnedOwner)).drafts.single()
        assertTrue(staleDraft.stale)
        assertEquals("Do not retarget", requireNotNull(store.draft(returnedOwner, staleDraft.handle)).name)
        assertTrue(store.discardDraft(returnedOwner, staleDraft.handle))
        currentOwner = otherOwner
        assertNull(store.catalog(owner))
        store.close()
    }

    @Test fun `delete writes a retained tombstone and reports pending deletion without a synced claim`() = runTest {
        val id = "00000000-0000-0000-0000-000000000304"
        val field = NativePlaylist.field(UUID.fromString(id))
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(document(id, "Remove me")))))
        var currentOwner = owner
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(MemoryQueuePersistence(), this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()

        val deletion = requireNotNull(store.captureDelete(owner, playlistHandle(store, owner, field)))
        val committed = async { store.commit(deletion) }
        runCurrent()
        assertTrue(committed.await() is SavedPlaylistWriteResult.Accepted)
        runCurrent()
        val visible = requireNotNull(store.catalog(owner))
        assertTrue(visible.playlists.isEmpty())
        assertEquals(1, visible.pendingDeletionCount)
        assertEquals(0, visible.unknownDeletionCount)
        val retained = gateway.rawRegisters()
        assertTrue(retained.has(field))
        assertTrue(retained.getJSONObject(field).get("value") === JSONObject.NULL)
        store.close()
    }

    @Test fun `missing receipt remains cloud unknown after durable local readback`() = runTest {
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()).apply { issueReceipts = false }
        var currentOwner = owner
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(MemoryQueuePersistence(), this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        runCurrent()
        assertTrue(queue.appendCandidates(owner, listOf(MetaItem("tt-unknown", MediaType.MOVIE, "Unknown"))))
        runCurrent()
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()

        val accepted = async { store.commit(requireNotNull(store.captureCreateFromQueue(
            owner, requireNotNull(store.catalog(owner)).creationHandle, "Unknown receipt",
        ))) }
        runCurrent()
        val result = accepted.await() as SavedPlaylistWriteResult.Accepted
        assertEquals(SavedPlaylistStatus.CloudUnknown, result.status)
        runCurrent()
        assertEquals(SavedPlaylistStatus.CloudUnknown,
            requireNotNull(store.catalog(owner)).playlists.single().status)
        store.close()
    }

    @Test fun `same profile projection cut preserves pending receipt through accepted sync`() = runTest {
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject())
        var currentOwner = owner
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(MemoryQueuePersistence(), this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        runCurrent()
        assertTrue(queue.appendCandidates(owner, listOf(MetaItem("tt-pending", MediaType.MOVIE, "Pending"))))
        runCurrent()
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()

        val intent = requireNotNull(store.captureCreateFromQueue(
            owner, requireNotNull(store.catalog(owner)).creationHandle, "Pending receipt",
        ))
        val committed = async { store.commit(intent) }
        runCurrent()
        val accepted = committed.await() as SavedPlaylistWriteResult.Accepted
        runCurrent()
        assertEquals(SavedPlaylistStatus.LocalPending,
            requireNotNull(store.catalog(owner)).playlists.single().status)

        store.nativeProjectionWillChange()
        gateway.emitPlaylistHint() // Mirrors the Session playlist pulse after its before-change callback.
        runCurrent()
        assertEquals(0, gateway.retiredReceiptOwners)
        assertEquals(SavedPlaylistStatus.LocalPending,
            requireNotNull(store.catalog(owner)).playlists.single().status)

        gateway.markSaved(accepted.editID, 73L)
        runCurrent()
        assertEquals(SavedPlaylistStatus.CloudSaved(73L),
            requireNotNull(store.catalog(owner)).playlists.single().status)
        store.close()
    }

    @Test fun `true profile cut purges receipt capability and account ABA cannot restore saved state`() = runTest {
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject())
        var currentOwner = owner
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(MemoryQueuePersistence(), this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        runCurrent()
        assertTrue(queue.appendCandidates(owner, listOf(MetaItem("tt-cut", MediaType.MOVIE, "Cut"))))
        runCurrent()
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()
        val intent = requireNotNull(store.captureCreateFromQueue(
            owner, requireNotNull(store.catalog(owner)).creationHandle, "Cut receipt",
        ))
        val committed = async { store.commit(intent) }
        runCurrent()
        val accepted = committed.await() as SavedPlaylistWriteResult.Accepted
        runCurrent()

        currentOwner = otherOwner
        store.invalidateAuthority()
        runCurrent()
        assertTrue(gateway.retiredReceiptOwners > 0)
        val returnedOwner = owner.copy(revision = 99L)
        currentOwner = returnedOwner
        gateway.emitPlaylistHint()
        runCurrent()
        assertEquals(SavedPlaylistStatus.CloudUnknown,
            requireNotNull(store.catalog(returnedOwner)).playlists.single().status)

        gateway.markSaved(accepted.editID, 99L)
        runCurrent()
        assertEquals(SavedPlaylistStatus.CloudUnknown,
            requireNotNull(store.catalog(returnedOwner)).playlists.single().status)
        store.close()
    }

    @Test fun `stale rendered capability cannot rename a refreshed same field`() = runTest {
        val id = "00000000-0000-0000-0000-000000000308"
        val field = NativePlaylist.field(UUID.fromString(id))
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(document(id, "Rendered")))))
        val currentOwner = owner
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(MemoryQueuePersistence(), this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()

        val rendered = requireNotNull(store.detail(owner, playlistHandle(store, owner, field)))
            as SavedPlaylistDetail.Supported
        val delayed = requireNotNull(store.captureRename(owner, rendered.handle, "Delayed"))
        gateway.replaceRegister(field, NativePlaylist.encodedValue(document(id, "Remote newer")))
        runCurrent()

        assertNull(store.captureRename(owner, rendered.handle, "Must reject"))
        val stale = async { store.commit(delayed) }
        runCurrent()
        assertEquals(SavedPlaylistWriteResult.Superseded, stale.await())
        assertEquals(0, gateway.writes)
        val fresh = requireNotNull(store.detail(owner, playlistHandle(store, owner, field)))
            as SavedPlaylistDetail.Supported
        assertEquals("Remote newer", fresh.name)
        store.close()
    }

    @Test fun `create and replace reject a queue revision changed after the gesture`() = runTest {
        val id = "00000000-0000-0000-0000-000000000311"
        val field = NativePlaylist.field(UUID.fromString(id))
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(document(id, "Observed queue")))))
        val currentOwner = owner
        val dispatcher = StandardTestDispatcher(testScheduler)
        val persistence = MemoryQueuePersistence()
        val queue = PlaybackQueueStore(persistence, this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        runCurrent()
        assertTrue(queue.add(owner, MetaItem("queue-original", MediaType.MOVIE, "Original")))
        runCurrent()
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()
        val catalog = requireNotNull(store.catalog(owner))
        val handle = catalog.playlists.single().handle

        val create = requireNotNull(store.captureCreateFromQueue(owner, catalog.creationHandle, "Captured"))
        val replace = requireNotNull(store.captureReplaceFromQueue(owner, handle))
        assertTrue(queue.add(owner, MetaItem("queue-newer", MediaType.MOVIE, "Newer")))
        runCurrent()

        val createResult = async { store.commit(create) }
        runCurrent()
        assertEquals(SavedPlaylistWriteResult.Superseded, createResult.await())
        val replaceResult = async { store.commit(replace) }
        runCurrent()
        assertEquals(SavedPlaylistWriteResult.Superseded, replaceResult.await())
        assertEquals(0, gateway.writes)
        assertEquals(listOf("Original", "Newer"), queue.state.value.entries.map { it.item.name })
        store.close()
    }

    @Test fun `all gesture captures stay local when gateway access is forbidden`() = runTest {
        val id = "00000000-0000-0000-0000-000000000309"
        val field = NativePlaylist.field(UUID.fromString(id))
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(document(id, "Rendered")))))
        val currentOwner = owner
        var ownerReads = 0
        var ownerReadForbidden = false
        val ownerLookup = {
            ownerReads += 1
            check(!ownerReadForbidden) { "Unexpected current-owner lookup" }
            currentOwner
        }
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(MemoryQueuePersistence(), this, ownerLookup, dispatcher)
        queue.bindOwner(owner)
        val store = SavedPlaylistStore(gateway, queue, this, ownerLookup, dispatcher)
        runCurrent()

        val firstHandle = playlistHandle(store, owner, field)
        val failedIntent = requireNotNull(store.captureRename(owner, firstHandle, "Retained"))
        gateway.failNextWrite = true
        val failed = async { store.commit(failedIntent) }
        runCurrent()
        assertEquals(SavedPlaylistWriteResult.DraftRetained, failed.await())
        runCurrent()
        val catalog = requireNotNull(store.catalog(owner))
        val detail = requireNotNull(store.detail(owner, catalog.playlists.single().handle))
            as SavedPlaylistDetail.Supported
        val draftSummary = requireNotNull(store.drafts(owner)).drafts.single()
        val draft = requireNotNull(store.draft(owner, draftSummary.handle))
        val gatewayAccesses = gateway.nativeAccesses
        val currentOwnerReads = ownerReads

        gateway.nativeAccessForbidden = true
        ownerReadForbidden = true
        assertTrue(store.captureCreateFromQueue(owner, catalog.creationHandle, "New") != null)
        assertTrue(store.captureRename(owner, detail.handle, "Renamed") != null)
        assertTrue(store.captureReplaceFromQueue(owner, detail.handle) != null)
        assertTrue(store.captureDelete(owner, detail.handle) != null)
        assertTrue(store.captureImport(owner, detail.handle) != null)
        assertTrue(store.captureDraftAsCopy(owner, requireNotNull(draft.copyHandle), "Copy") != null)
        assertEquals(gatewayAccesses, gateway.nativeAccesses)
        assertEquals(currentOwnerReads, ownerReads)
        ownerReadForbidden = false
        gateway.nativeAccessForbidden = false
        store.close()
    }

    @Test fun `duplicate playlist content retains distinct entry identities in saved and draft views`() = runTest {
        val id = "00000000-0000-0000-0000-000000000310"
        val field = NativePlaylist.field(UUID.fromString(id))
        val duplicate = duplicateDocument(id, "Duplicates")
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(duplicate))))
        val currentOwner = owner
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(MemoryQueuePersistence(), this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()

        val detail = requireNotNull(store.detail(owner, playlistHandle(store, owner, field)))
            as SavedPlaylistDetail.Supported
        assertEquals(listOf("tt-duplicate", "tt-duplicate"), detail.entries.map { it.contentID })
        assertEquals(2, detail.entries.map { it.entryID }.toSet().size)

        val intent = requireNotNull(store.captureRename(owner, detail.handle, "Draft duplicates"))
        gateway.failNextWrite = true
        val retained = async { store.commit(intent) }
        runCurrent()
        assertEquals(SavedPlaylistWriteResult.DraftRetained, retained.await())
        runCurrent()
        val draftSummary = requireNotNull(store.drafts(owner)).drafts.single()
        val draft = requireNotNull(store.draft(owner, draftSummary.handle))
        assertEquals(listOf("tt-duplicate", "tt-duplicate"), draft.entries.map { it.contentID })
        assertEquals(2, draft.entries.map { it.entryID }.toSet().size)
        store.close()
    }

    @Test fun `intent capture cannot adopt a cut advanced before invalidation reaches its monitor`() = runTest {
        val id = "00000000-0000-0000-0000-000000000307"
        val field = NativePlaylist.field(UUID.fromString(id))
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(document(id, "Race")))))
        val currentOwner = owner
        val persistence = MemoryQueuePersistence()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(persistence, this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val sourceCertified = CountDownLatch(1)
        val cutAdvanced = CountDownLatch(1)
        val raceHook = object : SavedPlaylistAuthorityRaceTestHook {
            override fun beforeIntentCertificateWhileHoldingConsumerMonitor() {
                sourceCertified.countDown()
                check(cutAdvanced.await(5, TimeUnit.SECONDS))
            }

            override fun afterAuthorityCutBeforeConsumerMonitor() {
                cutAdvanced.countDown()
            }
        }
        val store = SavedPlaylistStore(
            gateway, queue, this, { currentOwner }, dispatcher, authorityRaceTestHook = raceHook,
        )
        runCurrent()

        val intent = requireNotNull(store.captureImport(owner, playlistHandle(store, owner, field)))
        val invalidated = async(Dispatchers.Default) {
            check(sourceCertified.await(5, TimeUnit.SECONDS))
            store.nativeProjectionWillChange()
        }
        val captured = async { store.importIntoQueue(intent) }
        runCurrent()

        assertEquals(SavedPlaylistImportResult.SUPERSEDED, captured.await())
        invalidated.await()
        assertTrue(cutAdvanced.await(5, TimeUnit.SECONDS))
        runCurrent()
        assertTrue(queue.state.value.entries.isEmpty())
        assertTrue(persistence.writes.isEmpty())
        store.close()
        runCurrent()
    }

    @Test fun `authority cut during refreshed import wins before final queue admission`() = runTest {
        val id = "00000000-0000-0000-0000-000000000305"
        val field = NativePlaylist.field(UUID.fromString(id))
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(document(id, "Two", count = 2)))))
        var currentOwner = owner
        val persistence = MemoryQueuePersistence()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(persistence, this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()
        val intent = requireNotNull(store.captureImport(owner, playlistHandle(store, owner, field)))
        val publications = gateway.publications
        gateway.afterSnapshot = { store.nativeProjectionWillChange() }

        val imported = async { store.importIntoQueue(intent) }
        runCurrent()
        assertEquals(SavedPlaylistImportResult.SUPERSEDED, imported.await())
        assertTrue(queue.state.value.entries.isEmpty())
        assertTrue(persistence.writes.isEmpty())
        assertTrue(gateway.publications > publications) // Final refreshed snapshot admission was attempted.
        store.close()
    }

    @Test fun `draft aggregate budget rejects a new draft without losing retained edits`() = runTest {
        val registers = JSONObject()
        val fields = (1L..20L).map { number ->
            val id = UUID(3L, number).toString()
            NativePlaylist.field(UUID.fromString(id)).also { field ->
                registers.put(field, register(NativePlaylist.encodedValue(largeDocument(id, "Large $number")), number))
            }
        }
        val gateway = FakeGateway(accountID, profileID, actorID, registers)
        var currentOwner = owner
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(MemoryQueuePersistence(), this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()

        var admitted = 0
        for ((index, field) in fields.withIndex()) {
            val intent = requireNotNull(store.captureRename(
                owner, playlistHandle(store, owner, field), "Draft $index",
            ))
            gateway.failNextWrite = true
            val result = async { store.commit(intent) }
            runCurrent()
            if (result.await() != SavedPlaylistWriteResult.DraftRetained) break
            runCurrent() // Apply the requested reload before observing the next rendered capability.
            admitted += 1
        }
        val retained = requireNotNull(store.drafts(owner))
        assertTrue(admitted in 1 until fields.size)
        assertEquals(admitted, retained.drafts.size)
        assertTrue(retained.retainedBytes <= retained.limitBytes)
        assertTrue(retained.drafts.all { requireNotNull(store.draft(owner, it.handle)).name.startsWith("Draft ") })
        assertEquals(0, gateway.writes)
        store.close()
    }

    @Test fun `playlist import is one admitted local write with fresh queue identities`() = runTest {
        val id = "00000000-0000-0000-0000-000000000306"
        val field = NativePlaylist.field(UUID.fromString(id))
        val cloud = document(id, "Two", count = 2)
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(cloud))))
        var currentOwner = owner
        val persistence = MemoryQueuePersistence()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(persistence, this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()

        val imported = async {
            store.importIntoQueue(requireNotNull(store.captureImport(owner, playlistHandle(store, owner, field))))
        }
        runCurrent()
        assertEquals(SavedPlaylistImportResult.LOCAL_QUEUE_WRITE_ADMITTED, imported.await())
        runCurrent()
        val queued = queue.state.value.entries
        assertEquals(listOf("Movie 1", "Movie 2"), queued.map { it.item.name })
        assertEquals(2, queued.map { it.id }.toSet().size)
        assertTrue(queued.map { it.id }.toSet().intersect(cloud.entries.map { it.entryID }.toSet()).isEmpty())
        assertEquals(1, persistence.writes.size)
        store.close()
    }

    @Test fun `queue admission stamp conserves state on cut and appends once without consuming head`() = runTest {
        var currentOwner = owner
        val persistence = MemoryQueuePersistence()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(persistence, this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        runCurrent()
        assertTrue(queue.add(owner, MetaItem("head", MediaType.MOVIE, "Existing head")))
        runCurrent()
        persistence.writes.clear()
        val before = queue.state.value
        var rejectedChecks = 0

        assertFalse(queue.appendCandidatesIfCurrent(
            owner, listOf(MetaItem("blocked", MediaType.MOVIE, "Blocked")),
        ) { rejectedChecks += 1; false })
        assertEquals(1, rejectedChecks)
        assertEquals(before, queue.state.value)
        assertTrue(persistence.writes.isEmpty())

        var admittedChecks = 0
        assertTrue(queue.appendCandidatesIfCurrent(
            owner, listOf(
                MetaItem("one", MediaType.MOVIE, "One"),
                MetaItem("two", MediaType.MOVIE, "Two"),
            ),
        ) { admittedChecks += 1; true })
        runCurrent()
        assertEquals(1, admittedChecks)
        assertEquals(before.entries.single(), queue.state.value.entries.first())
        assertEquals(listOf("Existing head", "One", "Two"), queue.state.value.entries.map { it.item.name })
        assertEquals(1, persistence.writes.size)
    }

    @Test fun `playlist import rejects capacity overflow without partial queue mutation or autoplay`() = runTest {
        val id = "00000000-0000-0000-0000-000000000303"
        val field = NativePlaylist.field(UUID.fromString(id))
        val gateway = FakeGateway(accountID, profileID, actorID, JSONObject()
            .put(field, register(NativePlaylist.encodedValue(document(id, "Two", count = 2)))))
        var currentOwner = owner
        val persistence = MemoryQueuePersistence().apply {
            values[PlaybackQueueModel.storageKey(owner)] =
                PlaybackQueueCodec.encode((1..99).map(::queueEntry))
        }
        val dispatcher = StandardTestDispatcher(testScheduler)
        val queue = PlaybackQueueStore(persistence, this, { currentOwner }, dispatcher)
        queue.bindOwner(owner)
        val store = SavedPlaylistStore(gateway, queue, this, { currentOwner }, dispatcher)
        runCurrent()
        val before = queue.state.value

        val import = requireNotNull(store.captureImport(owner, playlistHandle(store, owner, field)))
        val result = async { store.importIntoQueue(import) }
        runCurrent()
        assertEquals(SavedPlaylistImportResult.REJECTED, result.await())
        assertEquals(before, queue.state.value)
        assertEquals(99, queue.state.value.entries.size)
        assertTrue(persistence.writes.isEmpty())
        store.close()
    }
}
