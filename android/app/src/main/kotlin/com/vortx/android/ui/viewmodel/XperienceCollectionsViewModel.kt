package com.vortx.android.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.vortx.android.engine.NativeXperienceCatalogGateway
import com.vortx.android.engine.XperienceCatalogConsumerID
import com.vortx.android.model.MetaItem
import com.vortx.android.sync.NativeXperienceProfileGateway
import com.vortx.android.xperience.XperienceCollections
import com.vortx.android.xperience.XperienceImportNamespace
import com.vortx.android.xperience.XperienceImportStore
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.Collections
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

/** Caller only: original Store observations and opaque catalog leases remain private. Every
 * native/JSON/file operation is on the owned IO lane. A fixed Route never adopts a later epoch. */
internal class XperienceCollectionsViewModel(
    profileGateway: NativeXperienceProfileGateway,
    private val catalog: NativeXperienceCatalogGateway,
    scopeOverride: CoroutineScope? = null,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val cleanupDispatcher: CoroutineDispatcher = Dispatchers.Default,
) : ViewModel() {
    class Route internal constructor(val id: String, internal val epoch: Long)
    class FileTicket internal constructor(val id: String, internal val request: Long,
        internal val observation: XperienceImportStore.Observation, internal val replacing: XperienceImportStore.RecordHandle?,
        internal val label: String, internal val bindings: Map<String, XperienceImportNamespace.Binding>) {
        val launcherKey: String = "xperience-file-$id" // Stable only within this retained original entry.
        internal val launchIssued = java.util.concurrent.atomic.AtomicBoolean(false)
    }
    class Confirmation internal constructor(val kind: Kind, val label: String, internal val request: Long) {
        enum class Kind { APPEND, REPLACE, REBIND, DELETE }
    }
    enum class Phase { IDLE, LOADING, READY, READING, SAVING, LOCAL_ACCEPTED, RETIRED, ERROR, CLOSED }
    enum class Failure { UNAVAILABLE, STALE, INVALID_INPUT, TOO_LARGE, READ_ONLY, CANCELLED, MISSING,
        MISSING_SOURCE, AMBIGUOUS_SOURCE, MAPPING_UNAVAILABLE, UNSUPPORTED_SOURCE, INVALID_REGISTRY }
    enum class Page { COLLECTIONS, FOLDERS, SOURCES, CATALOG }
    data class Preview(val document: XperienceCollections.Document, val label: String,
        val bindings: List<NativeXperienceCatalogGateway.BindingRow>, val replacing: XperienceImportStore.RecordHandle?)
    data class Browser(val document: XperienceCollections.Document, val label: String, val page: Page,
        val collectionId: String? = null, val folderId: String? = null, val sourceIndex: Int? = null,
        val items: List<MetaItem> = emptyList(), val loading: Boolean = false, val hasMore: Boolean = false,
        val status: NativeXperienceCatalogGateway.SourceStatus? = null, val failure: Failure? = null,
        val limited: Boolean = false)
    data class State(val phase: Phase = Phase.IDLE, val records: List<XperienceImportStore.RecordSummary> = emptyList(),
        val preview: Preview? = null, val confirmation: Confirmation? = null, val browser: Browser? = null,
        val failure: Failure? = null, val fileTicket: FileTicket? = null) {
        val busy: Boolean get() = phase in setOf(Phase.LOADING, Phase.READING, Phase.SAVING)
    }
    private data class Prepared(val view: Preview, val observation: XperienceImportStore.Observation,
        val lease: NativeXperienceCatalogGateway.Lease, val bindings: Map<String, XperienceImportNamespace.Binding>)
    private data class Command(val ticket: Confirmation, val observation: XperienceImportStore.Observation,
        val opening: XperienceImportStore.Opening?, val handle: XperienceImportStore.RecordHandle?,
        val document: XperienceCollections.Document?, val label: String, val bindings: Map<String, XperienceImportNamespace.Binding>)

    private val parent = scopeOverride ?: viewModelScope
    private val lifetime = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + lifetime)
    private val store = XperienceImportStore(profileGateway, scope, io)
    private val lock = Any()
    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState.asStateFlow()
    val route = Route(UUID.randomUUID().toString(), catalog.callerEpoch()) // Atomic metadata only.
    private var generation = 0L
    private var requestLive = java.util.concurrent.atomic.AtomicBoolean(true)
    private var closed = false
    private var routeLive = true
    private var opening: XperienceImportStore.Opening? = null
    // Store.openCaptured hands off to its own lazy load. Keep its original terminal owner
    // after the wrapper ends, until that exact opening publishes READY/ERROR/RETIRED/CLOSED.
    private var openingRequest: Long? = null
    private var observation: XperienceImportStore.Observation? = null
    private var lease: NativeXperienceCatalogGateway.Lease? = null
    private var selection: NativeXperienceCatalogGateway.Selection? = null
    private var stage: NativeXperienceCatalogGateway.OpeningStage? = null
    private var worker: Job? = null
    private var saveJob: Job? = null
    private var saveRequest: Long? = null
    private var chooser: FileTicket? = null
    private var prepared: Prepared? = null
    private var command: Command? = null
    private var cursor = 0
    private val consumer = XperienceCatalogConsumerID.create()
    private val cleanup = ArrayDeque<() -> Unit>()
    private val metadataRegistration = catalog.observeMetadataInvalidation { metadataRetire() }

    init {
        scope.launch { store.state.collect { reflectStore(it) } }
        // Resource/context signals are wakeups. Exact proof is checked on IO, never on Main.
        scope.launch { catalog.invalidations.collect {
            drain()
            val original = synchronized(lock) { lease to generation }
            if (original.first != null) scope.launch(io) {
                if (!catalog.isCurrent(checkNotNull(original.first))) retire(original.second)
            }
        } }
    }
    private fun liveLocked(request: Long) = !closed && routeLive && generation == request && route.epoch == catalog.callerEpoch()
    private fun routeCurrent(original: Route): Boolean = original === route && !closed && routeLive && route.epoch == catalog.callerEpoch()
    /** Only metadata is touched here. Called while native/auth/lifecycle locks may still be held. */
    private fun metadataRetire() = synchronized(lock) {
        if (!closed && routeLive) { cutLocked(dropLease = true); routeLive = false; opening = null; cleanup.add { store.invalidate() }
            mutableState.value = State(Phase.RETIRED, failure = Failure.STALE) }
    }
    private fun cutLocked(dropLease: Boolean): Long {
        requestLive.set(false); requestLive = java.util.concurrent.atomic.AtomicBoolean(true)
        generation++
        worker?.let { job -> cleanup.add { job.cancel() } }; worker = null
        stage?.let { original -> cleanup.add { original.close() } }; stage = null
        selection?.let { original -> cleanup.add { original.close() } }; selection = null
        saveJob?.let { job -> cleanup.add { job.cancel(); store.invalidate() } }; saveJob = null; saveRequest = null
        openingRequest = null
        chooser = null; command = null
        if (dropLease) {
            lease?.let { original -> cleanup.add { original.close() } }; lease = null; observation = null; prepared = null
        }
        return generation
    }
    /** Drain only after returning from publication/native callbacks and outside the consumer lock. */
    private fun drain() {
        if (Thread.holdsLock(lock)) return
        while (true) {
            val action = synchronized(lock) { if (cleanup.isEmpty()) null else cleanup.removeFirst() } ?: return
            action()
        }
    }
    private fun begin(original: Route, dropLease: Boolean = true): Long? {
        if (Thread.holdsLock(lock)) { metadataRetire(); return null }
        return synchronized(lock) { if (!routeCurrent(original)) null else cutLocked(dropLease) }
    }
    private fun beginPreview(original: Preview): Pair<Long, Prepared>? {
        if (Thread.holdsLock(lock)) { metadataRetire(); return null }
        return synchronized(lock) {
            val saved = prepared?.takeIf { it.view === original } ?: return null
            if (!routeCurrent(route) || mutableState.value.preview !== original || mutableState.value.busy ||
                !catalog.locallyCurrent(saved.lease)) return null
            cutLocked(dropLease = false) to saved
        }
    }
    private fun beginBrowser(original: Browser): Pair<Long, XperienceImportStore.Observation>? {
        if (Thread.holdsLock(lock)) { metadataRetire(); return null }
        return synchronized(lock) {
            val selected = observation ?: return null
            val bound = lease ?: return null
            if (!routeCurrent(route) || mutableState.value.browser !== original || !catalog.locallyCurrent(bound)) return null
            cutLocked(dropLease = false) to selected
        }
    }
    private fun task(request: Long, action: suspend () -> Unit) {
        drain()
        val next = scope.launch(io, start = CoroutineStart.LAZY) {
            try { currentCoroutineContext().ensureActive(); action() }
            catch (cancelled: CancellationException) { retire(request, Failure.CANCELLED); throw cancelled }
            catch (failure: XperienceCollections.Rejected) { fail(request, if (failure.reason == XperienceCollections.Failure.TOO_LARGE) Failure.TOO_LARGE else Failure.INVALID_INPUT) }
            catch (_: Exception) { fail(request, Failure.UNAVAILABLE) }
        }
        val accepted = synchronized(lock) { if (!liveLocked(request)) false else { worker = next; true } }
        next.invokeOnCompletion { cause ->
            synchronized(lock) {
                if (liveLocked(request) && worker === next) {
                    cutLocked(dropLease = true); routeLive = false; opening = null; cleanup.add { store.invalidate() }
                    mutableState.value = State(Phase.RETIRED, failure = if (cause is CancellationException) Failure.CANCELLED else null)
                }
            }
            scope.launch(cleanupDispatcher) { drain() }
        }
        if (accepted) next.start() else next.cancel()
    }
    private fun retire(request: Long, reason: Failure = Failure.STALE) {
        synchronized(lock) { if (liveLocked(request)) {
            cutLocked(dropLease = true); routeLive = false; opening = null; cleanup.add { store.invalidate() }
            mutableState.value = State(Phase.RETIRED, failure = reason)
        } }
        drain()
    }
    private fun fail(request: Long, reason: Failure) {
        val original = synchronized(lock) { if (!liveLocked(request)) return else lease }
        if (original == null) synchronized(lock) { if (liveLocked(request)) {
            worker = null; chooser = null; prepared = null; command = null
            mutableState.value = State(Phase.ERROR, mutableState.value.records, failure = reason)
        } } else publish(request, original) {
            worker = null; chooser = null; prepared = null; command = null
            val browser = mutableState.value.browser
            mutableState.value = if (browser?.page == Page.CATALOG)
                mutableState.value.copy(phase = Phase.READY, browser = browser.copy(loading = false, failure = reason))
            else State(Phase.ERROR, mutableState.value.records, failure = reason)
        }
    }
    private fun publish(request: Long, original: NativeXperienceCatalogGateway.Lease, action: () -> Unit) {
        try {
            if (!catalog.publish(original) { synchronized(lock) {
                if (liveLocked(request) && lease === original && catalog.locallyCurrent(original)) action()
            } }) retire(request)
        } finally { drain() }
    }
    private fun acquire(request: Long, original: XperienceImportStore.Observation): NativeXperienceCatalogGateway.Lease {
        check(store.observationIsCurrent(original)) { "Original import opening retired" }
        val captured = catalog.capture(original.snapshot, original.saved).getOrThrow()
        if (!store.observationIsCurrent(original)) { captured.close(); error("Original import opening retired") }
        val accepted = synchronized(lock) { if (!liveLocked(request)) false else {
            observation = original; lease = captured; true
        } }
        if (!accepted) { captured.close(); throw CancellationException("Caller superseded") }
        return captured
    }

    fun open(original: Route) { try {
        val request = begin(original) ?: return
        synchronized(lock) { opening = null; cleanup.add { store.invalidate() }; mutableState.value = State(Phase.LOADING) }
        drain()
        val captured = catalog.stageOpening(original.epoch) ?: run { fail(request, Failure.UNAVAILABLE); return }
        val originalRequest = synchronized(lock) { requestLive }
        synchronized(lock) { if (!liveLocked(request)) { cleanup.add { captured.close() }; return } else stage = captured }
        task(request) {
            var snapshot: NativeXperienceProfileGateway.Snapshot? = null
            var transferred = false
            try {
                snapshot = catalog.open(captured).getOrThrow()
                currentCoroutineContext().ensureActive()
                check(synchronized(lock) { liveLocked(request) })
                val opened = store.openCaptured(checkNotNull(snapshot)) {
                    originalRequest.get() && original.epoch == catalog.callerEpoch()
                } ?: error("Original opening unavailable")
                transferred = true
                synchronized(lock) { if (liveLocked(request)) { opening = opened; openingRequest = request; stage = null; worker = null } }
                reflectStore(store.state.value)
            } finally { captured.close(); if (!transferred) snapshot?.let(catalog::discard) }
        }
    } finally { drain() } }

    fun beginFileImport(original: Route, replacing: Preview? = null): FileTicket? { try {
        val prior = synchronized(lock) { if (replacing == null) null else {
            prepared?.takeIf { it.view === replacing && mutableState.value.preview === replacing } ?: return null
        } }
        val request = begin(original) ?: return null
        drain()
        val current = synchronized(lock) { opening } ?: run { fail(request, Failure.STALE); return null }
        val selected = prior?.observation ?: store.observation(current) ?: run { fail(request, Failure.STALE); return null }
        return synchronized(lock) {
            if (!liveLocked(request)) null else FileTicket(UUID.randomUUID().toString(), request, selected,
                prior?.view?.replacing, prior?.view?.label ?: "Imported collections", prior?.bindings.orEmpty()).also {
                chooser = it; mutableState.value = State(Phase.READY, mutableState.value.records, fileTicket = it)
            }
        }
    } finally { drain() } }
    /** One OS launch per original retained ticket. Recreated presenters only re-register the
     * same launcherKey; process death cannot reconstruct this in-memory ticket/observation. */
    fun claimFileLaunch(original: FileTicket): Boolean = synchronized(lock) {
        chooser === original && liveLocked(original.request) && mutableState.value.fileTicket === original &&
            original.launchIssued.compareAndSet(false, true)
    }
    fun cancelFileImport(original: FileTicket) { try {
        val request = synchronized(lock) {
            if (chooser !== original || !liveLocked(original.request)) return
            cutLocked(dropLease = true).also { mutableState.value = State(Phase.READY, mutableState.value.records) }
        }
        check(request >= 0)
    } finally { drain() } }
    fun fileResult(original: FileTicket, opener: (() -> InputStream?)?) { try {
        if (opener == null) { cancelFileImport(original); return }
        val accepted = synchronized(lock) {
            if (chooser !== original || !liveLocked(original.request) || mutableState.value.phase == Phase.READING) false
            else { mutableState.value = State(Phase.READING, mutableState.value.records); true }
        }
        if (!accepted) return
        task(original.request) {
            val bound = acquire(original.request, original.observation)
            val bytes = readBounded(opener)
            try { val document = XperienceCollections.parse(bytes)
                installPreview(original.request, original.observation, bound, document, original.label, original.replacing, compatibleBindings(document, original.bindings), allowDefaults = true) }
            finally { bytes.fill(0) }
        }
    } finally { drain() } }
    fun previewPaste(original: Route, text: String, replacing: Preview? = null) { try {
        val prior = synchronized(lock) { if (replacing == null) null else {
            prepared?.takeIf { it.view === replacing && mutableState.value.preview === replacing } ?: return
        } }
        val request = begin(original) ?: return
        drain()
        val current = synchronized(lock) { opening } ?: run { fail(request, Failure.STALE); return }
        val selected = prior?.observation ?: store.observation(current) ?: run { fail(request, Failure.STALE); return }
        synchronized(lock) { if (liveLocked(request)) mutableState.value = State(Phase.READING, mutableState.value.records) }
        task(request) {
            if (text.length > XperienceCollections.MAX_BYTES) throw XperienceCollections.Rejected(XperienceCollections.Failure.TOO_LARGE)
            val bound = acquire(request, selected)
            val bytes = text.toByteArray(Charsets.UTF_8)
            try { val document = XperienceCollections.parse(bytes)
                installPreview(request, selected, bound, document, prior?.view?.label ?: "Imported collections",
                    prior?.view?.replacing, compatibleBindings(document, prior?.bindings.orEmpty()), allowDefaults = true) }
            finally { bytes.fill(0) }
        }
    } finally { drain() } }
    private fun compatibleBindings(document: XperienceCollections.Document, existing: Map<String, XperienceImportNamespace.Binding>): Map<String, XperienceImportNamespace.Binding> {
        val keys = document.collections.flatMap { it.folders }.flatMap { it.sources }.filter { it.isAddon }
            .map(com.vortx.android.xperience.XperienceAddonBinding::key).toSet()
        return existing.filterKeys { it in keys }
    }
    private suspend fun readBounded(opener: () -> InputStream?): ByteArray = suspendCancellableCoroutine { continuation ->
        val stream = AtomicReference<InputStream?>(null)
        val reader = scope.launch(io, start = CoroutineStart.LAZY) {
            try {
                currentCoroutineContext().ensureActive()
                val opened = checkNotNull(opener())
                stream.set(opened)
                val bytes = opened.use { input ->
                    currentCoroutineContext().ensureActive()
                    val output = object : ByteArrayOutputStream() { fun wipe() { buf.fill(0); reset() } }
                    val buffer = ByteArray(8_192)
                    try {
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (count == 0) {
                                val next = input.read()
                                if (next < 0) break
                                if (output.size() == XperienceCollections.MAX_BYTES)
                                    throw XperienceCollections.Rejected(XperienceCollections.Failure.TOO_LARGE)
                                output.write(next); continue
                            }
                            if (output.size() > XperienceCollections.MAX_BYTES - count)
                                throw XperienceCollections.Rejected(XperienceCollections.Failure.TOO_LARGE)
                            output.write(buffer, 0, count)
                        }
                        currentCoroutineContext().ensureActive()
                        output.toByteArray()
                    } finally { buffer.fill(0); output.wipe() }
                }
                stream.compareAndSet(opened, null)
                if (continuation.isActive) continuation.resume(bytes) else bytes.fill(0)
            } catch (cancelled: CancellationException) { continuation.cancel(cancelled); throw cancelled }
            catch (failure: Exception) { if (continuation.isActive) continuation.resumeWithException(failure) }
            finally { stream.getAndSet(null)?.let { try { it.close() } catch (_: Exception) { } } }
        }
        continuation.invokeOnCancellation {
            stream.getAndSet(null)?.let { try { it.close() } catch (_: Exception) { } }
            reader.cancel()
        }
        reader.invokeOnCompletion { cause ->
            // Error/OOM propagates to the awaiting owner as well as the coroutine handler;
            // it cannot strand a busy file request whose IO child never resumed it.
            if (cause != null && continuation.isActive) {
                if (cause is CancellationException) continuation.cancel(cause)
                else continuation.resumeWithException(cause)
            }
        }
        reader.start()
    }
    fun review(original: Route, handle: XperienceImportStore.RecordHandle) { try {
        val request = begin(original) ?: return
        drain()
        val selected = store.observation(handle) ?: run { fail(request, Failure.READ_ONLY); return }
        val saved = checkNotNull(selected.saved)
        synchronized(lock) { if (liveLocked(request)) mutableState.value = State(Phase.READING, mutableState.value.records) }
        task(request) { val bound = acquire(request, selected)
            installPreview(request, selected, bound, saved.document, saved.label, handle, saved.bindings) }
    } finally { drain() } }
    private fun installPreview(request: Long, selected: XperienceImportStore.Observation, bound: NativeXperienceCatalogGateway.Lease,
        document: XperienceCollections.Document, label: String, replacing: XperienceImportStore.RecordHandle?,
        mappings: Map<String, XperienceImportNamespace.Binding>, choices: Map<String, NativeXperienceCatalogGateway.Choice?> = emptyMap(),
        allowDefaults: Boolean = false) {
        val projected = catalog.preview(bound, document, label, mappings, choices, allowDefaults).getOrThrow()
        publish(request, bound) {
            val view = Preview(document, label, projected.rows, replacing)
            prepared = Prepared(view, selected, bound, projected.bindings); chooser = null; worker = null
            mutableState.value = State(Phase.READY, mutableState.value.records, preview = view)
        }
    }
    fun setLabel(original: Preview, label: String) { try {
        val (_, current) = beginPreview(original) ?: return
        // Small local draft metadata only. Complete domain/privacy/native validation occurs on
        // explicit stage/confirm, never for each text edit. UI may keep its own keyed draft.
        synchronized(lock) {
            val view = original.copy(label = label)
            prepared = current.copy(view = view)
            mutableState.value = mutableState.value.copy(preview = view, confirmation = null)
        }
    } finally { drain() } }
    fun chooseBinding(original: Preview, key: String, choice: NativeXperienceCatalogGateway.Choice?) { try {
        val (request, current) = beginPreview(original) ?: return
        synchronized(lock) { mutableState.value = mutableState.value.copy(phase = Phase.READING, confirmation = null) }
        task(request) { installPreview(request, current.observation, current.lease, original.document, original.label,
            original.replacing, current.bindings, mapOf(key to choice)) }
    } finally { drain() } }
    fun clearPreview(original: Preview) { try {
        beginPreview(original) ?: return
        synchronized(lock) { cutLocked(dropLease = true); mutableState.value = State(Phase.READY, mutableState.value.records) }
    } finally { drain() } }
    fun stageAppend(original: Preview, labelDraft: String = original.label) = stagePreview(original, labelDraft, Confirmation.Kind.APPEND)
    fun stageReplace(original: Preview, labelDraft: String = original.label) = stagePreview(original, labelDraft, Confirmation.Kind.REPLACE)
    fun stageRebind(original: Preview, labelDraft: String = original.label) = stagePreview(original, labelDraft, Confirmation.Kind.REBIND)
    private fun stagePreview(original: Preview, labelDraft: String, kind: Confirmation.Kind) { try {
        val (request, current) = beginPreview(original) ?: return
        if (kind != Confirmation.Kind.APPEND && original.replacing == null) { task(request) { fail(request, Failure.MISSING) }; return }
        synchronized(lock) { mutableState.value = mutableState.value.copy(phase = Phase.READING, confirmation = null) }
        task(request) {
            val validated = catalog.preview(current.lease, original.document, labelDraft, current.bindings, emptyMap()).getOrThrow()
            publish(request, current.lease) {
                val ticket = Confirmation(kind, labelDraft, request)
                command = Command(ticket, current.observation, opening, original.replacing, original.document, labelDraft, validated.bindings.toMap())
                worker = null
                mutableState.value = mutableState.value.copy(phase = Phase.READY, confirmation = ticket)
            }
        }
    } finally { drain() } }
    fun stageDelete(original: Route, handle: XperienceImportStore.RecordHandle) { try {
        val request = begin(original) ?: return
        drain()
        val selected = store.observation(handle) ?: run { fail(request, Failure.READ_ONLY); return }
        val saved = checkNotNull(selected.saved)
        task(request) {
            val bound = acquire(request, selected)
            publish(request, bound) {
                val ticket = Confirmation(Confirmation.Kind.DELETE, saved.label, request)
                command = Command(ticket, selected, null, handle, null, saved.label, saved.bindings.toMap()); worker = null
                mutableState.value = State(Phase.READY, mutableState.value.records, confirmation = ticket)
            }
        }
    } finally { drain() } }
    fun cancelConfirmation(original: Confirmation) { try {
        synchronized(lock) {
            if (command?.ticket !== original || !liveLocked(original.request)) return
            cutLocked(dropLease = false); mutableState.value = mutableState.value.copy(confirmation = null)
        }
    } finally { drain() } }
    fun confirm(original: Confirmation) { try {
        val captured = synchronized(lock) {
            val saved = command?.takeIf { it.ticket === original && liveLocked(original.request) } ?: return
            val request = cutLocked(dropLease = false)
            saveRequest = request
            mutableState.value = State(Phase.SAVING, mutableState.value.records)
            request to saved
        }
        task(captured.first) {
            val payload = captured.second
            check(store.observationIsCurrent(payload.observation))
            val bound = checkNotNull(synchronized(lock) { lease })
            check(catalog.isCurrent(bound))
            val saving = when (payload.ticket.kind) {
                Confirmation.Kind.APPEND -> store.append(checkNotNull(payload.opening), checkNotNull(payload.document), payload.label, bindings = payload.bindings, caller = currentCoroutineContext()[Job])
                Confirmation.Kind.REPLACE -> store.replace(checkNotNull(payload.handle), checkNotNull(payload.document), payload.label, payload.bindings, currentCoroutineContext()[Job])
                Confirmation.Kind.REBIND -> store.rebind(checkNotNull(payload.handle), payload.bindings, currentCoroutineContext()[Job])
                Confirmation.Kind.DELETE -> store.delete(checkNotNull(payload.handle), currentCoroutineContext()[Job])
            } ?: error("Original save gesture retired")
            val owned = synchronized(lock) { if (!liveLocked(captured.first)) false else { saveJob = saving; true } }
            if (!owned) { saving.cancel(); return@task }
            try { saving.join(); reflectStore(store.state.value) }
            finally { if (!saving.isCompleted) saving.cancel() }
        }
    } finally { drain() } }

    fun browse(original: Route, handle: XperienceImportStore.RecordHandle) { try {
        val request = begin(original) ?: return
        drain()
        val selected = store.observation(handle) ?: run { fail(request, Failure.READ_ONLY); return }
        val saved = checkNotNull(selected.saved)
        task(request) { val bound = acquire(request, selected)
            publish(request, bound) { worker = null; cursor = 0
                mutableState.value = State(Phase.READY, mutableState.value.records, browser = Browser(saved.document, saved.label, Page.COLLECTIONS)) }
        }
    } finally { drain() } }
    fun openCollection(original: Browser, id: String) = navigate(original, Page.FOLDERS, id, null)
    fun openFolder(original: Browser, id: String) = navigate(original, Page.SOURCES, original.collectionId, id)
    private fun navigate(original: Browser, page: Page, collectionId: String?, folderId: String?) { try {
        val (request, _) = beginBrowser(original) ?: return
        val collection = original.document.collections.singleOrNull { it.id == collectionId }
        if (collection == null || (folderId != null && collection.folders.none { it.id == folderId })) { task(request) { fail(request, Failure.MISSING) }; return }
        val bound = checkNotNull(synchronized(lock) { lease })
        task(request) { publish(request, bound) { worker = null; cursor = 0
            mutableState.value = mutableState.value.copy(browser = original.copy(page = page, collectionId = collectionId, folderId = folderId,
                sourceIndex = null, items = emptyList(), loading = false, hasMore = false, status = null, failure = null)) } }
    } finally { drain() } }
    fun openSource(original: Browser, index: Int) = loadCatalog(original, index, false)
    fun retryCatalog(original: Browser) = loadCatalog(original, original.sourceIndex, false)
    fun loadMoreCatalog(original: Browser) { if (original.hasMore && !original.loading) loadCatalog(original, original.sourceIndex, true) }
    private fun loadCatalog(original: Browser, index: Int?, more: Boolean) { try {
        val (request, _) = beginBrowser(original) ?: return
        val bound = checkNotNull(synchronized(lock) { lease })
        val collectionId = original.collectionId; val folderId = original.folderId
        if (collectionId == null || folderId == null || index == null) { task(request) { fail(request, Failure.MISSING_SOURCE) }; return }
        val offset = if (more) synchronized(lock) { cursor } else null
        val loading = original.copy(page = Page.CATALOG, sourceIndex = index, items = if (more) original.items else emptyList(),
            loading = true, hasMore = false, status = null, failure = null)
        synchronized(lock) { if (liveLocked(request)) mutableState.value = mutableState.value.copy(browser = loading) }
        task(request) {
            val selected = catalog.select(bound, collectionId, folderId, index).getOrThrow()
            val adopted = synchronized(lock) { if (!liveLocked(request)) false else { selection = selected; true } }
            if (!adopted) { selected.close(); return@task }
            val result = try { catalog.load(selected, consumer, offset).getOrThrow() } finally { selected.close() }
            currentCoroutineContext().ensureActive()
            publish(request, bound) {
                worker = null; selection = null
                val browser = when (result) {
                    is NativeXperienceCatalogGateway.Outcome.Unresolved -> loading.copy(loading = false, status = result.status)
                    is NativeXperienceCatalogGateway.Outcome.Loaded -> {
                        cursor = result.page.nextSkip
                        val unique = linkedMapOf<Pair<com.vortx.android.model.MediaType, String>, MetaItem>()
                        for (item in loading.items.asSequence() + result.page.items.asSequence()) {
                            unique.putIfAbsent(item.type to item.id, item)
                            if (unique.size == MAX_CATALOG_ITEMS) break
                        }
                        val limited = unique.size == MAX_CATALOG_ITEMS
                        loading.copy(items = Collections.unmodifiableList(unique.values.toList()), limited = limited,
                            loading = false, hasMore = result.page.hasMore && !limited, status = NativeXperienceCatalogGateway.SourceStatus.RESOLVED)
                    }
                }
                mutableState.value = mutableState.value.copy(browser = browser)
            }
        }
    } finally { drain() } }
    fun back(original: Browser) { try {
        val (request, _) = beginBrowser(original) ?: return
        val bound = checkNotNull(synchronized(lock) { lease })
        task(request) { publish(request, bound) {
            worker = null; cursor = 0
            val browser = when (original.page) {
                Page.COLLECTIONS -> null
                Page.FOLDERS -> original.copy(page = Page.COLLECTIONS, collectionId = null)
                Page.SOURCES -> original.copy(page = Page.FOLDERS, folderId = null)
                Page.CATALOG -> original.copy(page = Page.SOURCES, sourceIndex = null, items = emptyList(), hasMore = false, loading = false, status = null, failure = null)
            }
            mutableState.value = mutableState.value.copy(browser = browser)
        } }
    } finally { drain() } }
    /** Cheap original-rendered-row admission only. The ordinary detail path owns its native gate. */
    fun openItem(original: Browser, item: MetaItem, onItem: (MetaItem) -> Unit): Boolean { try {
        val accepted = synchronized(lock) {
            val bound = lease ?: return false
            if (!routeCurrent(route) || mutableState.value.browser !== original || original.loading ||
                !catalog.locallyCurrent(bound) || original.items.none { it === item }) return false
            item
        }
        // External navigation is outside the consumer monitor. The scalar click gate cannot
        // freeze authority until a later detail load; the ordinary detail path re-admits native.
        onItem(accepted); return true
    } finally { drain() } }
    fun stop(original: Route) { try {
        if (original !== route) return
        synchronized(lock) { if (!closed && routeLive) {
            cutLocked(dropLease = true); routeLive = false; opening = null; cleanup.add { store.invalidate() }
            mutableState.value = State(Phase.RETIRED)
        } }
    } finally { drain() } }
    private fun reflectStore(value: XperienceImportStore.State) {
        synchronized(lock) {
            if (!routeCurrent(route)) return
            val originalOpening = opening ?: return
            if (value.opening !== originalOpening && value.terminalOpening !== originalOpening) return
            when (value.phase) {
                XperienceImportStore.Phase.READY -> if (openingRequest == generation && mutableState.value.phase == Phase.LOADING) {
                    openingRequest = null; worker = null
                    mutableState.value = State(Phase.READY, value.records)
                }
                XperienceImportStore.Phase.LOCAL_ACCEPTED -> if (saveRequest == generation) {
                    cutLocked(dropLease = true); opening = null
                    mutableState.value = State(Phase.LOCAL_ACCEPTED)
                }
                XperienceImportStore.Phase.ERROR -> if (saveRequest == generation || openingRequest == generation) {
                    openingRequest = null; worker = null; saveJob = null; saveRequest = null
                    mutableState.value = State(Phase.ERROR, value.records, failure = if (value.failure == XperienceImportStore.Failure.STALE_REGISTER) Failure.STALE else Failure.UNAVAILABLE)
                }
                XperienceImportStore.Phase.RETIRED, XperienceImportStore.Phase.CLOSED -> {
                    cutLocked(dropLease = true); routeLive = false; opening = null
                    cleanup.add { store.invalidate() }
                    mutableState.value = State(Phase.RETIRED, failure = if (value.failure == XperienceImportStore.Failure.CANCELLED) Failure.CANCELLED else Failure.STALE)
                }
                else -> Unit
            }
        }
        // Store publications may be inline under its/native locks. Cleanup is always deferred.
        scope.launch(cleanupDispatcher) { drain() }
    }
    override fun onCleared() {
        synchronized(lock) {
            if (!closed) {
                cutLocked(dropLease = true); closed = true; opening = null
                cleanup.add { metadataRegistration.close(); store.close(); lifetime.cancel() }
                mutableState.value = State(Phase.CLOSED)
            }
        }
        drain()
        super.onCleared()
    }
    companion object { const val MAX_CATALOG_ITEMS = 2_000 }
}
