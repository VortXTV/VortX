package com.vortx.android.xperience

import com.vortx.android.sync.NativeXperienceProfileGateway
import java.util.Collections
import java.util.UUID
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
import kotlinx.coroutines.launch

/** Saved-import controller only. The gateway owns original account/Session/profile authority,
 * raw CAS, complete-account budget, checkpoint durability and readback. Binding values are data,
 * never a catalog/install/URL capability. A caller must explicitly open each new observation;
 * this Store has no automatic observer, network, cloud receipt or application activation. */
internal class XperienceImportStore(
    private val gateway: NativeXperienceProfileGateway,
    parentScope: CoroutineScope,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : AutoCloseable {
    /** Identity tokens retain no gateway target, raw register or Saved authority. */
    class Opening internal constructor(internal val identity: Any)
    class RecordHandle internal constructor(internal val identity: Any, internal val field: String)
    /** Local immutable selection only. Capture is cheap and never calls native under monitor.
     * The catalog adapter must admit this EXACT genuine Snapshot on IO before/after any await. */
    internal class Observation internal constructor(internal val identity: Any, internal val request: Long,
        internal val snapshot: NativeXperienceProfileGateway.Snapshot, internal val saved: XperienceImportNamespace.Saved?)
    enum class RecordKind { SUPPORTED, READ_ONLY, TOMBSTONE }
    data class RecordSummary(val handle: RecordHandle, val label: String?, val kind: RecordKind) {
        val editable: Boolean get() = kind == RecordKind.SUPPORTED
    }
    data class Detail(val document: XperienceCollections.Document, val label: String,
                      val bindings: Map<String, XperienceImportNamespace.Binding>)
    enum class Phase { IDLE, LOADING, READY, SAVING, LOCAL_ACCEPTED, ERROR, RETIRED, CLOSED }
    enum class Failure { UNAVAILABLE, STALE, STALE_REGISTER, READ_ONLY, MISSING, NAMESPACE_OCCUPIED,
        REJECTED, CANCELLED, SUPERSEDED }
    data class State(val phase: Phase = Phase.IDLE, val opening: Opening? = null,
                     val records: List<RecordSummary> = emptyList(), val failure: Failure? = null,
                     /** Local terminal correlation only; never a live opening or authority. */
                     internal val terminalOpening: Opening? = null)

    private class Source(val snapshot: NativeXperienceProfileGateway.Snapshot) {
        val identity = Any()
        val opening = Opening(identity)
        val target = snapshot.target
        var catalog: Catalog? = null // Consumer monitor only; the original snapshot never changes.
    }
    private data class Record(val saved: XperienceImportNamespace.Saved?, val kind: RecordKind)
    private data class Catalog(val fields: Set<String>, val records: Map<String, Record>,
                               val summaries: List<RecordSummary>)
    private sealed interface Action {
        data class Append(val document: XperienceCollections.Document, val label: String, val namespace: UUID,
                          val bindings: Map<String, XperienceImportNamespace.Binding>) : Action
        data class Replace(val saved: XperienceImportNamespace.Saved, val document: XperienceCollections.Document,
                           val label: String, val bindings: Map<String, XperienceImportNamespace.Binding>) : Action
        data class Delete(val saved: XperienceImportNamespace.Saved) : Action
        data class Denied(val failure: Failure) : Action
    }
    private data class Submission(val source: Source, val request: Long, val task: Job, val saving: State)

    private val monitor = Any()
    private val lifetime = SupervisorJob(parentScope.coroutineContext[Job])
    private val children = CoroutineScope(parentScope.coroutineContext + lifetime)
    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState.asStateFlow()
    private var generation = 0L
    private var active: Source? = null
    private var worker: Job? = null
    // Only the active original target may be deferred while publishing under the monitor.
    // Reentrant fresh openings are denied; the next public/publish exit drains this single slot.
    private var deferredRetirement: NativeXperienceProfileGateway.Target? = null
    // A recursive lifecycle signal can cancel only this Store's worker and its own lifetime.
    private val deferredCancellations = ArrayList<Job>(2)
    private var closed = false

    init { lifetime.invokeOnCompletion { close() } }

    /** A deliberate user opening. Capture is synchronous BEFORE any child launch/suspension.
     * No completion, retry or failed edit calls this method on the user's behalf. */
    fun open(): Opening? = openFrom { gateway.captureXperienceProfile() }

    /** Caller consumed an original cheap opening stage on IO; no fresh account capture here. */
    internal fun openCaptured(snapshot: NativeXperienceProfileGateway.Snapshot, callerCurrent: () -> Boolean): Opening? =
        openFrom(callerCurrent) { Result.success(snapshot) }

    private fun openFrom(callerCurrent: () -> Boolean = { true }, capture: () -> Result<NativeXperienceProfileGateway.Snapshot>): Opening? {
        if (Thread.holdsLock(monitor)) return null
        try {
        val cut = synchronized(monitor) {
            if (closed || !callerCurrent()) return null
            val previous = active to worker
            active = null; worker = null
            val request = ++generation
            mutableState.value = State(Phase.LOADING)
            Triple(request, previous.first, previous.second)
        }
        cancelWorker(cut.third)
        try { cut.second?.let { retireTarget(it.target) }; drainRetirements() }
        catch (cancelled: CancellationException) {
            openingFailure(cut.first, Failure.CANCELLED)
            throw cancelled
        } catch (_: Exception) {
            openingFailure(cut.first, Failure.UNAVAILABLE)
            return null
        }
        val captured = try { capture() }
        catch (cancelled: CancellationException) {
            openingFailure(cut.first, Failure.CANCELLED)
            throw cancelled
        } catch (_: Exception) {
            openingFailure(cut.first, Failure.UNAVAILABLE)
            return null
        }
        val snapshot = captured.getOrElse {
            if (it is Error) throw it
            if (it is CancellationException) { openingFailure(cut.first, Failure.CANCELLED); throw it }
            openingFailure(cut.first, Failure.UNAVAILABLE)
            return null
        }
        val source = Source(snapshot)
        val task = synchronized(monitor) {
            if (closed || generation != cut.first || !callerCurrent()) null else {
                active = source
                mutableState.value = State(Phase.LOADING, source.opening)
                if (!currentLocked(source, cut.first)) null else {
                    children.launch(io, start = CoroutineStart.LAZY) { load(source, cut.first) }.also { worker = it }
                }
            }
        }
        if (task == null) { retireTarget(source.target); return null }
        observeWorker(source, cut.first, task)
        task.start()
        return source.opening
        } finally { drainRetirements() }
    }

    internal fun observation(opening: Opening): Observation? = synchronized(monitor) {
        val source = active?.takeIf { it.identity === opening.identity && it.catalog != null && worker == null } ?: return null
        if (closed) null else Observation(source.identity, generation, source.snapshot, null)
    }
    internal fun observation(handle: RecordHandle): Observation? = synchronized(monitor) {
        val source = active?.takeIf { it.identity === handle.identity && worker == null } ?: return null
        val saved = source.catalog?.records?.get(handle.field)?.saved ?: return null
        if (closed) null else Observation(source.identity, generation, source.snapshot, saved)
    }
    internal fun observationIsCurrent(original: Observation): Boolean = synchronized(monitor) {
        !closed && active?.identity === original.identity && generation == original.request
    }

    /** Read-only display data; command methods still require the original opaque record handle. */
    fun detail(handle: RecordHandle): Detail? {
        if (Thread.holdsLock(monitor)) return null
        try {
        val original = synchronized(monitor) {
            val source = active?.takeIf { it.identity === handle.identity } ?: return null
            val saved = source.catalog?.records?.get(handle.field)?.saved ?: return null
            Triple(source, generation, saved)
        }
        val prepared = Detail(original.third.document, original.third.label,
            Collections.unmodifiableMap(original.third.bindings.toMap()))
        var result: Detail? = null
        val admitted = publish(original.first.snapshot) {
            synchronized(monitor) {
                if (currentLocked(original.first, original.second)) result = prepared
            }
        }
        if (!admitted) retireIfCurrent(original.first, original.second)
        return result
        } finally { drainRetirements() }
    }

    fun append(opening: Opening, document: XperienceCollections.Document, label: String,
               namespace: UUID = UUID.randomUUID(),
               bindings: Map<String, XperienceImportNamespace.Binding> = emptyMap(), caller: Job? = null): Job? =
        submit(opening.identity, caller) { source ->
            if (XperienceImportNamespace.field(namespace) in checkNotNull(source.catalog).fields) {
                Action.Denied(Failure.NAMESPACE_OCCUPIED) // Tombstone/future presence is never absence.
            } else Action.Append(document, label, namespace, bindings.toMap())
        }

    /** Refresh and label replacement use the exact Saved baseline shown by this handle. */
    fun replace(handle: RecordHandle, document: XperienceCollections.Document,
                label: String? = null,
                bindings: Map<String, XperienceImportNamespace.Binding>? = null, caller: Job? = null): Job? =
        submit(handle.identity, caller) { source ->
            val record = checkNotNull(source.catalog).records[handle.field]
            val saved = record?.saved
            when {
                record == null -> Action.Denied(Failure.MISSING)
                saved == null -> Action.Denied(Failure.READ_ONLY)
                else -> Action.Replace(saved, document, label ?: saved.label, (bindings ?: saved.bindings).toMap())
            }
        }

    fun rebind(handle: RecordHandle, bindings: Map<String, XperienceImportNamespace.Binding>, caller: Job? = null): Job? =
        submit(handle.identity, caller) { source ->
            val record = checkNotNull(source.catalog).records[handle.field]
            val saved = record?.saved
            when {
                record == null -> Action.Denied(Failure.MISSING)
                saved == null -> Action.Denied(Failure.READ_ONLY)
                else -> Action.Replace(saved, saved.document, saved.label, bindings.toMap())
            }
        }

    /** Confirmation must call with its original rendered handle. There is no Namespace.delete. */
    fun delete(handle: RecordHandle, caller: Job? = null): Job? = submit(handle.identity, caller) { source ->
        val record = checkNotNull(source.catalog).records[handle.field]
        when {
            record == null -> Action.Denied(Failure.MISSING)
            record.saved == null -> Action.Denied(Failure.READ_ONLY)
            else -> Action.Delete(record.saved)
        }
    }

    private fun submit(identity: Any, caller: Job?, select: (Source) -> Action): Job? {
        if (Thread.holdsLock(monitor)) return null
        try {
        val cancelled: Job?
        var retired: Source? = null
        val submission = synchronized(monitor) {
            val source = active?.takeIf { it.identity === identity } ?: return null
            if (closed) return null
            val request = ++generation // Every outcome of THIS opening cuts old publication.
            cancelled = worker
            if (worker != null || source.catalog == null) {
                // A new action cannot rebase a pending action. Retire it; a new opening is required.
                active = null; worker = null; retired = source
                mutableState.value = State(Phase.RETIRED, failure = Failure.SUPERSEDED, terminalOpening = source.opening)
                null
            } else {
                val action = select(source) // Immutable Saved/field/namespace/input selection before launch.
                // Original controller cancellation owns this actual child BEFORE it can start.
                // Store close still cancels its worker explicitly, regardless of parent choice.
                val task = children.launch(io + (caller ?: lifetime), start = CoroutineStart.LAZY) { execute(source, request, action) }
                worker = task
                Submission(source, request, task, State(Phase.SAVING, source.opening, checkNotNull(source.catalog).summaries))
            }
        }
        cancelWorker(cancelled)
        retired?.let { retireTarget(it.target) }
        if (submission == null) return null
        observeWorker(submission.source, submission.request, submission.task)
        var permitted = false
        val admitted = try { publish(submission.source.snapshot) {
            synchronized(monitor) {
                if (currentLocked(submission.source, submission.request) && worker === submission.task) {
                    mutableState.value = submission.saving
                    permitted = currentLocked(submission.source, submission.request) && worker === submission.task
                }
            }
        } } catch (cancelled: CancellationException) {
            cancelWorker(submission.task)
            retireIfCurrent(submission.source, submission.request)
            throw cancelled
        }
        if (permitted) submission.task.start()
        else {
            cancelWorker(submission.task)
            if (!admitted) retireIfCurrent(submission.source, submission.request)
        }
        return submission.task.takeIf { permitted }
        } finally { drainRetirements() }
    }

    private suspend fun load(source: Source, request: Long) {
        try {
            currentCoroutineContext().ensureActive()
            val catalog = project(source) // Only the original immutable snapshot, on the owned IO child.
            currentCoroutineContext().ensureActive()
            if (!current(source, request)) return
            val admitted = publish(source.snapshot) {
                synchronized(monitor) {
                    if (currentLocked(source, request)) {
                        source.catalog = catalog; worker = null
                        mutableState.value = State(Phase.READY, source.opening, catalog.summaries)
                    }
                }
            }
            if (!admitted) retireIfCurrent(source, request)
        } catch (cancelled: CancellationException) {
            if (!lifetime.isActive) close() else retireIfCurrent(source, request)
            throw cancelled
        } catch (_: XperienceCollections.Rejected) {
            fail(source, request, Failure.REJECTED)
        } catch (_: Exception) {
            fail(source, request, Failure.UNAVAILABLE)
        }
    }

    private suspend fun execute(source: Source, request: Long, action: Action) {
        try {
            currentCoroutineContext().ensureActive()
            if (!current(source, request)) return
            if (action is Action.Denied) { fail(source, request, action.failure); return }
            if (!gateway.xperienceTargetIsCurrent(source.target)) { retireIfCurrent(source, request); return }
            val result = when (action) {
                is Action.Append -> gateway.writeXperience(source.target,
                    XperienceImportNamespace.append(action.document, action.label, action.namespace, action.bindings))
                is Action.Replace -> gateway.writeXperience(source.target,
                    action.saved.replacement(action.document, action.label, action.bindings))
                is Action.Delete -> gateway.deleteXperience(source.target, action.saved)
                is Action.Denied -> error("Denied action escaped admission")
            }
            currentCoroutineContext().ensureActive() // A late result cannot publish after any new action.
            if (!current(source, request)) return
            val acknowledged = result.getOrElse {
                if (it is Error) throw it
                if (it is CancellationException) throw it
                val reason = if (it is XperienceCollections.Rejected && it.reason == XperienceCollections.Failure.STALE_REGISTER)
                    Failure.STALE_REGISTER else Failure.UNAVAILABLE
                fail(source, request, reason)
                return
            }
            if (acknowledged.target !== source.target) { retireIfCurrent(source, request); return }
            var accepted = false
            val admitted = publish(acknowledged) {
                synchronized(monitor) {
                    if (currentLocked(source, request)) {
                        active = null; worker = null; generation++
                        mutableState.value = State(Phase.LOCAL_ACCEPTED, terminalOpening = source.opening)
                        accepted = true
                    }
                }
            }
            if (accepted) retireTarget(source.target)
            else if (!admitted) retireIfCurrent(source, request)
        } catch (cancelled: CancellationException) {
            if (!lifetime.isActive) close() else retireIfCurrent(source, request)
            throw cancelled
        } catch (_: XperienceCollections.Rejected) {
            fail(source, request, Failure.REJECTED)
        } catch (_: Exception) {
            fail(source, request, Failure.UNAVAILABLE)
        }
    }

    private suspend fun project(source: Source): Catalog {
        val observations = XperienceImportNamespace.readIsolated(source.snapshot.registers())
        currentCoroutineContext().ensureActive()
        val records = linkedMapOf<String, Record>()
        val summaries = ArrayList<RecordSummary>()
        for (observation in observations) {
            currentCoroutineContext().ensureActive()
            val record = when (observation) {
                is XperienceImportNamespace.Observation.Supported -> Record(observation.saved, RecordKind.SUPPORTED)
                is XperienceImportNamespace.Observation.Tombstone -> Record(null, RecordKind.TOMBSTONE)
                is XperienceImportNamespace.Observation.ReadOnly -> Record(null, RecordKind.READ_ONLY)
            }
            records[observation.field] = record
            summaries += RecordSummary(RecordHandle(source.identity, observation.field), record.saved?.label, record.kind)
        }
        return Catalog(records.keys.toSet(), records.toMap(), Collections.unmodifiableList(summaries))
    }

    /** All gateway calls are OUTSIDE the consumer monitor. Native publication callbacks below
     * perform only local identity/generation checks and publication; never gateway/native reads. */
    private fun fail(source: Source, request: Long, failure: Failure) {
        if (!current(source, request)) return
        val admitted = publish(source.snapshot) {
            synchronized(monitor) {
                if (currentLocked(source, request)) {
                    worker = null
                    mutableState.value = State(Phase.ERROR, source.opening, source.catalog?.summaries.orEmpty(), failure)
                }
            }
        }
        if (!admitted) retireIfCurrent(source, request)
    }
    private fun currentLocked(source: Source, request: Long) = !closed && active === source && generation == request
    private fun current(source: Source, request: Long) = synchronized(monitor) { currentLocked(source, request) }
    /** Register OUTSIDE the monitor before start. Terminal cleanup cannot depend on body entry
     * or normal return; every still-owned completion retires the original worker/target. */
    private fun observeWorker(source: Source, request: Long, task: Job) {
        check(!Thread.holdsLock(monitor))
        task.invokeOnCompletion { cause ->
            synchronized(monitor) {
                if (currentLocked(source, request) && worker === task) {
                    active = null; worker = null; generation++
                    deferRetirementLocked(source.target)
                    mutableState.value = State(Phase.RETIRED,
                        failure = if (cause is CancellationException) Failure.CANCELLED else null,
                        terminalOpening = source.opening)
                }
            }
            drainRetirements()
        }
        drainRetirements()
    }
    private fun openingFailure(request: Long, failure: Failure) = synchronized(monitor) {
        if (!closed && generation == request) mutableState.value = State(Phase.ERROR, failure = failure)
    }
    private fun publish(snapshot: NativeXperienceProfileGateway.Snapshot, publication: () -> Unit): Boolean =
        try { gateway.publishXperienceIfCurrent(snapshot, publication) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { false } // Admission failure retires; Error/OOM are never swallowed.
        finally { drainRetirements() }
    private fun retireIfCurrent(source: Source, request: Long) {
        val cancelled = synchronized(monitor) {
            if (!currentLocked(source, request)) return
            val previous = worker
            active = null; worker = null; generation++
            mutableState.value = State(Phase.RETIRED, failure = Failure.STALE, terminalOpening = source.opening)
            previous
        }
        cancelWorker(cancelled)
        retireTarget(source.target)
    }

    private fun deferRetirementLocked(target: NativeXperienceProfileGateway.Target) {
        check(Thread.holdsLock(monitor))
        check(deferredRetirement == null || deferredRetirement === target) { "Overlapping deferred target retirement" }
        deferredRetirement = target
    }
    /** All retirement paths share this exact-original-target lane, including recursive close,
     * invalidation and completion invoked inline by a StateFlow publication. Never call native
     * while this thread owns the consumer monitor; fresh native reads are denied there as well. */
    private fun retireTarget(target: NativeXperienceProfileGateway.Target) {
        if (Thread.holdsLock(monitor)) { deferRetirementLocked(target); return }
        drainRetirements()
        gateway.retireXperienceTarget(target)
    }
    private fun cancelWorker(task: Job?) {
        if (task == null) return
        if (Thread.holdsLock(monitor)) {
            if (deferredCancellations.none { it === task }) {
                check(deferredCancellations.size < 2) { "Overlapping deferred worker cancellation" }
                deferredCancellations += task
            }
            return
        }
        task.cancel()
        drainRetirements()
    }
    private fun drainRetirements() {
        if (Thread.holdsLock(monitor)) return
        while (true) {
            val task = synchronized(monitor) {
                if (deferredCancellations.isEmpty()) null else deferredCancellations.removeAt(0)
            }
            if (task != null) { task.cancel(); continue }
            val target = synchronized(monitor) {
                deferredRetirement.also { deferredRetirement = null }
            } ?: return
            gateway.retireXperienceTarget(target)
        }
    }

    /** Signal-only future caller hook. It does not capture a successor or invent a change Flow. */
    fun invalidate() { try { retire(closing = false) } finally { drainRetirements() } }
    override fun close() { try { retire(closing = true) } finally { drainRetirements() } }
    private fun retire(closing: Boolean) {
        val previous = synchronized(monitor) {
            if (closed) return
            if (closing) closed = true
            generation++
            val result = active to worker
            active = null; worker = null
            mutableState.value = State(if (closing) Phase.CLOSED else Phase.RETIRED, terminalOpening = result.first?.opening)
            result
        }
        cancelWorker(previous.second)
        previous.first?.let { retireTarget(it.target) }
        if (closing) cancelWorker(lifetime)
    }

}
