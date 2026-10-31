package com.vortx.android.playlists

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.engine.NativeHostPreferences
import com.vortx.android.engine.NativePlaylist
import com.vortx.android.engine.NativePlaylistCloudReceiptLedger
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.PreferredEpisode
import com.vortx.android.model.continueWatchingEpisodeFromVideoIdentity
import com.vortx.android.player.queue.PlaybackQueueModel
import com.vortx.android.player.queue.PlaybackQueueStore
import com.vortx.android.sync.NativePlaylistProfileGateway
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Cached truth for one exact current register; only a receipt can produce [CloudSaved]. */
internal sealed interface SavedPlaylistStatus {
    data object CloudUnknown : SavedPlaylistStatus
    data object LocalPending : SavedPlaylistStatus
    data class CloudSaved(val version: Long) : SavedPlaylistStatus
}

/**
 * Opaque capability for the exact register/source generation rendered to the caller. The payload
 * contains no gateway target or receipt owner, so retaining UI state cannot retain native authority.
 */
internal class SavedPlaylistHandle internal constructor(
    val field: String,
    internal val opaque: Any,
)

/** Exact published collection generation used by a create gesture. */
internal class SavedPlaylistCollectionHandle internal constructor(internal val opaque: Any)

internal data class SavedPlaylistSummary(
    val handle: SavedPlaylistHandle,
    val name: String,
    val entryCount: Int?,
    val editable: Boolean,
    val status: SavedPlaylistStatus,
)

internal data class SavedPlaylistCatalog(
    val creationHandle: SavedPlaylistCollectionHandle,
    val playlists: List<SavedPlaylistSummary>,
    val pendingDeletionCount: Int,
    val unknownDeletionCount: Int,
)

internal data class SavedPlaylistEntryView(
    val entryID: String,
    val contentID: String,
    val type: String,
    val title: String,
    val videoIDHint: String?,
    val episodeLabel: String?,
)

internal sealed interface SavedPlaylistDetail {
    val handle: SavedPlaylistHandle
    val status: SavedPlaylistStatus

    data class Supported(
        override val handle: SavedPlaylistHandle,
        override val status: SavedPlaylistStatus,
        val name: String,
        val entries: List<SavedPlaylistEntryView>,
    ) : SavedPlaylistDetail

    /** Bounded future data stays in its raw native register but is never exposed or edited here. */
    data class ReadOnlyFuture(
        override val handle: SavedPlaylistHandle,
        override val status: SavedPlaylistStatus,
    ) : SavedPlaylistDetail
}

internal class SavedPlaylistDraftHandle internal constructor(
    val editID: String,
    internal val opaque: Any,
)

/** Deliberate current-source capability issued only by an off-main draft read. */
internal class SavedPlaylistDraftCopyHandle internal constructor(internal val opaque: Any)

internal data class SavedPlaylistDraftSummary(
    val handle: SavedPlaylistDraftHandle,
    val playlist: SavedPlaylistHandle,
    val name: String,
    val deleting: Boolean,
    val stale: Boolean,
    val retainedBytes: Int,
)

internal data class SavedPlaylistDraftCatalog(
    val drafts: List<SavedPlaylistDraftSummary>,
    val retainedBytes: Int,
    val limitBytes: Int,
)

internal data class SavedPlaylistDraftView(
    val handle: SavedPlaylistDraftHandle,
    val playlist: SavedPlaylistHandle,
    val copyHandle: SavedPlaylistDraftCopyHandle?,
    val name: String,
    val entries: List<SavedPlaylistEntryView>,
    val deleting: Boolean,
    val stale: Boolean,
)

internal sealed interface SavedPlaylistWriteResult {
    /** The raw CAS was checkpointed/read back; status remains receipt-derived and exact-register scoped. */
    data class Accepted(val editID: String, val status: SavedPlaylistStatus) : SavedPlaylistWriteResult
    data object DraftRetained : SavedPlaylistWriteResult
    data object Superseded : SavedPlaylistWriteResult
}

internal enum class SavedPlaylistImportResult {
    LOCAL_QUEUE_WRITE_ADMITTED,
    REJECTED,
    SUPERSEDED,
}

/** Signal-only deterministic race seam for pure source tests; production always supplies null. */
internal interface SavedPlaylistAuthorityRaceTestHook {
    /** Called with only the consumer monitor held. A test may block this callback, but must call no store API. */
    fun beforeIntentCertificateWhileHoldingConsumerMonitor()
    /** Called after the atomic cut advances and before invalidation takes the consumer monitor. Signal only. */
    fun afterAuthorityCutBeforeConsumerMonitor()
}

/**
 * Profile-scoped saved-playlist controller.
 *
 * The gateway owns authentication, the original revocable Session target, exact raw-register CAS,
 * prospective whole-account budget, checkpoint replacement and durable readback. This class owns
 * only bounded catalog projection, retained in-memory edit drafts and atomic local queue import.
 * It never recaptures a successor account for an edit. Only an exact receipt can label a register
 * cloud-saved; a locally checkpointed register remains pending or unknown.
 */
internal class SavedPlaylistStore(
    private val gateway: NativePlaylistProfileGateway,
    private val queue: PlaybackQueueStore,
    private val scope: CoroutineScope,
    private val currentQueueOwner: () -> ContinueWatchingOwner?,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val authorityRaceTestHook: SavedPlaylistAuthorityRaceTestHook? = null,
    private val newUUID: () -> UUID = UUID::randomUUID,
) : AutoCloseable {
    /** Opaque so no caller can rewrite the captured target, register, value or generation. */
    internal class WriteIntent internal constructor(internal val opaque: Any)
    internal class ImportIntent internal constructor(internal val opaque: Any)

    private data class Partition(val accountID: String, val profileID: String)

    private class ReceiptAuthority(val owner: NativePlaylistProfileGateway.ReceiptOwner) {
        var references = 1
        var retired = false
    }

    private class Authority(
        val target: NativePlaylistProfileGateway.Target,
        val receiptAuthority: ReceiptAuthority,
    ) {
        var references = 1
        var retired = false
    }

    private data class Record(
        val field: String,
        val register: JSONObject,
        val projection: NativePlaylist.Projection,
        val fingerprint: NativePlaylistCloudReceiptLedger.Fingerprint?,
    )

    private data class Source(
        /** Pure identity token; unlike [Authority], safe for rendered observations to retain. */
        val identity: Any,
        val generation: Long,
        val authorityEpoch: Long,
        val authorityCut: Long,
        val partition: Partition,
        val owner: ContinueWatchingOwner,
        val authority: Authority,
        val snapshot: NativePlaylistProfileGateway.Snapshot,
        val registers: JSONObject,
        val records: Map<String, Record>,
    )

    private data class SourceCertificate(
        val identity: Any,
        val generation: Long,
        val authorityEpoch: Long,
        val authorityCut: Long,
        val partition: Partition,
        val owner: ContinueWatchingOwner,
    )

    private data class CollectionObservation(val source: SourceCertificate)
    private data class PlaylistObservation(val source: SourceCertificate, val record: Record)
    private data class DraftPlaylistObservation(val field: String)
    private data class QueueObservation(
        val owner: ContinueWatchingOwner,
        val revision: Long,
        val items: List<MetaItem>,
    )

    private data class DraftKey(val partition: Partition, val owner: ContinueWatchingOwner, val field: String)

    private class Draft(
        val key: DraftKey,
        val editID: String,
        val writeGeneration: Long,
        val authorityEpoch: Long,
        var authority: Authority?,
        val expectedRegister: JSONObject?,
        val value: Any,
        val removeOnSuccess: Map<DraftKey, String>,
        val retainedBytes: Int,
        var ownsWriteAuthority: Boolean = true,
        var ownsReceiptAuthority: Boolean = true,
    )

    private data class DraftObservation(
        val key: DraftKey,
        val editID: String,
        val writeGeneration: Long,
    )

    private data class DraftCopyObservation(
        val draft: DraftObservation,
        val source: SourceCertificate,
    )

    private sealed interface WriteRequest {
        val owner: ContinueWatchingOwner
        val editID: String

        data class Create(
            override val owner: ContinueWatchingOwner,
            override val editID: String,
            val collection: CollectionObservation,
            val queue: QueueObservation,
            val name: String,
        ) : WriteRequest

        data class Replace(
            override val owner: ContinueWatchingOwner,
            override val editID: String,
            val playlist: PlaylistObservation,
            val queue: QueueObservation,
            val name: String?,
        ) : WriteRequest

        data class Rename(
            override val owner: ContinueWatchingOwner,
            override val editID: String,
            val playlist: PlaylistObservation,
            val name: String,
        ) : WriteRequest

        data class Delete(
            override val owner: ContinueWatchingOwner,
            override val editID: String,
            val playlist: PlaylistObservation,
        ) : WriteRequest

        data class CopyDraft(
            override val owner: ContinueWatchingOwner,
            override val editID: String,
            val copy: DraftCopyObservation,
            val name: String?,
        ) : WriteRequest
    }

    private data class ImportRequest(
        val owner: ContinueWatchingOwner,
        val playlist: PlaylistObservation,
    )

    private data class WriteToken(
        val key: DraftKey,
        val editID: String,
        val sourceIdentity: Any,
        val sourceGeneration: Long,
        val writeGeneration: Long,
        val authorityEpoch: Long,
        val authorityCut: Long,
    )

    private data class ImportToken(
        val sourceIdentity: Any,
        val sourceGeneration: Long,
        val authorityEpoch: Long,
        val authorityCut: Long,
        val partition: Partition,
        val owner: ContinueWatchingOwner,
        val target: NativePlaylistProfileGateway.Target,
        val field: String,
        val expectedRegister: JSONObject,
        val candidates: List<MetaItem>,
    )

    private data class ConsumerCertificate(val authorityEpoch: Long, val authorityCut: Long)

    private class ReceiptBinding(
        val partition: Partition,
        val field: String,
        val editID: String,
        val fingerprint: NativePlaylistCloudReceiptLedger.Fingerprint,
        val deleting: Boolean,
        var state: NativePlaylistCloudReceiptLedger.State,
        var receiptAuthority: ReceiptAuthority?,
        val ticket: NativePlaylistCloudReceiptLedger.Ticket?,
    )

    private sealed interface Publication {
        data object Loading : Publication
        data class Failed(val message: String) : Publication
        data class Ready(val source: Source) : Publication
    }

    private class Retirements {
        val targets = linkedSetOf<NativePlaylistProfileGateway.Target>()
        val receiptOwners = linkedSetOf<NativePlaylistProfileGateway.ReceiptOwner>()
    }

    /** Serializes the synchronous authority cut with final CAS publication and explicit draft discard. */
    private val authorityFence = Any()
    /** Lock-free queue-admission stamp; never calls Session/lifecycle code under a consumer lock. */
    private val authorityCut = AtomicLong(0L)
    private val monitor = Any()
    private val utilityLane = Mutex()
    private val _changes = MutableStateFlow(0L)
    /** Data-free invalidation only. Content must be obtained through an exact-owner query. */
    val changes: StateFlow<Long> = _changes.asStateFlow()
    private var publication: Publication = Publication.Loading
    private var loadGeneration = 0L
    private var writeGeneration = 0L
    private var authorityEpoch = 0L
    private var receiptRefreshGeneration = 0L
    private var loadJob: Job? = null
    private var sourceHints: Job? = null
    private var receiptHints: Job? = null
    private var receiptRefreshJob: Job? = null
    private var closed = false
    private val drafts = linkedMapOf<DraftKey, Draft>()
    private val activeWrites = mutableSetOf<DraftKey>()
    private val receiptByField = linkedMapOf<Pair<Partition, String>, ReceiptBinding>()
    private var retainedDraftBytes = 0

    init {
        sourceHints = scope.launch(io) {
            gateway.playlistChanges.conflate().collect { requestReload() }
        }
        receiptHints = scope.launch(io) {
            gateway.playlistReceiptChanges.conflate().collect { requestReceiptRefresh() }
        }
        requestReload()
    }

    /**
     * Synchronous data-free cut for the coordinator's general native revision callback. It revokes
     * write/projection work but deliberately preserves bounded read-only receipt bindings across a
     * same-profile merge. Native retirement is queued on [io]; the Session's following playlist
     * signal drives the reload and original receipt-owner probe.
     */
    fun nativeProjectionWillChange() {
        cutAuthority(purgeReceipts = false)
    }

    /**
     * Synchronous true account/profile/credential retirement. Unlike [nativeProjectionWillChange],
     * this advances the scope epoch and purges every held receipt capability. It performs no native
     * call while a producer callback or profile-transition lock may be held.
     */
    fun invalidateAuthority() {
        cutAuthority(purgeReceipts = true)
    }

    private fun cutAuthority(purgeReceipts: Boolean) {
        val retirements = Retirements()
        val cancelled: List<Job>
        synchronized(authorityFence) {
            authorityCut.updateAndGet { Math.incrementExact(it) }
            authorityRaceTestHook?.afterAuthorityCutBeforeConsumerMonitor()
            synchronized(monitor) {
                loadGeneration = Math.incrementExact(loadGeneration)
                if (purgeReceipts) authorityEpoch = Math.incrementExact(authorityEpoch)
                receiptRefreshGeneration = Math.incrementExact(receiptRefreshGeneration)
                cancelled = listOfNotNull(loadJob, receiptRefreshJob)
                loadJob = null
                receiptRefreshJob = null
                val authorities = buildSet {
                    (publication as? Publication.Ready)?.source?.authority?.let(::add)
                    drafts.values.forEach { draft ->
                        if (draft.ownsWriteAuthority) draft.authority?.let(::add)
                    }
                }
                authorities.forEach { authority ->
                    if (purgeReceipts) forceRetireLocked(authority, retirements)
                    else forceRetireTargetLocked(authority, retirements)
                }
                replacePublicationLocked(Publication.Loading, retirements)
                drafts.values.forEach { releaseDraftAuthoritiesLocked(it, keepReceipt = false, retirements) }
                if (purgeReceipts) {
                    receiptByField.values.forEach { releaseBindingLocked(it, retirements) }
                    receiptByField.clear()
                }
                signalLocked()
            }
        }
        cancelled.forEach(Job::cancel)
        scheduleRetirements(retirements)
    }

    fun requestReload() {
        val ticket: Long
        val previous: Job?
        synchronized(monitor) {
            if (closed) return
            ticket = Math.incrementExact(loadGeneration)
            loadGeneration = ticket
            previous = loadJob
            loadJob = null
        }
        previous?.cancel()
        val job = scope.launch(io) { load(ticket) }
        synchronized(monitor) {
            if (!closed && loadGeneration == ticket) loadJob = job else job.cancel()
        }
    }

    private fun requestReceiptRefresh() {
        val ticket: Long
        val previous: Job?
        synchronized(monitor) {
            if (closed) return
            ticket = Math.incrementExact(receiptRefreshGeneration)
            receiptRefreshGeneration = ticket
            previous = receiptRefreshJob
            receiptRefreshJob = null
        }
        previous?.cancel()
        val job = scope.launch(io) { refreshReceiptStates(ticket) }
        synchronized(monitor) {
            if (!closed && receiptRefreshGeneration == ticket) receiptRefreshJob = job else job.cancel()
        }
    }

    private suspend fun refreshReceiptStates(ticket: Long) {
        withContext(io) {
            utilityLane.withLock {
                currentCoroutineContext().ensureActive()
                val candidates = synchronized(monitor) {
                    if (closed || receiptRefreshGeneration != ticket) return@withLock
                    receiptByField.values.mapNotNull { binding ->
                        val authority = binding.receiptAuthority
                        val receipt = binding.ticket
                        if (authority == null || receipt == null) null else Triple(binding, authority, receipt)
                    }
                }
                val states = candidates.map { (binding, authority, receipt) ->
                    binding to gateway.playlistReceiptState(authority.owner, receipt, binding.fingerprint)
                }
                val retirements = Retirements()
                synchronized(monitor) {
                    if (closed || receiptRefreshGeneration != ticket) return@withLock
                    var changed = false
                    states.forEach { (candidate, state) ->
                        val key = candidate.partition to candidate.field
                        if (receiptByField[key] !== candidate || candidate.state == state) return@forEach
                        candidate.state = state
                        changed = true
                        if (state !is NativePlaylistCloudReceiptLedger.State.Pending) {
                            releaseBindingAuthorityLocked(candidate, retirements)
                        }
                    }
                    if (changed) signalLocked()
                }
                performRetirements(retirements)
            }
        }
    }

    fun loadError(owner: ContinueWatchingOwner): String? {
        if (ownerNow() != owner) return null
        val message = synchronized(monitor) { (publication as? Publication.Failed)?.message }
        return message?.takeIf { ownerNow() == owner }
    }

    /** Must be called off Main: current-target certification enters the native Session. */
    fun catalog(owner: ContinueWatchingOwner): SavedPlaylistCatalog? {
        return certifiedRead(owner) { source ->
            val sourceObservation = sourceCertificate(source)
            val receipts = synchronized(monitor) { receiptByField.toMap() }
            val rows = source.records.values.asSequence().mapNotNull { record ->
                val handle = SavedPlaylistHandle(
                    record.field,
                    PlaylistObservation(sourceObservation, record),
                )
                when (val projection = record.projection) {
                    NativePlaylist.Projection.Deleted -> null
                    is NativePlaylist.Projection.Supported -> SavedPlaylistSummary(
                        handle, projection.document.name,
                        projection.document.entries.size, editable = true,
                        status = status(source, record, receipts),
                    )
                    NativePlaylist.Projection.Unsupported -> SavedPlaylistSummary(
                        handle, "Newer playlist", entryCount = null,
                        editable = false, status = status(source, record, receipts),
                    )
                }
            }.sortedWith(compareBy<SavedPlaylistSummary>({ it.name.lowercase() }, { it.handle.field })).toList()
            val deletions = receipts.values.filter { binding ->
                binding.partition == source.partition && binding.deleting &&
                    source.records[binding.field]?.fingerprint == binding.fingerprint
            }
            SavedPlaylistCatalog(
                SavedPlaylistCollectionHandle(CollectionObservation(sourceObservation)),
                rows,
                pendingDeletionCount = deletions.count { it.state is NativePlaylistCloudReceiptLedger.State.Pending },
                unknownDeletionCount = deletions.count { it.state is NativePlaylistCloudReceiptLedger.State.Unknown },
            )
        }
    }

    /** Returns no content unless the supplied complete queue owner and original target are current. */
    fun detail(owner: ContinueWatchingOwner, handle: SavedPlaylistHandle): SavedPlaylistDetail? {
        val observation = handle.opaque as? PlaylistObservation ?: return null
        return certifiedRead(owner) { source ->
            if (!playlistObservationCurrent(source, observation)) return@certifiedRead null
            val record = observation.record
            val receipts = synchronized(monitor) { receiptByField.toMap() }
            val status = status(source, record, receipts)
            when (val projection = record.projection) {
                NativePlaylist.Projection.Deleted -> null
                NativePlaylist.Projection.Unsupported -> SavedPlaylistDetail.ReadOnlyFuture(handle, status)
                is NativePlaylist.Projection.Supported -> SavedPlaylistDetail.Supported(
                    handle, status, projection.document.name, projection.document.entries.map(::entryView),
                )
            }
        }
    }

    /** Explicit local-draft access. Stable account/profile match is required; no draft is rebound. */
    fun drafts(owner: ContinueWatchingOwner): SavedPlaylistDraftCatalog? {
        if (ownerNow() != owner) return null
        val partition = partition(owner) ?: return null
        val result = synchronized(monitor) {
            val rows = drafts.values.asSequence().filter { it.key.partition == partition }.map { draft ->
                val document = draftDocument(draft)
                val observation = draftObservation(draft)
                SavedPlaylistDraftSummary(
                    SavedPlaylistDraftHandle(draft.editID, observation),
                    SavedPlaylistHandle(draft.key.field, DraftPlaylistObservation(draft.key.field)),
                    document?.name ?: "Deleted playlist", draft.value === JSONObject.NULL,
                    stale = draft.authorityEpoch != authorityEpoch || !draft.ownsWriteAuthority ||
                        draft.authority == null,
                    retainedBytes = draft.retainedBytes,
                )
            }.sortedBy { it.handle.editID }.toList()
            SavedPlaylistDraftCatalog(rows, rows.sumOf(SavedPlaylistDraftSummary::retainedBytes), MAX_RETAINED_DRAFT_BYTES)
        }
        return result.takeIf { ownerNow() == owner }
    }

    fun draft(owner: ContinueWatchingOwner, handle: SavedPlaylistDraftHandle): SavedPlaylistDraftView? {
        if (ownerNow() != owner) return null
        val partition = partition(owner) ?: return null
        val observation = handle.opaque as? DraftObservation ?: return null
        if (observation.key.partition != partition || observation.editID != handle.editID) return null
        val currentSource = certifiedSource(owner)?.takeIf { it.partition == partition }
        val result = synchronized(monitor) {
            val draft = observedDraftLocked(observation) ?: return@synchronized null
            val document = draftDocument(draft)
            val sourceCertificate = currentSource?.takeIf(::sourceCertificateCurrentLocked)?.let(::sourceCertificate)
            val copyHandle = if (draft.value !== JSONObject.NULL && document != null && sourceCertificate != null &&
                !activeWrites.contains(draft.key)
            ) {
                SavedPlaylistDraftCopyHandle(DraftCopyObservation(observation, sourceCertificate))
            } else null
            SavedPlaylistDraftView(
                handle,
                SavedPlaylistHandle(draft.key.field, DraftPlaylistObservation(draft.key.field)),
                copyHandle,
                document?.name ?: "Deleted playlist",
                document?.entries?.map(::entryView).orEmpty(), deleting = draft.value === JSONObject.NULL,
                stale = draft.authorityEpoch != authorityEpoch || !draft.ownsWriteAuthority ||
                    draft.authority == null,
            )
        }
        return result?.takeIf { ownerNow() == owner }
    }

    /** Stable same-account/profile users may explicitly discard stale read-only drafts. */
    fun discardDraft(owner: ContinueWatchingOwner, handle: SavedPlaylistDraftHandle): Boolean {
        val observedCut = authorityCut.get()
        if (ownerNow() != owner) return false
        val partition = partition(owner) ?: return false
        val observation = handle.opaque as? DraftObservation ?: return false
        if (observation.key.partition != partition || observation.editID != handle.editID) return false
        val retirements = Retirements()
        synchronized(authorityFence) {
            synchronized(monitor) {
                if (authorityCut.get() != observedCut) return false
                val candidate = observedDraftLocked(observation) ?: return false
                if (activeWrites.contains(candidate.key)) return false
                drafts.remove(candidate.key)
                retainedDraftBytes -= candidate.retainedBytes
                releaseDraftAuthoritiesLocked(candidate, keepReceipt = false, retirements)
                signalLocked()
            }
        }
        scheduleRetirements(retirements)
        return true
    }

    /**
     * Bounded gesture capture: pure source checks plus one immutable queue-state observation; no
     * gateway, Session, persistence, JSON, current-owner closure, or external callback.
     */
    fun captureCreateFromQueue(
        owner: ContinueWatchingOwner,
        collection: SavedPlaylistCollectionHandle,
        name: String,
    ): WriteIntent? {
        val observation = collection.opaque as? CollectionObservation ?: return null
        val boundedName = capturedName(name) ?: return null
        if (observation.source.owner != owner || !sourceObservationCurrent(observation.source)) return null
        val queueObservation = captureQueueObservation(owner) ?: return null
        return WriteIntent(WriteRequest.Create(owner, canonicalUUID(), observation, queueObservation, boundedName))
    }

    fun captureReplaceFromQueue(
        owner: ContinueWatchingOwner,
        handle: SavedPlaylistHandle,
        name: String? = null,
    ): WriteIntent? {
        val observation = capturedPlaylist(owner, handle) ?: return null
        val boundedName = if (name == null) null else capturedName(name) ?: return null
        if (observation.record.projection !is NativePlaylist.Projection.Supported) return null
        val queueObservation = captureQueueObservation(owner) ?: return null
        return WriteIntent(WriteRequest.Replace(owner, canonicalUUID(), observation, queueObservation, boundedName))
    }

    /**
     * Reads only the queue's immutable StateFlow value. Catalog detachment is bounded by the queue's
     * existing 100-entry invariant and invokes no owner closure, persistence, JSON, or native code.
     */
    private fun captureQueueObservation(owner: ContinueWatchingOwner): QueueObservation? {
        val state = queue.state.value
        if (!state.ready || state.owner != owner) return null
        val items = try {
            state.entries.map { PlaybackQueueModel.catalogOnly(it.item) }
        } catch (_: Exception) {
            return null
        }
        return QueueObservation(owner, state.revision, items)
    }

    /** Certifies the exact observed queue generation and never substitutes newer queue contents. */
    private fun queueItemsIfCurrent(observed: QueueObservation): List<MetaItem>? {
        val current = queue.state.value
        return observed.items.takeIf {
            current.ready && current.owner == observed.owner && current.revision == observed.revision
        }
    }

    fun captureRename(owner: ContinueWatchingOwner, handle: SavedPlaylistHandle, name: String): WriteIntent? {
        val observation = capturedPlaylist(owner, handle) ?: return null
        val boundedName = capturedName(name) ?: return null
        if (observation.record.projection !is NativePlaylist.Projection.Supported) return null
        return WriteIntent(WriteRequest.Rename(owner, canonicalUUID(), observation, boundedName))
    }

    fun captureDelete(owner: ContinueWatchingOwner, handle: SavedPlaylistHandle): WriteIntent? {
        val observation = capturedPlaylist(owner, handle) ?: return null
        if (observation.record.projection !is NativePlaylist.Projection.Supported) return null
        return WriteIntent(WriteRequest.Delete(owner, canonicalUUID(), observation))
    }

    /** Explicit conflict resolution only: the retained draft is copied under a fresh playlist ID. */
    fun captureDraftAsCopy(
        owner: ContinueWatchingOwner,
        handle: SavedPlaylistDraftCopyHandle,
        name: String? = null,
    ): WriteIntent? {
        val observation = handle.opaque as? DraftCopyObservation ?: return null
        val boundedName = if (name == null) null else capturedName(name) ?: return null
        if (observation.source.owner != owner || !sourceObservationCurrent(observation.source)) return null
        val draftCurrent = synchronized(monitor) {
            observedDraftLocked(observation.draft)?.let { !activeWrites.contains(it.key) } == true
        }
        if (!draftCurrent) return null
        return WriteIntent(WriteRequest.CopyDraft(owner, canonicalUUID(), observation, boundedName))
    }

    suspend fun commit(intent: WriteIntent): SavedPlaylistWriteResult {
        val request = intent.opaque as? WriteRequest ?: return SavedPlaylistWriteResult.Superseded
        return withContext(io) {
            utilityLane.withLock {
                currentCoroutineContext().ensureActive()
                val token = prepareWrite(request) ?: return@withLock SavedPlaylistWriteResult.Superseded
                commitStaged(token)
            }
        }
    }

    private fun prepareWrite(request: WriteRequest): WriteToken? {
        return when (request) {
            is WriteRequest.Create -> {
                val source = certifyObservedSource(request.owner, request.collection.source) ?: return null
                val queueItems = queueItemsIfCurrent(request.queue) ?: return null
                val id = canonicalUUID()
                val document = documentFromQueue(id, request.name, queueItems) ?: return null
                stage(source, NativePlaylist.field(UUID.fromString(id)), expected = null,
                    value = NativePlaylist.encodedValue(document), editID = request.editID)
            }
            is WriteRequest.Replace -> {
                val source = certifyObservedPlaylist(request.owner, request.playlist) ?: return null
                val current = supported(request.playlist) ?: return null
                val queueItems = queueItemsIfCurrent(request.queue) ?: return null
                val document = documentFromQueue(
                    current.document.id, request.name ?: current.document.name, queueItems,
                ) ?: return null
                stage(source, request.playlist.record.field, current.register,
                    NativePlaylist.encodedValue(document), editID = request.editID)
            }
            is WriteRequest.Rename -> {
                val source = certifyObservedPlaylist(request.owner, request.playlist) ?: return null
                val current = supported(request.playlist) ?: return null
                val value = encodedOrNull(current.document.copy(name = request.name)) ?: return null
                stage(source, request.playlist.record.field, current.register, value, editID = request.editID)
            }
            is WriteRequest.Delete -> {
                val source = certifyObservedPlaylist(request.owner, request.playlist) ?: return null
                val current = supported(request.playlist) ?: return null
                stage(source, request.playlist.record.field, current.register, JSONObject.NULL,
                    editID = request.editID)
            }
            is WriteRequest.CopyDraft -> {
                val source = certifyObservedSource(request.owner, request.copy.source) ?: return null
                val retained = synchronized(monitor) {
                    observedDraftLocked(request.copy.draft)?.takeIf {
                        it.key.partition == source.partition && !activeWrites.contains(it.key)
                    }
                } ?: return null
                val original = draftDocument(retained) ?: return null
                val id = canonicalUUID()
                val copied = original.copy(
                    id = id,
                    name = request.name ?: original.name,
                    entries = original.entries.map { it.copy(entryID = canonicalUUID()) },
                )
                val field = NativePlaylist.field(UUID.fromString(id))
                val value = encodedOrNull(copied) ?: return null
                stage(source, field, expected = null, value = value, editID = request.editID,
                    removeOnSuccess = mapOf(retained.key to retained.editID))
            }
        }
    }

    private suspend fun commitStaged(token: WriteToken): SavedPlaylistWriteResult {
        val prepared = synchronized(monitor) {
            val current = drafts[token.key]
            val authority = current?.authority
            if (closed || current?.editID != token.editID || authority == null ||
                !current.ownsWriteAuthority || !activeWrites.add(token.key)
            ) null else current to authority
        } ?: return SavedPlaylistWriteResult.Superseded
        val (draft, authority) = prepared
        return try {
            currentCoroutineContext().ensureActive()
            if (!writeTargetCurrent(draft, authority, token)) return SavedPlaylistWriteResult.Superseded
            val acknowledged = gateway.compareAndSetPlaylistField(
                authority.target, draft.editID, draft.key.field,
                clone(draft.expectedRegister), cloneValue(draft.value),
            ).getOrElse {
                rethrowFatal(it)
                requestReload()
                return SavedPlaylistWriteResult.DraftRetained
            }
            val register = acknowledged.registers.optJSONObject(draft.key.field)
            if (acknowledged.target !== authority.target || register == null ||
                !NativeHostPreferences.equal(register.opt("value"), draft.value)
            ) {
                requestReload()
                return SavedPlaylistWriteResult.DraftRetained
            }
            val fingerprint = NativePlaylist.canonicalReceiptRegister(register)
                ?.let(NativePlaylistCloudReceiptLedger.Fingerprint::of)
                ?: return SavedPlaylistWriteResult.DraftRetained
            val ticket = acknowledged.receipt?.takeIf {
                it.id.toString() == draft.editID && it.field == draft.key.field && it.fingerprint == fingerprint
            }
            val retirements = Retirements()
            var producerAdmission = false
            val published = gateway.publishPlaylistIfCurrent(acknowledged) {
                synchronized(monitor) {
                    producerAdmission = authorityCut.get() == token.authorityCut &&
                        writeCompletionCurrentLocked(draft, authority, token)
                }
            }
            if (!published || !producerAdmission || ownerNow() != draft.key.owner) {
                return SavedPlaylistWriteResult.Superseded
            }
            var status: SavedPlaylistStatus? = null
            synchronized(authorityFence) {
                synchronized(monitor) {
                    if (authorityCut.get() == token.authorityCut &&
                        writeCompletionCurrentLocked(draft, authority, token)
                    ) {
                        status = acceptLocalWriteLocked(
                            draft, authority, token, acknowledged, fingerprint, ticket, retirements,
                        )
                    }
                }
            }
            performRetirements(retirements)
            val acceptedStatus = status ?: return SavedPlaylistWriteResult.Superseded
            requestReload()
            if (ticket != null) requestReceiptRefresh()
            SavedPlaylistWriteResult.Accepted(draft.editID, acceptedStatus)
        } finally {
            val retirements = Retirements()
            synchronized(authorityFence) {
                synchronized(monitor) {
                    activeWrites.remove(token.key)
                    if (drafts[token.key] === draft) {
                        releaseDraftAuthoritiesLocked(draft, keepReceipt = false, retirements)
                        signalLocked()
                    }
                }
            }
            performRetirements(retirements)
        }
    }

    fun captureImport(owner: ContinueWatchingOwner, handle: SavedPlaylistHandle): ImportIntent? {
        val observation = capturedPlaylist(owner, handle) ?: return null
        if (observation.record.projection !is NativePlaylist.Projection.Supported) return null
        return ImportIntent(ImportRequest(owner, observation))
    }

    /** One queue append, one local persistence intent, no playback or route side effect. */
    suspend fun importIntoQueue(intent: ImportIntent): SavedPlaylistImportResult {
        val request = intent.opaque as? ImportRequest ?: return SavedPlaylistImportResult.SUPERSEDED
        return withContext(io) {
            utilityLane.withLock {
                currentCoroutineContext().ensureActive()
                val source = certifyObservedPlaylist(request.owner, request.playlist)
                    ?: return@withLock SavedPlaylistImportResult.SUPERSEDED
                val currentDocument = supported(request.playlist)?.document
                    ?: return@withLock SavedPlaylistImportResult.SUPERSEDED
                val candidates = ArrayList<MetaItem>(currentDocument.entries.size)
                for (entry in currentDocument.entries) {
                    candidates += queueCandidate(entry)
                        ?: return@withLock SavedPlaylistImportResult.SUPERSEDED
                }
                if (candidates.isEmpty()) return@withLock SavedPlaylistImportResult.REJECTED
                val expectedRegister = clone(request.playlist.record.register)
                    ?: return@withLock SavedPlaylistImportResult.SUPERSEDED
                val token = withIntentCertificate(source) {
                    ImportToken(
                        source.identity, source.generation, source.authorityEpoch, source.authorityCut, source.partition,
                        request.owner, source.authority.target, request.playlist.record.field,
                        expectedRegister, candidates,
                    )
                } ?: return@withLock SavedPlaylistImportResult.SUPERSEDED
                val sourceMatches = synchronized(monitor) {
                    val publishedSource = (publication as? Publication.Ready)?.source
                    !closed && publishedSource != null && authorityCut.get() == token.authorityCut &&
                        authorityEpoch == token.authorityEpoch &&
                        publishedSource.identity === token.sourceIdentity &&
                        publishedSource.authorityCut == token.authorityCut &&
                        publishedSource.authorityEpoch == token.authorityEpoch &&
                        publishedSource.generation == token.sourceGeneration &&
                        publishedSource.partition == token.partition && publishedSource.owner == token.owner &&
                        publishedSource.authority.target === token.target
                }
                if (!sourceMatches) return@withLock SavedPlaylistImportResult.SUPERSEDED
                if (ownerNow() != token.owner || !gateway.playlistTargetIsCurrent(token.target)) {
                    return@withLock SavedPlaylistImportResult.SUPERSEDED
                }
                val refreshed = gateway.playlistSnapshot(token.target).getOrElse {
                    rethrowFatal(it)
                    return@withLock SavedPlaylistImportResult.SUPERSEDED
                }
                val current = refreshed.registers.optJSONObject(token.field)
                if (refreshed.target !== token.target || current == null ||
                    !NativeHostPreferences.equal(current, token.expectedRegister) || ownerNow() != token.owner
                ) return@withLock SavedPlaylistImportResult.SUPERSEDED
                var publishedSource: Source? = null
                val published = gateway.publishPlaylistIfCurrent(refreshed) {
                    synchronized(monitor) {
                        if (authorityCut.get() == token.authorityCut && importCompletionCurrentLocked(token)) {
                            publishedSource = (publication as Publication.Ready).source
                        }
                    }
                }
                val admittedSource = publishedSource
                if (!published || admittedSource == null || ownerNow() != token.owner) {
                    return@withLock SavedPlaylistImportResult.SUPERSEDED
                }
                val consumerCurrent = synchronized(monitor) {
                    authorityCut.get() == token.authorityCut &&
                        (publication as? Publication.Ready)?.source === admittedSource &&
                        importCompletionCurrentLocked(token)
                }
                if (!consumerCurrent || ownerNow() != token.owner) {
                    return@withLock SavedPlaylistImportResult.SUPERSEDED
                }
                if (queue.appendCandidatesIfCurrent(token.owner, token.candidates) {
                        authorityCut.get() == token.authorityCut
                    }
                ) {
                    SavedPlaylistImportResult.LOCAL_QUEUE_WRITE_ADMITTED
                } else {
                    SavedPlaylistImportResult.REJECTED
                }
            }
        }
    }

    private suspend fun load(ticket: Long) {
        try {
            withContext(io) {
                utilityLane.withLock {
                    currentCoroutineContext().ensureActive()
                    if (!loadTicketCurrent(ticket)) return@withLock
                    val owner = ownerNow() ?: return@withLock failLoad(ticket, "Choose a signed-in profile")
                    val snapshot = gateway.capturePlaylistProfile().getOrElse {
                        rethrowFatal(it)
                        return@withLock failLoad(ticket, "Saved playlists are unavailable for this profile")
                    }
                    val partition = partition(snapshot.target, owner)
                    if (partition == null || ownerNow() != owner || !loadTicketCurrent(ticket)) {
                        gateway.retirePlaylistTarget(snapshot.target)
                        gateway.retirePlaylistReceiptOwner(snapshot.target.receiptOwner)
                        return@withLock failLoad(ticket, "Saved playlists are unavailable for this profile")
                    }
                    val certificate = captureLoadCertificate(ticket)
                    if (certificate == null) {
                        gateway.retirePlaylistTarget(snapshot.target)
                        gateway.retirePlaylistReceiptOwner(snapshot.target.receiptOwner)
                        return@withLock
                    }
                    val authority = Authority(snapshot.target, ReceiptAuthority(snapshot.target.receiptOwner))
                    val registers = JSONObject(snapshot.registers.toString())
                    val source = Source(
                        Any(), ticket, certificate.authorityEpoch, certificate.authorityCut, partition, owner,
                        authority, snapshot, registers, project(registers),
                    )
                    val retirements = Retirements()
                    var published = false
                    val admitted = gateway.publishPlaylistIfCurrent(snapshot) {
                        synchronized(monitor) {
                            if (!closed && loadGeneration == ticket &&
                                authorityEpoch == certificate.authorityEpoch &&
                                authorityCut.get() == certificate.authorityCut
                            ) {
                                reconcileReceiptsLocked(source, retirements)
                                replacePublicationLocked(Publication.Ready(source), retirements)
                                signalLocked()
                                published = true
                            }
                        }
                    }
                    if (!admitted || !published || ownerNow() != owner) {
                        if (published) {
                            invalidatePublishedSource(source)
                        } else {
                            gateway.retirePlaylistTarget(snapshot.target)
                            gateway.retirePlaylistReceiptOwner(snapshot.target.receiptOwner)
                        }
                    }
                    performRetirements(retirements)
                    if (published) requestReceiptRefresh()
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: LinkageError) {
            failLoad(ticket, "Saved playlists are unavailable on this app version")
        } catch (_: Exception) {
            failLoad(ticket, "Saved playlists could not be loaded")
        }
    }

    private fun failLoad(ticket: Long, message: String) {
        val retirements = Retirements()
        synchronized(monitor) {
            if (closed || loadGeneration != ticket) return
            replacePublicationLocked(Publication.Failed(message), retirements)
            signalLocked()
        }
        performRetirements(retirements)
    }

    private fun invalidatePublishedSource(source: Source) {
        val retirements = Retirements()
        synchronized(monitor) {
            val current = publication as? Publication.Ready
            if (current?.source !== source) return
            replacePublicationLocked(Publication.Loading, retirements)
            signalLocked()
        }
        performRetirements(retirements)
    }

    private fun certifiedSource(owner: ContinueWatchingOwner): Source? {
        return certifiedRead(owner) { it }
    }

    private fun captureLoadCertificate(ticket: Long): ConsumerCertificate? =
        synchronized(authorityFence) {
            synchronized(monitor) {
                if (closed || loadGeneration != ticket) null
                else ConsumerCertificate(authorityEpoch, authorityCut.get())
            }
        }

    /** Caller holds [monitor]. No producer, owner, queue, or lifecycle call is permitted here. */
    private fun sourceCertificateCurrentLocked(source: Source): Boolean =
        !closed && authorityEpoch == source.authorityEpoch && authorityCut.get() == source.authorityCut &&
            !source.authority.retired && (publication as? Publication.Ready)?.source === source

    private fun sourceCertificateCurrent(source: Source): Boolean =
        synchronized(authorityFence) { synchronized(monitor) { sourceCertificateCurrentLocked(source) } }

    private fun sourceCertificate(source: Source) = SourceCertificate(
        source.identity,
        source.generation,
        source.authorityEpoch,
        source.authorityCut,
        source.partition,
        source.owner,
    )

    /** Caller holds [monitor]. Observations contain no gateway authority. */
    private fun sourceObservationCurrentLocked(source: Source, observed: SourceCertificate): Boolean =
        source.identity === observed.identity && source.generation == observed.generation &&
            source.authorityEpoch == observed.authorityEpoch && source.authorityCut == observed.authorityCut &&
            source.partition == observed.partition && source.owner == observed.owner &&
            sourceCertificateCurrentLocked(source)

    private fun sourceObservationCurrent(observed: SourceCertificate): Boolean = synchronized(monitor) {
        val source = (publication as? Publication.Ready)?.source ?: return@synchronized false
        sourceObservationCurrentLocked(source, observed)
    }

    private fun playlistObservationCurrent(source: Source, observed: PlaylistObservation): Boolean =
        sourceObservationCurrentLocked(source, observed.source) &&
            source.records[observed.record.field] === observed.record

    /** Pure local capture check. It deliberately never calls ownerNow or the gateway. */
    private fun capturedPlaylist(owner: ContinueWatchingOwner, handle: SavedPlaylistHandle): PlaylistObservation? {
        val observation = handle.opaque as? PlaylistObservation ?: return null
        if (handle.field != observation.record.field || observation.source.owner != owner) return null
        return synchronized(monitor) {
            val source = (publication as? Publication.Ready)?.source
            observation.takeIf { source != null && playlistObservationCurrent(source, observation) }
        }
    }

    private fun certifyObservedSource(owner: ContinueWatchingOwner, observed: SourceCertificate): Source? {
        if (observed.owner != owner || ownerNow() != owner) return null
        val source = synchronized(monitor) {
            (publication as? Publication.Ready)?.source?.takeIf {
                sourceObservationCurrentLocked(it, observed)
            }
        } ?: return null
        var admitted = false
        val published = gateway.publishPlaylistIfCurrent(source.snapshot) {
            synchronized(monitor) {
                admitted = sourceObservationCurrentLocked(source, observed)
            }
        }
        if (!published || !admitted || !sourceCertificateCurrent(source) || ownerNow() != owner) return null
        return source
    }

    private fun certifyObservedPlaylist(owner: ContinueWatchingOwner, observed: PlaylistObservation): Source? {
        val source = certifyObservedSource(owner, observed.source) ?: return null
        return synchronized(monitor) {
            source.takeIf { playlistObservationCurrent(source, observed) }
        }
    }

    private fun <T> withIntentCertificate(source: Source, body: () -> T?): T? {
        authorityRaceTestHook?.let { hook ->
            synchronized(monitor) { hook.beforeIntentCertificateWhileHoldingConsumerMonitor() }
        }
        return synchronized(authorityFence) {
            synchronized(monitor) {
                if (!sourceCertificateCurrentLocked(source)) null else body()
            }
        }
    }

    private fun <T> certifiedRead(owner: ContinueWatchingOwner, body: (Source) -> T): T? {
        if (ownerNow() != owner) return null
        val source = synchronized(monitor) {
            (publication as? Publication.Ready)?.source?.takeIf {
                it.owner == owner && sourceCertificateCurrentLocked(it)
            }
        } ?: return null
        var produced = false
        var result: T? = null
        val admitted = gateway.publishPlaylistIfCurrent(source.snapshot) {
            synchronized(monitor) {
                if (sourceCertificateCurrentLocked(source)) {
                    result = body(source)
                    produced = true
                }
            }
        }
        val consumerCurrent = admitted && produced && sourceCertificateCurrent(source)
        return result.takeIf { consumerCurrent && ownerNow() == owner }
    }

    private data class SupportedRecord(
        val register: JSONObject,
        val document: NativePlaylist.Document,
    )

    private fun supported(observed: PlaylistObservation): SupportedRecord? {
        val document = (observed.record.projection as? NativePlaylist.Projection.Supported)?.document ?: return null
        return SupportedRecord(clone(observed.record.register)!!, document)
    }

    private fun draftObservation(draft: Draft) = DraftObservation(draft.key, draft.editID, draft.writeGeneration)

    /** Caller holds [monitor]. */
    private fun observedDraftLocked(observed: DraftObservation): Draft? = drafts[observed.key]?.takeIf {
        it.editID == observed.editID && it.writeGeneration == observed.writeGeneration
    }

    private fun stage(
        source: Source,
        field: String,
        expected: JSONObject?,
        value: Any,
        editID: String,
        removeOnSuccess: Map<DraftKey, String> = emptyMap(),
    ): WriteToken? {
        if (ownerNow() != source.owner || !gateway.playlistTargetIsCurrent(source.authority.target)) return null
        val detachedExpected = clone(expected)
        val detachedValue = cloneValue(value)
        try {
            NativePlaylist.validateMutation(field, detachedExpected, detachedValue, source.registers)
        } catch (_: Exception) {
            return null
        }
        val retainedBytes = draftPayloadBytes(field, detachedExpected, detachedValue) ?: return null
        val key = DraftKey(source.partition, source.owner, field)
        return withIntentCertificate(source) intent@{
            if (activeWrites.contains(key) || drafts.containsKey(key)) return@intent null
            if (removeOnSuccess.any { (removeKey, removeEditID) ->
                    activeWrites.contains(removeKey) || drafts[removeKey]?.editID != removeEditID
                }
            ) return@intent null
            if (drafts.size >= MAX_RETAINED_DRAFTS) return@intent null
            if (retainedBytes > MAX_RETAINED_DRAFT_BYTES - retainedDraftBytes) return@intent null
            source.authority.references = Math.incrementExact(source.authority.references)
            source.authority.receiptAuthority.references =
                Math.incrementExact(source.authority.receiptAuthority.references)
            writeGeneration = Math.incrementExact(writeGeneration)
            val stagedGeneration = writeGeneration
            drafts[key] = Draft(key, editID, stagedGeneration, source.authorityEpoch, source.authority, detachedExpected,
                detachedValue, removeOnSuccess + (key to editID), retainedBytes)
            retainedDraftBytes = Math.addExact(retainedDraftBytes, retainedBytes)
            signalLocked()
            WriteToken(
                key, editID, source.identity, source.generation, stagedGeneration,
                source.authorityEpoch, source.authorityCut,
            )
        }
    }

    private fun writeTargetCurrent(draft: Draft, authority: Authority, token: WriteToken): Boolean {
        if (authorityCut.get() != token.authorityCut || ownerNow() != draft.key.owner ||
            !gateway.playlistTargetIsCurrent(authority.target)
        ) return false
        return synchronized(monitor) {
            !closed && authorityCut.get() == token.authorityCut && authorityEpoch == token.authorityEpoch &&
                drafts[token.key]?.let {
                it.editID == token.editID && it.writeGeneration == token.writeGeneration &&
                    it.authority === authority && it.ownsWriteAuthority
            } == true && activeWrites.contains(token.key)
        } && authorityCut.get() == token.authorityCut && ownerNow() == draft.key.owner
    }

    private fun writeCompletionCurrentLocked(draft: Draft, authority: Authority, token: WriteToken): Boolean =
        !closed && authorityEpoch == token.authorityEpoch && drafts[token.key]?.let {
            it === draft && it.editID == token.editID && it.writeGeneration == token.writeGeneration &&
                it.authority === authority && it.ownsWriteAuthority
        } == true && activeWrites.contains(token.key)

    private fun importCompletionCurrentLocked(token: ImportToken): Boolean {
        val source = (publication as? Publication.Ready)?.source ?: return false
        val observed = source.records[token.field]?.register ?: return false
        return !closed && authorityCut.get() == token.authorityCut &&
            authorityEpoch == token.authorityEpoch && source.identity === token.sourceIdentity &&
            source.generation == token.sourceGeneration &&
            source.authorityCut == token.authorityCut && source.authorityEpoch == token.authorityEpoch &&
            source.partition == token.partition && source.owner == token.owner &&
            source.authority.target === token.target && NativeHostPreferences.equal(observed, token.expectedRegister)
    }

    private fun acceptLocalWriteLocked(
        draft: Draft,
        authority: Authority,
        token: WriteToken,
        acknowledged: NativePlaylistProfileGateway.Snapshot,
        fingerprint: NativePlaylistCloudReceiptLedger.Fingerprint,
        ticket: NativePlaylistCloudReceiptLedger.Ticket?,
        retirements: Retirements,
    ): SavedPlaylistStatus {
        val key = draft.key.partition to draft.key.field
        receiptByField.remove(key)?.let { releaseBindingLocked(it, retirements) }
        val initialState = if (ticket == null) NativePlaylistCloudReceiptLedger.State.Unknown
            else NativePlaylistCloudReceiptLedger.State.Pending
        val binding = ReceiptBinding(
            draft.key.partition, draft.key.field, draft.editID, fingerprint,
            draft.value === JSONObject.NULL, initialState,
            receiptAuthority = if (ticket == null) null else authority.receiptAuthority,
            ticket = ticket,
        )
        if (ticket != null) draft.ownsReceiptAuthority = false // transfer this draft's reference
        receiptByField[key] = binding
        while (receiptByField.size > MAX_RECEIPT_BINDINGS) {
            val oldest = receiptByField.keys.first()
            receiptByField.remove(oldest)?.let { releaseBindingLocked(it, retirements) }
        }

        draft.removeOnSuccess.forEach { (remove, removeEditID) ->
            drafts[remove]?.takeIf { it.editID == removeEditID }?.let { removed ->
                drafts.remove(remove)
                retainedDraftBytes -= removed.retainedBytes
                releaseDraftAuthoritiesLocked(removed, keepReceipt = removed === draft && ticket != null, retirements)
            }
        }
        val source = (publication as? Publication.Ready)?.source
        if (source?.identity === token.sourceIdentity && source.generation == token.sourceGeneration &&
            source.authority === authority &&
            source.owner == draft.key.owner && source.authorityEpoch == token.authorityEpoch &&
            source.authorityCut == token.authorityCut
        ) {
            val registers = JSONObject(acknowledged.registers.toString())
            val acceptedSource = source.copy(
                identity = Any(), snapshot = acknowledged, registers = registers, records = project(registers),
            )
            reconcileReceiptsLocked(acceptedSource, retirements)
            publication = Publication.Ready(acceptedSource)
        }
        signalLocked()
        return status(binding)
    }

    private fun project(registers: JSONObject): Map<String, Record> = buildMap {
        registers.keys().asSequence().filter { it.startsWith(NativePlaylist.PREFIX) }.sorted().forEach { field ->
            val register = registers.optJSONObject(field) ?: return@forEach
            val projection = if (register.has("value")) NativePlaylist.projection(field, register.get("value"))
                else NativePlaylist.Projection.Unsupported
            val fingerprint = NativePlaylist.canonicalReceiptRegister(register)
                ?.let(NativePlaylistCloudReceiptLedger.Fingerprint::of)
            put(field, Record(field, JSONObject(register.toString()), projection, fingerprint))
        }
    }

    private fun reconcileReceiptsLocked(source: Source, retirements: Retirements) {
        val iterator = receiptByField.iterator()
        while (iterator.hasNext()) {
            val (_, binding) = iterator.next()
            if (binding.partition != source.partition) continue
            val live = source.records[binding.field]?.fingerprint
            if (live == null || live != binding.fingerprint) {
                iterator.remove()
                releaseBindingLocked(binding, retirements)
            }
        }
    }

    private fun status(
        source: Source,
        record: Record,
        receipts: Map<Pair<Partition, String>, ReceiptBinding>,
    ): SavedPlaylistStatus {
        val binding = receipts[source.partition to record.field]
        return if (binding != null && record.fingerprint == binding.fingerprint) status(binding)
            else SavedPlaylistStatus.CloudUnknown
    }

    private fun status(binding: ReceiptBinding): SavedPlaylistStatus = when (val state = binding.state) {
        NativePlaylistCloudReceiptLedger.State.Unknown -> SavedPlaylistStatus.CloudUnknown
        NativePlaylistCloudReceiptLedger.State.Pending -> SavedPlaylistStatus.LocalPending
        is NativePlaylistCloudReceiptLedger.State.Saved -> SavedPlaylistStatus.CloudSaved(state.version)
    }

    private fun partition(target: NativePlaylistProfileGateway.Target, owner: ContinueWatchingOwner): Partition? {
        val partition = partition(owner) ?: return null
        return partition.takeIf { target.accountId == it.accountID && target.profileId == it.profileID }
    }

    private fun partition(owner: ContinueWatchingOwner): Partition? {
        if (!owner.usesEngineHistory || !owner.principal.startsWith("account.")) return null
        val raw = owner.principal.removePrefix("account.")
        val account = runCatching { UUID.fromString(raw).toString().lowercase() }.getOrNull() ?: return null
        if (raw != account || owner.profileId.isBlank()) return null
        return Partition(account, owner.profileId)
    }

    private fun draftDocument(draft: Draft): NativePlaylist.Document? {
        val value = if (draft.value !== JSONObject.NULL) draft.value
            else draft.expectedRegister?.opt("value") ?: return null
        return (NativePlaylist.projection(draft.key.field, value) as? NativePlaylist.Projection.Supported)?.document
    }

    private fun draftPayloadBytes(field: String, expected: JSONObject?, value: Any): Int? = try {
        val expectedBytes = expected?.toString()?.toByteArray(Charsets.UTF_8)?.size ?: 0
        val valueBytes = if (value === JSONObject.NULL) 4
            else (value as JSONObject).toString().toByteArray(Charsets.UTF_8).size
        val total = field.toByteArray(Charsets.UTF_8).size.toLong() + expectedBytes + valueBytes + DRAFT_OVERHEAD_BYTES
        total.takeIf { it <= MAX_RETAINED_DRAFT_BYTES }?.toInt()
    } catch (_: Exception) {
        null
    }

    private fun documentFromQueue(id: String, name: String, items: List<MetaItem>): NativePlaylist.Document? = try {
        require(items.size <= 100)
        NativePlaylist.Document(id, name, items.map { item ->
            NativePlaylist.Entry(
                entryID = canonicalUUID(), contentID = item.id, type = item.type.id, title = item.name,
                videoIDHint = item.preferredEpisode?.videoIdentity,
                episodeLabel = item.preferredEpisode?.let { "S${it.season}E${it.episode}" },
            )
        }).also(NativePlaylist::encodedValue)
    } catch (_: Exception) {
        null
    }

    private fun queueCandidate(entry: NativePlaylist.Entry): MetaItem? {
        val type = when (entry.type) {
            MediaType.MOVIE.id -> MediaType.MOVIE
            MediaType.SERIES.id -> MediaType.SERIES
            else -> return null
        }
        if (type == MediaType.MOVIE) {
            if (entry.episodeLabel != null || (entry.videoIDHint != null && entry.videoIDHint != entry.contentID)) return null
            return MetaItem(entry.contentID, type, entry.title)
        }
        val hinted = entry.videoIDHint?.let {
            continueWatchingEpisodeFromVideoIdentity(MediaType.SERIES, it) ?: return null
        }
        val preferred = when {
            entry.episodeLabel == null && entry.videoIDHint == null -> null
            entry.episodeLabel == null -> hinted
            else -> episodePattern.matchEntire(entry.episodeLabel)?.let { match ->
                val season = match.groupValues[1].toIntOrNull()?.takeIf { it >= 0 } ?: return null
                val episode = match.groupValues[2].toIntOrNull()?.takeIf { it > 0 } ?: return null
                if (hinted != null && (hinted.season != season || hinted.episode != episode)) return null
                PreferredEpisode(season, episode, entry.videoIDHint)
            } ?: return null
        }
        return MetaItem(entry.contentID, type, entry.title, preferredEpisode = preferred)
    }

    private fun entryView(entry: NativePlaylist.Entry) = SavedPlaylistEntryView(
        entry.entryID, entry.contentID, entry.type, entry.title, entry.videoIDHint, entry.episodeLabel,
    )

    private fun replacePublicationLocked(next: Publication, retirements: Retirements) {
        val prior = (publication as? Publication.Ready)?.source
        val replacement = (next as? Publication.Ready)?.source
        publication = next
        if (prior != null && prior.authority !== replacement?.authority) {
            releaseAuthorityLocked(prior.authority, retirements)
        }
    }

    private fun releaseAuthorityLocked(authority: Authority, retirements: Retirements) {
        check(authority.references > 0)
        authority.references -= 1
        if (authority.references == 0 && !authority.retired) {
            authority.retired = true
            retirements.targets += authority.target
        }
        releaseReceiptAuthorityLocked(authority.receiptAuthority, retirements)
    }

    private fun releaseReceiptAuthorityLocked(authority: ReceiptAuthority, retirements: Retirements) {
        check(authority.references > 0)
        authority.references -= 1
        if (authority.references == 0 && !authority.retired) {
            authority.retired = true
            retirements.receiptOwners += authority.owner
        }
    }

    private fun releaseDraftAuthoritiesLocked(draft: Draft, keepReceipt: Boolean, retirements: Retirements) {
        val authority = draft.authority
        if (authority == null) {
            draft.ownsWriteAuthority = false
            draft.ownsReceiptAuthority = false
            return
        }
        if (draft.ownsWriteAuthority) {
            draft.ownsWriteAuthority = false
            check(authority.references > 0)
            authority.references -= 1
            if (authority.references == 0 && !authority.retired) {
                authority.retired = true
                retirements.targets += authority.target
            }
        }
        if (draft.ownsReceiptAuthority) {
            draft.ownsReceiptAuthority = false
            if (!keepReceipt) releaseReceiptAuthorityLocked(authority.receiptAuthority, retirements)
        }
        draft.authority = null
    }

    private fun releaseBindingAuthorityLocked(binding: ReceiptBinding, retirements: Retirements) {
        binding.receiptAuthority?.let { releaseReceiptAuthorityLocked(it, retirements) }
        binding.receiptAuthority = null
    }

    private fun releaseBindingLocked(binding: ReceiptBinding, retirements: Retirements) =
        releaseBindingAuthorityLocked(binding, retirements)

    private fun forceRetireLocked(authority: Authority, retirements: Retirements) {
        forceRetireTargetLocked(authority, retirements)
        forceRetireReceiptLocked(authority.receiptAuthority, retirements)
    }

    private fun forceRetireTargetLocked(authority: Authority, retirements: Retirements) {
        if (!authority.retired) {
            authority.retired = true
            retirements.targets += authority.target
        }
    }

    private fun forceRetireReceiptLocked(authority: ReceiptAuthority, retirements: Retirements) {
        if (!authority.retired) {
            authority.retired = true
            retirements.receiptOwners += authority.owner
        }
    }

    private fun performRetirements(retirements: Retirements) {
        retirements.targets.forEach(gateway::retirePlaylistTarget)
        retirements.receiptOwners.forEach(gateway::retirePlaylistReceiptOwner)
    }

    /** Authority callbacks get a synchronous local cut; Session-backed retirement drains off-caller. */
    private fun scheduleRetirements(retirements: Retirements) {
        if (retirements.targets.isEmpty() && retirements.receiptOwners.isEmpty()) return
        scope.launch(io) { utilityLane.withLock { performRetirements(retirements) } }
    }

    private fun signalLocked() {
        _changes.value = Math.incrementExact(_changes.value)
    }

    private fun loadTicketCurrent(ticket: Long) = synchronized(monitor) { !closed && loadGeneration == ticket }
    private fun ownerNow(): ContinueWatchingOwner? = runCatching(currentQueueOwner).getOrNull()
    private fun canonicalUUID(): String = newUUID().toString().lowercase()
    /** Same bounded scalar contract as NativePlaylist names, without JSON or an encoder allocation. */
    private fun capturedName(value: String): String? {
        if (value.isEmpty() || value != value.trim() || value.length > MAX_CAPTURED_NAME_BYTES) return null
        var bytes = 0
        var index = 0
        while (index < value.length) {
            val current = value[index]
            val scalar = when {
                Character.isHighSurrogate(current) -> {
                    if (index + 1 >= value.length || !Character.isLowSurrogate(value[index + 1])) return null
                    Character.toCodePoint(current, value[index + 1]).also { index += 2 }
                }
                Character.isLowSurrogate(current) -> return null
                else -> current.code.also { index += 1 }
            }
            val category = Character.getType(scalar)
            if (category == Character.CONTROL.toInt() || category == Character.FORMAT.toInt()) return null
            val width = when {
                scalar <= 0x7f -> 1
                scalar <= 0x7ff -> 2
                scalar <= 0xffff -> 3
                else -> 4
            }
            if (width > MAX_CAPTURED_NAME_BYTES - bytes) return null
            bytes += width
        }
        return value
    }
    private fun encodedOrNull(document: NativePlaylist.Document): JSONObject? = try {
        NativePlaylist.encodedValue(document)
    } catch (_: Exception) {
        null
    }
    private fun clone(value: JSONObject?): JSONObject? = value?.let { JSONObject(it.toString()) }
    private fun cloneValue(value: Any): Any = if (value === JSONObject.NULL) JSONObject.NULL else JSONObject((value as JSONObject).toString())
    private fun rethrowFatal(error: Throwable) {
        when (error) {
            is CancellationException, is VirtualMachineError, is ThreadDeath, is LinkageError -> throw error
        }
    }

    override fun close() {
        val retirements = Retirements()
        val jobs: List<Job>
        synchronized(authorityFence) {
            synchronized(monitor) {
                if (closed) return
                closed = true
                authorityCut.updateAndGet { Math.incrementExact(it) }
                authorityEpoch = Math.incrementExact(authorityEpoch)
                receiptRefreshGeneration = Math.incrementExact(receiptRefreshGeneration)
                jobs = listOfNotNull(loadJob, sourceHints, receiptHints, receiptRefreshJob)
                loadJob = null
                sourceHints = null
                receiptHints = null
                receiptRefreshJob = null
                val authorities = buildSet {
                    (publication as? Publication.Ready)?.source?.authority?.let(::add)
                    drafts.values.forEach { draft ->
                        if (draft.ownsWriteAuthority) draft.authority?.let(::add)
                    }
                }
                authorities.forEach { forceRetireLocked(it, retirements) }
                receiptByField.values.mapNotNull(ReceiptBinding::receiptAuthority)
                    .forEach { forceRetireReceiptLocked(it, retirements) }
                replacePublicationLocked(Publication.Loading, retirements)
                drafts.values.forEach { releaseDraftAuthoritiesLocked(it, keepReceipt = false, retirements) }
                drafts.clear()
                retainedDraftBytes = 0
                activeWrites.clear()
                receiptByField.values.forEach { releaseBindingLocked(it, retirements) }
                receiptByField.clear()
                signalLocked()
            }
        }
        jobs.forEach(Job::cancel)
        scheduleRetirements(retirements)
    }

    private companion object {
        const val MAX_RETAINED_DRAFTS = NativePlaylist.MAX_LIVE_PLAYLISTS
        const val MAX_RETAINED_DRAFT_BYTES = 4 * 1024 * 1024
        const val MAX_RECEIPT_BINDINGS = NativePlaylist.MAX_LIVE_PLAYLISTS * 2
        const val DRAFT_OVERHEAD_BYTES = 512
        const val MAX_CAPTURED_NAME_BYTES = 160
        val episodePattern = Regex("S([0-9]+)E([0-9]+)")
    }
}
