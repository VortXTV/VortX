package com.vortx.android.engine

import com.vortx.android.model.MetaItem
import com.vortx.android.sync.NativeXperienceProfileGateway
import com.vortx.android.xperience.XperienceAddonBinding
import com.vortx.android.xperience.XperienceCollections
import com.vortx.android.xperience.XperienceImportNamespace
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import org.json.JSONObject

/** Read-only catalog authority, issued only from the ORIGINAL genuine saved-import Snapshot.
 * UI receives opaque leases/choices/selections, never Session, native read or configured URLs. */
internal interface NativeXperienceCatalogGateway {
    interface OpeningStage : AutoCloseable
    interface Lease : AutoCloseable
    interface Selection : AutoCloseable
    interface Choice { val label: String }
    enum class SourceStatus { RESOLVED, MISSING, AMBIGUOUS, MAPPING_UNAVAILABLE, UNSUPPORTED, INVALID_REGISTRY }
    data class BindingRow(val key: String, val ordinal: Int, val choices: List<Choice>, val selected: Choice?, val status: SourceStatus)
    data class Preview(val rows: List<BindingRow>, val bindings: Map<String, XperienceImportNamespace.Binding>)
    data class Page(val items: List<MetaItem>, val rawCount: Int, val nextSkip: Int, val hasMore: Boolean)
    sealed interface Outcome {
        data class Loaded(val page: Page) : Outcome
        data class Unresolved(val status: SourceStatus) : Outcome
    }
    /** Wakeups only. Original Snapshot admission remains the proof for every publication. */
    val invalidations: Flow<Unit>
    fun callerEpoch(): Long
    /** Listener MUST perform metadata revocation/UI clearing only, with no cancellation/native. */
    fun observeMetadataInvalidation(listener: () -> Unit): AutoCloseable
    fun stageOpening(originalEpoch: Long): OpeningStage?
    fun open(stage: OpeningStage): Result<NativeXperienceProfileGateway.Snapshot>
    fun discard(snapshot: NativeXperienceProfileGateway.Snapshot)
    fun capture(snapshot: NativeXperienceProfileGateway.Snapshot, saved: XperienceImportNamespace.Saved? = null): Result<Lease>
    fun isCurrent(lease: Lease): Boolean
    fun locallyCurrent(lease: Lease): Boolean
    fun publish(lease: Lease, publication: () -> Unit): Boolean
    fun preview(lease: Lease, document: XperienceCollections.Document, label: String,
        existing: Map<String, XperienceImportNamespace.Binding>, choices: Map<String, Choice?>,
        allowDefaults: Boolean = false): Result<Preview>
    fun select(lease: Lease, collectionId: String, folderId: String, sourceIndex: Int): Result<Selection>
    suspend fun load(selection: Selection, consumer: XperienceCatalogConsumerID, skip: Int? = null): Result<Outcome>
}

/** Existing installed-addon resource transport only. Collection/artwork URLs never enter requests. */
internal class NativeXperienceCatalogAccess(
    private val accounts: NativeAccountCoordinator,
    private val repository: NativeCatalogRepository,
    private val scope: CoroutineScope,
) : NativeXperienceCatalogGateway {
    private val epoch = java.util.concurrent.atomic.AtomicLong(0)
    private val listeners = java.util.concurrent.CopyOnWriteArrayList<() -> Unit>()
    private val signals = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    override val invalidations: Flow<Unit> = merge(signals, repository.ctxUpdates().flowOn(Dispatchers.IO))
    private val observations = java.util.WeakHashMap<NativeXperienceProfileGateway.Snapshot, Long>()
    private class Stage(val issuer: NativeXperienceCatalogAccess, val originalEpoch: Long,
        val native: NativeXperienceCatalogGateway.OpeningStage) : NativeXperienceCatalogGateway.OpeningStage {
        override fun close() { native.close() }
    }
    override fun callerEpoch(): Long = epoch.get()
    override fun observeMetadataInvalidation(listener: () -> Unit): AutoCloseable {
        listeners += listener
        return AutoCloseable { listeners.remove(listener) }
    }
    /** Called under native/auth locks: only original epoch revocation and metadata callbacks.
     * Cancellation/Store retirement observers run from the owned outside-lock Default lane. */
    internal fun invalidateDeferred() {
        epoch.incrementAndGet()
        listeners.forEach { it() }
        scope.launch(Dispatchers.Default) { signals.emit(Unit) }
    }
    override fun stageOpening(originalEpoch: Long): NativeXperienceCatalogGateway.OpeningStage? {
        if (epoch.get() != originalEpoch) return null
        val native = accounts.stageXperienceOpening() ?: return null
        return if (epoch.get() == originalEpoch) Stage(this, originalEpoch, native) else { native.close(); null }
    }
    override fun open(stage: NativeXperienceCatalogGateway.OpeningStage): Result<NativeXperienceProfileGateway.Snapshot> = catalogResult {
        val original = stage as? Stage ?: error("Invalid catalog opening")
        check(original.issuer === this && epoch.get() == original.originalEpoch)
        var captured: NativeXperienceProfileGateway.Snapshot? = null
        var transferred = false
        try {
            captured = accounts.openXperienceSnapshot(original.native)
            check(epoch.get() == original.originalEpoch) { "Original caller epoch retired" }
            synchronized(observations) { observations[checkNotNull(captured)] = original.originalEpoch }
            checkNotNull(captured).also { transferred = true }
        } finally { if (!transferred) captured?.let { accounts.retireXperienceTarget(it.target) } }
    }
    override fun discard(snapshot: NativeXperienceProfileGateway.Snapshot) {
        synchronized(observations) { observations.remove(snapshot) }
        accounts.retireXperienceTarget(snapshot.target)
    }
    private class Context(val issuer: NativeXperienceCatalogAccess, val snapshot: NativeXperienceProfileGateway.Snapshot,
        val installed: XperienceInstalledCatalogSnapshot, val saved: XperienceImportNamespace.Saved?, val originalEpoch: Long,
        val rawObservation: VortxNativeSession.XperienceObservation) : NativeXperienceCatalogGateway.Lease {
        val live = AtomicBoolean(true)
        override fun close() { live.set(false); rawObservation.close() }
    }
    private class BoundChoice(val context: Context, val key: String, val candidate: XperienceAddonBinding.Candidate,
        override val label: String) : NativeXperienceCatalogGateway.Choice
    private class Selected(val context: Context, val source: XperienceCollections.Source,
        val mapping: XperienceAddonBinding.Mapping?) : NativeXperienceCatalogGateway.Selection {
        val live = AtomicBoolean(true)
        override fun close() { live.set(false) }
    }
    private fun context(lease: NativeXperienceCatalogGateway.Lease): Context =
        (lease as? Context)?.takeIf { it.issuer === this && it.live.get() && it.originalEpoch == epoch.get() } ?: error("Original catalog lease retired")
    private fun <T> admitted(lease: NativeXperienceCatalogGateway.Lease, action: (Context, VortxNativeSession, VortxNativeRead) -> T): T {
        val original = context(lease)
        return accounts.withXperienceSnapshotRead(original.snapshot) { session, read ->
            check(locallyCurrent(original)) { "Original catalog lease retired" }
            action(original, session, read).also { check(locallyCurrent(original)) { "Original catalog lease retired" } }
        }
    }
    override fun capture(snapshot: NativeXperienceProfileGateway.Snapshot, saved: XperienceImportNamespace.Saved?): Result<NativeXperienceCatalogGateway.Lease> = catalogResult {
        accounts.withXperienceSnapshotRead(snapshot) { session, read ->
            val originalEpoch = synchronized(observations) { observations[snapshot] } ?: error("Original opening observation unavailable")
            check(originalEpoch == epoch.get()) { "Original caller epoch retired" }
            if (saved != null) {
                val observed = snapshot.registers()
                val baseline = saved.register()
                try { check(observed[saved.field]?.contentEquals(baseline) == true) { "Original saved import changed" } }
                finally { baseline.fill(0); observed.values.forEach { it.fill(0) } }
            }
            val installed = repository.xperienceCandidates(session, read)
            Context(this, snapshot, installed, saved, originalEpoch, session.captureXperienceObservation(read.owner))
        }
    }
    override fun isCurrent(lease: NativeXperienceCatalogGateway.Lease): Boolean = try { admitted(lease) { _, _, _ -> true } }
        catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { false }
    override fun locallyCurrent(lease: NativeXperienceCatalogGateway.Lease): Boolean = (lease as? Context)?.let {
        it.issuer === this && it.live.get() && it.originalEpoch == epoch.get() && it.rawObservation.isCurrent()
    } == true
    override fun publish(lease: NativeXperienceCatalogGateway.Lease, publication: () -> Unit): Boolean = try {
        admitted(lease) { _, _, _ -> publication(); true }
    } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { false }

    override fun preview(lease: NativeXperienceCatalogGateway.Lease, document: XperienceCollections.Document, label: String,
        existing: Map<String, XperienceImportNamespace.Binding>, choices: Map<String, NativeXperienceCatalogGateway.Choice?>,
        allowDefaults: Boolean): Result<NativeXperienceCatalogGateway.Preview> = catalogResult {
        admitted(lease) { original, _, _ ->
            val sources = document.collections.flatMap { it.folders }.flatMap { it.sources }.distinctBy(XperienceAddonBinding::key)
            val keys = sources.filter { it.isAddon }.map(XperienceAddonBinding::key).toSet()
            require(existing.keys.all { it in keys } && choices.keys.all { it in keys })
            val bindings = existing.toMutableMap()
            choices.forEach { (key, choice) ->
                if (choice == null) bindings.remove(key) else {
                    val bound = choice as? BoundChoice ?: error("Invalid catalog choice")
                    check(bound.context === original && bound.key == key) { "Original catalog choice changed" }
                    bindings[key] = XperienceImportNamespace.Binding(bound.candidate.manifestID, bound.candidate.transportFingerprint)
                }
            }
            val rows = sources.mapIndexed { index, source ->
                val key = XperienceAddonBinding.key(source)
                val available = original.installed.candidates.mapIndexedNotNull { ordinal, candidate ->
                    if (original.installed.resolve(source, candidate.mapping) is XperienceAddonBinding.Resolution.Resolved)
                        BoundChoice(original, key, candidate, "Installed source ${ordinal + 1}") else null
                }
                val mapping = bindings[key]?.let { XperienceAddonBinding.Mapping(it.manifestID, it.transportFingerprint) }
                // Missing persisted/reviewed binding is deliberately unavailable. Only a fresh
                // JSON preview may propose an exact singleton default, never explicit null.
                val mayDefault = allowDefaults && key !in choices
                val resolution = if (source.isAddon && mapping == null && !mayDefault)
                    XperienceAddonBinding.Resolution.MappingUnavailable else original.installed.resolve(source, mapping)
                val chosen = (resolution as? XperienceAddonBinding.Resolution.Resolved)?.candidate
                // A single installed match is an explicit preview default. It is persisted only by
                // the subsequent original confirmation; no install/fetch follows this projection.
                if (mapping == null && chosen != null && source.isAddon && key !in choices)
                    bindings[key] = XperienceImportNamespace.Binding(chosen.manifestID, chosen.transportFingerprint)
                NativeXperienceCatalogGateway.BindingRow(key, index + 1, Collections.unmodifiableList(available),
                    available.singleOrNull { it.candidate === chosen }, status(resolution))
            }
            val edit = XperienceImportNamespace.append(document, label, bindings = bindings)
            // Validation only. Never serialize this disposable projection as original import bytes.
            NativeHostDocument.requireCredentialFree(JSONObject(OHJson.utf8(edit.value())))
            NativeXperienceWrite.Change.edit(edit)
            NativeXperienceCatalogGateway.Preview(Collections.unmodifiableList(rows), Collections.unmodifiableMap(bindings.toMap()))
        }
    }
    override fun select(lease: NativeXperienceCatalogGateway.Lease, collectionId: String, folderId: String,
        sourceIndex: Int): Result<NativeXperienceCatalogGateway.Selection> = catalogResult {
        admitted(lease) { original, _, _ ->
            val saved = checkNotNull(original.saved) { "Original saved import required" }
            val collection = saved.document.collections.single { it.id == collectionId }
            val folder = collection.folders.single { it.id == folderId }
            val source = folder.sources.getOrNull(sourceIndex) ?: error("Original catalog source missing")
            val binding = saved.bindings[XperienceAddonBinding.key(source)]
            Selected(original, source, binding?.let { XperienceAddonBinding.Mapping(it.manifestID, it.transportFingerprint) })
        }
    }
    override suspend fun load(selection: NativeXperienceCatalogGateway.Selection, consumer: XperienceCatalogConsumerID,
        skip: Int?): Result<NativeXperienceCatalogGateway.Outcome> {
        return try {
            val selected = selection as? Selected ?: error("Invalid catalog selection")
            check(selected.context.issuer === this && selected.live.get()) { "Original catalog selection retired" }
            currentCoroutineContext().ensureActive()
            val captured = admitted(selected.context) { _, session, read -> session to read }
            if (selected.source.isAddon && selected.mapping == null) {
                return Result.success(admitted(selected.context) { _, _, _ ->
                    check(selected.live.get()) { "Original catalog selection retired" }
                    NativeXperienceCatalogGateway.Outcome.Unresolved(NativeXperienceCatalogGateway.SourceStatus.MAPPING_UNAVAILABLE)
                }) // No repository slot/resource request without the saved explicit mapping.
            }
            val outcome = repository.requestXperienceCatalog(captured.first, captured.second, selected.source, consumer, selected.mapping, skip) {
                selected.live.get() && isCurrent(selected.context)
            }.getOrThrow()
            currentCoroutineContext().ensureActive()
            val result = admitted(selected.context) { _, _, _ ->
                check(selected.live.get()) { "Original catalog selection retired" }
                when (outcome) {
                    is XperienceCatalogRequestOutcome.Unresolved -> NativeXperienceCatalogGateway.Outcome.Unresolved(status(outcome.resolution))
                    is XperienceCatalogRequestOutcome.Loaded -> {
                        val next = Math.addExact(skip ?: 0, outcome.rawItemCount)
                        NativeXperienceCatalogGateway.Outcome.Loaded(NativeXperienceCatalogGateway.Page(outcome.items,
                            outcome.rawItemCount, next, outcome.supportsSkip && outcome.rawItemCount > 0))
                    }
                }
            }
            Result.success(result)
        } catch (cancelled: CancellationException) { throw cancelled } catch (failure: Exception) { Result.failure(failure) }
    }
    private fun status(resolution: XperienceAddonBinding.Resolution): NativeXperienceCatalogGateway.SourceStatus = when (resolution) {
        is XperienceAddonBinding.Resolution.Resolved -> NativeXperienceCatalogGateway.SourceStatus.RESOLVED
        XperienceAddonBinding.Resolution.Missing -> NativeXperienceCatalogGateway.SourceStatus.MISSING
        is XperienceAddonBinding.Resolution.Ambiguous -> NativeXperienceCatalogGateway.SourceStatus.AMBIGUOUS
        XperienceAddonBinding.Resolution.MappingUnavailable -> NativeXperienceCatalogGateway.SourceStatus.MAPPING_UNAVAILABLE
        XperienceAddonBinding.Resolution.InvalidRegistry -> NativeXperienceCatalogGateway.SourceStatus.INVALID_REGISTRY
        XperienceAddonBinding.Resolution.UnsupportedGenreConfiguration, XperienceAddonBinding.Resolution.UnsupportedProvider -> NativeXperienceCatalogGateway.SourceStatus.UNSUPPORTED
    }
    private inline fun <T> catalogResult(action: () -> T): Result<T> = try { Result.success(action()) }
        catch (cancelled: CancellationException) { throw cancelled } catch (failure: Exception) { Result.failure(failure) }
}
