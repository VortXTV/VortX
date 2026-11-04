package com.vortx.android.ui.viewmodel

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.vortx.android.backup.accountfiles.AccountBackupBytes
import com.vortx.android.backup.accountfiles.AccountBackupCopyKind
import com.vortx.android.backup.accountfiles.AccountBackupDocuments
import com.vortx.android.sync.AccountFileRepairFailure
import com.vortx.android.sync.AccountFileRepairReason
import com.vortx.android.sync.AccountFileRestoreExternalExclusion
import com.vortx.android.sync.PickerAccountSnapshot
import com.vortx.android.sync.VortXSyncManager
import com.vortx.android.ui.profilepicker.PickerToolsAccounts
import com.vortx.android.ui.profilepicker.PickerToolsActionGrant
import com.vortx.android.ui.profilepicker.PickerToolsBackupPreparer
import com.vortx.android.ui.profilepicker.PickerToolsDestinationRequest
import com.vortx.android.ui.profilepicker.PickerToolsException
import com.vortx.android.ui.profilepicker.PickerToolsFailure
import com.vortx.android.ui.profilepicker.PickerToolsPreparedBackup
import com.vortx.android.ui.profilepicker.PickerToolsRepairExport
import com.vortx.android.ui.profilepicker.PickerToolsRepairInputRequest
import com.vortx.android.ui.profilepicker.PickerToolsRepairPreparer
import com.vortx.android.ui.profilepicker.PickerToolsRestoreActions
import com.vortx.android.ui.profilepicker.PickerToolsRestoreCandidate
import com.vortx.android.ui.profilepicker.PickerToolsRestoreInput
import com.vortx.android.ui.profilepicker.PickerToolsRestoreInputRequest
import com.vortx.android.ui.profilepicker.PickerToolsRestoreSelection
import com.vortx.android.ui.profilepicker.PickerToolsSelectedBackup
import com.vortx.android.ui.profilepicker.PickerToolsSaveReceipt
import com.vortx.android.ui.profilepicker.PickerToolsWorkGate
import com.vortx.android.ui.profilepicker.ProfilePickerToolsController
import com.vortx.android.ui.screens.shareDiagnosticLog
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOf
import java.util.UUID
import java.util.WeakHashMap

internal class ManagerPickerToolsAccounts(private val manager: VortXSyncManager) : PickerToolsAccounts {
    override val authorityRevision: Long get() = manager.pickerAuthorityRevision.value
    override val sessionMarker: Any get() = manager.sessionUiState.value
    override val changes: Flow<Unit> =
        combine(manager.pickerAuthorityRevision, manager.sessionUiState, manager.pickerFileRecoveryPaused) { _, _, _ -> }
    override fun capture(): PickerAccountSnapshot? = manager.capturePickerAccountSnapshot()
    override fun isCurrent(original: PickerAccountSnapshot): Boolean = manager.isPickerAccountCurrent(original)
    override suspend fun download(original: PickerAccountSnapshot): ByteArray = manager.downloadAccountBackupFile(original)
}
private object UnavailablePickerToolsAccounts : PickerToolsAccounts {
    override val authorityRevision = 0L
    override val sessionMarker: Any = Unit
    override val changes = flowOf(Unit)
    override fun capture(): PickerAccountSnapshot? = null
    override fun isCurrent(original: PickerAccountSnapshot) = false
    override suspend fun download(original: PickerAccountSnapshot): ByteArray = throw PickerToolsException(PickerToolsFailure.SAVE_FAILED)
}
private class SafPickerToolsBackup(val bytes: AccountBackupBytes,
    val kind: AccountBackupCopyKind = AccountBackupCopyKind.ACCOUNT) : PickerToolsPreparedBackup {
    override val byteCount get() = bytes.byteCount
    override val sha256 get() = bytes.sha256
    override fun close() = bytes.close()
    override fun toString() = "SafPickerToolsBackup"
}
private fun AccountFileRepairFailure.toPickerRefusal() = PickerToolsException(when (reason) {
    AccountFileRepairReason.BUSY -> PickerToolsFailure.REPAIR_BUSY
    AccountFileRepairReason.ALREADY_REPAIRED -> PickerToolsFailure.ALREADY_REPAIRED
    AccountFileRepairReason.OWNER_UNAVAILABLE -> PickerToolsFailure.REPAIR_OWNER_UNAVAILABLE
    AccountFileRepairReason.ACCOUNT_UNSUPPORTED -> PickerToolsFailure.REPAIR_ACCOUNT_UNSUPPORTED
    AccountFileRepairReason.EXPIRED -> PickerToolsFailure.REPAIR_EXPIRED
    AccountFileRepairReason.INVALID_FILE -> PickerToolsFailure.INVALID_REPAIR_FILE
})

private class SafRestoreInput(val uri: Uri) : PickerToolsRestoreInput {
    override fun toString() = "SafRestoreInput"
}

private class ManagerPickerToolsRestoreActions(
    private val documents: AccountBackupDocuments,
    private val manager: VortXSyncManager,
    private val external: AccountFileRestoreExternalExclusion,
) : PickerToolsRestoreActions {
    override fun canSelect(original: PickerToolsActionGrant): Boolean =
        original.original?.let(manager::isPickerFileRecoveryPaused) == true

    override suspend fun status(original: PickerToolsActionGrant, isCurrent: () -> Boolean) =
        manager.readAccountBackupFileRestoreStatus(checkNotNull(original.original), isCurrent)

    override suspend fun read(original: PickerToolsActionGrant, input: PickerToolsRestoreInput,
        isCurrent: () -> Boolean): PickerToolsRestoreCandidate {
        val uri = checkNotNull(input as? SafRestoreInput).uri
        val selection = PickerToolsRestoreSelection.read(documents, uri, manager, original, isCurrent)
        return object : PickerToolsRestoreCandidate {
            override val byteCount get() = selection.byteCount
            override suspend fun confirm() = selection.confirm(original, external)
            override fun close() = selection.close()
        }
    }

    override suspend fun verify(original: PickerToolsActionGrant, operationId: UUID, isCurrent: () -> Boolean) =
        manager.verifyAccountBackupFileRestore(checkNotNull(original.original), operationId, isCurrent)
}

/** Process-local gate shared by every activity holder using the exact application manager.
 * An active slot owns its manager through real return. An empty gate does not retain its key. */
private object ManagerPickerRecoveryGates {
    private val gates = WeakHashMap<VortXSyncManager, PickerToolsWorkGate>()
    fun forManager(manager: VortXSyncManager): PickerToolsWorkGate = synchronized(gates) {
        gates.getOrPut(manager) { PickerToolsWorkGate() }
    }
}

/** Activity-owned, ephemeral only. It retains neither an Activity nor any SavedStateHandle/Bundle. */
internal class ProfilePickerToolsViewModel private constructor(
    private val documents: AccountBackupDocuments?,
    createController: (ProfilePickerToolsViewModel) -> ProfilePickerToolsController,
) : ViewModel() {
    val controller = createController(this)
    val state get() = controller.state
    private val _restoreStatusOwner = MutableStateFlow<PickerAccountSnapshot?>(null)
    val restoreStatusOwner = _restoreStatusOwner.asStateFlow()

    fun openRestoreStatus(original: PickerAccountSnapshot) {
        _restoreStatusOwner.compareAndSet(null, original)
    }

    fun closeRestoreStatus(original: PickerAccountSnapshot) {
        if (_restoreStatusOwner.value !== original) return
        controller.retireRestoreStatusRoute(original)
        _restoreStatusOwner.compareAndSet(original, null)
    }

    constructor(manager: VortXSyncManager?, context: Context, workGate: PickerToolsWorkGate = PickerToolsWorkGate(),
        externalRestore: AccountFileRestoreExternalExclusion? = null) : this(
        AccountBackupDocuments(context.applicationContext),
        { model ->
            ProfilePickerToolsController(manager?.let(::ManagerPickerToolsAccounts) ?: UnavailablePickerToolsAccounts,
                PickerToolsBackupPreparer { bytes, current ->
                    SafPickerToolsBackup(checkNotNull(model.documents).prepare(bytes, current))
                }, model.viewModelScope, workGate, manager?.let { source ->
                    PickerToolsRepairPreparer { owner, bytes, current ->
                        val operation = try { source.prepareAccountBackupRepair(owner, bytes, current) }
                        catch (refusal: AccountFileRepairFailure) { throw refusal.toPickerRefusal() }
                        object : PickerToolsRepairExport {
                            override val profileCount get() = operation.profileCount
                            override val nativeSchema get() = operation.nativeSchema
                            override val byteCount get() = operation.byteCount
                            override val sha256 get() = operation.sha256
                            override fun remainingMillis() = operation.remainingMillis()
                            override fun canSave() = operation.canSave()
                            override fun take() = try { operation.take() }
                                catch (refusal: AccountFileRepairFailure) { throw refusal.toPickerRefusal() }
                            override fun close() = operation.close()
                        }
                    }
                }, restoreActions = if (manager != null && externalRestore != null)
                    ManagerPickerToolsRestoreActions(checkNotNull(model.documents), manager, externalRestore)
                else null, recoveryGate = manager?.let(ManagerPickerRecoveryGates::forManager) ?: PickerToolsWorkGate())
        },
    )
    /** Test collaborator replaces I/O/transport only; the actual controller and route/slot logic remain. */
    internal constructor(controller: ProfilePickerToolsController) : this(null, { controller })
    fun repairInputReturned(request: PickerToolsRepairInputRequest, uri: Uri?) {
        if (uri == null) { controller.repairInputRefused(request); return }
        controller.repairInputReturned(request) { current ->
            val provider = checkNotNull(documents)
            val source = provider.read(uri, current)
            object : PickerToolsSelectedBackup {
                override fun copyBytes() = source.copyBytes()
                override suspend fun prepareRepairedCopy(bytes: ByteArray, isCurrent: () -> Boolean) =
                    SafPickerToolsBackup(provider.prepareRepairedCopy(bytes, source, isCurrent), AccountBackupCopyKind.REPAIRED)
                override fun close() = source.close()
            }
        }
    }
    fun restoreInputReturned(request: PickerToolsRestoreInputRequest, uri: Uri?) {
        if (uri == null) controller.restoreInputRefused(request)
        else controller.restoreInputReturned(request, SafRestoreInput(uri))
    }
    fun destinationReturned(request: PickerToolsDestinationRequest, tree: Uri?) {
        if (tree == null) { controller.destinationRefused(request); return }
        controller.destinationReturned(request) { prepared, current ->
            val original = prepared as? SafPickerToolsBackup
                ?: throw PickerToolsException(PickerToolsFailure.WRONG_RECEIPT)
            val receipt = checkNotNull(documents).saveNewCopy(tree, original.bytes, kind = original.kind, isCurrent = current)
            PickerToolsSaveReceipt(receipt.byteCount, receipt.sha256)
        }
    }
    fun diagnostics(route: PickerToolsActionGrant, context: Context, requiredPolicy: () -> Boolean) {
        val applicationContext = context.applicationContext
        controller.diagnostics(route, requiredPolicy) { admission ->
            // Never use shareDiagnosticLog's permissive default on a picker route.
            shareDiagnosticLog(applicationContext, mayShare = admission)
        }
    }
    override fun onCleared() {
        controller.close()
        _restoreStatusOwner.value = null
        super.onCleared()
    }
}

internal class PickerToolsModelHolder : ViewModel() {
    private var current: VortXSyncManager? = null
    private var currentRestore: AccountFileRestoreExternalExclusion? = null
    private val workGate = PickerToolsWorkGate()
    private var store = ReplacingViewModelStoreOwner()
    fun model(manager: VortXSyncManager?, applicationContext: Context,
        externalRestore: AccountFileRestoreExternalExclusion? = null): ProfilePickerToolsViewModel {
        if (current !== manager || currentRestore !== externalRestore) {
            store.clear()
            store = ReplacingViewModelStoreOwner()
            current = manager
            currentRestore = externalRestore
        }
        return ViewModelProvider(store, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                ProfilePickerToolsViewModel(manager, applicationContext, workGate, externalRestore) as T
        })[ProfilePickerToolsViewModel::class.java]
    }
    override fun onCleared() { store.clear(); super.onCleared() }
}
@Composable
internal fun rememberPickerToolsModel(manager: VortXSyncManager?,
    externalRestore: AccountFileRestoreExternalExclusion? = null): ProfilePickerToolsViewModel {
    val applicationContext = LocalContext.current.applicationContext
    val holder: PickerToolsModelHolder = viewModel(key = "pre-profile-vortx-tools-holder", factory = remember {
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = PickerToolsModelHolder() as T
        }
    })
    return holder.model(manager, applicationContext, externalRestore)
}
