package com.vortx.android.ui.profilepicker

import com.vortx.android.backup.accountfiles.AccountBackupDocumentFailure
import com.vortx.android.diagnostics.DiagnosticShareOutcome
import com.vortx.android.sync.AccountBackupFile
import com.vortx.android.sync.PickerAccountSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.Closeable
import java.util.UUID

/** No keys, bearer, account bytes or provider URI are part of presentation/saved state. */
internal data class PickerToolsState(
    val open: Boolean = false,
    val routeGeneration: Long = 0L,
    val presentationId: String? = null,
    val phase: PickerToolsPhase = PickerToolsPhase.IDLE,
    val destination: PickerToolsDestinationRequest? = null,
    val repairInput: PickerToolsRepairInputRequest? = null,
    val repairReview: PickerToolsRepairReview? = null,
    val message: String? = null,
) { val busy: Boolean get() = phase != PickerToolsPhase.IDLE }
internal enum class PickerToolsPhase {
    IDLE, DOWNLOADING, CHOOSING_REPAIR_INPUT, PREPARING_REPAIR, REVIEWING_REPAIR,
    AWAITING_DESTINATION, SAVING, SHARING_DIAGNOSTICS, CANCELLING,
}
@ConsistentCopyVisibility
internal data class PickerToolsAttachment internal constructor(val routeId: String, val attachmentId: String)
@ConsistentCopyVisibility
internal data class PickerToolsDestinationRequest internal constructor(val routeId: String, val operationId: String)
@ConsistentCopyVisibility
internal data class PickerToolsRepairInputRequest internal constructor(val routeId: String, val operationId: String)
internal data class PickerToolsRepairReview(
    val request: PickerToolsRepairInputRequest,
    val profileCount: Int,
    val nativeSchema: Int,
    val byteCount: Int,
)

/** Captured when Tools renders, never acquired by a queued action at click time. */
internal class PickerToolsActionGrant internal constructor(
    internal val attachment: PickerToolsAttachment,
    internal val presentationId: String,
    internal val original: PickerAccountSnapshot?,
    internal val revision: Long,
    internal val marker: Any,
    internal val routeIdentity: Any,
) { override fun toString() = "PickerToolsActionGrant" }

/** This is an injectable boundary, not replacement account authority. Production delegates to the manager. */
internal interface PickerToolsAccounts {
    val authorityRevision: Long
    val sessionMarker: Any
    val changes: Flow<Unit>
    fun capture(): PickerAccountSnapshot?
    fun isCurrent(original: PickerAccountSnapshot): Boolean
    suspend fun download(original: PickerAccountSnapshot): ByteArray
}
internal interface PickerToolsPreparedBackup : Closeable {
    val byteCount: Int
    val sha256: String
}
internal data class PickerToolsSaveReceipt(val byteCount: Int, val sha256: String)
internal fun interface PickerToolsBackupPreparer {
    suspend fun prepare(bytes: ByteArray, isCurrent: () -> Boolean): PickerToolsPreparedBackup
}
internal interface PickerToolsSelectedBackup : Closeable {
    fun copyBytes(): ByteArray
    suspend fun prepareRepairedCopy(bytes: ByteArray, isCurrent: () -> Boolean): PickerToolsPreparedBackup
}
internal interface PickerToolsRepairExport : Closeable {
    val profileCount: Int
    val nativeSchema: Int
    val byteCount: Int
    val sha256: String
    fun remainingMillis(): Long
    fun canSave(): Boolean
    fun take(): ByteArray
}
internal fun interface PickerToolsRepairPreparer {
    suspend fun prepare(original: PickerAccountSnapshot, bytes: ByteArray, isCurrent: () -> Boolean): PickerToolsRepairExport
}
internal enum class PickerToolsFailure(val message: String) {
    SAVE_FAILED("The backup could not be saved safely. A new complete or incomplete copy may remain in the selected folder."),
    REPAIR_FAILED("The backup could not be repaired safely. Your original file was not written by this repair."),
    REPAIR_BUSY("Finish or cancel the other backup repair before starting a new one."),
    ALREADY_REPAIRED("This backup is already repaired. No new copy was created."),
    REPAIR_OWNER_UNAVAILABLE("The current cloud backup could not establish the signed-in owner. Your file is unchanged."),
    REPAIR_ACCOUNT_UNSUPPORTED("The current account backup needs recovery before this repair can verify its owner. Your file is unchanged."),
    REPAIR_EXPIRED("This repair preview expired. Choose the backup again."),
    INVALID_REPAIR_FILE("This backup could not be repaired safely for the signed-in account. Your file is unchanged."),
    NO_FILE_PROVIDER("This device has no compatible file provider. Install or enable one, then try again."),
    DESTINATION_UNAVAILABLE("The folder could not be opened. Choose a folder with write access and try again."),
    WRONG_RECEIPT("The saved copy could not be verified. A new complete or incomplete copy may remain in the selected folder."),
}
internal class PickerToolsException(val failure: PickerToolsFailure) : Exception(failure.message)

/** Shared by the activity holder across manager replacement; retired provider I/O still owns it. */
internal class PickerToolsWorkGate {
    private val lock = Any()
    private var owner: Any? = null
    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()
    fun reserve(expected: Any): Boolean = synchronized(lock) {
        if (owner != null) false else { owner = expected; _busy.value = true; true }
    }
    fun release(expected: Any) = synchronized(lock) {
        if (owner === expected) { owner = null; _busy.value = false }
    }
}

/**
 * One activity-retained slot per manager. Cancellation revokes admission immediately, but never frees the
 * slot before its coroutine actually returns. A provider/transport ignoring cancellation therefore cannot
 * overlap a successor GET/save. Neither our lock nor a manager monitor is held over blocking I/O.
 */
internal class ProfilePickerToolsController(
    private val accounts: PickerToolsAccounts,
    private val preparer: PickerToolsBackupPreparer,
    private val scope: CoroutineScope,
    private val workGate: PickerToolsWorkGate = PickerToolsWorkGate(),
    private val repairPreparer: PickerToolsRepairPreparer? = null,
) : Closeable {
    private val lock = Any()
    private var attachment: PickerToolsAttachment? = null
    private class RouteAuthority(val routeId: String, val original: PickerAccountSnapshot?, val revision: Long, val marker: Any)
    private var routeAuthority: RouteAuthority? = null
    private var slot: Slot? = null
    private var closed = false
    private var publicationAuthority: Pair<Long, Any>? = null
    private val _state = MutableStateFlow(PickerToolsState())
    val state: StateFlow<PickerToolsState> = _state.asStateFlow()
    val repairAvailable: Boolean get() = repairPreparer != null
    private sealed interface Destination {
        class Save(val write: suspend (PickerToolsPreparedBackup, () -> Boolean) -> PickerToolsSaveReceipt) : Destination
        class Refused(val failure: PickerToolsFailure?) : Destination
    }
    private sealed interface RepairSelection {
        class Read(val read: suspend (() -> Boolean) -> PickerToolsSelectedBackup) : RepairSelection
        class Refused(val failure: PickerToolsFailure?) : RepairSelection
    }
    private class Slot(
        val request: PickerToolsDestinationRequest,
        val presentationId: String,
        val routeIdentity: Any,
        val original: PickerAccountSnapshot?,
        val revision: Long,
        val marker: Any,
        val diagnosticPolicy: (() -> Boolean)? = null,
        val repair: PickerToolsRepairInputRequest? = null,
    ) {
        @Volatile var revoked = false
        @Volatile var entered = false
        var job: Job? = null
        var destinationLaunched = false
        val destination = CompletableDeferred<Destination>()
        var repairInputLaunched = false
        val repairSelection = CompletableDeferred<RepairSelection>()
        val repairConfirmation = CompletableDeferred<Boolean>()
    }
    private val observer = scope.launch(start = CoroutineStart.UNDISPATCHED) {
        accounts.changes.collect {
            val route = synchronized(lock) { routeAuthority }
            if (route != null && !routeCurrent(route)) retireRoute(route)
            val original = synchronized(lock) { slot }
            if (original != null && !authorityCurrent(original)) revoke(original)
            synchronized(lock) {
                val published = publicationAuthority
                if (published != null && (accounts.authorityRevision != published.first || accounts.sessionMarker != published.second)) {
                    publicationAuthority = null
                    _state.value = _state.value.copy(message = null)
                }
            }
        }
    }

    private val gateObserver = scope.launch(start = CoroutineStart.UNDISPATCHED) {
        workGate.busy.collect { busy ->
            synchronized(lock) {
                if (!closed && slot == null && _state.value.open)
                    _state.value = _state.value.copy(phase = if (busy) PickerToolsPhase.CANCELLING else PickerToolsPhase.IDLE)
            }
        }
    }

    /** Captured once per picker route, before rendering either Tools entry or menu callbacks.
     * An unavailable capture never gains file authority later; diagnostics still use the route/policy. */
    private fun captureRouteAuthority(): RouteAuthority {
        val revision = accounts.authorityRevision
        val marker = accounts.sessionMarker
        val original = accounts.capture()
        return RouteAuthority(UUID.randomUUID().toString(), original, revision, marker)
    }
    private fun routeCurrent(route: RouteAuthority): Boolean =
        accounts.authorityRevision == route.revision && accounts.sessionMarker == route.marker &&
            (route.original?.let(accounts::isCurrent) ?: true)

    /** Rotation retains original route authority but replaces attachment/callback identity. */
    fun attachPicker(): PickerToolsAttachment = synchronized(lock) {
        check(!closed)
        val route = routeAuthority ?: captureRouteAuthority().also { routeAuthority = it }
        PickerToolsAttachment(route.routeId, UUID.randomUUID().toString()).also { attachment = it }
    }
    private fun retireRoute(expected: RouteAuthority) {
        val cancel = synchronized(lock) {
            if (routeAuthority !== expected) return
            routeAuthority = null; attachment = null; publicationAuthority = null
            val generation = _state.value.routeGeneration + 1L
            _state.value = PickerToolsState(routeGeneration = generation,
                phase = if (slot == null) PickerToolsPhase.IDLE else PickerToolsPhase.CANCELLING)
            slot?.takeIf { it.routeIdentity === expected }?.also { it.revoked = true }
        }
        cancel?.job?.cancel()
    }
    fun detachPicker(expected: PickerToolsAttachment, changingConfigurations: Boolean) {
        if (changingConfigurations) return
        val route = synchronized(lock) { routeAuthority?.takeIf { attachment == expected } } ?: return
        retireRoute(route)
    }
    fun open(expected: PickerToolsAttachment) {
        val route = synchronized(lock) { routeAuthority?.takeIf { attachment == expected } } ?: return
        if (!routeCurrent(route)) { retireRoute(route); return }
        synchronized(lock) {
            if (!closed && attachment == expected && routeAuthority === route)
                _state.value = _state.value.copy(open = true,
                    presentationId = _state.value.presentationId ?: UUID.randomUUID().toString(),
                    phase = if (slot == null && workGate.busy.value) PickerToolsPhase.CANCELLING else _state.value.phase)
        }
    }
    /** The host captures this value while rendering. No onClick calls this method or captures an account. */
    fun renderedActions(expected: PickerToolsAttachment): PickerToolsActionGrant? = synchronized(lock) {
        val route = routeAuthority ?: return null
        val presentation = _state.value.presentationId ?: return null
        if (closed || attachment != expected || !_state.value.open) return null
        PickerToolsActionGrant(expected, presentation, route.original, route.revision, route.marker, route)
    }
    private fun currentGrant(expected: PickerToolsActionGrant): Boolean {
        val route = synchronized(lock) {
            routeAuthority?.takeIf { it === expected.routeIdentity && attachment == expected.attachment &&
                _state.value.open && _state.value.presentationId == expected.presentationId }
        } ?: return false
        if (!routeCurrent(route)) { retireRoute(route); return false }
        return true
    }
    fun closeTools(expected: PickerToolsAttachment) {
        val cancel = synchronized(lock) {
            if (attachment != expected) return
            publicationAuthority = null
            _state.value = _state.value.copy(open = false, presentationId = null, destination = null, repairInput = null, repairReview = null, message = null,
                phase = if (slot == null) PickerToolsPhase.IDLE else PickerToolsPhase.CANCELLING)
            slot?.also { it.revoked = true }
        }
        cancel?.job?.cancel()
    }
    private fun authorityCurrent(original: Slot): Boolean =
        accounts.authorityRevision == original.revision && accounts.sessionMarker == original.marker &&
            (original.original?.let(accounts::isCurrent) ?: true)
    private fun current(original: Slot): Boolean {
        val own = synchronized(lock) {
            !closed && slot === original && !original.revoked && _state.value.open &&
                routeAuthority === original.routeIdentity && attachment?.routeId == original.request.routeId &&
                _state.value.presentationId == original.presentationId
        }
        return own && authorityCurrent(original) &&
            (original.diagnosticPolicy?.let { runCatching(it).getOrDefault(false) } ?: true)
    }
    private suspend fun requireCurrent(original: Slot) {
        currentCoroutineContext().ensureActive()
        if (!current(original)) throw CancellationException("Picker Tools operation retired")
    }
    private fun revoke(original: Slot) {
        val job = synchronized(lock) {
            if (slot !== original) return
            original.revoked = true
            _state.value = _state.value.copy(phase = PickerToolsPhase.CANCELLING, destination = null, repairInput = null, repairReview = null, message = null)
            original.job
        }
        job?.cancel()
    }
    private fun admit(expected: PickerToolsActionGrant, diagnosticPolicy: (() -> Boolean)? = null,
        repair: Boolean = false): Slot? {
        if (!currentGrant(expected)) return null
        return synchronized(lock) {
            if (closed || attachment != expected.attachment || routeAuthority !== expected.routeIdentity ||
                !_state.value.open || _state.value.presentationId != expected.presentationId || slot != null) return null
            // All authority comes from the immutable rendered grant, never a new capture at click time.
            val request = PickerToolsDestinationRequest(expected.attachment.routeId, UUID.randomUUID().toString())
            val candidate = Slot(request, expected.presentationId, expected.routeIdentity, expected.original,
                expected.revision, expected.marker, diagnosticPolicy,
                if (repair) PickerToolsRepairInputRequest(request.routeId, request.operationId) else null)
            if (!workGate.reserve(candidate)) {
                _state.value = _state.value.copy(phase = PickerToolsPhase.CANCELLING, message = null)
                null
            } else candidate.also { publicationAuthority = null; slot = it }
        }
    }
    private fun phase(original: Slot, value: PickerToolsPhase, destination: PickerToolsDestinationRequest? = null,
        repairReview: PickerToolsRepairReview? = null) {
        if (!current(original)) return
        synchronized(lock) {
            if (slot === original && !original.revoked && attachment?.routeId == original.request.routeId)
                _state.value = _state.value.copy(phase = value, destination = destination,
                    repairInput = original.repair.takeIf { value == PickerToolsPhase.CHOOSING_REPAIR_INPUT },
                    repairReview = repairReview, message = null)
        }
    }
    private fun drain(original: Slot, message: String?) {
        synchronized(lock) {
            if (slot !== original) return
            // Recheck under the same publication lock as close/revoke/route replacement. A later
            // authority event also clears this safe status after the operation slot has drained.
            val publish = current(original)
            publicationAuthority = if (publish) original.revision to original.marker else null
            slot = null
            workGate.release(original)
            _state.value = _state.value.copy(phase = PickerToolsPhase.IDLE, destination = null, repairInput = null, repairReview = null,
                message = if (publish && attachment?.routeId == original.request.routeId) message else null)
        }
    }
    private fun launch(original: Slot, work: suspend () -> String?) {
        val job = scope.launch(start = CoroutineStart.LAZY) {
            original.entered = true
            var message: String? = null
            try { requireCurrent(original); message = work(); requireCurrent(original) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: AccountBackupFile.Failure) { message = AccountBackupFile.Failure(failure.reason).message }
            catch (failure: AccountBackupDocumentFailure) { message = failure.message }
            catch (failure: PickerToolsException) { message = failure.failure.message }
            catch (_: Exception) {
                message = if (original.repair != null && _state.value.phase != PickerToolsPhase.SAVING)
                    PickerToolsFailure.REPAIR_FAILED.message else PickerToolsFailure.SAVE_FAILED.message
            }
            finally {
                // This runs after the actual suspend/provider invocation drained, including a
                // NonCancellable provider call. A stale result never publishes into a new route.
                drain(original, message)
            }
        }
        synchronized(lock) { original.job = job }
        // A LAZY job cancelled before entry has no coroutine finally block and owns no I/O. Release
        // that unstarted slot from completion; started work alone owns its real-return drain.
        job.invokeOnCompletion { if (!original.entered) drain(original, null) }
        job.start()
        if (original.revoked || closed) job.cancel()
    }
    fun download(expected: PickerToolsActionGrant) {
        if (!requireFileGrant(expected, "downloading")) return
        val original = admit(expected) ?: return
        phase(original, PickerToolsPhase.DOWNLOADING)
        launch(original) {
            var raw: ByteArray? = null
            var prepared: PickerToolsPreparedBackup? = null
            try {
                requireCurrent(original)
                raw = accounts.download(checkNotNull(original.original)) // Production calls the real original-owned manager GET.
                requireCurrent(original)
                val ready = preparer.prepare(checkNotNull(raw)) { current(original) }
                prepared = ready
                raw.fill(0); raw = null
                requireCurrent(original)
                save(original, ready, "Download cancelled.", "Encrypted account backup saved and read back successfully.")
            } finally { raw?.fill(0); prepared?.close() }
        }
    }
    private fun requireFileGrant(expected: PickerToolsActionGrant, action: String): Boolean {
        if (!currentGrant(expected)) return false
        if (expected.original?.account != null) return true
        synchronized(lock) {
            if (attachment == expected.attachment && routeAuthority === expected.routeIdentity && slot == null &&
                _state.value.open && _state.value.presentationId == expected.presentationId)
                _state.value = _state.value.copy(message =
                    "Sign in with the separate Sign in control, then open Tools again before $action an account backup.")
        }
        return false
    }

    private suspend fun save(original: Slot, ready: PickerToolsPreparedBackup, cancelled: String, saved: String,
        maySave: () -> Boolean = { true }): String {
        phase(original, PickerToolsPhase.AWAITING_DESTINATION, original.request)
        return when (val destination = original.destination.await()) {
            is Destination.Refused -> {
                destination.failure?.let { throw PickerToolsException(it) }
                cancelled
            }
            is Destination.Save -> {
                requireCurrent(original)
                phase(original, PickerToolsPhase.SAVING)
                if (!maySave()) throw CancellationException("Backup export owner retired")
                val receipt = destination.write(ready) { current(original) && maySave() }
                requireCurrent(original)
                if (!maySave()) throw CancellationException("Backup export owner retired")
                if (receipt.byteCount != ready.byteCount || receipt.sha256 != ready.sha256)
                    throw PickerToolsException(PickerToolsFailure.WRONG_RECEIPT)
                saved
            }
        }
    }

    fun repair(expected: PickerToolsActionGrant) {
        val prepare = repairPreparer ?: return
        if (!requireFileGrant(expected, "repairing")) return
        val original = admit(expected, repair = true) ?: return
        phase(original, PickerToolsPhase.CHOOSING_REPAIR_INPUT)
        launch(original) {
            val selected = when (val selection = original.repairSelection.await()) {
                is RepairSelection.Refused -> {
                    selection.failure?.let { throw PickerToolsException(it) }
                    return@launch "Repair cancelled."
                }
                is RepairSelection.Read -> {
                    requireCurrent(original)
                    phase(original, PickerToolsPhase.PREPARING_REPAIR)
                    selection.read { current(original) }
                }
            }
            selected.use { source ->
                requireCurrent(original)
                val raw = source.copyBytes()
                val export = try { prepare.prepare(checkNotNull(original.original), raw) { current(original) } }
                finally { raw.fill(0) }
                export.use { candidate ->
                    requireCurrent(original)
                    val review = PickerToolsRepairReview(checkNotNull(original.repair), candidate.profileCount,
                        candidate.nativeSchema, candidate.byteCount)
                    phase(original, PickerToolsPhase.REVIEWING_REPAIR, repairReview = review)
                    when (withTimeoutOrNull(candidate.remainingMillis()) { original.repairConfirmation.await() }) {
                        true -> Unit
                        false -> return@launch "Repair cancelled. Your original backup is unchanged."
                        null -> throw PickerToolsException(PickerToolsFailure.REPAIR_EXPIRED)
                    }
                    requireCurrent(original)
                    val bytes = candidate.take()
                    val ready = try { source.prepareRepairedCopy(bytes) { current(original) && candidate.canSave() } }
                    finally { bytes.fill(0) }
                    ready.use {
                        requireCurrent(original)
                        if (ready.byteCount != candidate.byteCount || ready.sha256 != candidate.sha256)
                            throw PickerToolsException(PickerToolsFailure.WRONG_RECEIPT)
                        save(original, ready, "Save cancelled. Your original backup is unchanged.",
                            "Repaired encrypted backup saved and read back successfully.", candidate::canSave)
                    }
                }
            }
        }
    }

    fun claimRepairInputLaunch(request: PickerToolsRepairInputRequest): Boolean {
        val original = synchronized(lock) { slot?.takeIf { it.repair == request } } ?: return false
        if (!current(original)) { revoke(original); return false }
        return synchronized(lock) {
            if (slot !== original || original.revoked || original.repairInputLaunched ||
                _state.value.repairInput != request || original.repairSelection.isCompleted) false
            else { original.repairInputLaunched = true; true }
        }
    }

    fun repairInputReturned(request: PickerToolsRepairInputRequest,
        read: suspend (() -> Boolean) -> PickerToolsSelectedBackup) =
        completeRepairSelection(request, RepairSelection.Read(read))

    fun repairInputRefused(request: PickerToolsRepairInputRequest, failure: PickerToolsFailure? = null) =
        completeRepairSelection(request, RepairSelection.Refused(failure))

    private fun completeRepairSelection(request: PickerToolsRepairInputRequest, selection: RepairSelection) {
        val original = synchronized(lock) { slot?.takeIf { it.repair == request } } ?: return
        if (!current(original)) { revoke(original); return }
        synchronized(lock) {
            if (slot === original && !original.revoked && original.repairInputLaunched && _state.value.repairInput == request)
                original.repairSelection.complete(selection)
        }
    }

    fun confirmRepair(expected: PickerToolsActionGrant, request: PickerToolsRepairInputRequest, approved: Boolean) {
        if (!currentGrant(expected)) return
        synchronized(lock) {
            val original = slot?.takeIf { it.repair == request } ?: return
            if (!original.revoked && original.routeIdentity === expected.routeIdentity &&
                attachment == expected.attachment && _state.value.repairReview?.request == request)
                original.repairConfirmation.complete(approved)
        }
    }

    /** Rotation and repeated clicks cannot launch another selector for an already-presented request. */
    fun claimDestinationLaunch(request: PickerToolsDestinationRequest): Boolean {
        val original = synchronized(lock) { slot?.takeIf { it.request == request } } ?: return false
        if (!current(original)) { revoke(original); return false }
        return synchronized(lock) {
            if (slot !== original || original.revoked || original.destinationLaunched || original.destination.isCompleted ||
                _state.value.destination != request) false
            else { original.destinationLaunched = true; true }
        }
    }
    /** The callback carries the original immutable request; it never looks up a newer slot's request. */
    fun destinationReturned(request: PickerToolsDestinationRequest,
        write: suspend (PickerToolsPreparedBackup, () -> Boolean) -> PickerToolsSaveReceipt) {
        val original = synchronized(lock) { slot?.takeIf { it.request == request } } ?: return
        if (!current(original)) { revoke(original); return }
        synchronized(lock) {
            if (slot === original && !original.revoked && _state.value.destination == request &&
                (original.repair == null || original.destinationLaunched))
                original.destination.complete(Destination.Save(write))
        }
    }
    fun destinationRefused(request: PickerToolsDestinationRequest, failure: PickerToolsFailure? = null) {
        val original = synchronized(lock) { slot?.takeIf { it.request == request } } ?: return
        if (!current(original)) { revoke(original); return }
        synchronized(lock) {
            if (slot === original && !original.revoked && _state.value.destination == request &&
                (original.repair == null || original.destinationLaunched))
                original.destination.complete(Destination.Refused(failure))
        }
    }
    fun diagnostics(expected: PickerToolsActionGrant, policy: () -> Boolean,
        share: suspend (() -> Boolean) -> DiagnosticShareOutcome) {
        if (!currentGrant(expected)) return
        if (!runCatching(policy).getOrDefault(false)) {
            synchronized(lock) {
                if (attachment == expected.attachment && routeAuthority === expected.routeIdentity && slot == null &&
                    _state.value.open && _state.value.presentationId == expected.presentationId)
                    _state.value = _state.value.copy(message = DiagnosticShareOutcome.BLOCKED.message)
            }
            return
        }
        val original = admit(expected, diagnosticPolicy = policy) ?: return
        phase(original, PickerToolsPhase.SHARING_DIAGNOSTICS)
        launch(original) {
            requireCurrent(original)
            // shareDiagnosticLog checks this mandatory original-route/current-policy callback before
            // and after staging, immediately before handing its private file to another activity.
            val result = share { current(original) }
            requireCurrent(original)
            result.message ?: "Diagnostic log shared."
        }
    }
    override fun close() {
        val cancel = synchronized(lock) {
            closed = true; attachment = null; routeAuthority = null; publicationAuthority = null; _state.value = PickerToolsState()
            slot?.also { it.revoked = true }
        }
        observer.cancel(); gateObserver.cancel()
        cancel?.job?.cancel()
    }
}
